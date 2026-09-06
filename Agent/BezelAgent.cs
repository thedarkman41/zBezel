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
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Windows.Automation;
using System.Windows.Forms;

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
        // A session with no display attached can never enumerate a monitor, so
        // riding out a hotplug there spends six seconds waiting for something
        // that cannot arrive — and every Mac-side probe of a detached host pays
        // it. Off the console, or disconnected, ask once and answer. The full
        // settle loop stays for the on-console case, which is the only one where
        // a monitor really can be mid-re-enumeration.
        targetsCache = SessionHasNoDisplay() ? EnumerateSettled(1, 0) : EnumerateSettled();
        targetsCachedAt = DateTime.UtcNow;
        return targetsCache;
    }

    /// True when this process sits in a session that cannot own a display:
    /// not the console session, or the console session while it is disconnected.
    /// A failed probe answers false, so an unknown session keeps the patient path.
    private static bool SessionHasNoDisplay()
    {
        try
        {
            uint id = OwnSessionId();
            int console = ConsoleSessionId();
            if (console < 0 || id != (uint)console) return true;
            return SessionState(id) == WTSDisconnected;
        }
        catch (Exception) { return false; }
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
                                  + LinkFields(targets.Count) + ","
                                  + SessionFields() + "}");
                return true;
            case "list":   CmdList(targets);         return true;
            case "caps":   CmdCaps(targets, args);   return true;
            case "get":    CmdGet(targets, args);    return true;
            case "setget": CmdSetGet(targets, args); return true;
            case "set":    CmdSet(targets, args);    return true;
            case "setraw": CmdSetRaw(targets, args); return true;
            case "probe":  CmdProbe(targets, args);  return true;
            case "cursor":   CmdCursor();            return true;
            case "keystate": CmdKeyState();          return true;
            case "clip":     CmdClip();              return true;
            case "screenshot": CmdScreenshot(args);  return true;
            case "stream":     CmdStream(args);      return true;
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

    internal static string Esc(string s)
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

    internal static void Log(string message)
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

    // ---- LAN discovery -----------------------------------------------------
    //
    // A tiny UDP broadcast, every few seconds, that lets zBezel find this machine
    // on the local network with nothing configured — no hostname typed, no
    // registry, no Tailscale required. The packet carries the machine name and
    // the EDID product code of each monitor it sees; zBezel keeps only the ones
    // that are faces of the panel it manages and reads the input from the code.
    // Discovery is announce-only; control still goes over SSH exactly as before.

    private const int DiscoveryPort = 48222;

    private static void AnnounceLoop()
    {
        System.Net.Sockets.UdpClient udp = null;
        try
        {
            udp = new System.Net.Sockets.UdpClient();
            udp.EnableBroadcast = true;
            string host = Environment.MachineName;
            while (true)
            {
                try
                {
                    var products = new List<string>();
                    foreach (var t in Targets(false))
                    {
                        string p = ProductCode(t.DeviceID);
                        if (p.Length > 0 && !products.Contains(p)) products.Add(p);
                    }
                    var sb = new StringBuilder();
                    sb.Append("{\"v\":1,\"kind\":\"bezelkvm\",\"host\":\"").Append(Esc(host))
                      .Append("\",\"user\":\"").Append(Esc(Environment.UserName))
                      .Append("\",\"products\":[");
                    for (int i = 0; i < products.Count; i++)
                    {
                        if (i > 0) sb.Append(',');
                        sb.Append('"').Append(Esc(products[i])).Append('"');
                    }
                    sb.Append("]}");
                    byte[] bytes = Encoding.UTF8.GetBytes(sb.ToString());

                    // Send to the directed broadcast of EVERY local IPv4 subnet,
                    // not just 255.255.255.255. This box is multi-homed (a LAN NIC
                    // and Tailscale), and the limited broadcast leaves by only one
                    // interface — often the wrong one — so a listener on the LAN
                    // sees it only intermittently. A directed broadcast per subnet
                    // guarantees a packet reaches each network the machine is on.
                    foreach (var endpoint in BroadcastTargets())
                    {
                        try { udp.Send(bytes, bytes.Length, endpoint); }
                        catch (Exception) { }
                    }
                }
                catch (Exception)
                {
                    // A transient failure (interface down, no route) must not end
                    // the loop — the next tick tries again.
                }
                System.Threading.Thread.Sleep(5000);
            }
        }
        catch (Exception e) { Log("announce: loop stopped: " + e.Message); }
        finally { if (udp != null) udp.Close(); }
    }

    /// One UDP endpoint per network this machine is on: the directed broadcast
    /// address of each up IPv4 interface (host bits all ones), plus the limited
    /// broadcast as a catch-all. Recomputed each tick so a cable plugged or a
    /// VPN coming up is picked up without a restart.
    private static List<System.Net.IPEndPoint> BroadcastTargets()
    {
        var targets = new List<System.Net.IPEndPoint>();
        try
        {
            foreach (var ni in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
                if (ni.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Loopback) continue;
                foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                {
                    if (ua.Address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) continue;
                    byte[] ip = ua.Address.GetAddressBytes();
                    byte[] mask;
                    try { mask = ua.IPv4Mask.GetAddressBytes(); }
                    catch (Exception) { continue; }
                    if (mask == null || mask.Length != 4) continue;
                    var bc = new byte[4];
                    for (int i = 0; i < 4; i++) bc[i] = (byte)(ip[i] | (~mask[i] & 0xFF));
                    targets.Add(new System.Net.IPEndPoint(new System.Net.IPAddress(bc), DiscoveryPort));
                }
            }
        }
        catch (Exception) { }
        targets.Add(new System.Net.IPEndPoint(System.Net.IPAddress.Broadcast, DiscoveryPort));
        return targets;
    }

    /// Pull the EDID product identity out of a Windows display device path,
    /// e.g. "\\?\DISPLAY#HPN36D5#5&..." -> "HPN36D5". "" when it is not there.
    private static string ProductCode(string deviceId)
    {
        if (string.IsNullOrEmpty(deviceId)) return "";
        int i = deviceId.IndexOf("DISPLAY#", StringComparison.OrdinalIgnoreCase);
        if (i < 0) return "";
        int start = i + "DISPLAY#".Length;
        int end = deviceId.IndexOf('#', start);
        if (end < 0) return "";
        return deviceId.Substring(start, end - start);
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
        if (args.Length == 0) { Fail("usage: BezelAgent list|caps|get|set|probe|screenshot|stream|reclaim"); return 1; }

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
            // Reclaim never touches a monitor, and must work when no session
            // exists yet — so it dispatches here, before enumeration.
            case "reclaim":   return CmdReclaim();
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
        // An empty array means "no monitor here"; the session says whether that
        // is because there is nothing attached or because this session has no
        // display to attach one to.
        sb.Append("],").Append(SessionFields()).Append('}');
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

    /// Write and do not read anything back.
    ///
    /// `set` follows every write with a read of the same code, which is right
    /// for a value the caller wants confirmed. It is wrong for a write that
    /// makes the panel reconfigure itself: the read then lands while the monitor
    /// is busy, and the retry logic waits it out. Measured on this panel, a PiP
    /// placement write took 8.09s that way and the same write again took 0.61s —
    /// the variance is the read waiting on a display that is mid-change, not the
    /// write.
    ///
    /// Nothing is lost by not reading: 0xE1 answers with whichever sub-setting
    /// it feels like naming, so the read-back could never confirm the write in
    /// the first place.
    private static int CmdSetRaw(List<Target> targets, string[] args)
    {
        if (args.Length < 4) { Fail("setraw needs an index, a VCP code and a value"); return 1; }
        var t = Pick(targets, args[1]);
        byte code = ParseCode(args[2]);
        uint value = uint.Parse(args[3], CultureInfo.InvariantCulture);

        bool wrote = SetVCPFeature(t.Handle, code, value);
        Console.WriteLine("{\"ok\":" + (wrote ? "true" : "false")
                          + ",\"code\":" + code + ",\"wrote\":" + value + "}");
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

    // Non-zero inside a Remote Desktop session, where the desktop this process
    // sees is the virtual RDP display rather than the panel on the desk.
    private const int SM_REMOTESESSION = 0x1000;

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

            case "MARK":
                {
                    // "MARK <stage>": the user let go of that drag. Resolve the
                    // destination NOW, while the pointer is still where they
                    // released it -- the copy may not have finished, and by the
                    // time it does the pointer will have moved. The ghost stays,
                    // parked where it was dropped, filling up: for a large file
                    // that bar is the only sign anything is happening.
                    // Park FIRST: Mark() calls UI Automation and a late-bound
                    // shell enumeration and can take hundreds of ms, during which
                    // an unparked ghost would keep chasing the cursor and the
                    // offset captured below would be wrong.
                    var stage = parts.Length >= 2 ? parts[1] : DragGhost.CarryingStage;
                    if (stage == null) { BezelAgent.Log("MARK with nothing in hand"); break; }
                    DragGhost.Park(stage);
                    DropTarget.Mark(stage);
                    DragGhost.AttachAnchor(stage, DropTarget.MarkedAnchor(stage));
                    // Then, off this thread: put a placeholder in the folder so
                    // Explorer draws a real item in its real slot, find that item,
                    // and snap the ghost down into it.
                    DropTarget.PlaceholderAndSnap(stage);
                }
                break;

            case "DROP":
                {
                    // The bytes have landed. Move that drag's folder to the spot
                    // remembered at MARK — OFF this thread, because this is the
                    // single input-pipe reader and a large or cross-volume move
                    // here froze every pointer and key event for its duration.
                    // The ghost stays up, bar full, until the move is really done.
                    var stage = parts.Length >= 2 ? parts[1] : null;
                    DragGhost.Delivering(stage);
                    ThreadPool.QueueUserWorkItem(delegate
                    {
                        bool ok;
                        var result = DropTarget.Deliver(stage, out ok);
                        BezelAgent.Log("drop " + stage + " -> " + result);
                        if (ok) DragGhost.Hide(stage, false); else DragGhost.Fail(stage, result);
                    });
                }
                break;

            case "P":
                // Heartbeat. Does nothing except give the pipe something to
                // carry: an idle connection gets dropped somewhere between here
                // and the Mac, and the first anyone knows of it is a crossing
                // that goes nowhere.
                break;

            case "DI":
                // The icon for the drag about to start, as base64 PNG. Its own
                // message rather than a field on "D": the ghost's parameters are
                // read positionally, and an icon big enough to be worth sending
                // has no business in a line that is split on spaces.
                if (parts.Length >= 2)
                {
                    try { DragGhost.SetIcon(Convert.FromBase64String(parts[1])); }
                    catch (Exception e) { BezelAgent.Log("drag icon: bad payload, " + e.Message); }
                }
                else DragGhost.SetIcon(null);
                break;

            case "D":
                // "D <stage> <totalBytes> <label...>" shows it. "D - <stage>"
                // hides that one drag: it was abandoned and its bytes are
                // unwanted. A bare "D -" clears every ghost at once.
                if (parts.Length >= 4 && parts[1] != "-")
                {
                    long total;
                    long.TryParse(parts[2], out total);
                    DragGhost.Show(parts[1], total,
                                   string.Join(" ", parts, 3, parts.Length - 3));
                }
                else if (parts.Length >= 3 && parts[1] == "-") DragGhost.Hide(parts[2], true);
                else DragGhost.HideAll();
                break;

            case "L":
                // The lock badge. -1 hides it, 0 shows it open, 1 shows it shut.
                // Drawn here rather than on the Mac because while this machine is
                // on the panel, nothing the Mac draws is visible.
                if (parts.Length >= 4) LockOverlay.Set(Num(parts[1]), Num(parts[2]), Num(parts[3]));
                else if (parts.Length >= 2) LockOverlay.Set(Num(parts[1]), -1, -1);
                break;

            case "F":
                // Fade curtain. "F <opacity 0..100> <ms>" drives a full-screen
                // black layer to that opacity over that many milliseconds — the
                // machine's own side of an input-switch dissolve. Drawn here for
                // the same reason as the badge: while this machine is on the panel,
                // nothing the Mac draws is visible, so the machine fades itself.
                if (parts.Length >= 3) FadeOverlay.Set(Num(parts[1]), Num(parts[2]));
                else if (parts.Length >= 2) FadeOverlay.Set(Num(parts[1]), 0);
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

    // ---- Screen capture -----------------------------------------------
    //
    // A picture of this machine's desktop, sent to the Mac on request.
    //
    // It exists to fill a Mission Control thumbnail, nothing more: the moment
    // the user is actually looking at that Space the monitor has switched to
    // this machine and they are seeing it live, not the picture. So it is sent
    // small and lossy — a full 4K PNG would be about 2MB for something rendered
    // a couple of hundred pixels wide.
    //
    // Requested by the Mac rather than pushed on a timer here, so the cadence is
    // decided by the side that knows whether anyone can see it.

    private static void CaptureScreen(int maxWidth)
    {
        int x = GetSystemMetrics(SM_XVIRTUALSCREEN), y = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int w = GetSystemMetrics(SM_CXVIRTUALSCREEN), h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        if (w <= 0 || h <= 0) { Log("capture: virtual screen is degenerate"); return; }

        using (var full = new System.Drawing.Bitmap(w, h))
        {
            using (var canvas = System.Drawing.Graphics.FromImage(full))
                canvas.CopyFromScreen(x, y, 0, 0, new System.Drawing.Size(w, h));

            int outWidth = Math.Min(maxWidth, w);
            int outHeight = (int)((long)h * outWidth / w);
            using (var small = new System.Drawing.Bitmap(full, outWidth, outHeight))
            using (var buffer = new System.IO.MemoryStream())
            {
                System.Drawing.Imaging.ImageCodecInfo jpeg = null;
                foreach (var codec in System.Drawing.Imaging.ImageCodecInfo.GetImageEncoders())
                    if (codec.MimeType == "image/jpeg") { jpeg = codec; break; }

                if (jpeg == null)
                {
                    small.Save(buffer, System.Drawing.Imaging.ImageFormat.Png);
                }
                else
                {
                    var settings = new System.Drawing.Imaging.EncoderParameters(1);
                    settings.Param[0] = new System.Drawing.Imaging.EncoderParameter(
                        System.Drawing.Imaging.Encoder.Quality, 70L);
                    small.Save(buffer, jpeg, settings);
                    settings.Dispose();
                }

                byte[] bytes = buffer.ToArray();
                SendBack("S " + Convert.ToBase64String(bytes));
                Log("capture: sent " + outWidth + "x" + outHeight + ", " + bytes.Length + " bytes");
            }
        }
    }

    /// Report what is on the clipboard of the interactive session.
    ///
    /// Needed because SSH lands in session 0, which has a clipboard of its own
    /// that nothing ever writes to — reading it there would answer confidently
    /// about the wrong thing.
    // ---- Seeing the screen -------------------------------------------------
    //
    // The KVM can move a pointer on this machine but the Mac cannot see where
    // it landed unless the monitor happens to be showing this input. These two
    // commands are the eyes: a single capture of the real console, and a
    // stream of them. Both run here, in the interactive session, because a
    // process in session 0 (where SSH lands) has no desktop to capture — the
    // same reason the DDC/CI calls live in this service. Neither can see the
    // secure desktop (login screen, UAC); that is by design in Windows and the
    // capture simply comes back black there. Wake Console is the tool for that.

    /// One JPEG of the whole virtual screen, cursor composited in, since a KVM
    /// user's first question is "where is my pointer". `maxWidth` scales it
    /// down (a 4K desktop is a 3 MB PNG and nobody needs that to see a dialog);
    /// `quality` is the JPEG quality 1-100.
    internal static byte[] CaptureJpeg(int maxWidth, long quality, out int width, out int height)
    {
        var bounds = SystemInformation.VirtualScreen;   // physical pixels: the process is per-monitor DPI aware
        using (var bmp = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb))
        {
            using (var g = Graphics.FromImage(bmp))
            {
                g.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, bounds.Size, CopyPixelOperation.SourceCopy);
                DrawCursor(g, bounds);
            }

            Image src = bmp;
            Bitmap scaled = null;
            if (maxWidth > 0 && bmp.Width > maxWidth)
            {
                int h = Math.Max(1, (int)((long)bmp.Height * maxWidth / bmp.Width));
                scaled = new Bitmap(maxWidth, h, PixelFormat.Format24bppRgb);
                using (var g2 = Graphics.FromImage(scaled))
                {
                    g2.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                    g2.DrawImage(bmp, 0, 0, maxWidth, h);
                }
                src = scaled;
            }

            try { width = src.Width; height = src.Height; return EncodeJpeg(src, quality); }
            finally { if (scaled != null) scaled.Dispose(); }
        }
    }

    private static byte[] EncodeJpeg(Image src, long quality)
    {
        ImageCodecInfo jpeg = null;
        foreach (var codec in ImageCodecInfo.GetImageEncoders())
            if (codec.MimeType == "image/jpeg") { jpeg = codec; break; }
        using (var ms = new MemoryStream())
        {
            if (jpeg == null) { src.Save(ms, ImageFormat.Png); return ms.ToArray(); }
            using (var ps = new EncoderParameters(1))
            {
                ps.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality,
                                                   Math.Max(1L, Math.Min(100L, quality)));
                src.Save(ms, jpeg, ps);
            }
            return ms.ToArray();
        }
    }

    /// A frame to show when the real screen cannot be had — chiefly the secure
    /// desktop (a UAC prompt or the sign-in screen), which Windows forbids a
    /// user process from capturing (CopyFromScreen throws "handle is invalid").
    /// The stream keeps flowing a captioned card and picks the real desktop
    /// back up on the next frame once the prompt is gone, so a viewer sees
    /// WHY it went blank instead of a broken image. This is precisely what a
    /// real RDP session would still show, because RDP renders the secure
    /// desktop into its own session — a difference worth naming on the card.
    internal static byte[] PlaceholderJpeg(string message, int maxWidth, long quality, out int width, out int height)
    {
        int w = maxWidth > 0 ? maxWidth : 1280;
        int h = Math.Max(1, w * 9 / 16);
        using (var bmp = new Bitmap(w, h, PixelFormat.Format24bppRgb))
        {
            using (var g = Graphics.FromImage(bmp))
            {
                g.Clear(Color.FromArgb(20, 20, 24));
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
                using (var title = new Font("Segoe UI", Math.Max(9f, w / 64f), FontStyle.Bold))
                using (var body = new Font("Segoe UI", Math.Max(7f, w / 100f)))
                using (var dim = new SolidBrush(Color.FromArgb(150, 160, 170)))
                using (var faint = new SolidBrush(Color.FromArgb(110, 120, 130)))
                {
                    var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                    var top = new RectangleF(0, h * 0.36f, w, h * 0.14f);
                    var bot = new RectangleF(w * 0.1f, h * 0.5f, w * 0.8f, h * 0.28f);
                    g.DrawString(Environment.MachineName + " — screen not visible", title, dim, top, fmt);
                    g.DrawString(message, body, faint, bot, fmt);
                }
            }
            width = w; height = h;
            return EncodeJpeg(bmp, quality);
        }
    }

    /// Capture, or the placeholder card explaining why not. The stream uses
    /// this so it never dies on a UAC prompt; the `screenshot` verb calls the
    /// raw CaptureJpeg so a script gets the real error.
    internal static byte[] CaptureOrPlaceholder(int maxWidth, long quality, out int width, out int height)
    {
        try { return CaptureJpeg(maxWidth, quality, out width, out height); }
        catch (Exception e)
        {
            string why = e.Message.IndexOf("handle is invalid", StringComparison.OrdinalIgnoreCase) >= 0
                ? "A secure desktop is up (UAC prompt or sign-in screen). Windows does not let this "
                  + "agent capture it. Use Wake Console for the sign-in screen; a UAC prompt clears when answered."
                : "Capture failed: " + e.Message;
            return PlaceholderJpeg(why, maxWidth, quality, out width, out height);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ICONINFO { public int fIcon; public int xHotspot; public int yHotspot; public IntPtr hbmMask; public IntPtr hbmColor; }
    [DllImport("user32.dll")] private static extern bool GetIconInfo(IntPtr hIcon, out ICONINFO piconinfo);
    [DllImport("user32.dll")] private static extern bool DrawIconEx(IntPtr hdc, int x, int y, IntPtr hIcon, int cx, int cy,
                                                                    int istepIfAniCur, IntPtr hbrFlickerFreeDraw, int diFlags);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr hObject);

    /// CopyFromScreen leaves the cursor out; draw the real one, at its hotspot.
    private static void DrawCursor(Graphics g, Rectangle bounds)
    {
        try
        {
            var ci = new CURSORINFO();
            ci.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
            if (!GetCursorInfo(ref ci) || ci.flags != 1 /* CURSOR_SHOWING */ || ci.hCursor == IntPtr.Zero) return;
            ICONINFO ii;
            if (!GetIconInfo(ci.hCursor, out ii)) return;
            try
            {
                int x = ci.ptScreenPos.x - bounds.Left - ii.xHotspot;
                int y = ci.ptScreenPos.y - bounds.Top - ii.yHotspot;
                IntPtr hdc = g.GetHdc();
                try { DrawIconEx(hdc, x, y, ci.hCursor, 0, 0, 0, IntPtr.Zero, 3 /* DI_NORMAL */); }
                finally { g.ReleaseHdc(hdc); }
            }
            finally
            {
                if (ii.hbmMask != IntPtr.Zero) DeleteObject(ii.hbmMask);
                if (ii.hbmColor != IntPtr.Zero) DeleteObject(ii.hbmColor);
            }
        }
        catch (Exception) { /* a missing cursor is not worth a failed capture */ }
    }

    /// `screenshot [maxWidth] [quality] [file]` — the JPEG rides the reply
    /// inline as base64 (so it comes back over the relay channel the Mac
    /// already holds open, no second SSH round trip) and is also written to
    /// `file` (default C:\Temp\bezel-screen.jpg) for anyone who wants to open it.
    private static int CmdScreenshot(string[] args)
    {
        int maxWidth = 1600; long quality = 70;
        string file = Path.Combine(DropTarget.Staging, "bezel-screen.jpg");
        if (args.Length > 1) int.TryParse(args[1], out maxWidth);
        if (args.Length > 2) long.TryParse(args[2], out quality);
        if (args.Length > 3 && args[3].Length > 0) file = args[3];

        int w, h;
        byte[] jpeg;
        try { jpeg = CaptureJpeg(maxWidth, quality, out w, out h); }
        catch (Exception e)
        {
            Console.WriteLine("{\"ok\":false,\"error\":\"capture failed: " + Esc(e.Message) + "\"}");
            return 1;
        }
        string written = "";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file));
            File.WriteAllBytes(file, jpeg);
            written = file;
        }
        catch (Exception e) { Log("screenshot: could not write " + file + ": " + e.Message); }

        var sb = new StringBuilder(jpeg.Length * 4 / 3 + 256);
        sb.Append("{\"ok\":true,\"width\":").Append(w).Append(",\"height\":").Append(h)
          .Append(",\"bytes\":").Append(jpeg.Length)
          .Append(",\"path\":\"").Append(Esc(written)).Append("\"")
          .Append(",\"jpegBase64\":\"").Append(Convert.ToBase64String(jpeg)).Append("\"}");
        Console.WriteLine(sb.ToString());
        return 0;
    }

    /// `stream start [port] [fps] [maxWidth] [quality]` / `stream stop` /
    /// `stream status`. The server binds loopback only; reach it through an SSH
    /// tunnel (`ssh -N -L 8765:127.0.0.1:8765 <host>`) and open
    /// http://127.0.0.1:8765/ — the tunnel is the authentication.
    private static int CmdStream(string[] args)
    {
        string verb = args.Length > 1 ? args[1].ToLowerInvariant() : "status";
        switch (verb)
        {
            case "start":
            {
                int port = 8765, fps = 4, maxWidth = 1600; long quality = 60;
                if (args.Length > 2) int.TryParse(args[2], out port);
                if (args.Length > 3) int.TryParse(args[3], out fps);
                if (args.Length > 4) int.TryParse(args[4], out maxWidth);
                if (args.Length > 5) long.TryParse(args[5], out quality);
                Console.WriteLine(ScreenStream.Start(port, fps, maxWidth, quality));
                return 0;
            }
            case "stop":
                Console.WriteLine(ScreenStream.Stop());
                return 0;
            default:
                Console.WriteLine(ScreenStream.Status());
                return 0;
        }
    }

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
                            if (line.StartsWith("SHOT", StringComparison.Ordinal))
                            {
                                // Capture on the STA thread: it is the one that
                                // already owns desktop access in this session.
                                int width = 1280;
                                var bits = line.Split(' ');
                                if (bits.Length > 1) int.TryParse(bits[1], out width);
                                int requested = width;
                                ClipboardWork.Add(() =>
                                {
                                    try { CaptureScreen(requested); }
                                    catch (Exception e) { Log("capture failed: " + e.Message); }
                                });
                                continue;
                            }
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

    // ---------------------------------------------------------------------
    // Console reclaim
    // ---------------------------------------------------------------------

    private const int WTSActive = 0, WTSDisconnected = 4;

    [StructLayout(LayoutKind.Sequential)]
    private struct WTS_SESSION_INFO
    {
        public uint SessionId;
        [MarshalAs(UnmanagedType.LPWStr)] public string pWinStationName;
        public int State;
    }

    [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool WTSEnumerateSessionsW(
        IntPtr hServer, int Reserved, int Version, out IntPtr ppSessionInfo, out int pCount);

    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr pMemory);

    [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool WTSQuerySessionInformationW(
        IntPtr hServer, uint sessionId, int wtsInfoClass, out IntPtr ppBuffer, out int pBytesReturned);

    [DllImport("kernel32.dll")]
    private static extern uint WTSGetActiveConsoleSessionId();

    private static string SessionUser(uint id)
    {
        IntPtr buf; int len;
        // 5 = WTSUserName
        if (!WTSQuerySessionInformationW(IntPtr.Zero, id, 5, out buf, out len)) return "";
        try { return Marshal.PtrToStringUni(buf) ?? ""; }
        finally { WTSFreeMemory(buf); }
    }

    // WTS_CONNECTSTATE_CLASS, in the order wtsapi32.h declares it.
    private static readonly string[] SessionStateNames =
    {
        "active", "connected", "connectQuery", "shadow", "disconnected",
        "idle", "listen", "reset", "down", "init",
    };

    /// The connect state of a session, or -1 when Windows will not say.
    private static int SessionState(uint id)
    {
        IntPtr buf; int len;
        // 8 = WTSConnectState; the buffer holds a single 4-byte state class.
        if (!WTSQuerySessionInformationW(IntPtr.Zero, id, 8, out buf, out len)) return -1;
        try { return len >= 4 ? Marshal.ReadInt32(buf) : -1; }
        finally { WTSFreeMemory(buf); }
    }

    /// The WinStation a session is attached to. Legitimately empty for some
    /// sessions, so an empty string is an answer rather than a failure.
    private static string SessionStation(uint id)
    {
        IntPtr buf; int len;
        // 6 = WTSWinStationName
        if (!WTSQuerySessionInformationW(IntPtr.Zero, id, 6, out buf, out len)) return "";
        try { return Marshal.PtrToStringUni(buf) ?? ""; }
        finally { WTSFreeMemory(buf); }
    }

    private static uint OwnSessionId()
    {
        using (var p = Process.GetCurrentProcess()) return (uint)p.SessionId;
    }

    /// The session holding the physical console, or -1 when nothing does —
    /// WTSGetActiveConsoleSessionId answers 0xFFFFFFFF while the console is
    /// mid-transition, which is a state and not a session number.
    private static int ConsoleSessionId()
    {
        uint console = WTSGetActiveConsoleSessionId();
        return console == 0xFFFFFFFF ? -1 : (int)console;
    }

    /// Which Windows session this process is actually running in.
    ///
    /// Without it the Mac cannot tell "the agent is in the wrong session" apart
    /// from "the session the agent is in has been disconnected": both answer
    /// list with an empty array, because a session with no display attached
    /// enumerates no monitors. After an RDP session to this machine closes, the
    /// agent's session sits Disconnected while a fresh console session owns the
    /// panel; inside a live RDP session the agent enumerates the virtual RDP
    /// display instead, and DDC writes to it succeed without ever reaching the
    /// panel. Reporting the session on every health and list answer is what
    /// lets the Mac say which of those it is looking at.
    ///
    /// Returns a well-formed fragment (no leading comma) whatever happens: a
    /// diagnostic that throws is worse than one that admits it does not know.
    private static string SessionFields()
    {
        uint id = 0;
        int console = -1, state = -1;
        string station = "";
        bool remote = false;
        try
        {
            id = OwnSessionId();
            console = ConsoleSessionId();
            state = SessionState(id);
            station = SessionStation(id);
            remote = GetSystemMetrics(SM_REMOTESESSION) != 0;
        }
        catch (Exception)
        {
            // Report whatever was gathered before the failure; the defaults
            // above already read as "unknown" rather than as a real session.
        }
        string name = state >= 0 && state < SessionStateNames.Length
            ? SessionStateNames[state] : "unknown";
        return "\"session\":{\"id\":" + id
             + ",\"console\":" + console
             + ",\"state\":\"" + Esc(name) + "\""
             + ",\"stateCode\":" + state
             + ",\"station\":\"" + Esc(station) + "\""
             + ",\"remote\":" + (remote ? "true" : "false")
             + ",\"onConsole\":" + (console >= 0 && id == (uint)console ? "true" : "false")
             + "}";
    }

    /// Move a disconnected session onto the physical console.
    ///
    /// The point of this is a machine with no reachable keyboard: RDP in from
    /// elsewhere, authenticate, disconnect — the session survives as
    /// Disconnected — then run this and it lands on the console, where the
    /// Monitor Configuration API can finally see the real panel. An RDP session
    /// is no good for that; it enumerates the virtual RDP display instead.
    ///
    /// MUST run as SYSTEM. The move needs SeTcbPrivilege, which an elevated
    /// administrator token does not carry — measured, not assumed: whoami /priv
    /// in an elevated SSH session lists 24 privileges and SeTcbPrivilege is not
    /// among them. install-service.ps1 therefore registers this half as a
    /// separate task with a ServiceAccount principal.
    ///
    /// Enumeration is done through wtsapi32 because it is structured. The move
    /// itself shells out to tscon.exe rather than calling WTSConnectSession:
    /// the API's two session-id parameters are documented ambiguously enough
    /// that getting them backwards is a real risk, and tscon's argument order
    /// is unambiguous and is what every operator has tested.
    /// The verdict goes to stdout for whoever ran this by hand, AND to
    /// reclaim.log beside the executable: the scheduled task runs this as
    /// SYSTEM with no console anyone can see, and Log() would land in SYSTEM's
    /// profile where nobody looks. The Mac reads the last line of this file to
    /// learn whether the move actually happened — schtasks /run returns the
    /// moment the task is queued and says nothing about tscon.
    private static void EmitReclaim(StringBuilder sb)
    {
        var line = sb.ToString();
        Console.WriteLine(line);
        try
        {
            var path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "reclaim.log");
            File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + "  " + line + Environment.NewLine);
        }
        catch (Exception) { }
    }

    private static int CmdReclaim()
    {
        IntPtr info; int count;
        if (!WTSEnumerateSessionsW(IntPtr.Zero, 0, 1, out info, out count))
        {
            Fail("WTSEnumerateSessions failed: " + Marshal.GetLastWin32Error());
            return 1;
        }

        var sessions = new List<WTS_SESSION_INFO>();
        try
        {
            int size = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
            for (int i = 0; i < count; i++)
            {
                var p = new IntPtr(info.ToInt64() + i * size);
                sessions.Add((WTS_SESSION_INFO)Marshal.PtrToStructure(p, typeof(WTS_SESSION_INFO)));
            }
        }
        finally { WTSFreeMemory(info); }

        uint console = WTSGetActiveConsoleSessionId();

        var sb = new StringBuilder();
        sb.Append("{\"ok\":true,\"console\":").Append(console).Append(",\"sessions\":[");
        for (int i = 0; i < sessions.Count; i++)
        {
            var s = sessions[i];
            if (i > 0) sb.Append(',');
            sb.Append("{\"id\":").Append(s.SessionId)
              .Append(",\"station\":\"").Append(Esc(s.pWinStationName))
              .Append("\",\"state\":").Append(s.State)
              .Append(",\"user\":\"").Append(Esc(SessionUser(s.SessionId))).Append("\"}");
        }
        sb.Append(']');

        // Already sitting on the console with a user in it? Then there is
        // nothing to reclaim, and saying so is more useful than moving something.
        foreach (var s in sessions)
        {
            if (s.SessionId == console && s.State == WTSActive && SessionUser(s.SessionId) != "")
            {
                sb.Append(",\"moved\":false,\"reason\":\"console already active\"}");
                EmitReclaim(sb);
                return 0;
            }
        }

        // Session 0 is services and is permanently disconnected; the rdp-tcp
        // listener shows up too. Neither is a user session.
        WTS_SESSION_INFO? target = null;
        foreach (var s in sessions)
        {
            if (s.State != WTSDisconnected) continue;
            if (s.SessionId == 0 || s.SessionId >= 65536) continue;
            if (SessionUser(s.SessionId) == "") continue;
            target = s;
            break;
        }

        if (target == null)
        {
            sb.Append(",\"moved\":false,\"reason\":\"no disconnected user session\"}");
            EmitReclaim(sb);
            return 2;
        }

        var t = target.Value;
        string output;
        int exit;
        try
        {
            var psi = new ProcessStartInfo("tscon.exe", t.SessionId + " /dest:console")
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            using (var proc = Process.Start(psi))
            {
                output = (proc.StandardOutput.ReadToEnd() + proc.StandardError.ReadToEnd()).Trim();
                proc.WaitForExit(30000);
                exit = proc.ExitCode;
            }
        }
        catch (Exception e)
        {
            sb.Append(",\"moved\":false,\"reason\":\"").Append(Esc(e.Message)).Append("\"}");
            EmitReclaim(sb);
            return 1;
        }

        sb.Append(",\"moved\":").Append(exit == 0 ? "true" : "false")
          .Append(",\"from\":").Append(t.SessionId)
          .Append(",\"exit\":").Append(exit)
          .Append(",\"tscon\":\"").Append(Esc(output)).Append("\"}");
        EmitReclaim(sb);
        return exit == 0 ? 0 : 1;
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

        // Announce ourselves on the LAN so zBezel discovers this machine without
        // anyone typing a hostname. Runs in the interactive session, which is the
        // only place the monitor can be enumerated. See AnnounceLoop.
        var announceThread = new System.Threading.Thread(AnnounceLoop);
        announceThread.IsBackground = true;
        announceThread.Start();

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


/// The console as a picture that keeps updating: an MJPEG server on loopback.
///
/// Plain HTTP over a raw socket rather than HttpListener, which wants a URL
/// reservation that only an elevated shell can grant — and this runs as the
/// logged-in user in the interactive session, on purpose. Loopback only: the
/// way in is an SSH tunnel, so the key that already opens the KVM channel is
/// the key that opens the picture. Frames are captured only while somebody is
/// watching; an idle server costs nothing.
///
///   GET /            a page showing the stream
///   GET /stream.mjpg multipart/x-mixed-replace, one JPEG per frame
///   GET /frame.jpg   a single JPEG, for anything that cannot do multipart
internal static class ScreenStream
{
    private static readonly object _sync = new object();
    private static System.Net.Sockets.TcpListener _listener;
    private static volatile bool _running;
    private static int _port, _fps, _maxWidth;
    private static long _quality;
    private static int _watching;
    private static long _framesSent;
    private static int _idleSince;

    /// Ten minutes with nobody watching and the listener goes away by itself.
    /// A viewer that closes its window drops the tunnel and nothing more, so
    /// without this a stream started once would listen forever. Harmless on
    /// loopback, but "harmless and forever" is how a machine ends up with
    /// six of them.
    private const int IdleStopMs = 600000;

    public static string Start(int port, int fps, int maxWidth, long quality)
    {
        lock (_sync)
        {
            if (_running)
                return "{\"ok\":true,\"streaming\":true,\"port\":" + _port + ",\"already\":true}";
            _port = port; _fps = Math.Max(1, Math.Min(30, fps)); _maxWidth = maxWidth; _quality = quality;
            try
            {
                _listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, _port);
                _listener.Start();
            }
            catch (Exception e)
            {
                _listener = null;
                return "{\"ok\":false,\"error\":\"cannot listen on 127.0.0.1:" + _port + ": " + BezelAgent.Esc(e.Message) + "\"}";
            }
            _running = true;
            _framesSent = 0;
            _idleSince = Environment.TickCount;
            var t = new Thread(AcceptLoop);
            t.IsBackground = true;
            t.Start();
            var idle = new Thread(IdleWatch);
            idle.IsBackground = true;
            idle.Start();
        }
        BezelAgent.Log("stream: listening on 127.0.0.1:" + _port + " at " + _fps + " fps, width " + _maxWidth);
        return "{\"ok\":true,\"streaming\":true,\"port\":" + _port + ",\"fps\":" + _fps
             + ",\"maxWidth\":" + _maxWidth + ",\"quality\":" + _quality + "}";
    }

    public static string Stop()
    {
        lock (_sync)
        {
            if (!_running) return "{\"ok\":true,\"streaming\":false}";
            _running = false;
            try { _listener.Stop(); } catch (Exception) { }
            _listener = null;
        }
        BezelAgent.Log("stream: stopped after " + _framesSent + " frame(s)");
        return "{\"ok\":true,\"streaming\":false,\"framesSent\":" + _framesSent + "}";
    }

    public static string Status()
    {
        return "{\"ok\":true,\"streaming\":" + (_running ? "true" : "false") + ",\"port\":" + _port
             + ",\"watching\":" + _watching + ",\"framesSent\":" + _framesSent + "}";
    }

    private static void IdleWatch()
    {
        while (_running)
        {
            Thread.Sleep(15000);
            if (!_running) break;
            if (_watching > 0) { _idleSince = Environment.TickCount; continue; }
            if (Environment.TickCount - _idleSince > IdleStopMs)
            {
                BezelAgent.Log("stream: nobody has watched for ten minutes; stopping");
                Stop();
                break;
            }
        }
    }

    private static void AcceptLoop()
    {
        while (_running)
        {
            System.Net.Sockets.TcpClient client;
            try { client = _listener.AcceptTcpClient(); }
            catch (Exception) { break; }       // Stop() closed the listener
            ThreadPool.QueueUserWorkItem(delegate { Serve(client); });
        }
    }

    private static void Serve(System.Net.Sockets.TcpClient client)
    {
        try
        {
            using (client)
            using (var s = client.GetStream())
            {
                client.NoDelay = true;
                client.ReceiveTimeout = 10000;
                var reader = new StreamReader(s, Encoding.ASCII, false, 1024, true);
                string request = reader.ReadLine();
                if (request == null) return;
                string line;
                while ((line = reader.ReadLine()) != null && line.Length > 0) { }   // headers, ignored

                var parts = request.Split(' ');
                string path = parts.Length > 1 ? parts[1] : "/";

                if (path.StartsWith("/stream"))
                {
                    WriteHead(s, "200 OK", "multipart/x-mixed-replace; boundary=frame", -1);
                    Interlocked.Increment(ref _watching);
                    try
                    {
                        int interval = 1000 / _fps;
                        while (_running)
                        {
                            int t0 = Environment.TickCount;
                            int w, h;
                            byte[] jpeg = BezelAgent.CaptureOrPlaceholder(_maxWidth, _quality, out w, out h);
                            var head = Encoding.ASCII.GetBytes("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: "
                                                               + jpeg.Length + "\r\n\r\n");
                            s.Write(head, 0, head.Length);
                            s.Write(jpeg, 0, jpeg.Length);
                            s.Write(new byte[] { 13, 10 }, 0, 2);
                            s.Flush();
                            Interlocked.Increment(ref _framesSent);
                            int spent = Environment.TickCount - t0;
                            if (spent < interval) Thread.Sleep(interval - spent);
                        }
                    }
                    finally { Interlocked.Decrement(ref _watching); }
                }
                else if (path.StartsWith("/frame"))
                {
                    int w, h;
                    byte[] jpeg = BezelAgent.CaptureOrPlaceholder(_maxWidth, _quality, out w, out h);
                    WriteHead(s, "200 OK", "image/jpeg", jpeg.Length);
                    s.Write(jpeg, 0, jpeg.Length);
                    s.Flush();
                }
                else
                {
                    var html = Encoding.UTF8.GetBytes(
                        "<!doctype html><html><head><meta charset=utf-8><title>" + Environment.MachineName
                        + " console</title><style>html,body{margin:0;height:100%;background:#111}"
                        + "img{display:block;max-width:100%;max-height:100vh;margin:0 auto}</style></head>"
                        + "<body><img src=\"/stream.mjpg\" alt=\"" + Environment.MachineName + "\"></body></html>");
                    WriteHead(s, "200 OK", "text/html; charset=utf-8", html.Length);
                    s.Write(html, 0, html.Length);
                    s.Flush();
                }
            }
        }
        catch (Exception)
        {
            // The viewer went away mid-frame. Nothing to do; the next one starts fresh.
        }
    }

    private static void WriteHead(Stream s, string status, string contentType, int length)
    {
        var sb = new StringBuilder();
        sb.Append("HTTP/1.1 ").Append(status).Append("\r\n")
          .Append("Content-Type: ").Append(contentType).Append("\r\n")
          .Append("Cache-Control: no-store\r\n")
          .Append("Connection: close\r\n");
        if (length >= 0) sb.Append("Content-Length: ").Append(length).Append("\r\n");
        sb.Append("\r\n");
        var bytes = Encoding.ASCII.GetBytes(sb.ToString());
        s.Write(bytes, 0, bytes.Length);
    }
}


