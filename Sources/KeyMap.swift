import CoreGraphics
import Foundation

/// macOS virtual keycode -> Windows virtual-key code.
///
/// The two are unrelated numbering schemes and neither is an ASCII code, so this
/// has to be a table. macOS keycodes are POSITIONAL — 0x00 is the key where A
/// sits on a US ANSI keyboard, whatever that key produces on the layout in use —
/// which is convenient here: the position is what should be forwarded, and the
/// far machine applies its own layout to it. A character that has no key of its
/// own on this keyboard is sent as a Unicode event instead, which bypasses the
/// far layout entirely.
enum KeyMap {

    // Windows virtual-key codes used below, named rather than spelled as
    // magic numbers at each use.
    private static let vkBack: UInt16     = 0x08, vkTab: UInt16    = 0x09
    private static let vkReturn: UInt16   = 0x0D, vkEscape: UInt16 = 0x1B
    private static let vkSpace: UInt16    = 0x20
    private static let vkPrior: UInt16    = 0x21, vkNext: UInt16   = 0x22
    private static let vkEnd: UInt16      = 0x23, vkHome: UInt16   = 0x24
    private static let vkLeft: UInt16     = 0x25, vkUp: UInt16     = 0x26
    private static let vkRight: UInt16    = 0x27, vkDown: UInt16   = 0x28
    private static let vkInsert: UInt16   = 0x2D, vkDelete: UInt16 = 0x2E
    private static let vkCapital: UInt16  = 0x14
    private static let vkLWin: UInt16     = 0x5B
    private static let vkNumpad0: UInt16  = 0x60
    private static let vkMultiply: UInt16 = 0x6A, vkAdd: UInt16      = 0x6B
    private static let vkSubtract: UInt16 = 0x6D, vkDecimal: UInt16  = 0x6E
    private static let vkDivide: UInt16   = 0x6F, vkNumlock: UInt16  = 0x90
    private static let vkF1: UInt16       = 0x70
    private static let vkLShift: UInt16   = 0xA0, vkRShift: UInt16   = 0xA1
    private static let vkLControl: UInt16 = 0xA2, vkRControl: UInt16 = 0xA3
    private static let vkLMenu: UInt16    = 0xA4, vkRMenu: UInt16    = 0xA5
    private static let vkOem1: UInt16     = 0xBA   // ;:
    private static let vkOemPlus: UInt16  = 0xBB   // =+
    private static let vkOemComma: UInt16 = 0xBC   // ,<
    private static let vkOemMinus: UInt16 = 0xBD   // -_
    private static let vkOemPeriod: UInt16 = 0xBE  // .>
    private static let vkOem2: UInt16     = 0xBF   // /?
    private static let vkOem3: UInt16     = 0xC0   // `~
    private static let vkOem4: UInt16     = 0xDB   // [{
    private static let vkOem5: UInt16     = 0xDC   // \|
    private static let vkOem6: UInt16     = 0xDD   // ]}
    private static let vkOem7: UInt16     = 0xDE   // '"

    /// The keycodes macOS assigns to modifier keys. flagsChanged events do not
    /// say whether the key went down or up, only what the resulting flag state
    /// is, so the caller pairs the keycode with the flag it owns.
    static let modifierFlags: [UInt16: CGEventFlags] = [
        0x37: .maskCommand,     // Command (left)
        0x36: .maskCommand,     // Command (right)
        0x38: .maskShift,       // Shift (left)
        0x3C: .maskShift,       // Shift (right)
        0x3A: .maskAlternate,   // Option (left)
        0x3D: .maskAlternate,   // Option (right)
        0x3B: .maskControl,     // Control (left)
        0x3E: .maskControl,     // Control (right)
        0x39: .maskAlphaShift,  // Caps Lock
    ]

    /// Every modifier this maps, so a hand-back can release the lot.
    ///
    /// Cross the edge holding Shift and let go on the far side and the release
    /// is never forwarded: the far machine believes Shift is still down and
    /// stays that way indefinitely. Handing control back releases all of these
    /// unconditionally, which is cheap and idempotent.
    static let allModifierVKs: [UInt16] = [
        vkLShift, vkRShift, vkLControl, vkRControl, vkLMenu, vkRMenu, vkLWin,
    ]

