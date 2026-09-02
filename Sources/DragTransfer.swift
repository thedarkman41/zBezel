import AppKit
import Foundation

/// Files dragged off the Mac and onto a machine the pointer travels to.
///
/// What this does NOT do is drop them into a Windows application. Synthesising
/// an OLE drag that another process will accept is not something an outside
/// injector can do — Synergy has the same limit — so the files land in a folder
/// on the far machine and the user picks them up from there. Saying so plainly
/// is better than a feature that silently means something else.
///
/// The pasteboard is read at the moment of crossing because that is the only
/// moment it is guaranteed to hold the drag: it is a system pasteboard, alive
/// only for the duration of the gesture.
enum DragTransfer {

    /// Where files land on the far machine, relative to its user profile.
    /// Staging, not the destination.
    ///
    /// The copy starts the moment the pointer crosses, while the user is still
    /// deciding where to put the file — so it cannot go to its final home yet.
    /// It waits here until the release, when the agent asks the desktop what is
    /// under the pointer and moves it there.
    static let staging = "C:\\Temp"

    /// The copies in flight, by stage, so an abandoned drag can be stopped
    /// rather than left saturating the link to fill a folder nobody will
    /// collect. A stage cancelled before its scp has started is remembered,
    /// and the copy never begins.
    private static var running: [String: Process] = [:]
    private static var cancelled = Set<String>()
    private static let lock = NSLock()

    static func cancel(stage: String) {
        lock.lock()
        cancelled.insert(stage)
        let scp = running.removeValue(forKey: stage)
        lock.unlock()
        if let scp, scp.isRunning { scp.terminate() }
    }

    private static func isCancelled(_ stage: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled.contains(stage)
    }

    private static func register(_ scp: Process, for stage: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled.contains(stage) { return false }
        running[stage] = scp
        return true
    }

    private static func finished(_ stage: String) {
        lock.lock()
        running[stage] = nil
        cancelled.remove(stage)
        lock.unlock()
    }

    /// The files currently being dragged, if any.
    ///
    /// Read from the drag pasteboard rather than tracked ourselves: the Mac knows
    /// what is in flight and we would only be guessing.
    static func draggedFiles() -> [URL] {
        let board = NSPasteboard(name: .drag)
        guard let items = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        else { return [] }
        return items.filter { $0.isFileURL }
    }

    /// Copy them over, reporting progress as a line of text.
    ///
    /// scp rather than the agent's own channel: that channel is a line-oriented
    /// pipe carrying pointer events, and pushing a few hundred megabytes of
    /// base64 down it would stall the pointer for as long as the copy took.
    /// Copy into a folder of this drag's own, named by `stage`.
    ///
    /// Not a shared staging folder. The far side moves whatever it finds when the
    /// drop arrives, so a shared one sweeps up leftovers from an earlier drag —
    /// and if a copy is still in flight, sweeps up nothing at all and delivers
    /// that file with the NEXT drop instead. One folder per drag makes both
    /// impossible.
    static func send(_ files: [URL], to host: String, stage: String,
                     total: @escaping (Int) -> Void,
                     progress: @escaping (String) -> Void,
                     done: @escaping (Bool, String) -> Void) {
        guard !files.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let names = files.map { $0.lastPathComponent }

            // The true size, including folders. URLResourceValues.fileSize is
            // nil for a directory, so the crossing-time sum sends 0 for a
            // folder drag and the far side draws no bar at all. Walked here,
            // off the crossing path, and reported back. Logical bytes, not
            // allocated size — the far side compares against FileInfo.Length.
            // Hidden files are counted because scp -r copies them.
            var bytes = 0
            for url in files {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir, let walk = FileManager.default.enumerator(
                        at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                    for case let entry as URL in walk {
                        let v = try? entry.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        if v?.isRegularFile == true { bytes += v?.fileSize ?? 0 }
                    }
                } else {
                    bytes += (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                }
            }
            if isCancelled(stage) {
                finished(stage)
                done(false, "abandoned before the copy started")
                return
            }
            total(bytes)
            progress(files.count == 1
                     ? "copying \(names[0]) to \(host)…"
                     : "copying \(files.count) items to \(host)…")

            // Make the landing folder first; scp will not create it.
            let mkdir = Process()
            mkdir.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            mkdir.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host,
                               "New-Item -ItemType Directory -Force -Path "
                               + "'\(staging)\\\(stage)' | Out-Null"]
            mkdir.standardOutput = FileHandle.nullDevice
            mkdir.standardError = FileHandle.nullDevice
            try? mkdir.run()
            mkdir.waitUntilExit()

            let scp = Process()
            scp.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            scp.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-r"]
                + files.map { $0.path }
                + ["\(host):/Temp/\(stage)/"]
            let err = Pipe()
            scp.standardOutput = FileHandle.nullDevice
            scp.standardError = err
            guard register(scp, for: stage) else {
                finished(stage)
                done(false, "abandoned before the copy started")
                return
            }
            do { try scp.run() } catch {
                finished(stage)
                done(false, "could not start the copy: \(error.localizedDescription)")
                return
            }
            let problem = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
            scp.waitUntilExit()
            let wasCancelled = isCancelled(stage)
            finished(stage)

            if wasCancelled {
                done(false, "copy stopped: the drag was abandoned")
            } else if scp.terminationStatus == 0 {
                done(true, files.count == 1
                     ? "\(names[0]) ready on \(host)"
                     : "\(files.count) items ready on \(host)")
            } else {
                done(false, "copy failed: "
                     + problem.trimmingCharacters(in: .whitespacesAndNewlines)
                       .split(separator: "\n").last.map(String.init).orEmpty)
            }
        }
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "unknown error" }
}