/// A padlock on the glass, telling the user whether leaving this machine will
/// take the monitor back with them.
///
/// It lives on THIS machine because this machine is what the panel is showing;
/// anything the Mac drew would be behind a screen the user cannot see.
///
/// Click-through by construction (WS_EX_TRANSPARENT). The Mac already knows
/// where the pointer is on this desktop — it is the one putting it there — so it
/// recognises a click on the badge and never sends it. That saves hit-testing
/// here and, more usefully, means the badge cannot swallow a click meant for the
/// application beneath it.
internal static class LockOverlay
{
    /// Big enough to hit without aiming. The first attempt was 84 and read as a
    /// decoration rather than a control.
    internal const int Size = 140;

    private static Thread _ui;
    private static Form _form;
    private static bool _locked;

    /// -1 hide, 0 unlocked, 1 locked. x/y place its top-left corner; -1 leaves
    /// it where it is.
    /// The slide in flight, if any. Touched only on the form's thread.
    private static System.Windows.Forms.Timer _slide;

    public static void Set(int state, int x, int y)
    {
        if (state < 0) { Hide(); return; }
        bool wasLocked = _locked;
        _locked = state != 0;
        EnsureUI();
        var f = _form;
        if (f == null) { BezelAgent.Log("lock: no overlay form"); return; }
        try
        {
            f.BeginInvoke((MethodInvoker)delegate
            {
                var target = (x >= 0 && y >= 0) ? new Point(x, y) : f.Location;
                if (_slide != null) { _slide.Stop(); _slide.Dispose(); _slide = null; }

                // Slide only when a badge already on screen is being locked: the
                // motion IS the confirmation that the click took, and it shows
                // where the status light went to live. A badge appearing for the
                // first time, or one being unlocked, just goes where it is told.
                bool slide = _locked && !wasLocked && f.Visible && target != f.Location;
                if (!slide)
                {
                    f.Location = target;
                }
                else
                {
                    var start = f.Location;
                    int t0 = Environment.TickCount;
                    const int ms = 320;
                    _slide = new System.Windows.Forms.Timer { Interval = 16 };
                    _slide.Tick += delegate
                    {
                        double p = Math.Min(1.0, (Environment.TickCount - t0) / (double)ms);
                        double e = 1 - Math.Pow(1 - p, 3);   // ease out: fast away, settle gently
                        f.Location = new Point(
                            (int)Math.Round(start.X + (target.X - start.X) * e),
                            (int)Math.Round(start.Y + (target.Y - start.Y) * e));
                        if (p >= 1.0 && _slide != null) { _slide.Stop(); _slide.Dispose(); _slide = null; }
                    };
                    _slide.Start();
                }
                f.Visible = true;
                f.TopMost = true;   // re-asserted every time: TopMost decays if another topmost window appears
                f.Invalidate();
            });
            BezelAgent.Log("lock: badge " + (_locked ? "locked" : "unlocked"));
        }
        catch (Exception e) { BezelAgent.Log("lock: " + e.Message); }
    }

