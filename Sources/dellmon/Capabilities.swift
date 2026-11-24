import Foundation

/// The monitor's self-description, as returned by a DDC capabilities request.
///
/// It arrives as one parenthesised string, for example:
///
///     (prot(monitor)type(LCD)model(U3818DW)cmds(01 02 ...)
///      vcp(02 04 10 12 14(04 05 06) 60(1B 0F 11 12 ) ...)mccs_ver(2.1))
///
/// The `vcp` section is the interesting part: every feature the monitor
/// implements, and for the ones that take a fixed set of settings, the exact
/// values it accepts.
struct Capabilities {
    let raw: String
    let model: String?
    let mccsVersion: String?
    let controls: [Control]

    struct Control {
        let code: UInt8
        /// Values the monitor advertises, empty for a continuous control.
        let values: [UInt16]
    }

    static func parse(_ raw: String) -> Capabilities {
        Capabilities(
            raw: raw,
            model: section("model", in: raw),
            mccsVersion: section("mccs_ver", in: raw),
            controls: section("vcp", in: raw).map(controls(in:)) ?? [])
    }

    /// Returns the contents of `name(...)`, honouring nested parentheses.
    private static func section(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: name + "(") else { return nil }
        var depth = 1
        var body = ""
        var index = start.upperBound
        while index < text.endIndex {
            let character = text[index]
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return body }
            }
            body.append(character)
            index = text.index(after: index)
        }
        return nil
    }

    private static func controls(in vcp: String) -> [Control] {
        var controls = [Control]()
        var index = vcp.startIndex

        while index < vcp.endIndex {
            guard vcp[index].isHexDigit else {
                index = vcp.index(after: index)
                continue
            }

            var token = ""
            while index < vcp.endIndex, vcp[index].isHexDigit {
                token.append(vcp[index])
                index = vcp.index(after: index)
            }
            guard let code = UInt8(token, radix: 16) else { continue }

            var values = [UInt16]()
            if index < vcp.endIndex, vcp[index] == "(" {
                index = vcp.index(after: index)
                var depth = 1
                var body = ""
                while index < vcp.endIndex {
                    let character = vcp[index]
                    index = vcp.index(after: index)
                    if character == "(" { depth += 1 }
                    if character == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    body.append(character)
                }
                values = body.split(whereSeparator: \.isWhitespace)
                    .compactMap { UInt16($0, radix: 16) }
            }
            controls.append(Control(code: code, values: values))
        }
        return controls
    }
}
