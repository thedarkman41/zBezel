// BezelAgent — a thin DDC/CI proxy for a monitor attached to this Windows machine.
//
// Exists because a Mac whose video path runs through a dock cannot reach the
// monitor's DDC/CI address: the dock's DP branch chip proxies EDID but refuses
// MCCS. This machine has the monitor on USB-C directly, so its AUX channel
// terminates at the panel and the Windows Monitor Configuration API works.
//
// Speaks line-oriented JSON on stdout so it can be driven over SSH.
//
//   BezelAgent list
//   BezelAgent caps  <index>
//   BezelAgent get   <index> <vcpHex> [vcpHex ...]
//   BezelAgent set   <index> <vcpHex> <value>
//   BezelAgent probe <index>            -- read every code the monitor declares

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

internal static class BezelAgent
{
    // ---- Win32 ------------------------------------------------------------

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int left, top, right, bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PHYSICAL_MONITOR
    {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    private delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT rect, IntPtr data);

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX info);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplayDevices(string device, uint index, ref DISPLAY_DEVICE info, uint flags);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, ref uint count);
    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint count, [Out] PHYSICAL_MONITOR[] monitors);
    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool DestroyPhysicalMonitors(uint count, [In] PHYSICAL_MONITOR[] monitors);
    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, out uint type,
                                                               out uint current, out uint maximum);
    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool SetVCPFeature(IntPtr h, byte code, uint value);
    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetCapabilitiesStringLength(IntPtr h, out uint length);
    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr h, StringBuilder buffer, uint length);

    // ---- Monitor discovery -------------------------------------------------

    private sealed class Target
    {
        public int Index;
        public IntPtr Handle;
        public string Description = "";
        public string Device = "";
        public string DeviceID = "";
    }

    // Handles handed out by GetPhysicalMonitorsFromHMONITOR must be returned with
    // DestroyPhysicalMonitors, or a long-running service slowly leaks them.
    private static readonly List<PHYSICAL_MONITOR[]> Owned = new List<PHYSICAL_MONITOR[]>();

    private static void ReleaseAll()
    {
        foreach (var array in Owned)
        {
            try { DestroyPhysicalMonitors((uint)array.Length, array); }
            catch (Exception e)
            {
                // Teardown continues regardless, but a handle that will not close
                // is worth knowing about rather than discarding in silence.
                Console.Error.WriteLine("DestroyPhysicalMonitors failed: " + e.Message);
            }
        }
        Owned.Clear();
    }

    private static List<Target> Enumerate()
    {
        ReleaseAll();
        var targets = new List<Target>();
        var handles = new List<IntPtr>();

        MonitorEnumProc collect = (IntPtr hMonitor, IntPtr hdc, ref RECT r, IntPtr d) =>
        {
            handles.Add(hMonitor);
            return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, collect, IntPtr.Zero);

        foreach (var hMonitor in handles)
        {
            var info = new MONITORINFOEX();
            info.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            string device = GetMonitorInfo(hMonitor, ref info) ? info.szDevice : "";

            string deviceID = "";
            var dd = new DISPLAY_DEVICE();
            dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (device.Length > 0 && EnumDisplayDevices(device, 0, ref dd, 0x00000001))
                deviceID = dd.DeviceID;

            uint count = 0;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMonitor, ref count) || count == 0) continue;

            var physical = new PHYSICAL_MONITOR[count];
            if (!GetPhysicalMonitorsFromHMONITOR(hMonitor, count, physical)) continue;
            Owned.Add(physical);

            foreach (var pm in physical)
            {
                targets.Add(new Target
                {
                    Index = targets.Count,
                    Handle = pm.hPhysicalMonitor,
                    Description = pm.szPhysicalMonitorDescription ?? "",
                    Device = device,
                    DeviceID = deviceID,
                });
            }
        }
        return targets;
    }

    /// Enumeration returns nothing while the monitor is mid-hotplug, and changing
    /// a setting like DisplayPort version makes the panel re-enumerate. Treating
    /// that momentary gap as failure loses the very transition being measured, so
    /// wait for the monitor to come back instead.
    // Link telemetry for the current request. A reading taken while the monitor
    // is re-enumerating is not wrong so much as meaningless, and the caller has
    // no way to tell that apart from a genuine value unless we say so.
    private static int enumAttempts;
    private static int readFailures;
    private static int readSuccesses;

    private static List<Target> EnumerateSettled(int attempts = 10, int delayMs = 600)
    {
        for (int i = 0; i < attempts; i++)
        {
            var found = Enumerate();
            enumAttempts = i + 1;
            if (found.Count > 0) return found;
            System.Threading.Thread.Sleep(delayMs);
        }
        enumAttempts = attempts;
        return new List<Target>();
    }

    /// How much the caller should trust everything else in this response.
    ///   absent        - nothing enumerated; the monitor is not there
    ///   renegotiating - it came back only after retrying, or reads are failing
    ///                   alongside ones that work: a link event is in progress
    ///   degraded      - enumerated first time, but some reads still failed
    ///   active        - clean
    private static string LinkState(int monitorCount)
    {
        if (monitorCount == 0) return "absent";
        if (enumAttempts > 1) return "renegotiating";
        if (readFailures > 0 && readSuccesses > 0) return "degraded";
        if (readFailures > 0 && readSuccesses == 0) return "renegotiating";
        return "active";
    }

    private static string LinkFields(int monitorCount)
    {
        return "\"link\":\"" + LinkState(monitorCount) + "\""
             + ",\"stable\":" + (LinkState(monitorCount) == "active" ? "true" : "false")
             + ",\"enumAttempts\":" + enumAttempts
             + ",\"readFailures\":" + readFailures;
    }

    private static List<Target> targetsCache;
    private static DateTime targetsCachedAt = DateTime.MinValue;

    /// Enumeration is expensive — GetPhysicalMonitorsFromHMONITOR probes the
    /// display and costs seconds — so reuse the handles for a short while.
    /// They go stale when the monitor re-enumerates, which is why every caller
    /// can force a refresh and why a request that reads nothing successfully
    /// retries once with fresh handles.
    private static List<Target> Targets(bool refresh)
    {
        if (!refresh && targetsCache != null && targetsCache.Count > 0
            && (DateTime.UtcNow - targetsCachedAt).TotalSeconds < 20)
        {
            enumAttempts = 0;              // served from cache
            return targetsCache;
        }
        targetsCache = EnumerateSettled();
        targetsCachedAt = DateTime.UtcNow;
        return targetsCache;
    }


    /// The single place a command name maps to its handler.
    ///
    /// This existed in three copies — the CLI path, the service dispatcher, and
    /// the stale-handle retry — and they had already drifted: `setget` was in
    /// only one, so it could not be run from the command line and silently lost
    /// the retry it needs most, being the command issued during a hotplug.
    /// Returns false for an unrecognised command so each caller can report it in
    /// its own format.
    private static bool RunCommand(List<Target> targets, string[] args)
    {
        switch (args[0].ToLowerInvariant())
        {
            case "health":
                Console.WriteLine("{\"ok\":true,\"monitors\":" + targets.Count + ","
                                  + LinkFields(targets.Count) + "}");
                return true;
            case "list":   CmdList(targets);         return true;
            case "caps":   CmdCaps(targets, args);   return true;
            case "get":    CmdGet(targets, args);    return true;
            case "setget": CmdSetGet(targets, args); return true;
            case "set":    CmdSet(targets, args);    return true;
            case "probe":  CmdProbe(targets, args);  return true;
            default:       return false;
        }
    }

    private static Target Pick(List<Target> targets, string arg)
    {
        int index;
        if (!int.TryParse(arg, out index) || index < 0 || index >= targets.Count)
            throw new ArgumentException("no monitor at index " + arg);
        return targets[index];
    }

    // ---- JSON --------------------------------------------------------------

    private static string Esc(string s)
    {
        if (s == null) return "";
        var sb = new StringBuilder();
        foreach (char c in s)
        {
            switch (c)
            {
                case '"':  sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n");  break;
                case '\r': sb.Append("\\r");  break;
                case '\t': sb.Append("\\t");  break;
                default:
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    /// True while running as the long-lived service.
    private static bool servingRequests;

    /// Report a failure. In one-shot CLI use this ends the process; inside the
    /// service it must NOT, because Fail is reachable from ordinary command
    /// paths — a SetVCPFeature that returns false, or a capabilities read
    /// against a sleeping panel — and exiting there took the agent down until
    /// the next logon. The scheduled task cannot restart it either: its action
    /// is wscript.exe, which returns immediately, so Task Scheduler sees a task
    /// that already succeeded.
    private static void Fail(string message)
    {
        Console.WriteLine("{\"ok\":false,\"error\":\"" + Esc(message) + "\"}");
        if (!servingRequests) Environment.Exit(1);
    }

    private static byte ParseCode(string s)
    {
        s = s.Trim();
        if (s.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) s = s.Substring(2);
        return byte.Parse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
    }

    // ---- Commands ----------------------------------------------------------

    private static int Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;
        if (args.Length == 0) { Fail("usage: BezelAgent list|caps|get|set|probe"); return 1; }

        // serve/client/relay never touch a monitor themselves, and the client runs
        // in session 0 where there are never any monitors — so enumerating first
        // made every relayed call wait out the full hotplug patience (six seconds)
        // for a result it then discarded.
        switch (args[0].ToLowerInvariant())
        {
            case "serve":  return CmdServe(args);
            case "client": return CmdClient(args);
            case "relay":  return CmdRelay(args);
        }

        List<Target> targets;
        try { targets = Targets(refresh: false); }
        catch (Exception e) { Fail("enumeration failed: " + e.Message); return 1; }

        try
        {
            if (!RunCommand(targets, args)) { Fail("unknown command: " + args[0]); return 1; }
            return 0;
        }
        catch (Exception e)
        {
            Fail(e.Message);
            return 1;
        }
    }

    private static int CmdList(List<Target> targets)
    {
        var sb = new StringBuilder();
        sb.Append("{\"ok\":true,\"monitors\":[");
        for (int i = 0; i < targets.Count; i++)
        {
            var t = targets[i];
            if (i > 0) sb.Append(',');
            sb.Append("{\"index\":").Append(t.Index)
              .Append(",\"description\":\"").Append(Esc(t.Description))
              .Append("\",\"device\":\"").Append(Esc(t.Device))
              .Append("\",\"deviceId\":\"").Append(Esc(t.DeviceID))
              .Append("\"}");
        }
        sb.Append("]}");
        Console.WriteLine(sb.ToString());
        return 0;
    }

    private static int CmdCaps(List<Target> targets, string[] args)
    {
        if (args.Length < 2) { Fail("caps needs a monitor index"); return 1; }
        var t = Pick(targets, args[1]);

        uint length;
        if (!GetCapabilitiesStringLength(t.Handle, out length) || length == 0)
        {
            Fail("monitor did not return a capabilities string (win32 error " +
                 Marshal.GetLastWin32Error() + ")");
            return 1;
        }
        var buffer = new StringBuilder((int)length + 1);
        if (!CapabilitiesRequestAndCapabilitiesReply(t.Handle, buffer, length))
        {
            Fail("capabilities read failed (win32 error " + Marshal.GetLastWin32Error() + ")");
            return 1;
        }
        Console.WriteLine("{\"ok\":true,\"capabilities\":\"" + Esc(buffer.ToString()) + "\"}");
        return 0;
    }

    private static string ReadOne(Target t, byte code)
    {
        int lastError = 0;
        for (int attempt = 0; attempt < 2; attempt++)
        {
            uint type, current, maximum;
            if (GetVCPFeatureAndVCPFeatureReply(t.Handle, code, out type, out current, out maximum))
            {
                readSuccesses++;
                return "{\"code\":" + code + ",\"ok\":true,\"current\":" + current +
                       ",\"maximum\":" + maximum + ",\"type\":" + type + "}";
            }
            lastError = Marshal.GetLastWin32Error();
            if (attempt == 1) readFailures++;   // count the code, not each retry
            // A code the monitor simply does not implement fails the same way every
            // time; only a communication failure is worth retrying.
            System.Threading.Thread.Sleep(50);
        }
        return "{\"code\":" + code + ",\"ok\":false,\"error\":" + lastError + "}";
    }

    private static int CmdGet(List<Target> targets, string[] args)
    {
        if (args.Length < 3) { Fail("get needs an index and at least one VCP code"); return 1; }
        var t = Pick(targets, args[1]);

        var sb = new StringBuilder();
        sb.Append("{\"ok\":true,\"values\":[");
        for (int i = 2; i < args.Length; i++)
        {
            if (i > 2) sb.Append(',');
            sb.Append(ReadOne(t, ParseCode(args[i])));
        }
        sb.Append("],").Append(LinkFields(1)).Append('}');
        Console.WriteLine(sb.ToString());
        return 0;
    }

    private static int CmdSet(List<Target> targets, string[] args)
    {
        if (args.Length < 4) { Fail("set needs an index, a VCP code and a value"); return 1; }
        var t = Pick(targets, args[1]);
        byte code = ParseCode(args[2]);
        uint value = uint.Parse(args[3], CultureInfo.InvariantCulture);

        if (!SetVCPFeature(t.Handle, code, value))
        {
            Fail("set failed (win32 error " + Marshal.GetLastWin32Error() + ")");
            return 1;
        }
        System.Threading.Thread.Sleep(60);
        Console.WriteLine("{\"ok\":true,\"wrote\":" + ReadOne(t, code) + ","
                          + LinkFields(1) + "}");
        return 0;
    }

    /// Write one code and read several back in a single request.
    /// Each round trip to this machine costs seconds, so a UI action that used to
    /// be write-then-confirm-then-refresh is now one call.
    ///   setget <index> <vcpHex> <value> [readCodeHex ...]
    private static int CmdSetGet(List<Target> targets, string[] args)
    {
        if (args.Length < 4) { Fail("setget needs an index, a code, a value and codes to read"); return 1; }
        var t = Pick(targets, args[1]);
        byte code = ParseCode(args[2]);
        uint value = uint.Parse(args[3], CultureInfo.InvariantCulture);

        bool wrote = SetVCPFeature(t.Handle, code, value);
        System.Threading.Thread.Sleep(80);

        var sb = new StringBuilder();
        sb.Append("{\"ok\":true,\"wrote\":").Append(wrote ? "true" : "false").Append(",\"values\":[");
        for (int i = 4; i < args.Length; i++)
        {
            if (i > 4) sb.Append(',');
            sb.Append(ReadOne(t, ParseCode(args[i])));
        }
        sb.Append("],").Append(LinkFields(1)).Append('}');
        Console.WriteLine(sb.ToString());
        return 0;
    }


    // Read every code the monitor declares in its capabilities string.
    private static int CmdProbe(List<Target> targets, string[] args)
    {
        if (args.Length < 2) { Fail("probe needs a monitor index"); return 1; }
        var t = Pick(targets, args[1]);

        string caps = "";
        uint length;
        if (GetCapabilitiesStringLength(t.Handle, out length) && length > 0)
        {
            var buffer = new StringBuilder((int)length + 1);
            if (CapabilitiesRequestAndCapabilitiesReply(t.Handle, buffer, length))
                caps = buffer.ToString();
        }

        var codes = ExtractVcpCodes(caps);
        var sb = new StringBuilder();
        sb.Append("{\"ok\":true,\"capabilities\":\"").Append(Esc(caps)).Append("\",\"values\":[");
        bool first = true;
        foreach (var code in codes)
        {
            if (!first) sb.Append(',');
            first = false;
            sb.Append(ReadOne(t, code));
        }
        sb.Append("]}");
        Console.WriteLine(sb.ToString());
        return 0;
    }

    /// Pull the code list out of the vcp(...) section, ignoring nested value lists.
    private static List<byte> ExtractVcpCodes(string caps)
    {
        var result = new List<byte>();
        int start = caps.IndexOf("vcp(", StringComparison.OrdinalIgnoreCase);
        if (start < 0) return result;
        start += 4;

        int depth = 1, i = start;
        var token = new StringBuilder();
        while (i < caps.Length && depth > 0)
        {
            char c = caps[i];
            if (c == '(')
            {
                // The token immediately before '(' is a code that carries a value
                // list, so flush it before descending — otherwise every code with
                // enumerated values is silently dropped.
                if (depth == 1) Flush(token, result);
                token.Length = 0;
                depth++;
            }
            else if (c == ')')
            {
                if (depth == 1) Flush(token, result);
                token.Length = 0;
                depth--;
            }
            else if (depth == 1)
            {
                if (Uri.IsHexDigit(c)) token.Append(c);
                else { Flush(token, result); token.Length = 0; }
            }
            i++;
        }
        Flush(token, result);
        return result;
    }

    private static void Flush(StringBuilder token, List<byte> result)
    {
        if (token.Length == 0) return;
        byte b;
        if (byte.TryParse(token.ToString(), NumberStyles.HexNumber,
                          CultureInfo.InvariantCulture, out b) && !result.Contains(b))
            result.Add(b);
    }

    // ---- Persistent service ------------------------------------------------
    //
    // The Monitor Configuration API only works from the interactive desktop
    // session, so this process is started there by a logon scheduled task. It
    // listens on loopback and speaks one tab-separated command per line,
    // answering with one line of JSON. `client` is the other half, invoked over
    // SSH from the Mac: SSH lands in session 0, but loopback still reaches here.

    private const int DefaultPort = 9110;

    private static int PortFrom(string[] args, int position)
    {
        int port;
        if (args.Length > position && int.TryParse(args[position], out port)) return port;
        return DefaultPort;
    }

    private static int CmdServe(string[] args)
    {
        int port = PortFrom(args, 1);
        servingRequests = true;
        var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, port);
        listener.Start();
        Console.WriteLine("{\"ok\":true,\"listening\":" + port + "}");
        Console.Out.Flush();

        while (true)
        {
            try
            {
                using (var client = listener.AcceptTcpClient())
                using (var stream = client.GetStream())
                using (var reader = new System.IO.StreamReader(stream, Encoding.UTF8))
                using (var writer = new System.IO.StreamWriter(stream, new UTF8Encoding(false)))
                {
                    client.ReceiveTimeout = 300000;
                    client.SendTimeout = 300000;
                    string line = reader.ReadLine();
                    if (line == null) continue;

                    string response;
                    try { response = Dispatch(line.Split('\t')); }
                    catch (Exception e) { response = "{\"ok\":false,\"error\":\"" + Esc(e.Message) + "\"}"; }

                    writer.WriteLine(response);
                    writer.Flush();
                }
            }
            catch (Exception)
            {
                // One bad connection must not take the service down.
            }
        }
    }

    /// Runs a command and returns the JSON it would have printed.
    private static string Dispatch(string[] args)
    {
        if (args.Length == 0) return "{\"ok\":false,\"error\":\"empty command\"}";

        var previous = Console.Out;
        var buffer = new System.IO.StringWriter();
        Console.SetOut(buffer);
        enumAttempts = 0; readFailures = 0; readSuccesses = 0;
        try
        {
            var targets = Targets(refresh: false);
            if (!RunCommand(targets, args))
                Console.WriteLine("{\"ok\":false,\"error\":\"unknown command\"}");
        }
        finally
        {
            Console.SetOut(previous);
        }

        // Everything failed: the cached handles are probably stale after a
        // hotplug. Re-enumerate and try the whole command once more.
        if (readFailures > 0 && readSuccesses == 0)
        {
            var retryOut = new System.IO.StringWriter();
            Console.SetOut(retryOut);
            readFailures = 0; readSuccesses = 0;
            try
            {
                var fresh = Targets(refresh: true);
                RunCommand(fresh, args);
            }
            catch (Exception e)
            {
                // The retry is best-effort, but a silent swallow here hides the
                // reason the first attempt failed as well as the second.
                Console.Error.WriteLine("retry after stale handles failed: " + e.Message);
            }
            finally { Console.SetOut(previous); }
            var retried = retryOut.ToString().Trim();
            if (retried.Length > 0) return retried;
        }

        return buffer.ToString().Trim();
    }

    private static int CmdClient(string[] args)
    {
        int port = DefaultPort;
        var payload = new List<string>();
        for (int i = 1; i < args.Length; i++)
        {
            if (args[i] == "--port" && i + 1 < args.Length) { port = int.Parse(args[++i]); continue; }
            payload.Add(args[i]);
        }
        if (payload.Count == 0) { Fail("client needs a command"); return 1; }

        try
        {
            using (var client = new System.Net.Sockets.TcpClient())
            {
                client.Connect(System.Net.IPAddress.Loopback, port);
                client.ReceiveTimeout = 300000;
                client.SendTimeout = 300000;
                using (var stream = client.GetStream())
                using (var writer = new System.IO.StreamWriter(stream, new UTF8Encoding(false)))
                using (var reader = new System.IO.StreamReader(stream, Encoding.UTF8))
                {
                    writer.WriteLine(string.Join("\t", payload.ToArray()));
                    writer.Flush();
                    string reply = reader.ReadLine();
                    Console.WriteLine(reply ?? "{\"ok\":false,\"error\":\"no reply from service\"}");
                }
            }
            return 0;
        }
        catch (Exception e)
        {
            Fail("cannot reach the Bezel service on 127.0.0.1:" + port + " (" + e.Message + ")");
            return 1;
        }
    }

    // ---- Relay -------------------------------------------------------------
    //
    // Starting a process over SSH costs the better part of a second, almost all
    // of it PowerShell login-shell startup. The Mac therefore opens ONE ssh
    // channel running this, then streams one command per line down it. Each
    // command is forwarded to the interactive-session service over loopback,
    // which costs about a millisecond.

    private static string SendToService(string command, int port)
    {
        using (var client = new System.Net.Sockets.TcpClient())
        {
            client.Connect(System.Net.IPAddress.Loopback, port);
            client.ReceiveTimeout = 20000;
            client.SendTimeout = 20000;
            using (var stream = client.GetStream())
            using (var writer = new System.IO.StreamWriter(stream, new UTF8Encoding(false)))
            using (var reader = new System.IO.StreamReader(stream, Encoding.UTF8))
            {
                writer.WriteLine(command);
                writer.Flush();
                return reader.ReadLine() ?? "{\"ok\":false,\"error\":\"no reply from service\"}";
            }
        }
    }

    private static int CmdRelay(string[] args)
    {
        int port = DefaultPort;
        for (int i = 1; i < args.Length; i++)
            if (args[i] == "--port" && i + 1 < args.Length) port = int.Parse(args[++i]);

        Console.WriteLine("{\"ok\":true,\"relay\":\"ready\",\"port\":" + port + "}");
        Console.Out.Flush();

        string line;
        while ((line = Console.ReadLine()) != null)
        {
            if (line.Trim().Length == 0) continue;
            string reply;
            try { reply = SendToService(line, port); }
            catch (Exception e)
            {
                reply = "{\"ok\":false,\"error\":\"" + Esc(e.Message) + "\"}";
            }
            Console.WriteLine(reply);
            Console.Out.Flush();
        }
        return 0;
    }
}