    public static void Hide()
    {
        var f = _form;
        if (f == null) return;
        try { f.BeginInvoke((MethodInvoker)delegate { f.Visible = false; }); }
        catch (InvalidOperationException) { }
    }

    private static void EnsureUI()
    {
        if (_ui != null) return;
        _ui = new Thread(delegate ()
        {
            var screen = Screen.PrimaryScreen.Bounds;
            var form = new BadgeForm
            {
                StartPosition = FormStartPosition.Manual,
                Location = new Point(screen.Left + 40,
                                     screen.Top + (screen.Height - Size) / 2),
                Size = new Size(Size, Size),
                Visible = false
            };
            // Touching Handle forces the window into existence. A Form that has
            // never been shown has no handle, and BeginInvoke on it throws — which
            // is exactly how this failed silently the first time.
            var forced = form.Handle;
            GC.KeepAlive(forced);
            _form = form;
            Application.Run(new ApplicationContext(form));
        });
        _ui.IsBackground = true;
        _ui.SetApartmentState(ApartmentState.STA);
        _ui.Start();

        // The form has to exist before anything can BeginInvoke onto it.
        for (int i = 0; i < 100 && (_form == null || !_form.IsHandleCreated); i++)
            Thread.Sleep(20);
    }

    private sealed class BadgeForm : Form
    {
        public BadgeForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            BackColor = Color.Black;
            TransparencyKey = Color.Magenta;
            Opacity = 0.5;
            DoubleBuffered = true;
        }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= 0x00080000   // WS_EX_LAYERED
                            | 0x00000020   // WS_EX_TRANSPARENT — clicks fall through
                            | 0x08000000   // WS_EX_NOACTIVATE — never takes focus
                            | 0x00000080;  // WS_EX_TOOLWINDOW — no Alt-Tab entry
                return cp;
            }
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.Clear(Color.Magenta);

            var w = ClientSize.Width;
            var h = ClientSize.Height;
            using (var plate = new SolidBrush(Color.FromArgb(210, 20, 20, 22)))
                g.FillRectangle(plate, 0, 0, w, h);

            var pen = new Pen(Color.White, 8f);
            pen.StartCap = System.Drawing.Drawing2D.LineCap.Round;
            pen.EndCap = System.Drawing.Drawing2D.LineCap.Round;

            // Body.
            var body = new Rectangle(w / 2 - 34, h / 2 - 4, 68, 50);
            using (var fill = new SolidBrush(Color.White))
                g.FillRectangle(fill, body);

            // Shackle: upright when shut, tipped open when not — the difference
            // has to be legible at a glance from across a desk.
            if (_locked)
                g.DrawArc(pen, w / 2 - 22, h / 2 - 46, 44, 52, 180, 180);
            else
                g.DrawArc(pen, w / 2 - 2, h / 2 - 50, 44, 52, 180, 150);

            pen.Dispose();
        }
    }
}


