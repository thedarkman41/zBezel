import Foundation

/// The physical orientation of the panel, sensed by a phone bonded to its back.
///
/// The phone runs a small foreground service (PanelTilt) and is cabled to the
/// proxy host (rigel) — NOT to the Mac, and NOT through the monitor's own USB hub
/// (that hub does not route data to the PC). So the Mac reads orientation the
/// same way it reaches everything else on that box: BezelAgent's `orient` verb
/// over SSH. The verb re-establishes its own `adb forward` on demand, so there is
/// nothing to manage here.
///
/// The returned `orient` is ALREADY snapped to 0/90/180/270 with the 45°-boundary
/// hysteresis done on the phone (drift-free gravity-roll — a flat spin on a desk
/// reads nothing by design). `inplane` is the in-plane gravity magnitude: ~9.8
/// when the panel stands vertical and the reading is trustworthy, below ~1.5 when
/// it lies near flat and the orientation is undefined and being held.
enum PanelOrientation {
    struct Reading { var orient: Int; var inplane: Double }

    private static let sshOpts = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6"]

    // A one-shot, host-explicit read: it must always hit the box the phone is
    // wired to, never wherever the shared DDC agent happens to be pointed. adb is
    // not on PATH in a non-interactive SSH session, so point the agent at rigel's
    // scoop-installed adb — exactly as the verb's one-shot documents.
    private static let command =
        #"$env:BEZEL_ADB="$env:USERPROFILE\scoop\shims\adb.exe"; & "$HOME\bezel\BezelAgent.exe" orient"#

    /// One reading, or nil when the host is unreachable or the verb failed. A
    /// hiccup returning nil is treated by the caller as "no reading, hold" — it
    /// never rotates on a guess.
    nonisolated static func read(host: String) async -> Reading? {
        let r = await ConsoleReclaim.run("/usr/bin/ssh", sshOpts + [host, command])
        guard r.status == 0 else { return nil }
        let line = r.output.split(separator: "\n").last.map(String.init) ?? r.output
        let json = String(line.drop(while: { $0 != "{" }))
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              (obj["ok"] as? Bool) == true,
              let orient = (obj["orient"] as? NSNumber)?.intValue else { return nil }
        let inplane = (obj["inplane"] as? NSNumber)?.doubleValue ?? 9.8
        return Reading(orient: orient, inplane: inplane)
    }
}
