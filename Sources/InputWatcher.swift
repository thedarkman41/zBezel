import Foundation

/// Decides what should happen when the panel changes input, so that switching
/// the monitor by hand carries the keyboard and mouse with it.
///
/// Switching to a machine on the monitor's own buttons is as clear a statement
/// of intent as clicking the lock: you are looking at that machine and you want
/// to type at it. This makes the two mean the same thing.
///
/// **There is no interrupt to use, and that was checked rather than assumed.**
/// DDC/CI is host-initiated by construction — the monitor answers, it never
/// speaks first, and MCCS has no asynchronous notification. `0x52` reports the
/// last control changed, and does correctly name `0x60` after a switch on the
/// monitor's buttons, but it is sticky rather than self-clearing, so it is a
/// level and not an edge. DisplayPort's real sink-initiated interrupt (HPD IRQ,
/// DPCD `DEVICE_SERVICE_IRQ_VECTOR`) signals link events rather than VCP
/// changes, is not exposed to userspace by macOS, and is blocked by the dock's
/// branch device regardless. And neither operating system raises a display
/// event: HPD stays asserted on every input at once — both Windows hosts
/// enumerate the panel simultaneously, and this Mac still lists it while the
/// panel shows HDMI — so nothing is added or removed when the input moves.
///
/// Polling is therefore the only mechanism. This type holds the part worth
/// testing — the debounce and the decision — while the controller owns the
/// timer and the reading, since it is the one that can reach the monitor.
struct InputWatcher {

    enum Action: Equatable {
        /// The panel came back to this Mac. The lock exists to stop the panel
        /// following the pointer home; arriving home ends it.
        case release
        /// The panel is showing this machine, so the pointer should be there.
        case lock(index: Int, why: String)
        /// The input moved somewhere no machine is configured for. Nothing to
        /// do, but worth saying: a silent decision is indistinguishable from a
        /// watcher that is not running, which cost an evening to work out once.
        case unknownInput(value: UInt16)
    }

    /// Readings taken while the link is renegotiating look like ordinary values
    /// and quietly become evidence — the README says exactly that about
    /// `0xAC`/`0xAE`, and an input switch is precisely when the link is
    /// renegotiating. So a value is only believed once it has held still.
    ///
    /// Three readings, not two. Measured: switching USB-C to HDMI by hand, the
    /// panel passed through DisplayPort for about six seconds on the way —
    /// Auto Switch (0xE6) hunting for a live input once USB-C dropped — and two
    /// readings were not enough to disbelieve it. The watcher released the lock
    /// and then re-took it. Harmless there only because the way-point happened
    /// to be this Mac; had it been another machine's input, the pointer would
    /// have been thrown at a machine the user was not looking at.
    private var candidate: UInt16?
    private var timesSeen = 0
    private static let readingsBeforeBelieved = 3

    /// The last value actually acted on. Nil until the first settled reading,
    /// which establishes a baseline rather than causing anything — otherwise the
    /// app would engage a lock merely because it had started.
    private var settled: UInt16?

    /// What a settled reading means: the value itself, always, plus something to
    /// do about it only when it has changed.
    ///
    /// The value comes back even when nothing needs doing, and that distinction
    /// matters more than it looks. The state this reports — which input is live —
    /// is what the pointer crossing consults to decide where to hand control. An
    /// earlier version reported only actions, so a launch with the panel already
    /// on a machine told nobody anything: the crossing then believed the panel
    /// was on the Mac and refused to hand over to the machine plainly on screen.
    struct Reading: Equatable {
        let value: UInt16
        let action: Action?
    }

    /// Feed a reading in; get back the settled value and what to do, if anything.
    mutating func observe(_ value: UInt16,
                          machines: [KVMController.Machine],
                          macInput: UInt16) -> Reading? {
        if value == candidate {
            timesSeen += 1
        } else {
            candidate = value
            timesSeen = 1
        }
        guard timesSeen >= Self.readingsBeforeBelieved else { return nil }

        // First settled reading establishes where things stand. Report it, so
        // everything downstream knows which input is live, but do not act on it:
        // the app starting is not the user changing anything.
        guard let previous = settled else {
            settled = value
            return Reading(value: value, action: nil)
        }
        guard value != previous else { return Reading(value: value, action: nil) }
        settled = value

        if value == macInput {
            return Reading(value: value, action: .release)
        }
        guard let index = machines.firstIndex(where: { $0.input == value }) else {
            // An input with no machine behind it — a spare socket, or one this
            // Mac does not drive. Leave the lock alone: nothing here knows what
            // was wanted, and guessing would send the pointer somewhere the user
            // cannot see it.
            return Reading(value: value, action: .unknownInput(value: value))
        }
        return Reading(value: value,
                       action: .lock(index: index,
                                     why: "the panel was switched to \(HPProfile.inputLabel(value)) "
                                        + "from \(HPProfile.inputLabel(previous))"))
    }

    /// Forget the baseline, so the next settled reading re-establishes one
    /// without acting. For when the app itself moved the panel and there is
    /// nothing to follow.
    mutating func resync(to value: UInt16) {
        candidate = value
        timesSeen = Self.readingsBeforeBelieved
        settled = value
    }
}