/// A full-screen black curtain this machine draws over itself, so an input
/// switch away from or back to it is a dissolve rather than a cut.
///
/// Same reason the badge lives here: while this machine is on the panel, the
/// Mac's own curtain is behind a screen nobody can see, so the machine has to
/// fade itself. The backlight cannot do this smoothly over the proxy — a DDC
/// write costs the better part of a second, so a ramp can only step coarsely —
/// whereas a layered window's opacity animates on the GPU at any frame rate.
///
/// Click-through and never-focus, exactly like the badge (WS_EX_TRANSPARENT /
/// NOACTIVATE), so it cannot swallow input while it is up: the Mac keeps driving
/// the desktop beneath it right through a fade.
internal static class FadeOverlay
{
    private static Thread _ui;
    private static Form _form;
    private static System.Windows.Forms.Timer _fade;
    private static System.Windows.Forms.Timer _watchdog;
    private static double _current;   // 0..1, touched only on the form thread

    /// Drive the curtain to `opacityPercent` (0..100) over `ms` milliseconds.
    /// ms <= 0 sets it at once — used to arm it black behind an input that is not
    /// yet on screen, where there is nothing to animate.
    public static void Set(int opacityPercent, int ms)
    {
        double target = Math.Max(0, Math.Min(100, opacityPercent)) / 100.0;
        BezelAgent.Log("fade: -> " + opacityPercent + "% over " + ms + "ms");
        EnsureUI();
        var f = _form;
        if (f == null) { BezelAgent.Log("fade: no overlay form"); return; }
        try
        {
            f.BeginInvoke((MethodInvoker)delegate
            {
                if (_fade != null) { _fade.Stop(); _fade.Dispose(); _fade = null; }

                // Safety net. A black curtain whose clearing command never arrives
                // — a dropped message, the Mac quitting mid-switch — would leave
                // this machine's screen black with no way back from its own side.
                // So any time it is driven toward black, arm a watchdog that fades
                // it away on its own; a command that takes it transparent cancels
                // it. A normal switch clears it within a few seconds, well under
                // the timeout, so this only ever fires on a genuinely stuck curtain.
                if (_watchdog != null) { _watchdog.Stop(); _watchdog.Dispose(); _watchdog = null; }
                if (target > 0)
                {
                    _watchdog = new System.Windows.Forms.Timer { Interval = 8000 };
                    _watchdog.Tick += delegate
                    {
                        if (_watchdog != null) { _watchdog.Stop(); _watchdog.Dispose(); _watchdog = null; }
                        BezelAgent.Log("fade: watchdog cleared a stuck curtain");
                        Set(0, 500);
                    };
                    _watchdog.Start();
                }

                // Coming up from nothing: the window must be present before it is
                // asked to show any black.
                if (target > 0) { f.Visible = true; f.TopMost = true; }

                if (ms <= 0)
                {
                    _current = target;
                    f.Opacity = target;
                    if (target <= 0) f.Visible = false;
                    return;
                }

                double start = _current;
                int t0 = Environment.TickCount;
                _fade = new System.Windows.Forms.Timer { Interval = 16 };
                _fade.Tick += delegate
                {
                    double p = Math.Min(1.0, (Environment.TickCount - t0) / (double)ms);
                    double e = p * p * (3 - 2 * p);   // smoothstep: eases in and out
                    _current = start + (target - start) * e;
                    f.Opacity = _current;
                    f.TopMost = true;   // TopMost decays when another topmost appears
                    if (p >= 1.0)
                    {
                        _current = target;
                        f.Opacity = target;
                        if (target <= 0) f.Visible = false;   // gone, not a 0% ghost
                        if (_fade != null) { _fade.Stop(); _fade.Dispose(); _fade = null; }
                    }
                };
                _fade.Start();
            });
        }
        catch (Exception e) { BezelAgent.Log("fade: " + e.Message); }
    }

