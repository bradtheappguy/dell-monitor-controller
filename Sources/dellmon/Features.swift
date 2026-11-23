import Foundation

/// A named MCCS/VCP feature the CLI exposes.
struct Feature {
    let name: String
    let code: UInt8
    /// Named values, for features whose range is a set of choices rather than
    /// a slider. Empty means the feature is continuous.
    let choices: [Choice]

    var isContinuous: Bool { choices.isEmpty }

    struct Choice {
        let name: String
        let value: UInt16
        /// Alternate spellings accepted on the command line.
        let aliases: [String]

        init(_ name: String, _ value: UInt16, _ aliases: String...) {
            self.name = name
            self.value = value
            self.aliases = aliases
        }

        func matches(_ text: String) -> Bool {
            name == text || aliases.contains(text)
        }
    }

    /// Some monitors (the U3818DW among them) echo a discrete value in both
    /// bytes of the reply, reporting DisplayPort as 0x0F0F rather than 0x0F.
    func normalize(_ value: UInt16) -> UInt16 {
        isContinuous ? value : value & 0xFF
    }

    /// Renders a raw value the way a human reads it.
    func describe(_ value: UInt16) -> String {
        let value = normalize(value)
        guard let choice = choices.first(where: { $0.value == value }) else {
            return isContinuous ? String(value) : "0x\(String(format: "%02X", value))"
        }
        return choice.name
    }

    func value(for text: String) -> UInt16? {
        choices.first(where: { $0.matches(text) })?.value
    }
}

enum Features {
    /// The four inputs a U3818DW reports in its capability string,
    /// `60(1B 0F 11 12)`. On another monitor, `dellmon caps` is the authority
    /// and `dellmon raw set 0x60 <code>` reaches anything not listed here.
    static let input = Feature(name: "input", code: 0x60, choices: [
        .init("dp", 0x0F, "displayport", "dp1"),
        .init("hdmi1", 0x11, "hdmi", "hdmi-1"),
        .init("hdmi2", 0x12, "hdmi-2"),
        .init("usbc", 0x1B, "usb-c", "typec", "type-c", "thunderbolt"),
    ])

    static let all: [Feature] = [
        Feature(name: "brightness", code: 0x10, choices: []),
        Feature(name: "contrast", code: 0x12, choices: []),
        Feature(name: "volume", code: 0x62, choices: []),
        input,
    ]

    static func named(_ name: String) -> Feature? {
        all.first { $0.name == name }
    }
}
