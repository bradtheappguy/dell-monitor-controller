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
    static let brightness = Feature(name: "brightness", code: 0x10, choices: [])
    static let contrast = Feature(name: "contrast", code: 0x12, choices: [])
    static let volume = Feature(name: "volume", code: 0x62, choices: [])

    /// The four inputs a U3818DW reports in its capability string,
    /// `60(1B 0F 11 12)`. On another monitor, `dellmon caps` is the authority
    /// and `dellmon raw set 0x60 <code>` reaches anything not listed here.
    static let input = Feature(name: "input", code: 0x60, choices: [
        .init("dp", 0x0F, "displayport", "dp1"),
        .init("hdmi1", 0x11, "hdmi", "hdmi-1"),
        .init("hdmi2", 0x12, "hdmi-2"),
        .init("usbc", 0x1B, "usb-c", "typec", "type-c", "thunderbolt"),
    ])

    /// `D6(01 04 05)`. A monitor switched off this way may stop answering
    /// DDC, so waking it can need its power button rather than `power on`.
    static let power = Feature(name: "power", code: 0xD6, choices: [
        .init("on", 0x01),
        .init("standby", 0x04, "sleep", "suspend"),
        .init("off", 0x05),
    ])

    /// `DC(00 03 05)` — the monitor's picture presets.
    static let preset = Feature(name: "preset", code: 0xDC, choices: [
        .init("standard", 0x00),
        .init("movie", 0x03),
        .init("game", 0x05, "games"),
    ])

    /// `14(04 05 06 08 09 0B 0C)`, named per MCCS. Dell's OSD labels its
    /// colour temperatures slightly differently, so treat these as the codes
    /// the monitor accepts rather than as exact OSD wording.
    static let colorTemperature = Feature(name: "colortemp", code: 0x14, choices: [
        .init("5000k", 0x04),
        .init("6500k", 0x05),
        .init("7500k", 0x06),
        .init("9300k", 0x08),
        .init("10000k", 0x09),
        .init("user1", 0x0B, "custom"),
        .init("user2", 0x0C),
    ])

    /// White-point gains, which the monitor applies in its custom colour mode.
    static let red = Feature(name: "red", code: 0x16, choices: [])
    static let green = Feature(name: "green", code: 0x18, choices: [])
    static let blue = Feature(name: "blue", code: 0x1A, choices: [])

    /// What `dellmon get` reports when asked for nothing in particular.
    static let core = [brightness, contrast, volume, input]

    static let all = core + [power, preset, colorTemperature, red, green, blue]

    static func named(_ name: String) -> Feature? {
        all.first { $0.name == name }
    }

    static func named(code: UInt8) -> Feature? {
        all.first { $0.code == code }
    }
}