    private static void EnsureUI()
    {
        if (_ui != null) return;
        _ui = new Thread(delegate ()
        {
            // The whole virtual desktop, so whichever monitor is the panel is
            // covered without the agent having to know which one it is.
            var vs = SystemInformation.VirtualScreen;
            var form = new CurtainForm
            {
                StartPosition = FormStartPosition.Manual,
                Location = new Point(vs.Left, vs.Top),
                Size = new Size(vs.Width, vs.Height),
                Opacity = 0.0,
                Visible = false
            };
            var forced = form.Handle;   // force the window into existence
            GC.KeepAlive(forced);
            _form = form;
            Application.Run(new ApplicationContext(form));
        });
        _ui.IsBackground = true;
        _ui.SetApartmentState(ApartmentState.STA);
        _ui.Start();
        for (int i = 0; i < 100 && (_form == null || !_form.IsHandleCreated); i++)
            Thread.Sleep(20);
    }

    private sealed class CurtainForm : Form
    {
        public CurtainForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            BackColor = Color.Black;   // solid black, opacity does the blending
            DoubleBuffered = true;
        }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= 0x00080000   // WS_EX_LAYERED
                            | 0x00000020   // WS_EX_TRANSPARENT — clicks fall through
                            | 0x08000000   // WS_EX_NOACTIVATE — never takes focus
                            | 0x00000080;  // WS_EX_TOOLWINDOW — no Alt-Tab entry
                return cp;
            }
        }

        protected override bool ShowWithoutActivation { get { return true; } }
    }
}


/// The ghosts: what this machine draws for a drag that came from the Mac.
///
/// One per drag in flight, not one for all. A large file is still landing long
/// after the user let go of it, and by then they may be dragging the next one;
/// so each stage has its own window and its own state, every message from the
/// Mac names the stage it is about, and a message for a stage that is not here
/// is about a drag that is already over and does nothing. At most one ghost is
/// Carrying — the one in hand — while any number sit in their Explorer items
/// filling up.
internal static class DragGhost
{
    /// What a ghost is doing. Carrying follows the cursor; Parked sits at the
    /// drop point, anchored to the window if there was one; Snapping is the
    /// animation from the page down into the Explorer item; Item is the thin
    /// progress bar clipped to that item until the real file replaces it.
    internal enum Mode { Carrying, Parked, Snapping, Item }

    /// One drag's state. Written from the pipe reader, the item tracker and
    /// the UI thread, so every field lives under DragGhost's lock and Follow()
    /// reads them in one Snapshot. `Form` is the exception: UI thread only.
    internal sealed class Ghost
    {
        public readonly string Stage;
        public string Label = "";
        public long Total;
        public Image Icon;
        public GhostForm Form;

        public Mode Mode = Mode.Carrying;
        public IntPtr Anchor;            // Explorer window the drop landed in, or Zero
        public Point AnchorOffset;       // parked page top-left relative to that window
        public Point ParkedAt;
        /// The last sign of life: the release, bytes arriving, the drop. The
        /// self-clear clocks run from here rather than from the release, so a
        /// slow copy is never mistaken for a dead one.
        public int IdleSince;
        public int FailedTicks;
        public string FailReason;
        public bool Delivering;          // DROP has arrived: the bar is full, whatever staging says
        public Rectangle LastBounds;     // where the page was last drawn, for the snap to start from

        public Rectangle SnapFrom, ItemRect;
        public Point ItemOffset;         // the item's top-left relative to Anchor's frame
        public int SnapStart;
        public string ItemName;
        public IntPtr ItemRoot;
        public bool Tracking;

        public double FracValue;
        public int FracAt;

        public Ghost(string stage) { Stage = stage; IdleSince = Environment.TickCount; }
    }

    private static readonly object _sync = new object();
    private static readonly Dictionary<string, Ghost> _ghosts = new Dictionary<string, Ghost>();
    private static Thread _ui;
    private static Dispatcher _dispatcher;
    /// "DI" arrives before the "D" it belongs to; held for the next new ghost.
    private static Image _nextIcon;

    private static Ghost Get(string stage)
    {
        if (stage == null) return null;
        lock (_sync) { Ghost g; return _ghosts.TryGetValue(stage, out g) ? g : null; }
    }

    private static bool Alive(Ghost g)
    {
        lock (_sync) { Ghost cur; return _ghosts.TryGetValue(g.Stage, out cur) && cur == g; }
    }

    /// The drag in hand, if any: what a MARK that names no stage is about.
    internal static string CarryingStage
    {
        get
        {
            lock (_sync)
                foreach (var g in _ghosts.Values) if (g.Mode == Mode.Carrying) return g.Stage;
            return null;
        }
    }

    public static void Show(string stage, long total, string label)
    {
        if (string.IsNullOrEmpty(stage)) return;
        Ghost g; bool fresh;
        lock (_sync)
        {
            // A second "D" for a ghost already here only refines the numbers
            // (the Mac re-sends once it has walked a folder for its true size).
            // It must not un-park a ghost the user has already dropped.
            fresh = !_ghosts.TryGetValue(stage, out g);
            if (fresh)
            {
                g = new Ghost(stage);
                g.Icon = _nextIcon;
                _nextIcon = null;
                _ghosts[stage] = g;
            }
            g.Label = label ?? "";
            g.Total = total;
        }
        if (!fresh) { BezelAgent.Log("ghost: " + stage + " size corrected to " + total); return; }

        EnsureUI();
        var ghost = g;
        OnUI(delegate
        {
            var f = new GhostForm(ghost);
            ghost.Form = f;
            f.Visible = true;
            f.TopMost = true;
            f.Follow();
        });
        BezelAgent.Log("ghost: carrying " + g.Label + " (" + stage + ")");
    }

    /// Stop following the cursor and stay where it was dropped.
    public static void Park(string stage)
    {
        var g = Get(stage); if (g == null) return;
        var p = Cursor.Position;
        lock (_sync)
        {
            g.Mode = Mode.Parked;
            g.ParkedAt = new Point(p.X + 16, p.Y + 16);   // matches Follow()'s placement
            g.IdleSince = Environment.TickCount;
        }
    }

    /// Ride inside this window from now on. Zero means the desktop: stay put.
    public static void AttachAnchor(string stage, IntPtr hwnd)
    {
        var g = Get(stage); if (g == null) return;
        lock (_sync)
        {
            g.Anchor = IntPtr.Zero;
            if (hwnd == IntPtr.Zero) return;
            RECT r;
            if (!GetWindowRect(hwnd, out r)) return;
            g.AnchorOffset = new Point(g.ParkedAt.X - r.Left, g.ParkedAt.Y - r.Top);
            g.Anchor = hwnd;
        }
        BezelAgent.Log("ghost: " + stage + " anchored to window " + hwnd);
    }

    /// The window the ghost was riding in has closed. The bar has nowhere to
    /// be, so it is a page again, frozen where the drop was.
    private static void WindowGone(Ghost g)
    {
        lock (_sync)
        {
            g.Anchor = IntPtr.Zero;
            if (g.Mode == Mode.Item || g.Mode == Mode.Snapping) g.Mode = Mode.Parked;
        }
    }

    /// The placeholder is in the folder and Explorer has drawn it: go and be it.
    ///
    /// The item's place is kept relative to the window's frame, not as a
    /// screen rectangle. While the user drags the window the item keeps its
    /// place inside it, and the frame is a microsecond call where the
    /// Automation query that found the item takes tens of milliseconds and is
    /// stale by the time it answers. So Follow() pins the bar to the frame
    /// every tick, and the tracker below only corrects where the item sits
    /// WITHIN the frame when Explorer scrolls or re-sorts.
    public static void SnapToItem(string stage, IntPtr root, string name, Rectangle item)
    {
        var g = Get(stage); if (g == null) return;
        var offset = item.Location;
        RECT r;
        if (root != IntPtr.Zero && GetWindowRect(root, out r)) offset = new Point(item.X - r.Left, item.Y - r.Top);
        lock (_sync)
        {
            if (g.Mode != Mode.Parked) return;
            g.Mode = Mode.Snapping;
            g.SnapFrom = g.LastBounds;
            g.ItemRect = item;
            g.ItemOffset = offset;
            g.ItemName = name;
            g.ItemRoot = root;
            g.SnapStart = Environment.TickCount;
            g.IdleSince = g.SnapStart;
        }
        BezelAgent.Log("ghost: " + stage + " snapping into " + name + " at " + item);
        StartTracking(g);
    }

    /// Explorer re-sorts and scrolls; keep finding the item so the bar stays on
    /// it. Off the UI thread: a UI Automation query can take tens of ms.
    private static void StartTracking(Ghost g)
    {
        lock (_sync) { if (g.Tracking) return; g.Tracking = true; }
        ThreadPool.QueueUserWorkItem(delegate
        {
            try
            {
                while (true)
                {
                    Thread.Sleep(400);
                    IntPtr root; string name; Mode mode;
                    lock (_sync) { root = g.ItemRoot; name = g.ItemName; mode = g.Mode; }
                    if (!Alive(g) || (mode != Mode.Item && mode != Mode.Snapping)) break;

                    // The reading is only good if the frame held still across
                    // the query; otherwise the offset would carry the move.
                    RECT before = new RECT(), after = new RECT();
                    bool framed = root != IntPtr.Zero && GetWindowRect(root, out before);
                    var found = DropTarget.FindItemRect(root, name);
                    if (!found.HasValue) continue;
                    if (root == IntPtr.Zero) { lock (_sync) g.ItemRect = found.Value; continue; }
                    if (!framed || !GetWindowRect(root, out after)
                        || after.Left != before.Left || after.Top != before.Top) continue;
                    lock (_sync)
                    {
                        g.ItemRect = found.Value;
                        g.ItemOffset = new Point(found.Value.X - after.Left, found.Value.Y - after.Top);
                    }
                }
            }
            finally { lock (_sync) g.Tracking = false; }
        });
    }

    /// Where the item is right now: the frame's position plus the offset.
    internal static Rectangle ItemBounds(IntPtr anchor, Point itemOffset, Rectangle itemRect)
    {
        RECT r;
        if (anchor != IntPtr.Zero && GetWindowRect(anchor, out r))
            return new Rectangle(r.Left + itemOffset.X, r.Top + itemOffset.Y, itemRect.Width, itemRect.Height);
        return itemRect;
    }

    internal static void NoteBounds(Ghost g, Rectangle b) { lock (_sync) g.LastBounds = b; }
    internal static void FinishSnap(Ghost g) { lock (_sync) if (g.Mode == Mode.Snapping) g.Mode = Mode.Item; }

    /// DROP has arrived: from here the bar is full and stays up until the move
    /// into place is really done. Staging is being emptied by that move, so
    /// measuring it now would run the bar backwards.
    public static void Delivering(string stage)
    {
        var g = Get(stage); if (g == null) return;
        lock (_sync) { g.Delivering = true; g.IdleSince = Environment.TickCount; }
    }

    /// The move failed or the Mac went away. Show why, briefly, then clear.
    /// Wakes a dormant ghost: a failure that arrives after the copy stalled
    /// is exactly the one that must be seen.
    public static void Fail(string stage, string reason)
    {
        var g = Get(stage);
        BezelAgent.Log("ghost: " + stage + " FAILED " + reason + (g == null ? " (no ghost to show it)" : ""));
        if (g == null) return;
        lock (_sync)
        {
            g.FailReason = reason ?? "failed";
            g.FailedTicks = Environment.TickCount;
            g.Delivering = false;
            g.IdleSince = g.FailedTicks;
        }
        OnUI(delegate { if (g.Form != null && !g.Form.IsDisposed) g.Form.Invalidate(); });
    }