    private static let table: [UInt16: UInt16] = [
        // Letters, in macOS's scattered positional order.
        0x00: 0x41, 0x0B: 0x42, 0x08: 0x43, 0x02: 0x44, 0x0E: 0x45, 0x03: 0x46,
        0x05: 0x47, 0x04: 0x48, 0x22: 0x49, 0x26: 0x4A, 0x28: 0x4B, 0x25: 0x4C,
        0x2E: 0x4D, 0x2D: 0x4E, 0x1F: 0x4F, 0x23: 0x50, 0x0C: 0x51, 0x0F: 0x52,
        0x01: 0x53, 0x11: 0x54, 0x20: 0x55, 0x09: 0x56, 0x0D: 0x57, 0x07: 0x58,
        0x10: 0x59, 0x06: 0x5A,

        // Digits along the top row.
        0x1D: 0x30, 0x12: 0x31, 0x13: 0x32, 0x14: 0x33, 0x15: 0x34,
        0x17: 0x35, 0x16: 0x36, 0x1A: 0x37, 0x1C: 0x38, 0x19: 0x39,

        // Punctuation.
        0x18: vkOemPlus,  0x1B: vkOemMinus, 0x21: vkOem4,  0x1E: vkOem6,
        0x2A: vkOem5,     0x29: vkOem1,     0x27: vkOem7,  0x2B: vkOemComma,
        0x2F: vkOemPeriod, 0x2C: vkOem2,    0x32: vkOem3,

        // Editing and whitespace. macOS "Delete" is Backspace; the key it calls
        // "Forward Delete" is what Windows means by Delete.
        0x24: vkReturn, 0x30: vkTab,    0x31: vkSpace,  0x33: vkBack,
        0x35: vkEscape, 0x75: vkDelete, 0x72: vkInsert,
        0x73: vkHome,   0x77: vkEnd,    0x74: vkPrior,  0x79: vkNext,

        // Arrows.
        0x7B: vkLeft, 0x7C: vkRight, 0x7D: vkDown, 0x7E: vkUp,

        // Modifiers. Mapped by POSITION for now: Command becomes the Windows
        // key, Option becomes Alt. That is the honest literal mapping and it is
        // predictable, but it is not what muscle memory wants — Cmd-C lands as
        // Win-C. Swapping Command to Control is the "key remapping" feature,
        // kept separate so this stays a plain positional table.
        0x37: vkLWin,     0x36: vkLWin,
        0x38: vkLShift,   0x3C: vkRShift,
        0x3B: vkLControl, 0x3E: vkRControl,
        0x3A: vkLMenu,    0x3D: vkRMenu,
        0x39: vkCapital,

        // Function keys. macOS orders these almost at random.
        0x7A: vkF1,      0x78: vkF1 + 1,  0x63: vkF1 + 2,  0x76: vkF1 + 3,
        0x60: vkF1 + 4,  0x61: vkF1 + 5,  0x62: vkF1 + 6,  0x64: vkF1 + 7,
        0x65: vkF1 + 8,  0x6D: vkF1 + 9,  0x67: vkF1 + 10, 0x6F: vkF1 + 11,
        0x69: vkF1 + 12, 0x6B: vkF1 + 13, 0x71: vkF1 + 14,

        // Keypad.
        0x52: vkNumpad0,     0x53: vkNumpad0 + 1, 0x54: vkNumpad0 + 2,
        0x55: vkNumpad0 + 3, 0x56: vkNumpad0 + 4, 0x57: vkNumpad0 + 5,
        0x58: vkNumpad0 + 6, 0x59: vkNumpad0 + 7, 0x5B: vkNumpad0 + 8,
        0x5C: vkNumpad0 + 9,
        0x41: vkDecimal, 0x43: vkMultiply, 0x45: vkAdd, 0x4E: vkSubtract,
        0x4B: vkDivide,  0x4C: vkReturn,   0x47: vkNumlock,
    ]

    /// The Windows key for a macOS keycode, or nil if there is no equivalent —
    /// the Function (fn) key, for instance, which has no Windows counterpart.
    static func windowsKey(for macKeyCode: UInt16) -> UInt16? { table[macKeyCode] }
}
