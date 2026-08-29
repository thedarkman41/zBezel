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
//
// It also carries the KVM receiver: `serve` accepts pointer and keyboard events
// on a named pipe and replays them here, so the Mac can drive this machine once
// the pointer crosses its screen edge. See "Input injection" below.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
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
            case "cursor":   CmdCursor();            return true;
            case "keystate": CmdKeyState();          return true;
            case "clip":     CmdClip();              return true;
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

    /// Append a line to %USERPROFILE%\bezel\agent.log.
    ///
    /// Serve mode is started by install-service.ps1 registering wscript.exe
    /// against start-hidden.vbs, which does `shell.Run "<exe> serve", 0, False`
    /// — window hidden, nothing redirected anywhere. So Console.Error from the
    /// running agent goes precisely nowhere, and until now a failure inside it
    /// left no trace of any kind: no console, no file, no event. That is
    /// tolerable for a request/response command that reports its own errors up
    /// the socket, and not tolerable for the KVM receiver, which runs unattended
    /// for hours and has no caller waiting on a reply to complain to.
    private static readonly object LogLock = new object();

    private static void Log(string message)
    {
        try
        {
            string dir = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "bezel");
            System.IO.Directory.CreateDirectory(dir);
            string path = System.IO.Path.Combine(dir, "agent.log");
            lock (LogLock)
            {
                // Bounded, and history is not the point — this exists to answer
                // "what is it doing right now", so truncating the old half is
                // better than growing without limit on a machine nobody watches.
                var info = new System.IO.FileInfo(path);
                if (info.Exists && info.Length > 256 * 1024) info.Delete();

                // TWO processes write here — the session-1 service and the
                // session-0 relay — and File.AppendAllText opens for exclusive
                // write, so simultaneous writes throw a sharing violation that
                // the catch below would swallow. Lines were being lost exactly
                // when both ends were busy, which is exactly when the log is
                // being read. Share the handle and retry briefly instead.
                string stamped = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff",
                                                       CultureInfo.InvariantCulture)
                                 + "  " + message + Environment.NewLine;
                byte[] bytes = Encoding.UTF8.GetBytes(stamped);
                for (int attempt = 0; attempt < 12; attempt++)
                {
                    try
                    {
                        using (var file = new System.IO.FileStream(
                                   path, System.IO.FileMode.Append,
                                   System.IO.FileAccess.Write,
                                   System.IO.FileShare.ReadWrite))
                        {
                            file.Write(bytes, 0, bytes.Length);
                        }
                        break;
                    }
                    catch (System.IO.IOException)
                    {
                        System.Threading.Thread.Sleep(15);   // the other process has it
                    }
                }
            }
        }
        catch (Exception)
        {
            // Deliberately swallowed, and the one place in this file where that
            // is right: the logger is the thing you would report a failure to.
        }
    }

    private static byte ParseCode(string s)
    {
        s = s.Trim();
        if (s.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) s = s.Substring(2);
        return byte.Parse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
    }

    // ---- Commands ----------------------------------------------------------

    [DllImport("user32.dll")]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    private static readonly IntPtr PerMonitorAwareV2 = new IntPtr(-4);

    /// Ask Windows for real pixels.
    ///
    /// A DPI-unaware process is lied to for its own good: on this machine the
    /// desktop is 3840x2160 at 150%, and GetSystemMetrics answered 2560x1440 —
    /// the virtualised size — while GetCursorPos returned virtualised
    /// coordinates to match. That is coherent but useless here, because the Mac
    /// is going to send absolute pixel positions and they have to mean the same
    /// thing at both ends. Without this the pointer lands two thirds of the way
    /// to where it was asked to go, and only on scaled displays, which is the
    /// kind of bug that survives a long time.
    ///
    /// Per-monitor v2 where it exists (Windows 10 1703+), falling back to the
    /// old system-wide call, which is enough for a machine whose displays share
    /// a scale factor.
    private static void MakeDpiAware()
    {
        try { if (SetProcessDpiAwarenessContext(PerMonitorAwareV2)) return; }
        catch (EntryPointNotFoundException) { /* pre-1703; fall through */ }
        try { SetProcessDPIAware(); }
        catch (EntryPointNotFoundException) { /* pre-Vista; nothing to do */ }
    }

    private static int Main(string[] args)
    {
        // Before anything reads a coordinate or a metric.
        MakeDpiAware();
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
            case "kvm":       return CmdKvm();
            case "clipboard": return CmdClipboard();
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

    // ---- Input injection ---------------------------------------------------
    //
    // The KVM receiver. When the pointer leaves the right edge of the Mac's
    // screen, the Mac stops handling its own input and streams it here instead;
    // these functions replay it with SendInput so it lands in the console
    // session as though it came from the local keyboard and mouse.
    //
    // Two things decide the shape of this.
    //
    // SendInput only reaches the desktop of the session it is called from, so it
    // has to run on the session-1 service. An SSH process lands in session 0 and
    // has no desktop at all, which is the same constraint that put the DDC
    // commands behind a loopback relay in the first place.
    //
    // And it deliberately does NOT ride that loopback TCP socket. Any local
    // process, running as any user, can connect to 127.0.0.1 — a socket that
    // sets monitor brightness and a socket that types into the console session
    // are very different propositions, and the second one is why the earlier
    // `inject` command was deleted rather than fixed. This uses a named pipe
    // whose DACL names exactly one account: the one already running the
    // interactive session. That account can synthesise its own input anyway, so
    // nothing new is granted and no privilege boundary is crossed; every other
    // account, including another user logged on at the same time, is refused by
    // the kernel before a byte is read.

    private const string InputPipeName  = "BezelAgentInput";   // pointer + keys, Mac -> PC
    private const string ClipInPipeName = "BezelAgentClipIn";  // clipboard,     Mac -> PC
    private const string BackPipeName   = "BezelAgentBack";    // clipboard,     PC -> Mac

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadFile(IntPtr handle, byte[] buffer, uint toRead,
                                        out uint read, IntPtr overlapped);

    private const int STD_INPUT_HANDLE = -10;
    private const int ERROR_BROKEN_PIPE = 109;

    /// Read newline-delimited lines from stdin, via ReadFile rather than Console.
    ///
    /// Console.ReadLine() cannot be used here, and neither can a StreamReader
    /// over Console.OpenStandardInput(). When stdin is the pipe SSH provides,
    /// both return the FIRST line and then block forever on the next read, even
    /// though more data is arriving and the writer is still open. No exception,
    /// no EOF — the process simply stops seeing its own input.
    ///
    /// That was worth pinning down precisely, because it looks exactly like a
    /// transport fault and sent the investigation to entirely the wrong places.
    /// It is not SSH, the shell, or PowerShell's call operator: `findstr` reads
    /// the same stream incrementally without trouble through the identical
    /// command, and so does this, once the .NET console layer is out of the way.
    /// A three-line-apart test read one line via Console and all three via
    /// ReadFile.
    ///
    /// ERROR_BROKEN_PIPE is how a closed stdin reports itself here, and is the
    /// normal way this ends rather than a fault worth logging.
    private static IEnumerable<string> StdinLines()
    {
        IntPtr handle = GetStdHandle(STD_INPUT_HANDLE);
        var buffer = new byte[4096];
        var pending = new StringBuilder();

        while (true)
        {
            uint read;
            if (!ReadFile(handle, buffer, (uint)buffer.Length, out read, IntPtr.Zero))
            {
                int error = Marshal.GetLastWin32Error();
                if (error != ERROR_BROKEN_PIPE) Log("stdin ReadFile failed win32=" + error);
                yield break;
            }
            if (read == 0) yield break;                    // clean end of stream

            pending.Append(Encoding.UTF8.GetString(buffer, 0, (int)read));
            while (true)
            {
                string buffered = pending.ToString();
                int newline = buffered.IndexOf('\n');
                if (newline < 0) break;
                string line = buffered.Substring(0, newline).TrimEnd('\r');
                pending.Remove(0, newline + 1);
                yield return line;
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx, dy;
        public uint mouseData, dwFlags, time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk, wScan;
        public uint dwFlags, time;
        public IntPtr dwExtraInfo;
    }

    // INPUT is a tagged union. On x64 the union aligns to 8 because it contains
    // a pointer, so the struct is 40 bytes with 4 of padding after `type`;
    // Marshal.SizeOf works that out, which is why SendInput is handed it rather
    // than a hard-coded size.
    [StructLayout(LayoutKind.Explicit)]
    private struct INPUTUNION
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public INPUTUNION u;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, INPUT[] inputs, int size);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetThreadDesktop(IntPtr desktop);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetThreadDesktop(uint threadId);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool GetUserObjectInformation(IntPtr obj, int index,
        StringBuilder info, uint length, out uint needed);
    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetProcessWindowStation();

    private const int UOI_NAME = 2;
    private const uint MAXIMUM_ALLOWED = 0x02000000;

    private static string DesktopName(IntPtr desktop)
    {
        if (desktop == IntPtr.Zero) return "(none)";
        var name = new StringBuilder(256);
        uint needed;
        return GetUserObjectInformation(desktop, UOI_NAME, name, 256, out needed)
             ? name.ToString() : "(unreadable)";
    }

    /// Point this thread at whatever desktop is currently receiving input.
    ///
    /// SendInput delivers to the desktop of the CALLING THREAD, and it reports
    /// success either way — a process attached to the wrong desktop injects
    /// perfectly valid events into a desktop nobody is looking at, and the only
    /// symptom is that nothing happens. The agent is started by a logon
    /// scheduled task, which is exactly the situation where the thread can end
    /// up somewhere other than the visible desktop.
    ///
    /// This must run on the thread that will call SendInput, which is why it is
    /// at the top of the pipe loop rather than in Main.
    private static void AttachToInputDesktop()
    {
        // The window station matters as much as the desktop and is easy to miss:
        // EVERY window station has a desktop called "Default", so a process
        // stranded on a non-interactive station reports exactly the same desktop
        // name as one doing it right. Only WinSta0 is attached to the physical
        // input, so log the station before concluding anything from the desktop.
        Log("station=\"" + DesktopName(GetProcessWindowStation())
            + "\" desktop=\"" + DesktopName(GetThreadDesktop(GetCurrentThreadId())) + "\"");

        string before = DesktopName(GetThreadDesktop(GetCurrentThreadId()));
        IntPtr input = OpenInputDesktop(0, true, MAXIMUM_ALLOWED);
        if (input == IntPtr.Zero)
        {
            Log("OpenInputDesktop failed (win32 " + Marshal.GetLastWin32Error()
                + "); staying on desktop \"" + before + "\"");
            return;
        }
        if (!SetThreadDesktop(input))
        {
            Log("SetThreadDesktop failed (win32 " + Marshal.GetLastWin32Error()
                + "); staying on desktop \"" + before + "\"");
            return;
        }
        Log("input desktop: \"" + before + "\" -> \"" + DesktopName(input) + "\"");
    }

    private const uint InputMouse = 0, InputKeyboard = 1;
    private const uint MouseMove       = 0x0001,
                       MouseLeftDown   = 0x0002, MouseLeftUp   = 0x0004,
                       MouseRightDown  = 0x0008, MouseRightUp  = 0x0010,
                       MouseMiddleDown = 0x0020, MouseMiddleUp = 0x0040,
                       MouseWheel      = 0x0800, MouseHWheel   = 0x1000,
                       MouseVirtualDesk = 0x4000, MouseAbsolute = 0x8000;
    private const uint KeyUp = 0x0002, KeyUnicode = 0x0004;

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int x, y; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetCursorPos(out POINT point);

    [StructLayout(LayoutKind.Sequential)]
    private struct CURSORINFO
    {
        public int cbSize;
        public int flags;
        public IntPtr hCursor;
        public POINT ptScreenPos;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetCursorInfo(ref CURSORINFO info);

    // 0 hidden, 1 CURSOR_SHOWING, 2 CURSOR_SUPPRESSED.
    //
    // Suppression is the interesting one: Windows sets it when the machine has
    // no active pointing device — common on a laptop being driven remotely —
    // and while it is set the cursor is parked and position calls are refused.
    private static int CursorFlags()
    {
        var info = new CURSORINFO();
        info.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
        return GetCursorInfo(ref info) ? info.flags : -1;
    }
    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    private const int SM_XVIRTUALSCREEN  = 76, SM_YVIRTUALSCREEN  = 77,
                      SM_CXVIRTUALSCREEN = 78, SM_CYVIRTUALSCREEN = 79;

    /// Where the pointer is, and the bounds it may occupy.
    ///
    /// The Mac needs both. It has handed the pointer over and is no longer being
    /// told where it went, so the only way to know the pointer has reached this
    /// machine's left edge — the signal to hand control back — is to ask. The
    /// virtual-screen rectangle is what "left edge" means when this machine has
    /// more than one display, and it can be negative on a multi-monitor layout,
    /// which is why it is reported rather than assumed to start at zero.
    ///
    /// Answered from the session-1 service, so it is the console session's
    /// pointer. Asked over SSH directly it would report session 0's, which has a
    /// desktop nobody can see and a cursor that never moves.
    private static int CmdCursor()
    {
        POINT p;
        if (!GetCursorPos(out p))
        {
            Fail("GetCursorPos failed (win32 error " + Marshal.GetLastWin32Error() + ")");
            return 1;
        }
        Console.WriteLine("{\"ok\":true,\"x\":" + p.x + ",\"y\":" + p.y
            + ",\"cursorFlags\":" + CursorFlags()
            + ",\"virtual\":{\"x\":" + GetSystemMetrics(SM_XVIRTUALSCREEN)
            + ",\"y\":" + GetSystemMetrics(SM_YVIRTUALSCREEN)
            + ",\"w\":" + GetSystemMetrics(SM_CXVIRTUALSCREEN)
            + ",\"h\":" + GetSystemMetrics(SM_CYVIRTUALSCREEN) + "}}");
        return 0;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    private static extern short GetKeyState(int vk);
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vk);

    /// Toggle and modifier state.
    ///
    /// Two uses. It answers "did a keystroke actually land" without needing
    /// anything on screen to type into — Caps Lock is observable, reversible and
    /// harmless. And a KVM leaves modifiers stuck when control is handed over
    /// mid-chord: press Shift on the Mac, cross the edge, release it, and the
    /// far machine never hears the release and behaves as though Shift is held
    /// forever. Being able to read the state is the first half of fixing that.
    private static int CmdKeyState()
    {
        Console.WriteLine("{\"ok\":true"
            + ",\"caps\":"   + ((GetKeyState(0x14) & 1) != 0 ? "true" : "false")
            + ",\"num\":"    + ((GetKeyState(0x90) & 1) != 0 ? "true" : "false")
            + ",\"scroll\":" + ((GetKeyState(0x91) & 1) != 0 ? "true" : "false")
            + ",\"shift\":"  + ((GetAsyncKeyState(0x10) & 0x8000) != 0 ? "true" : "false")
            + ",\"ctrl\":"   + ((GetAsyncKeyState(0x11) & 0x8000) != 0 ? "true" : "false")
            + ",\"alt\":"    + ((GetAsyncKeyState(0x12) & 0x8000) != 0 ? "true" : "false")
            + ",\"win\":"    + ((GetAsyncKeyState(0x5B) & 0x8000) != 0 ? "true" : "false")
            + "}");
        return 0;
    }

    private static INPUT MouseEvent(uint flags, int dx, int dy, int data)
    {
        var input = new INPUT();
        input.type = InputMouse;
        input.u.mi.dx = dx;
        input.u.mi.dy = dy;
        input.u.mi.mouseData = unchecked((uint)data);
        input.u.mi.dwFlags = flags;
        input.u.mi.time = 0;
        input.u.mi.dwExtraInfo = IntPtr.Zero;
        return input;
    }

    private static INPUT KeyEvent(ushort vk, ushort scan, uint flags)
    {
        var input = new INPUT();
        input.type = InputKeyboard;
        input.u.ki.wVk = vk;
        input.u.ki.wScan = scan;
        input.u.ki.dwFlags = flags;
        input.u.ki.time = 0;
        input.u.ki.dwExtraInfo = IntPtr.Zero;
        return input;
    }

    /// The first events of each crossing are traced, then it goes quiet.
    ///
    /// SendInput returning 1 means the event was accepted into the input stream,
    /// not that anything moved — the two come apart when the injecting thread is
    /// on a desktop other than the visible one, and that failure is completely
    /// silent. Logging where the pointer actually ended up is the only way to
    /// tell "injected and ignored" from "injected and worked", and a dozen lines
    /// per connection is cheap enough to leave switched on.
    private static int traced;

    private static void Send(INPUT input)
    {
        var batch = new INPUT[1];
        batch[0] = input;
        if (SendInput(1, batch, Marshal.SizeOf(typeof(INPUT))) == 0)
        {
            Log("SendInput refused (win32 " + Marshal.GetLastWin32Error() + ")");
            return;
        }
        if (traced < 12)
        {
            traced++;
            POINT p;
            string where = GetCursorPos(out p) ? p.x + "," + p.y : "unreadable";
            Log(input.type == InputMouse
                ? "sent mouse flags=0x" + input.u.mi.dwFlags.ToString("x")
                    + " dx=" + input.u.mi.dx + " dy=" + input.u.mi.dy
                    + " data=" + input.u.mi.mouseData + " -> cursor " + where
                : "sent key vk=" + input.u.ki.wVk + " scan=" + input.u.ki.wScan
                    + " flags=0x" + input.u.ki.dwFlags.ToString("x"));
        }
    }

    /// Place the pointer at a pixel position in this machine's virtual-screen
    /// space.
    ///
    /// Absolute, not relative, and that is not a detail. A relative event is
    /// measured in mickeys and goes through the pointer speed and acceleration
    /// curve before it reaches the cursor, so the far end cannot know where the
    /// pointer will land; with acceleration on, the same event produces a
    /// different distance depending on how fast the previous ones arrived. For a
    /// KVM that is unusable — the Mac has to know exactly where the pointer is
    /// to decide when it has reached an edge and should come back.
    ///
    /// SendInput takes absolute coordinates normalised to 0..65535 rather than
    /// pixels, and with VIRTUALDESK that range spans every display. Doing the
    /// conversion here rather than on the Mac keeps the one machine that knows
    /// its own layout in charge of it.
    private static void SendAbsolute(int x, int y)
    {
        int vx = GetSystemMetrics(SM_XVIRTUALSCREEN), vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN), vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        if (vw <= 1 || vh <= 1) { Log("virtual screen is degenerate: " + vw + "x" + vh); return; }

        if (x < vx) x = vx; else if (x > vx + vw - 1) x = vx + vw - 1;
        if (y < vy) y = vy; else if (y > vy + vh - 1) y = vy + vh - 1;

        // Windows converts back with floor(n * extent / 65536), so dividing by
        // 65535 and rounding down lands a pixel short about half the time —
        // measured: asking for x=500 produced 501, x=3000 produced 3002. Round
        // UP against 65536 instead and the round trip is exact.
        int nx = (int)((((long)(x - vx) * 65536) + vw - 1) / vw);
        int ny = (int)((((long)(y - vy) * 65536) + vh - 1) / vh);
        Send(MouseEvent(MouseMove | MouseAbsolute | MouseVirtualDesk, nx, ny, 0));
    }

    private static int Num(string s)
    {
        int value;
        if (!int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out value))
            throw new ArgumentException("not a number: " + s);
        return value;
    }

    // Replay one event. Text, one per line, deliberately: the peak volume is a
    // few hundred events a second, the saving from packing it into binary is
    // irrelevant next to the network hop, and being able to watch the stream
    // with a terminal open is worth considerably more while this is young.
    //
    //   A <x> <y>            pointer move, absolute, in virtual-screen pixels
    //   M <dx> <dy>          pointer move, relative
    //   B <button> <1|0>     1 left, 2 right, 3 middle; 1 down, 0 up
    //   W <delta>            wheel, in WHEEL_DELTA (120) units
    //   H <delta>            horizontal wheel
    //   K <vk> <1|0>         virtual-key code, down or up
    //   U <codepoint> <1|0>  a character, bypassing the far keyboard layout
    private static void Inject(string line)
    {
        var parts = line.Split(' ');
        if (parts.Length == 0 || parts[0].Length == 0) return;

        switch (parts[0])
        {
            case "A":
                if (parts.Length >= 3) SendAbsolute(Num(parts[1]), Num(parts[2]));
                break;

            case "S":
                // Diagnostic counterpart to A. SetCursorPos writes the position
                // directly instead of posting through the input stream, so the
                // two disagreeing tells us whether injection is being filtered
                // or the session is not moving the pointer at all.
                if (parts.Length >= 3)
                {
                    bool moved = SetCursorPos(Num(parts[1]), Num(parts[2]));
                    POINT after;
                    GetCursorPos(out after);
                    Log("SetCursorPos(" + parts[1] + "," + parts[2] + ") returned "
                        + moved + " (win32 " + Marshal.GetLastWin32Error()
                        + ") -> cursor " + after.x + "," + after.y);
                }
                break;

            case "M":
                if (parts.Length >= 3) Send(MouseEvent(MouseMove, Num(parts[1]), Num(parts[2]), 0));
                break;

            case "B":
                if (parts.Length >= 3)
                {
                    bool down = Num(parts[2]) != 0;
                    uint flags;
                    switch (Num(parts[1]))
                    {
                        case 1:  flags = down ? MouseLeftDown   : MouseLeftUp;   break;
                        case 2:  flags = down ? MouseRightDown  : MouseRightUp;  break;
                        case 3:  flags = down ? MouseMiddleDown : MouseMiddleUp; break;
                        default: return;
                    }
                    Send(MouseEvent(flags, 0, 0, 0));
                }
                break;

            case "W":
                if (parts.Length >= 2) Send(MouseEvent(MouseWheel, 0, 0, Num(parts[1])));
                break;

            case "H":
                if (parts.Length >= 2) Send(MouseEvent(MouseHWheel, 0, 0, Num(parts[1])));
                break;

            case "K":
                if (parts.Length >= 3)
                    Send(KeyEvent((ushort)Num(parts[1]), 0, Num(parts[2]) != 0 ? 0 : KeyUp));
                break;

            case "U":
                // wVk must be 0 for a unicode event; the character rides in wScan
                // and arrives regardless of the layout selected on this machine.
                if (parts.Length >= 3)
                    Send(KeyEvent(0, (ushort)Num(parts[1]),
                                  KeyUnicode | (Num(parts[2]) != 0 ? 0 : KeyUp)));
                break;

            default:
                break;
        }
    }

    // ---- Clipboard ----------------------------------------------------
    //
    // Copy on one machine, paste on the other.
    //
    // This lives in the session-1 service and not in the relay, because the
    // Windows clipboard belongs to a session: the relay runs in session 0 and
    // would be reading and writing a clipboard nobody can see.
    //
    // It also needs an STA thread. The clipboard is an OLE surface and the
    // managed wrappers refuse outright from an MTA thread, so one thread owns
    // every clipboard operation and everything else queues work onto it.
    //
    // Change detection is GetClipboardSequenceNumber, polled. The alternative,
    // AddClipboardFormatListener, needs a window and a message pump, which is a
    // lot of machinery to add to a console service for the same answer.

    // The clipboard has its own channel now, so this is no longer about keeping
    // the pointer responsive — it is only about not holding an unreasonable
    // amount of memory, base64 included, at both ends.
    private const int MaxClipboard = 32 * 1048576;

    private static readonly object ClipboardLock = new object();

    /// The raw pipe stream, NOT a StreamWriter.
    ///
    /// Setting StreamWriter.AutoFlush flushes immediately, and on the SERVER end
    /// of a named pipe a flush is FlushFileBuffers, which blocks until the
    /// client has consumed everything in the buffer. Wrapping this end in an
    /// auto-flushing writer therefore wedged the server thread the moment a
    /// client connected — before it reached its own read loop — so no event or
    /// clipboard payload was ever read again. The client end does not have that
    /// behaviour, which is why the pointer stream never showed it.
    ///
    /// Byte-mode pipe writes go out as they are made, so nothing needs flushing.
    private static System.IO.Stream pipeBack;
    private static uint lastClipboardSequence;

    /// The payload most recently pushed in from the Mac. Compared against what
    /// is read back out, because setting the clipboard bumps the sequence
    /// number exactly as a real copy does — without this the two machines
    /// return the same item to each other indefinitely.
    private static string lastAppliedPayload;

    private static readonly System.Collections.Concurrent.BlockingCollection<Action> ClipboardWork
        = new System.Collections.Concurrent.BlockingCollection<Action>();

    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    private static void SendBack(string line)
    {
        lock (ClipboardLock)
        {
            if (pipeBack == null) return;
            try
            {
                byte[] bytes = Encoding.UTF8.GetBytes(line + "\n");
                pipeBack.Write(bytes, 0, bytes.Length);
            }
            catch (Exception e) { Log("clipboard: could not send back: " + e.Message); }
        }
    }

    private static void ClipboardLoop()
    {
        lastClipboardSequence = GetClipboardSequenceNumber();
        Log("clipboard: watching");
        while (true)
        {
            Action work;
            // Queued work first and immediately; polling only when idle, so an
            // incoming paste does not wait out the poll interval.
            if (ClipboardWork.TryTake(out work, 400))
            {
                try { work(); }
                catch (Exception e) { Log("clipboard: apply failed: " + e.Message); }
                continue;
            }
            uint sequence = GetClipboardSequenceNumber();
            if (sequence == lastClipboardSequence) continue;
            lastClipboardSequence = sequence;
            try { CaptureClipboard(); }
            catch (Exception e) { Log("clipboard: capture failed: " + e.Message); }
        }
    }

    private static void CaptureClipboard()
    {
        string format = null;
        byte[] payload = null;

        if (System.Windows.Forms.Clipboard.ContainsImage())
        {
            using (var image = System.Windows.Forms.Clipboard.GetImage())
            {
                if (image == null) return;
                using (var buffer = new System.IO.MemoryStream())
                {
                    image.Save(buffer, System.Drawing.Imaging.ImageFormat.Png);
                    format = "png";
                    payload = buffer.ToArray();
                }
            }
        }
        else if (System.Windows.Forms.Clipboard.ContainsText(System.Windows.Forms.TextDataFormat.Rtf))
        {
            format = "rtf";
            payload = Encoding.UTF8.GetBytes(
                System.Windows.Forms.Clipboard.GetText(System.Windows.Forms.TextDataFormat.Rtf));
        }
        else if (System.Windows.Forms.Clipboard.ContainsText())
        {
            format = "text";
            payload = Encoding.UTF8.GetBytes(System.Windows.Forms.Clipboard.GetText());
        }

        if (format == null || payload == null || payload.Length == 0) return;
        if (payload.Length > MaxClipboard)
        {
            Log("clipboard: " + format + " of " + payload.Length + " bytes is too large to send");
            return;
        }

        string encoded = Convert.ToBase64String(payload);
        if (encoded == lastAppliedPayload) return;      // this is what the Mac just sent
        SendBack("C " + format + " " + encoded);
        Log("clipboard: sent " + format + ", " + payload.Length + " bytes");
    }

    /// Report what is on the clipboard of the interactive session.
    ///
    /// Needed because SSH lands in session 0, which has a clipboard of its own
    /// that nothing ever writes to — reading it there would answer confidently
    /// about the wrong thing.
    private static int CmdClip()
    {
        string result = null;
        var done = new System.Threading.ManualResetEventSlim(false);
        ClipboardWork.Add(() =>
        {
            try
            {
                if (System.Windows.Forms.Clipboard.ContainsImage()) result = "<image>";
                else if (System.Windows.Forms.Clipboard.ContainsText()) result = System.Windows.Forms.Clipboard.GetText();
                else result = "";
            }
            catch (Exception e) { result = "<error: " + e.Message + ">"; }
            done.Set();
        });
        if (!done.Wait(3000)) { Fail("the clipboard thread did not answer"); return 1; }
        Console.WriteLine("{\"ok\":true,\"text\":\"" + Esc(result) + "\"}");
        return 0;
    }

    private static void ApplyClipboard(string format, string encoded)
    {
        byte[] data;
        try { data = Convert.FromBase64String(encoded); }
        catch (FormatException e) { Log("clipboard: undecodable payload: " + e.Message); return; }
        if (data.Length == 0) return;

        lastAppliedPayload = encoded;
        ClipboardWork.Add(() =>
        {
            switch (format)
            {
                case "text":
                    System.Windows.Forms.Clipboard.SetText(Encoding.UTF8.GetString(data));
                    break;
                case "rtf":
                    System.Windows.Forms.Clipboard.SetText(Encoding.UTF8.GetString(data),
                        System.Windows.Forms.TextDataFormat.Rtf);
                    break;
                case "png":
                    using (var buffer = new System.IO.MemoryStream(data))
                        System.Windows.Forms.Clipboard.SetImage(System.Drawing.Image.FromStream(buffer));
                    break;
                default:
                    Log("clipboard: ignoring unknown format " + format);
                    return;
            }
            // Setting the clipboard bumps the sequence number; adopt it so the
            // poll does not read this straight back out and return it.
            lastClipboardSequence = GetClipboardSequenceNumber();
            Log("clipboard: received " + format + ", " + data.Length + " bytes");
        });
    }

    /// A DACL with a single Allow entry, naming the account this service runs
    /// as. Everyone else is refused by omission, which is preferable to adding
    /// Deny entries: there is no ordering to reason about and nothing inherited.
    private static PipeSecurity InputPipeSecurity()
    {
        var security = new PipeSecurity();
        security.SetAccessRule(new PipeAccessRule(
            WindowsIdentity.GetCurrent().User,
            PipeAccessRights.ReadWrite | PipeAccessRights.CreateNewInstance,
            AccessControlType.Allow));
        return security;
    }

    /// Inbound clipboard, Mac -> PC. Its own pipe, deliberately: sharing the
    /// input pipe put a multi-megabyte paste in front of every pointer event
    /// behind it, and the pointer froze mid-motion until it drained.
    private static void ClipInPipeLoop()
    {
        Log("clip pipe: listening on \\\\.\\pipe\\" + ClipInPipeName);
        while (true)
        {
            try
            {
                using (var pipe = new NamedPipeServerStream(
                           ClipInPipeName, PipeDirection.In, 1,
                           PipeTransmissionMode.Byte, PipeOptions.None,
                           4096, 4096, InputPipeSecurity()))
                {
                    pipe.WaitForConnection();
                    Log("clip pipe: client connected");
                    using (var reader = new System.IO.StreamReader(pipe, new UTF8Encoding(false)))
                    {
                        string line;
                        while ((line = reader.ReadLine()) != null)
                        {
                            if (!line.StartsWith("C ", StringComparison.Ordinal)) continue;
                            var parts = line.Split(new[] { ' ' }, 3);
                            if (parts.Length != 3) continue;
                            try { ApplyClipboard(parts[1], parts[2]); }
                            catch (Exception e) { Log("clip pipe: bad payload: " + e.Message); }
                        }
                    }
                    Log("clip pipe: client disconnected");
                }
            }
            catch (Exception e)
            {
                Log("clip pipe: " + e.Message);
                System.Threading.Thread.Sleep(500);
            }
        }
    }

    /// The return path: PC -> Mac, for clipboard payloads.
    ///
    /// A SECOND one-directional pipe rather than making the input pipe duplex.
    /// Duplex looked tidier and cost a long evening: with both directions on one
    /// handle the server stopped receiving anything at all the moment a client
    /// connected, while the client happily went on writing. Two pipes, each
    /// carrying one direction, restores the input path to exactly the code that
    /// was already proven and makes the return path just as dull.
    private static void BackPipeLoop()
    {
        while (true)
        {
            try
            {
                using (var pipe = new NamedPipeServerStream(
                           BackPipeName, PipeDirection.Out, 1,
                           PipeTransmissionMode.Byte, PipeOptions.None,
                           4096, 4096, InputPipeSecurity()))
                {
                    pipe.WaitForConnection();
                    Log("back pipe: client connected");
                    lock (ClipboardLock) { pipeBack = pipe; }

                    // Hold the connection open until the client goes away, and
                    // detect that by writing to it.
                    //
                    // IsConnected is not enough: on a server stream it stays
                    // true after a client dies without any I/O, so a single
                    // abandoned relay held this pipe's only instance forever and
                    // every later relay timed out waiting for it. A periodic
                    // write throws the moment the far end is gone. The Mac
                    // ignores any line that is not a clipboard payload, so the
                    // heartbeat costs nothing there.
                    byte[] beat = Encoding.UTF8.GetBytes("P\n");
                    while (true)
                    {
                        System.Threading.Thread.Sleep(2000);
                        bool alive = true;
                        lock (ClipboardLock)
                        {
                            try { pipe.Write(beat, 0, beat.Length); }
                            catch (Exception) { alive = false; }
                        }
                        if (!alive) break;
                    }

                    lock (ClipboardLock) { pipeBack = null; }
                    Log("back pipe: client disconnected");
                }
            }
            catch (Exception e)
            {
                lock (ClipboardLock) { pipeBack = null; }
                Log("back pipe: " + e.Message);
                System.Threading.Thread.Sleep(500);
            }
        }
    }

    private static void InputPipeLoop()
    {
        AttachToInputDesktop();
        Log("input pipe: listening on \\\\.\\pipe\\" + InputPipeName);
        while (true)
        {
            try
            {
                using (var pipe = new NamedPipeServerStream(
                           InputPipeName, PipeDirection.In, 1,
                           PipeTransmissionMode.Byte, PipeOptions.None,
                           4096, 4096, InputPipeSecurity()))
                {
                    pipe.WaitForConnection();
                    traced = 0;          // a fresh trace window per crossing
                    // The input desktop is not fixed for the life of the process:
                    // locking, unlocking and any UAC prompt each switch it. Once
                    // at startup would leave the KVM silently dead after the
                    // first lock, so re-attach at every crossing.
                    AttachToInputDesktop();
                    Log("input pipe: client connected");

                    using (var reader = new System.IO.StreamReader(pipe, new UTF8Encoding(false)))
                    {
                        string line;
                        int received = 0;
                        while ((line = reader.ReadLine()) != null)
                        {
                            received++;
                            if (received <= 4)
                                Log("server: line[" + received + "] "
                                    + (line.Length > 40 ? line.Substring(0, 40) + "..." : line));
                            // Input only. Clipboard has its own pipe, so a large
                            // paste can no longer queue in front of pointer events.
                            try { Inject(line); }
                            catch (Exception e) { Log("bad event \"" + line + "\": " + e.Message); }
                        }
                    }

                    Log("input pipe: client disconnected");
                }
            }
            catch (Exception e)
            {
                // A dropped client must not end the loop, or the KVM works
                // exactly once per logon.
                Log("input pipe: " + e.Message);
                System.Threading.Thread.Sleep(500);
            }
        }
    }

    /// The session-0 half: reads events from the Mac on stdin and hands them to
    /// the session-1 service through the pipe. One SSH channel is opened for the
    /// whole session, so the ~0.8s PowerShell login cost is paid once at the
    /// crossing rather than per event.
    private static int CmdKvm()
    {
        // Relays are no longer evicted, and must not be.
        //
        // That eviction existed because a stale relay held the pipe's only
        // instance forever: it sat in Console.ReadLine, which never returned on
        // a dead SSH channel. StdinLines reads with ReadFile now and reports
        // ERROR_BROKEN_PIPE when the channel goes, so the relay exits on its own
        // and the pipe frees — the condition it guarded against cannot arise.
        //
        // Keeping it would now be actively harmful: there are TWO relays, one
        // for input and one for the clipboard, both running in session 0. Each
        // would kill the other on startup.
        try
        {
            using (var pipe = new NamedPipeClientStream(".", InputPipeName, PipeDirection.Out))
            {
                pipe.Connect(5000);
                using (var writer = new System.IO.StreamWriter(pipe, new UTF8Encoding(false)))
                {
                    writer.AutoFlush = true;      // every event, immediately
                    Console.WriteLine("{\"ok\":true,\"kvm\":\"ready\"}");
                    Console.Out.Flush();

                    int seen = 0;
                    foreach (string line in StdinLines())
                    {
                        seen++;
                        if (line.Length == 0) continue;
                        if (line == "quit") break;
                        writer.Write(line);
                        writer.Write("\n");
                    }
                    Log("kvm relay: stdin ended after " + seen + " line(s)");
                }
            }
            return 0;
        }
        catch (Exception e)
        {
            Fail("cannot reach the input pipe (" + e.Message + ")");
            return 1;
        }
    }

    /// The clipboard's own relay: its own SSH channel, its own pipes.
    ///
    /// Separate from the input relay so a multi-megabyte paste cannot sit in
    /// front of pointer events. They travel over different SSH connections
    /// entirely, so neither can block the other at any layer.
    private static int CmdClipboard()
    {
        try
        {
            using (var outbound = new NamedPipeClientStream(".", ClipInPipeName, PipeDirection.Out))
            {
                outbound.Connect(5000);

                // Inbound clipboard goes out on stdout, which is the SSH channel
                // the Mac is already reading.
                var returnPump = new System.Threading.Thread(() =>
                {
                    try
                    {
                        using (var backPipe = new NamedPipeClientStream(
                                   ".", BackPipeName, PipeDirection.In))
                        {
                            backPipe.Connect(5000);
                            var fromService = new System.IO.StreamReader(
                                backPipe, new UTF8Encoding(false));
                            string back;
                            while ((back = fromService.ReadLine()) != null)
                            {
                                Console.WriteLine(back);
                                Console.Out.Flush();
                            }
                        }
                    }
                    catch (Exception e) { Log("clipboard relay: return path ended: " + e.Message); }
                });
                returnPump.IsBackground = true;
                returnPump.Start();

                using (var writer = new System.IO.StreamWriter(outbound, new UTF8Encoding(false)))
                {
                    writer.AutoFlush = true;
                    Console.WriteLine("{\"ok\":true,\"clipboard\":\"ready\"}");
                    Console.Out.Flush();

                    int seen = 0;
                    foreach (string line in StdinLines())
                    {
                        seen++;
                        if (line.Length == 0) continue;
                        if (line == "quit") break;
                        writer.Write(line);
                        writer.Write("\n");
                    }
                    Log("clipboard relay: stdin ended after " + seen + " line(s)");
                }
            }
            return 0;
        }
        catch (Exception e)
        {
            Fail("cannot reach the clipboard pipe (" + e.Message + ")");
            return 1;
        }
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

        // The KVM receiver runs alongside the DDC listener rather than as its own
        // process: SendInput has to be called from this session, and this is
        // already the process that lives in it. Background, so a stuck pipe read
        // cannot keep the agent alive after the DDC loop is gone.
        var inputThread = new System.Threading.Thread(InputPipeLoop);
        inputThread.IsBackground = true;
        inputThread.Start();

        // STA, because the clipboard is an OLE surface and the managed wrappers
        // refuse from an MTA thread.
        var clipInThread = new System.Threading.Thread(ClipInPipeLoop);
        clipInThread.IsBackground = true;
        clipInThread.Start();

        var backThread = new System.Threading.Thread(BackPipeLoop);
        backThread.IsBackground = true;
        backThread.Start();

        var clipboardThread = new System.Threading.Thread(ClipboardLoop);
        clipboardThread.SetApartmentState(System.Threading.ApartmentState.STA);
        clipboardThread.IsBackground = true;
        clipboardThread.Start();

        var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, port);
        listener.Start();
        Console.WriteLine("{\"ok\":true,\"listening\":" + port + "}");
        Console.Out.Flush();
        Log("serve: listening on 127.0.0.1:" + port);

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

        foreach (string line in StdinLines())
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