    /// This drag is over. `discardBytes` for a drag that was abandoned: its
    /// staging folder is unwanted, and the scp that was filling it has been
    /// stopped by the Mac.
    public static void Hide(string stage, bool discardBytes)
    {
        var g = Get(stage);
        if (g != null) Remove(g);
        DropTarget.Discard(stage);
        if (discardBytes) DropTarget.ForgetStaging(stage);
    }

    /// Everything, at once: the Mac stood the whole KVM down.
    public static void HideAll()
    {
        List<Ghost> all;
        lock (_sync) { all = new List<Ghost>(_ghosts.Values); }
        foreach (var g in all) Remove(g);
        DropTarget.DiscardAll();
        SetIcon(null);
    }

    private static void Remove(Ghost g)
    {
        lock (_sync)
        {
            Ghost cur;
            if (_ghosts.TryGetValue(g.Stage, out cur) && cur == g) _ghosts.Remove(g.Stage);
        }
        OnUI(delegate
        {
            var f = g.Form;
            g.Form = null;
            if (f != null)
            {
                try { f.Close(); f.Dispose(); }
                catch (Exception e) { BezelAgent.Log("ghost: " + e.Message); }
            }
            if (g.Icon != null) { g.Icon.Dispose(); g.Icon = null; }
        });
    }

    /// The icon Finder shows for whatever is being dragged, sent over as a PNG
    /// before the ghost appears. Drawn instead of the hand-made page, so the
    /// thing under the pointer looks like what was picked up — a thumbnail for
    /// an image, an app's own icon for an app — rather than a generic sheet that
    /// only means "a file".
    ///
    /// Null when the Mac sent nothing, and the drawn page stands in.
    public static void SetIcon(byte[] png)
    {
        Image next = null;
        if (png != null && png.Length > 0)
        {
            try
            {
                // Copy out of the stream: Image keeps the stream alive, and a
                // disposed one gives a GDI+ error at paint time rather than here.
                using (var ms = new System.IO.MemoryStream(png))
                using (var loaded = Image.FromStream(ms))
                    next = new Bitmap(loaded);
            }
            catch (Exception e) { BezelAgent.Log("drag icon: " + e.Message); }
        }
        lock (_sync)
        {
            if (_nextIcon != null) _nextIcon.Dispose();
            _nextIcon = next;
        }
    }

    /// How much of this drag has landed, measured rather than estimated: the
    /// bytes actually present in its staging folder against the total the Mac
    /// said it was sending. No round trips -- both numbers are known here.
    internal static double Fraction(Ghost g)
    {
        int now = Environment.TickCount;
        string stage; long total;
        lock (_sync)
        {
            if (g.Delivering) return 1.0;
            // Cached: this walked the staging tree at 60 Hz from the paint timer.
            if (g.FracAt != 0 && now - g.FracAt < 150) return g.FracValue;
            g.FracAt = now;
            stage = g.Stage; total = g.Total;
        }
        var v = ComputeFraction(stage, total);
        lock (_sync)
        {
            if (v > g.FracValue) g.IdleSince = now;   // bytes are moving: not dead
            g.FracValue = v;
        }
        return v;
    }

    private static double ComputeFraction(string stage, long total)
    {
        if (total <= 0 || string.IsNullOrEmpty(stage)) return 0;
        try
        {
            var dir = System.IO.Path.Combine(DropTarget.Staging, stage);
            if (!System.IO.Directory.Exists(dir)) return 0;
            long have = 0;
            // Recursive: a dropped folder is a subdirectory of the stage. The
            // per-file try matters — scp replaces files between enumeration and
            // stat, and one FileNotFound must not zero the entire bar.
            foreach (var f in System.IO.Directory.GetFiles(dir, "*", System.IO.SearchOption.AllDirectories))
            {
                try { have += new System.IO.FileInfo(f).Length; } catch { }
            }
            return Math.Max(0, Math.Min(1, (double)have / total));
        }
        catch { return 0; }
    }

    /// Follow()'s view of a ghost, taken in one lock so the fields cannot
    /// change under it mid-decision.
    internal static void Snapshot(Ghost g, out Mode mode, out IntPtr anchor, out Point offset, out Point parkedAt,
                                  out int idleSince, out int failedTicks, out bool delivering,
                                  out Rectangle snapFrom, out Rectangle itemRect, out Point itemOffset, out int snapStart)
    {
        lock (_sync)
        {
            mode = g.Mode; anchor = g.Anchor; offset = g.AnchorOffset; parkedAt = g.ParkedAt;
            idleSince = g.IdleSince; failedTicks = g.FailedTicks; delivering = g.Delivering;
            snapFrom = g.SnapFrom; itemRect = g.ItemRect; itemOffset = g.ItemOffset; snapStart = g.SnapStart;
        }
    }
    internal static string FailReason(Ghost g) { lock (_sync) return g.FailReason; }
    internal static bool IsDelivering(Ghost g) { lock (_sync) return g.Delivering; }

    // MARK: the UI thread

    private static void EnsureUI()
    {
        if (_ui != null) return;
        _ui = new Thread(delegate ()
        {
            var d = new Dispatcher();
            var forced = d.Handle;
            GC.KeepAlive(forced);
            _dispatcher = d;
            Application.Run(new ApplicationContext(d));
        });
        _ui.IsBackground = true;
        _ui.SetApartmentState(ApartmentState.STA);
        _ui.Start();
        for (int i = 0; i < 100 && (_dispatcher == null || !_dispatcher.IsHandleCreated); i++)
            Thread.Sleep(20);
    }

    private static void OnUI(MethodInvoker work)
    {
        var d = _dispatcher;
        if (d == null) return;
        try { d.BeginInvoke(work); } catch (InvalidOperationException) { }
    }

    /// Never shown. It owns the message loop the ghosts live on, the one timer
    /// that drives all of them, and the hook that follows their windows.
    private sealed class Dispatcher : Form
    {
        private readonly System.Windows.Forms.Timer _tick;

        public Dispatcher()
        {
            ShowInTaskbar = false;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-32000, -32000);
            Size = new Size(1, 1);
            _tick = new System.Windows.Forms.Timer { Interval = 16 };
            _tick.Tick += delegate { Tick(); };
            _tick.Start();
        }

