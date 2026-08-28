import Foundation

/// Parsed form of a monitor's DDC/CI capabilities string.
///
/// The capabilities string is the ground truth for what a given monitor supports.
/// It is the only reliable way to discover manufacturer-specific VCP codes, because
/// no public standard documents them — the monitor enumerates its own.
struct Capabilities {
    var raw: String = ""
    var protocolClass: String?      // prot(...)
    var type: String?               // type(...)
    var model: String?              // model(...)
    var mccsVersion: String?        // mccs_ver(...)
    var commands: [UInt8] = []      // cmds(...)
    /// VCP code -> permitted non-continuous values (empty means continuous or unenumerated).
    var vcp: [UInt8: [UInt16]] = [:]
    /// vcpname(...) supplies vendor names for codes and values on some monitors.
    var vcpNames: [UInt8: String] = [:]
    /// Codes whose value list is itself a set of sub-addressed groups, which is
    /// how HP packs many settings behind one code: vcp(E1(04(00 01) 0A(00 01)))
    var nested: [UInt8: [UInt16: [UInt16]]] = [:]

    var supportedCodes: [UInt8] { vcp.keys.sorted() }

    func supports(_ code: UInt8) -> Bool { vcp[code] != nil }
    func values(for code: UInt8) -> [UInt16] { vcp[code] ?? [] }

    var manufacturerCodes: [UInt8] { supportedCodes.filter { VCP.isManufacturerSpecific($0) } }

    // MARK: Parsing

    static func parse(_ input: String) -> Capabilities {
        var caps = Capabilities()
        caps.raw = input
        let s = Array(input)

        // Walk top-level `name(body)` sections, tracking nesting so that a body
        // containing its own parentheses — vcp() always does — stays intact.
        var i = 0
        while i < s.count {
            guard s[i].isLetter || s[i] == "_" else { i += 1; continue }
            var nameEnd = i
            while nameEnd < s.count, s[nameEnd].isLetter || s[nameEnd].isNumber || s[nameEnd] == "_" {
                nameEnd += 1
            }
            guard nameEnd < s.count, s[nameEnd] == "(" else { i = nameEnd + 1; continue }

            let name = String(s[i..<nameEnd]).lowercased()
            var depth = 1
            var j = nameEnd + 1
            while j < s.count, depth > 0 {
                if s[j] == "(" { depth += 1 }
                else if s[j] == ")" { depth -= 1 }
                if depth > 0 { j += 1 }
            }
            let body = j <= s.count ? String(s[(nameEnd + 1)..<min(j, s.count)]) : ""

            switch name {
            case "prot":      caps.protocolClass = body.trimmingCharacters(in: .whitespaces)
            case "type":      caps.type = body.trimmingCharacters(in: .whitespaces)
            case "model":     caps.model = body.trimmingCharacters(in: .whitespaces)
            case "mccs_ver":  caps.mccsVersion = body.trimmingCharacters(in: .whitespaces)
            case "cmds":      caps.commands = hexBytes(body)
            case "vcp":
                let parsed = parseVCPSection(body)
                caps.vcp = parsed.values
                caps.nested = parsed.nested
            case "vcpname":   caps.vcpNames = parseVCPNames(body)
            default:          break
            }
            i = j + 1
        }
        return caps
    }

    private static func hexBytes(_ s: String) -> [UInt8] {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .compactMap { UInt8($0, radix: 16) }
    }

    /// vcp body looks like: `02 04 10 12 14(01 05 08) 60(0F 11 12) DF E0`,
    /// and on HP panels also `E1(04(00 01) 0A(00 01))` — a second level where the
    /// outer values are sub-selectors rather than settable values in their own right.
    private static func parseVCPSection(_ body: String)
        -> (values: [UInt8: [UInt16]], nested: [UInt8: [UInt16: [UInt16]]]) {
        var values: [UInt8: [UInt16]] = [:]
        var nested: [UInt8: [UInt16: [UInt16]]] = [:]

        for (code, group) in topLevelGroups(body) {
            let sub = topLevelGroups(group)
            if sub.contains(where: { !$0.group.isEmpty }) {
                // Sub-addressed: the outer tokens select which setting is meant.
                var table: [UInt16: [UInt16]] = [:]
                for (selector, inner) in sub {
                    table[UInt16(selector)] = hexWords(inner)
                }
                nested[code] = table
                values[code] = sub.map { UInt16($0.code) }
            } else {
                values[code] = hexWords(group)
            }
        }
        return (values, nested)
    }

    /// Split `AA(...) BB CC(...)` into its top-level `code` / `group` pairs.
    private static func topLevelGroups(_ body: String) -> [(code: UInt8, group: String)] {
        var out: [(UInt8, String)] = []
        let chars = Array(body)
        var i = 0
        while i < chars.count {
            guard chars[i].isHexDigit else { i += 1; continue }
            var end = i
            while end < chars.count, chars[end].isHexDigit { end += 1 }
            guard let code = UInt8(String(chars[i..<end]), radix: 16) else { i = end; continue }

            var group = ""
            if end < chars.count, chars[end] == "(" {
                var depth = 1
                var j = end + 1
                let start = j
                while j < chars.count, depth > 0 {
                    if chars[j] == "(" { depth += 1 }
                    else if chars[j] == ")" { depth -= 1 }
                    if depth > 0 { j += 1 }
                }
                group = String(chars[start..<min(j, chars.count)])
                end = j + 1
            }
            out.append((code, group))
            i = end
        }
        return out
    }

    private static func hexWords(_ s: String) -> [UInt16] {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .compactMap { UInt16($0, radix: 16) }
    }

    /// Sub-selectors this code carries, if it is sub-addressed.
    func subSelectors(for code: UInt8) -> [UInt16] {
        (nested[code]?.keys).map { Array($0).sorted() } ?? []
    }

    /// vcpname body looks like: `60(USB-C=1B DisplayPort=0F)` on monitors that supply it.
    private static func parseVCPNames(_ body: String) -> [UInt8: String] {
        var result: [UInt8: String] = [:]
        let chars = Array(body)
        var i = 0
        while i < chars.count {
            guard chars[i].isHexDigit else { i += 1; continue }
            var end = i
            while end < chars.count, chars[end].isHexDigit { end += 1 }
            guard let code = UInt8(String(chars[i..<end]), radix: 16) else { i = end; continue }
            if end < chars.count, chars[end] == "(" {
                var depth = 1
                var j = end + 1
                let start = j
                while j < chars.count, depth > 0 {
                    if chars[j] == "(" { depth += 1 }
                    else if chars[j] == ")" { depth -= 1 }
                    if depth > 0 { j += 1 }
                }
                result[code] = String(chars[start..<min(j, chars.count)])
                end = j + 1
            }
            i = end
        }
        return result
    }
}