        protected override bool ShowWithoutActivation { get { return true; } }
    }

    private static void Tick()
    {
        List<Ghost> all; bool anchored = false;
        lock (_sync)
        {
            all = new List<Ghost>(_ghosts.Values);
            foreach (var g in all) if (g.Anchor != IntPtr.Zero) anchored = true;
        }
        if (anchored) EnsureMoveHook(); else DropMoveHook();
        foreach (var g in all)
        {
            var f = g.Form;
            if (f == null || f.IsDisposed) continue;
            try { f.Follow(); } catch (Exception e) { BezelAgent.Log("ghost: " + e.Message); }
        }
    }

    // A window being dragged reports every step of its move. Following those
    // rather than waiting for the timer puts the bar on its item in the same
    // frame the window lands in, instead of one behind it. Installed only
    // while some ghost is anchored, and on this thread, so the callback runs
    // here through the message loop.
    private delegate void WinEventProc(IntPtr hook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
    [DllImport("user32.dll")]
    private static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmod, WinEventProc proc,
                                                 uint idProcess, uint idThread, uint flags);
    [DllImport("user32.dll")] private static extern bool UnhookWinEvent(IntPtr hook);
    private const uint EVENT_OBJECT_LOCATIONCHANGE = 0x800B;
    private static WinEventProc _moveProc;   // held: the hook keeps only a raw pointer to it
    private static IntPtr _moveHook;

    private static void EnsureMoveHook()
    {
        if (_moveHook != IntPtr.Zero) return;
        _moveProc = OnWindowMoved;
        _moveHook = SetWinEventHook(EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE,
                                    IntPtr.Zero, _moveProc, 0, 0, 0 /* WINEVENT_OUTOFCONTEXT */);
    }

    private static void DropMoveHook()
    {
        if (_moveHook == IntPtr.Zero) return;
        UnhookWinEvent(_moveHook);
        _moveHook = IntPtr.Zero;
    }

    private static void OnWindowMoved(IntPtr hook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        if (idObject != 0 || idChild != 0) return;   // OBJID_WINDOW: the frame, not a child or the caret
        List<Ghost> hit = null;
        lock (_sync)
            foreach (var g in _ghosts.Values)
                if (g.Anchor == hwnd) { if (hit == null) hit = new List<Ghost>(); hit.Add(g); }
        if (hit == null) return;
        foreach (var g in hit)
        {
            var f = g.Form;
            if (f != null && !f.IsDisposed) f.Follow();
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] internal static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] internal static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] internal static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] internal static extern bool IsIconic(IntPtr hWnd);

    internal sealed class GhostForm : Form
    {
        private readonly Ghost _g;

        // 8.5 x 11 at 20 points per inch, plus a strip for the name.
        private const int PageW = 170;
        private const int PageH = 220;
        private const int LabelH = 30;
        private const int BarH = 5;

        public GhostForm(Ghost g)
        {
            _g = g;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            // White, and translucent by Opacity alone. NO TransparencyKey: a
            // layered window applies the colour key AFTER the alpha, so a keyed
            // colour at 72% opacity no longer matches the key and shows through —
            // which is where the pink came from. Clipping the window to the shape
            // of the page does the same job with none of that.
            BackColor = Color.White;
            Opacity = 0.62;
            DoubleBuffered = true;
            // Sized to the page it draws. Anything smaller left the bottom of
            // the sheet and the whole label strip outside the window.
            Size = new Size(PageW + 20, PageH + LabelH);
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            ApplyLook(Mode.Carrying, Rectangle.Empty);
        }

        private Mode _look = Mode.Carrying;

        /// Shape and size for a mode. Carrying/Parked: the page at its natural
        /// size. Snapping: the page scaled to `bounds`. Item: `bounds` is the
        /// Explorer item and the window is clipped to a thin bar along its foot,
        /// so what shows is a progress bar on the real icon and nothing else.
        public void ApplyLook(Mode mode, Rectangle bounds)
        {
            using (var shape = new System.Drawing.Drawing2D.GraphicsPath())
            {
                switch (mode)
                {
                    case Mode.Carrying:
                    case Mode.Parked:
                        if (Size != new Size(PageW + 20, PageH + LabelH)) Size = new Size(PageW + 20, PageH + LabelH);
                        shape.AddPath(PagePath(), false);
                        shape.AddRectangle(new Rectangle(0, PageH + 4, PageW + 20, LabelH - 4));
                        Opacity = 0.62;
                        break;
                    case Mode.Snapping:
                        Bounds = bounds;
                        var page = PagePath();
                        using (var m = new System.Drawing.Drawing2D.Matrix())
                        {
                            m.Scale(Math.Max(0.01f, bounds.Width / (float)(PageW + 20)),
                                    Math.Max(0.01f, bounds.Height / (float)(PageH + LabelH)));
                            page.Transform(m);
                        }
                        shape.AddPath(page, false);
                        Opacity = 0.62;
                        break;
                    case Mode.Item:
                        Bounds = bounds;
                        shape.AddRectangle(new Rectangle(0, Math.Max(0, bounds.Height - BarH), bounds.Width, BarH));
                        Opacity = 0.95;
                        break;
                }
                Region = new Region(shape);
            }
            _look = mode;
        }

        /// A page with the top-right corner turned down.
        private static System.Drawing.Drawing2D.GraphicsPath PagePath()
        {
            const int x = 10, y = 4, fold = 34;
            var p = new System.Drawing.Drawing2D.GraphicsPath();
            p.AddLines(new[] {
                new Point(x, y),
                new Point(x + PageW - fold, y),
                new Point(x + PageW, y + fold),
                new Point(x + PageW, y + PageH - 8),
                new Point(x, y + PageH - 8),
                new Point(x, y)
            });
            p.CloseFigure();
            return p;
        }

        private double _lastPainted = -1;

        public void Follow()
        {
            if (IsDisposed) return;
            var g = _g;
            int now = Environment.TickCount;
            // Asked first: it stamps IdleSince when bytes have moved.
            var frac = DragGhost.Fraction(g);

            Mode mode; IntPtr anchor; Point offset, parkedAt, itemOffset;
            int idleSince, failedTicks, snapStart; bool delivering; Rectangle snapFrom, itemRect;
            DragGhost.Snapshot(g, out mode, out anchor, out offset, out parkedAt, out idleSince, out failedTicks,
                               out delivering, out snapFrom, out itemRect, out itemOffset, out snapStart);

            // A failure shows for four seconds, then the ghost goes. It is the
            // one thing that overrides dormancy below, so a failure that arrives
            // after the copy stalled is still seen.
            if (failedTicks != 0 && now - failedTicks > 4000) { DragGhost.Remove(g); return; }

            if (mode == Mode.Carrying)
            {
                var p = Cursor.Position;
                Location = new Point(p.X + 16, p.Y + 16);
                if (!Visible) Visible = true;
                DragGhost.NoteBounds(g, Bounds);
                return;
            }

            // Parked, one way or another. The clocks run from the last sign of
            // life — the release, bytes arriving, the drop — never from the
            // release alone, which hid a slow copy's bar two minutes in. Two
            // minutes of nothing means the copy has stalled or the Mac is gone:
            // go dormant, and come back if bytes move again. An hour of nothing
            // and the drag is over. While the move into place runs there is no
            // clock at all: Deliver always ends in Hide or Fail.
            if (failedTicks == 0 && !delivering)
            {
                int idle = now - idleSince;
                if (idle > 3600000)
                {
                    BezelAgent.Log("ghost: " + g.Stage + " gave up after an hour without progress");
                    DragGhost.Hide(g.Stage, true);
                    return;
                }
                if (idle > 120000) { if (Visible) Visible = false; return; }
            }

            if (anchor != IntPtr.Zero && !DragGhost.IsWindow(anchor))
            {
                DragGhost.WindowGone(g);
                anchor = IntPtr.Zero;
                if (mode == Mode.Item || mode == Mode.Snapping) mode = Mode.Parked;
            }
            if (anchor != IntPtr.Zero && (DragGhost.IsIconic(anchor) || !DragGhost.IsWindowVisible(anchor)))
            {
                if (Visible) Visible = false;
                return;
            }
            if (!Visible) Visible = true;

            if (mode == Mode.Snapping)
            {
                var item = DragGhost.ItemBounds(anchor, itemOffset, itemRect);
                double pgs = Math.Min(1.0, (now - snapStart) / 260.0);
                double e = 1 - Math.Pow(1 - pgs, 3);
                var b = new Rectangle(
                    (int)Math.Round(snapFrom.X + (item.X - snapFrom.X) * e),
                    (int)Math.Round(snapFrom.Y + (item.Y - snapFrom.Y) * e),
                    Math.Max(8, (int)Math.Round(snapFrom.Width + (item.Width - snapFrom.Width) * e)),
                    Math.Max(8, (int)Math.Round(snapFrom.Height + (item.Height - snapFrom.Height) * e)));
                ApplyLook(pgs >= 1.0 ? Mode.Item : Mode.Snapping, pgs >= 1.0 ? item : b);
                if (pgs >= 1.0) DragGhost.FinishSnap(g);
                Invalidate();
                return;
            }
            if (mode == Mode.Item)
            {
                // Pinned to the frame every tick (and on every move event), so
                // the bar travels with the window rather than after it.
                var item = DragGhost.ItemBounds(anchor, itemOffset, itemRect);
                if (Bounds != item || _look != Mode.Item) ApplyLook(Mode.Item, item);
                if (Math.Abs(frac - _lastPainted) >= 0.005 || failedTicks != 0) { _lastPainted = frac; Invalidate(); }
                return;
            }

            // Parked: the page, riding in its window or frozen where it dropped.
            if (_look != Mode.Parked) ApplyLook(Mode.Parked, Rectangle.Empty);
            if (anchor == IntPtr.Zero)
            {
                // The desktop, or a window that closed under us: frozen where it
                // was dropped. The move still lands — the path was fixed at MARK.
                if (Location != parkedAt) Location = parkedAt;
            }
            else
            {
                DragGhost.RECT r;
                if (DragGhost.GetWindowRect(anchor, out r))
                {
                    int ox = Math.Max(0, Math.Min(offset.X, (r.Right - r.Left) - Width));
                    int oy = Math.Max(0, Math.Min(offset.Y, (r.Bottom - r.Top) - Height));
                    var want = new Point(r.Left + ox, r.Top + oy);
                    if (want != Location) Location = want;
                }
            }
            DragGhost.NoteBounds(g, Bounds);

            // Repaint only when the bar has visibly moved; the fraction is cached
            // in DragGhost, so this is cheap to ask.
            if (Math.Abs(frac - _lastPainted) >= 0.005 || failedTicks != 0)
            {
                _lastPainted = frac;
                Invalidate();
            }
        }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= 0x00080000 | 0x00000020 | 0x08000000 | 0x00000080;
                return cp;
            }
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;

            if (_look == Mode.Item)
            {
                // The real icon is Explorer's; ours is only the bar at its foot.
                // Blue while the bytes arrive from the Mac, green while they
                // move into place, amber if they could not.
                var itemWhy = DragGhost.FailReason(_g);
                var delivering = DragGhost.IsDelivering(_g);
                var itemDone = DragGhost.Fraction(_g);
                int w = ClientSize.Width, h = ClientSize.Height;
                var strip = new Rectangle(0, Math.Max(0, h - BarH), w, BarH);
                using (var track = new SolidBrush(Color.FromArgb(255, 60, 60, 66))) g.FillRectangle(track, strip);
                var fillColor = itemWhy != null ? Color.FromArgb(255, 230, 140, 30)
                              : delivering     ? Color.FromArgb(255, 70, 190, 110)
                                               : Color.FromArgb(255, 60, 160, 255);
                var fillFrac = (itemWhy != null || delivering) ? 1.0 : itemDone;
                using (var fill = new SolidBrush(fillColor))
                    g.FillRectangle(fill, new Rectangle(strip.X, strip.Y, (int)(strip.Width * fillFrac), strip.Height));
                return;
            }

            g.Clear(Color.White);

            const int x = 10, y = 4, fold = 34;

            var icon = _g.Icon;
            if (icon != null)
            {
                // Square, centred in the page area, keeping its aspect: macOS
                // icons are square but a thumbnail of a photograph is not, and
                // stretching one to fill would look nothing like the drag the
                // user started.
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                int box = Math.Min(PageW, PageH - 8);
                float scale = Math.Min((float)box / icon.Width, (float)box / icon.Height);
                int w = (int)(icon.Width * scale), h = (int)(icon.Height * scale);
                g.DrawImage(icon, x + (PageW - w) / 2, y + (PageH - 8 - h) / 2, w, h);
            }
            else
            {
                using (var edge = new Pen(Color.FromArgb(150, 90, 90, 95), 2f))
                {
                    g.DrawPath(edge, PagePath());
                    g.DrawLines(edge, new[] {
                        new Point(x + PageW - fold, y),
                        new Point(x + PageW - fold, y + fold),
                        new Point(x + PageW, y + fold)
                    });
                }

                using (var rule = new Pen(Color.FromArgb(120, 90, 90, 95), 2f))
                    for (int i = 0; i < 7; i++)
                        g.DrawLine(rule, x + 18, y + fold + 22 + i * 22,
                                         x + PageW - 18, y + fold + 22 + i * 22);
            }

            // Progress along the foot of the page, once there is something to
            // report. Drawn only while a transfer is actually running, so a small
            // file that lands instantly never flashes a bar.
            var why = DragGhost.FailReason(_g);
            if (why != null)
            {
                using (var tint = new SolidBrush(Color.FromArgb(110, 230, 160, 40)))
                    g.FillPath(tint, PagePath());
                using (var font = new Font("Segoe UI", 9f, FontStyle.Bold))
                using (var ink = new SolidBrush(Color.FromArgb(230, 120, 60, 0)))
                {
                    var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                    g.DrawString(why, font, ink, new RectangleF(x + 8, y + fold + 8, PageW - 16, PageH - fold - 40), fmt);
                }
            }

            var done = DragGhost.Fraction(_g);
            if (why == null && done > 0 && done < 1)
            {
                var barY = y + PageH - 34;
                var barX = x + 16;
                var barW = PageW - 32;
                using (var track = new SolidBrush(Color.FromArgb(70, 60, 60, 65)))
                    g.FillRectangle(track, barX, barY, barW, 8);
                using (var fill = new SolidBrush(Color.FromArgb(220, 40, 110, 220)))
                    g.FillRectangle(fill, barX, barY, (int)(barW * done), 8);
                using (var pct = new Font("Segoe UI", 8.5f))
                using (var ink = new SolidBrush(Color.FromArgb(200, 40, 40, 45)))
                    g.DrawString(((int)(done * 100)) + "%", pct, ink, barX, barY + 10);
            }

            var label = _g.Label;
            if (label.Length > 0)
                using (var font = new Font("Segoe UI", 10f))
                using (var text = new SolidBrush(Color.FromArgb(230, 25, 25, 28)))
                {
                    var fmt = new StringFormat {
                        Alignment = StringAlignment.Center,
                        Trimming = StringTrimming.EllipsisCharacter,
                        FormatFlags = StringFormatFlags.NoWrap };
                    g.DrawString(label, font, text,
                                 new RectangleF(0, PageH + 6, PageW + 20, LabelH - 6), fmt);
                }
        }
    }
}


/// Where a dragged file actually lands.
///
/// Windows will not accept a drop synthesised from outside the process, so the
/// file is not dropped at all: it is copied to a staging folder while the drag is
/// in flight, and on release we ask the desktop what is under the pointer and
/// move it there. The user sees a drag and a drop; underneath it is a question
/// and a file move.
///
/// UI Automation answers the question. AutomationElement.FromPoint names whatever
/// is beneath the cursor — a folder icon, a file list, the desktop itself — and
/// that name, resolved against the folder being displayed, is the destination.
internal static class DropTarget
{
    internal const string Staging = @"C:\Temp";

    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hwnd, StringBuilder text, int max);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X; public int Y; }

    /// What MARK resolved for one drag, kept until its DROP: the folder, the
    /// Explorer window it was showing in (Zero for the desktop) from the SAME
    /// resolution — re-hit-testing later could anchor the ghost to Notepad
    /// while the files go to the Desktop — and the placeholders put there.
    /// Per stage, because a drag's DROP can arrive after the next drag's MARK.
    private sealed class Marked
    {
        public string Folder;
        public IntPtr Anchor;
        /// Placeholders this drop created in the destination, full paths.
        /// Deleted just before the real item moves in, or on any failure.
        public readonly List<string> Stubs = new List<string>();
    }
    private static readonly Dictionary<string, Marked> _marks = new Dictionary<string, Marked>();
    private static readonly object _markLock = new object();

    private static Marked Peek(string stage)
    {
        if (stage == null) return null;
        lock (_markLock) { Marked m; return _marks.TryGetValue(stage, out m) ? m : null; }
    }

    private static Marked Take(string stage)
    {
        if (stage == null) return null;
        lock (_markLock)
        {
            Marked m;
            if (!_marks.TryGetValue(stage, out m)) return null;
            _marks.Remove(stage);
            return m;
        }
    }

    internal static IntPtr MarkedAnchor(string stage)
    {
        var m = Peek(stage);
        return m == null ? IntPtr.Zero : m.Anchor;
    }

    /// The drag is over without a delivery: forget where it was going and
    /// take its placeholders back out of the folder.
    internal static void Discard(string stage)
    {
        var m = Take(stage);
        if (m != null) DiscardStubs(m);
    }

    internal static void DiscardAll()
    {
        List<Marked> all;
        lock (_markLock) { all = new List<Marked>(_marks.Values); _marks.Clear(); }
        foreach (var m in all) DiscardStubs(m);
    }

    private static void DiscardStubs(Marked m)
    {
        List<string> gone;
        lock (_markLock) { gone = new List<string>(m.Stubs); m.Stubs.Clear(); }
        foreach (var s in gone)
        {
            try
            {
                if (Directory.Exists(s)) { if (Directory.GetFileSystemEntries(s).Length == 0) Directory.Delete(s); }
                else if (File.Exists(s) && new FileInfo(s).Length == 0) File.Delete(s);
            }
            catch { }
        }
    }

    private static bool IsStub(Marked m, string path) { lock (_markLock) return m.Stubs.Contains(path); }
    private static void ForgetStub(Marked m, string path) { lock (_markLock) m.Stubs.Remove(path); }

    /// An abandoned drag's staging folder. The Mac has stopped the scp that
    /// was filling it, but the far end of that scp may hold a file open for a
    /// moment yet, so this retries for a few seconds. Only ever a stage
    /// folder — never Staging itself, whatever it is asked.
    internal static void ForgetStaging(string stage)
    {
        if (string.IsNullOrEmpty(stage)
            || !System.Text.RegularExpressions.Regex.IsMatch(stage, "^zb[0-9]+$")) return;
        var dir = Path.Combine(Staging, stage);
        ThreadPool.QueueUserWorkItem(delegate
        {
            for (int i = 0; i < 10; i++)
            {
                try
                {
                    if (!Directory.Exists(dir)) return;
                    Directory.Delete(dir, true);
                    BezelAgent.Log("staging: removed " + dir);
                    return;
                }
                catch (Exception) { Thread.Sleep(500); }
            }
            BezelAgent.Log("staging: could not remove " + dir);
        });
    }

    /// A zero-byte file (or empty folder) with the real name, so Explorer sorts
    /// it into place and draws it with its own icon while the bytes are still
    /// landing in staging. Then find where Explorer put it and snap the ghost
    /// there. Off the pipe thread: this waits on scp and on UI Automation.
    public static void PlaceholderAndSnap(string stage)
    {
        var m = Peek(stage);
        if (m == null || string.IsNullOrEmpty(m.Folder)) return;
        var destination = m.Folder;
        var anchor = m.Anchor;
        ThreadPool.QueueUserWorkItem(delegate
        {
            try
            {
                var source = Path.Combine(Staging, stage);
                // scp creates the first entry within a moment of starting; wait for it.
                string first = null;
                for (int i = 0; i < 30 && first == null; i++)
                {
                    if (Directory.Exists(source))
                    {
                        var entries = Directory.GetFileSystemEntries(source);
                        if (entries.Length > 0) first = entries[0];
                    }
                    if (first == null) Thread.Sleep(100);
                }
                if (first == null) { BezelAgent.Log("placeholder: nothing staged yet for " + stage); return; }

                var name = Path.GetFileName(first);
                var stub = Path.Combine(destination, name);
                if (File.Exists(stub) || Directory.Exists(stub))
                {
                    // Something real is already there. Deliver will pick a
                    // unique name; do not pretend to be it.
                    BezelAgent.Log("placeholder: " + name + " already exists in " + destination + "; not stubbing");
                    return;
                }
                if (Directory.Exists(first)) Directory.CreateDirectory(stub);
                else using (File.Create(stub)) { }
                lock (_markLock) m.Stubs.Add(stub);
                BezelAgent.Log("placeholder: created " + stub);

                // Explorer needs a moment to notice and draw it.
                Rectangle? rect = null;
                for (int i = 0; i < 30 && rect == null; i++)
                {
                    Thread.Sleep(100);
                    rect = FindItemRect(anchor, name);
                }
                if (rect == null) { BezelAgent.Log("placeholder: Explorer did not show " + name + "; ghost stays parked"); return; }
                DragGhost.SnapToItem(stage, anchor, name, rect.Value);
            }
            catch (Exception e) { BezelAgent.Log("placeholder: " + e.Message); }
        });
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);

    /// The on-screen rectangle of the Explorer item called `name` under
    /// `root` (an Explorer window, or Zero for the desktop). Null if Explorer
    /// is not showing it — scrolled away, or not drawn yet.
    internal static Rectangle? FindItemRect(IntPtr root, string name)
    {
        try
        {
            AutomationElement scope;
            if (root != IntPtr.Zero) scope = AutomationElement.FromHandle(root);
            else
            {
                // The desktop's icons live in a SHELLDLL_DefView under Progman
                // (or a WorkerW on some builds).
                var progman = FindWindowEx(IntPtr.Zero, IntPtr.Zero, "Progman", null);
                var view = progman == IntPtr.Zero ? IntPtr.Zero : FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
                if (view == IntPtr.Zero)
                {
                    IntPtr worker = IntPtr.Zero;
                    while (view == IntPtr.Zero && (worker = FindWindowEx(IntPtr.Zero, worker, "WorkerW", null)) != IntPtr.Zero)
                        view = FindWindowEx(worker, IntPtr.Zero, "SHELLDLL_DefView", null);
                }
                if (view == IntPtr.Zero) return null;
                scope = AutomationElement.FromHandle(view);
            }
            if (scope == null) return null;

            // Explorer may hide known extensions, so the item's name can be the stem.
            var stem = Path.GetFileNameWithoutExtension(name);
            foreach (var candidate in new[] { name, stem })
            {
                if (string.IsNullOrEmpty(candidate)) continue;
                var cond = new AndCondition(
                    new PropertyCondition(AutomationElement.NameProperty, candidate),
                    new OrCondition(
                        new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ListItem),
                        new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.DataItem)));
                var el = scope.FindFirst(TreeScope.Descendants, cond);
                if (el == null) continue;
                var r = el.Current.BoundingRectangle;
                if (r.IsEmpty || double.IsNaN(r.X) || r.Width < 4 || r.Height < 4) continue;
                if (el.Current.IsOffscreen) continue;
                return new Rectangle((int)r.X, (int)r.Y, (int)r.Width, (int)r.Height);
            }
        }
        catch (Exception e) { BezelAgent.Log("item lookup: " + e.Message); }
        return null;
    }

    /// Remember where the pointer was when the user let go of this drag.
    public static void Mark(string stage)
    {
        if (string.IsNullOrEmpty(stage)) return;
        IntPtr anchor;
        var folder = Resolve(out anchor);
        var m = new Marked { Folder = folder, Anchor = anchor };
        lock (_markLock) _marks[stage] = m;
        BezelAgent.Log("drop target marked for " + stage + ": " + folder + " (window " + anchor + ")");
    }

    /// Move one drag's folder to the spot marked at release.
    ///
    /// No fallback to "wherever the cursor is now": if nothing was marked, the
    /// files stay staged and this says so. Per-item failures are collected
    /// rather than aborting on the first, so a folder that will not move does
    /// not strand the loose files that already would have.
    public static string Deliver(string stage, out bool ok)
    {
        ok = false;
        if (string.IsNullOrEmpty(stage)) return "no stage named; nothing delivered";
        var m = Take(stage);
        string destination = m == null ? null : m.Folder;
        if (string.IsNullOrEmpty(destination)) return "no drop target was marked for " + stage + "; files left in staging";

        var source = Path.Combine(Staging, stage);
        try
        {
            if (!Directory.Exists(source)) return destination + " (nothing staged at " + source + ")";
            Directory.CreateDirectory(destination);
            int moved = 0;
            var failures = new List<string>();

            foreach (var file in Directory.GetFiles(source))
            {
                try
                {
                    var wanted = Path.Combine(destination, Path.GetFileName(file));
                    // Our own placeholder gives way, so the real file keeps its name.
                    if (IsStub(m, wanted) && File.Exists(wanted) && new FileInfo(wanted).Length == 0)
                    {
                        File.Delete(wanted);
                        ForgetStub(m, wanted);
                    }
                    var target = Unique(wanted);
                    File.Move(file, target);
                    moved++;
                }
                catch (Exception e) { failures.Add(Path.GetFileName(file) + ": " + e.Message); }
            }
            foreach (var folder in Directory.GetDirectories(source))
            {
                try
                {
                    var wanted = Path.Combine(destination, Path.GetFileName(folder));
                    // An empty placeholder folder gives way; one the user has
                    // already put something in is merged into instead.
                    if (IsStub(m, wanted) && Directory.Exists(wanted))
                    {
                        ForgetStub(m, wanted);
                        if (Directory.GetFileSystemEntries(wanted).Length == 0) Directory.Delete(wanted);
                    }
                    var target = Directory.Exists(wanted) && IsStub(m, wanted) == false && Directory.GetFileSystemEntries(wanted).Length > 0
                        ? wanted : UniqueDirectory(wanted);
                    MoveDirectory(folder, target);
                    moved++;
                }
                catch (Exception e) { failures.Add(Path.GetFileName(folder) + ": " + e.Message); }
            }

            // Leave nothing behind: a folder left in staging would be swept up by
            // a later drop, which is exactly the bug this replaced. Only when
            // everything left, though — a failed item stays where it can be found.
            if (!string.IsNullOrEmpty(stage) && failures.Count == 0)
            {
                try { Directory.Delete(source, true); } catch { }
            }
            ok = failures.Count == 0;
            DiscardStubs(m);
            var summary = destination + " (" + moved + " item" + (moved == 1 ? "" : "s") + ")";
            return failures.Count == 0 ? summary
                 : summary + " — " + failures.Count + " FAILED: " + string.Join("; ", failures.ToArray());
        }
        catch (Exception e) { return destination + " — FAILED: " + e.Message; }
    }

    /// Directory.Move refuses to cross volumes, and staging is fixed on C:, so a
    /// drop onto D:, a mapped drive or a UNC path threw halfway through. Fall
    /// back to copying the tree over and removing the original.
    private static void MoveDirectory(string from, string to)
    {
        try { Directory.Move(from, to); return; }
        catch (IOException) { }
        Directory.CreateDirectory(to);
        foreach (var f in Directory.GetFiles(from))
        {
            var target = Path.Combine(to, Path.GetFileName(f));
            try { File.Move(f, target); }
            catch (IOException) { File.Copy(f, target, false); File.Delete(f); }
        }
        foreach (var d in Directory.GetDirectories(from))
            MoveDirectory(d, Path.Combine(to, Path.GetFileName(d)));
        Directory.Delete(from, true);
    }

    private static string UniqueDirectory(string path)
    {
        if (!Directory.Exists(path) && !File.Exists(path)) return path;
        var parent = Path.GetDirectoryName(path);
        var name = Path.GetFileName(path);
        for (int i = 2; i < 500; i++)
        {
            var candidate = Path.Combine(parent, name + " (" + i + ")");
            if (!Directory.Exists(candidate) && !File.Exists(candidate)) return candidate;
        }
        return path;
    }

    /// Never overwrite. A drop that silently replaced something would be a very
    /// expensive surprise.
    private static string Unique(string path)
    {
        if (!File.Exists(path)) return path;
        var dir = Path.GetDirectoryName(path);
        var stem = Path.GetFileNameWithoutExtension(path);
        var ext = Path.GetExtension(path);
        for (int i = 2; i < 500; i++)
        {
            var candidate = Path.Combine(dir, stem + " (" + i + ")" + ext);
            if (!File.Exists(candidate)) return candidate;
        }
        return path;
    }

    /// The folder under the cursor.
    public static string Resolve()
    {
        IntPtr ignored;
        return Resolve(out ignored);
    }

    public static string Resolve(out IntPtr anchor)
    {
        var desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        var pos = Cursor.Position;

        // The anchor is the Explorer window itself even when the drop lands in a
        // nested folder icon: the item view is one window and icons have no hwnd.
        string container = ContainerFor(pos, out anchor) ?? desktop;

        // If the thing directly under the cursor is a folder inside that
        // container, the drop belongs in it rather than beside it.
        try
        {
            var element = AutomationElement.FromPoint(
                new System.Windows.Point(pos.X, pos.Y));
            if (element != null)
            {
                var name = element.Current.Name;
                if (!string.IsNullOrEmpty(name))
                {
                    var nested = Path.Combine(container, name);
                    if (Directory.Exists(nested)) return nested;
                }
            }
        }
        catch (Exception e) { BezelAgent.Log("drop: automation said " + e.Message); }

        return container;
    }

    /// Which folder the window under the cursor is showing.
    private static string ContainerFor(Point pos, out IntPtr anchor)
    {
        // Published ONLY on the Explorer-window path below. The desktop
        // (Progman/WorkerW) is a window too, but anchoring to it is just today's
        // whole-desktop freeze under a new name, so it stays Zero.
        anchor = IntPtr.Zero;
        var hwnd = GetAncestor(WindowFromPoint(new POINT { X = pos.X, Y = pos.Y }), 2 /*GA_ROOT*/);
        if (hwnd == IntPtr.Zero) return null;

        var cls = new StringBuilder(256);
        GetClassName(hwnd, cls, cls.Capacity);
        var name = cls.ToString();

        // The desktop is a window like any other; it just happens to be the one
        // showing the Desktop folder.
        if (name == "Progman" || name == "WorkerW")
            return Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);

        if (name != "CabinetWClass" && name != "ExplorerWClass") return null;

        // Ask the shell which of its open windows this is, and what it is showing.
        // Late-bound so the agent needs no interop assembly for a feature that is
        // only reached during a drop.
        try
        {
            var shellType = Type.GetTypeFromProgID("Shell.Application");
            var shell = Activator.CreateInstance(shellType);
            var windows = shellType.InvokeMember("Windows", BindingFlags.InvokeMethod,
                                                 null, shell, null);
            var count = (int)windows.GetType().InvokeMember("Count",
                            BindingFlags.GetProperty, null, windows, null);
            for (int i = 0; i < count; i++)
            {
                var w = windows.GetType().InvokeMember("Item", BindingFlags.InvokeMethod,
                            null, windows, new object[] { i });
                if (w == null) continue;
                var h = w.GetType().InvokeMember("HWND", BindingFlags.GetProperty,
                            null, w, null);
                if (new IntPtr(Convert.ToInt64(h)) != hwnd) continue;
                var url = (string)w.GetType().InvokeMember("LocationURL",
                            BindingFlags.GetProperty, null, w, null);
                if (string.IsNullOrEmpty(url)) return null;
                anchor = hwnd;
                return new Uri(url).LocalPath;
            }
        }
        catch (Exception e) { BezelAgent.Log("drop: shell said " + e.Message); }
        return null;
    }
}
