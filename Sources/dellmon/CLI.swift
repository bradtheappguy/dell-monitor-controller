import Foundation

enum CLI {
    static let usage = """
    dellmon — control a Dell monitor over DDC/CI

    USAGE
      dellmon <feature> [value]          read a feature, or set it
      dellmon get [feature ...]          read the main features
      dellmon set <feature> <value>      set a feature
      dellmon info                       everything the monitor reports
      dellmon list                       list DDC-capable displays
      dellmon reset <what>               restore factory defaults
      dellmon caps                       print the monitor's capability string
      dellmon probe                      read every control the monitor has
      dellmon watch                      report controls as they change
      dellmon raw get <code>             read any VCP code
      dellmon raw set <code> <value>     write any VCP code

    FEATURES
      brightness         0-100
      contrast           0-100
      volume             0-100
      input              dp, hdmi1, hdmi2, usbc
      power              on, standby, off
      preset             standard, movie, game
      colortemp          5000k, 6500k, 7500k, 9300k, 10000k, user1, user2
      red, green, blue   0-100, white point gain in custom colour mode

    VALUES
      60            absolute
      +10  -10      relative to the current value

    RESET
      dellmon reset brightness           brightness and contrast
      dellmon reset color                colour settings
      dellmon reset all                  every setting

    OPTIONS
      -d, --display <n|text>   target display: list index, or part of its
                               name or serial (default: the first one)
      -q, --quiet              print bare values, nothing else
      -v, --verbose            dump the DDC packets to stderr
      -h, --help               show this help

    EXAMPLES
      dellmon brightness 60
      dellmon volume +10
      dellmon input hdmi2
      dellmon get brightness contrast
    """

    static func main() {
        var displaySelector: String?
        var verbose = false
        var quiet = false
        var positional = [String]()

        let args = Array(CommandLine.arguments.dropFirst())
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-h", "--help":
                print(usage)
                exit(0)
            case "-v", "--verbose":
                verbose = true
            case "-q", "--quiet":
                quiet = true
            case "-d", "--display":
                index += 1
                guard index < args.count else { fail("--display needs a value") }
                displaySelector = args[index]
            default:
                if arg.hasPrefix("--display=") {
                    displaySelector = String(arg.dropFirst("--display=".count))
                } else if arg.hasPrefix("-") && Int(arg) == nil {
                    fail("unknown option '\(arg)' — try `dellmon --help`")
                } else {
                    positional.append(arg)
                }
            }
            index += 1
        }

        guard let command = positional.first else {
            print(usage)
            exit(0)
        }
        let rest = Array(positional.dropFirst())

        do {
            switch command {
            case "help":
                print(usage)
            case "list":
                try list()
            case "caps":
                print(try display(displaySelector).ddc(verbose: verbose).capabilities())
            case "info":
                try info(display: display(displaySelector), verbose: verbose)
            case "probe":
                try probe(display: display(displaySelector), verbose: verbose)
            case "watch":
                try watch(display: display(displaySelector), verbose: verbose)
            case "reset":
                try reset(rest, display: display(displaySelector), quiet: quiet, verbose: verbose)
            case "raw":
                try raw(rest, display: display(displaySelector), quiet: quiet, verbose: verbose)
            case "get":
                try get(rest, display: display(displaySelector), quiet: quiet, verbose: verbose)
            case "set":
                guard rest.count == 2 else { fail("usage: dellmon set <feature> <value>") }
                try set(rest[0], to: rest[1], display: display(displaySelector), quiet: quiet, verbose: verbose)
            default:
                guard Features.named(command) != nil else {
                    fail("unknown command or feature '\(command)' — try `dellmon --help`")
                }
                let target = try display(displaySelector)
                if let value = rest.first {
                    try set(command, to: value, display: target, quiet: quiet, verbose: verbose)
                } else {
                    try get([command], display: target, quiet: quiet, verbose: verbose)
                }
            }
        } catch let error as DDCError {
            fail(error.description)
        } catch {
            fail("\(error)")
        }
    }

    // MARK: - Commands

    private static func display(_ selector: String?) throws -> Display {
        try DisplayFinder.select(selector)
    }

    private static func list() throws {
        for display in try DisplayFinder.all() {
            let maker = display.manufacturer.isEmpty ? "" : "  \(display.manufacturer)"
            let serial = display.serial.isEmpty ? "" : "  serial \(display.serial)"
            print("\(display.index)  \(display.name)\(maker)\(serial)")
        }
    }

    private static func get(_ names: [String], display: Display, quiet: Bool, verbose: Bool) throws {
        let readingEverything = names.isEmpty
        let features = (readingEverything ? Features.core.map(\.name) : names).map { name -> Feature in
            guard let feature = Features.named(name) else {
                fail("unknown feature '\(name)' — try `dellmon --help`")
            }
            return feature
        }

        let ddc = display.ddc(verbose: verbose)
        for feature in features {
            do {
                let (current, _) = try ddc.getVCP(feature.code)
                print(quiet ? feature.describe(current) : row(feature.name, feature.describe(current)))
            } catch let error as DDCError {
                guard readingEverything else { throw error }
                // A feature this monitor happens not to implement shouldn't
                // hide the rest. A bus that has stopped answering will fail
                // them all, so report that once rather than waiting out the
                // retry budget another three times.
                guard case .unsupportedFeature = error else { throw error }
                warn("\(feature.name): \(error.description)")
            }
        }
    }

    private static func set(_ name: String, to text: String, display: Display, quiet: Bool, verbose: Bool) throws {
        guard let feature = Features.named(name) else {
            fail("unknown feature '\(name)' — try `dellmon --help`")
        }
        let ddc = display.ddc(verbose: verbose)

        let value: UInt16
        var previous: UInt16?
        if feature.isContinuous {
            // Reading first gives us the monitor's real range to clamp to, and
            // the old value to report. A monitor that refuses the read still
            // gets the write, as long as it was an absolute one.
            let reading = try? ddc.getVCP(feature.code)
            previous = reading?.current
            let ceiling = Int(reading?.max ?? 100)

            if text.hasPrefix("+") || text.hasPrefix("-") {
                guard let delta = Int(text) else { fail("'\(text)' is not a number") }
                guard let current = reading?.current else { throw DDCError.noReply(feature.code) }
                value = UInt16(min(ceiling, max(0, Int(current) + delta)))
            } else {
                guard let absolute = parseNumber(text), absolute >= 0 else {
                    fail("'\(text)' is not a value for \(feature.name)")
                }
                value = UInt16(min(ceiling, absolute))
            }
        } else if let named = feature.value(for: text.lowercased()) {
            value = named
        } else if let code = parseNumber(text), code >= 0, code <= 0xFFFF {
            value = UInt16(code)
        } else {
            let choices = feature.choices.map(\.name).joined(separator: ", ")
            fail("'\(text)' is not a \(feature.name) — try one of: \(choices)")
        }

        try ddc.setVCP(feature.code, value)

        guard !quiet else { return }
        if let previous, previous != value {
            print("\(feature.name) \(feature.describe(previous)) -> \(feature.describe(value))")
        } else {
            print("\(feature.name) \(feature.describe(value))")
        }
        if feature.code == Features.power.code, value != 0x01 {
            warn("the monitor may stop answering DDC while off — its power button always wakes it")
        }
    }

    private static func info(display: Display, verbose: Bool) throws {
        let ddc = display.ddc(verbose: verbose)
        print(row("model", display.name))
        if !display.manufacturer.isEmpty { print(row("vendor", display.manufacturer)) }
        if !display.serial.isEmpty { print(row("serial", display.serial)) }

        if let version = try? ddc.getVCP(0xDF).current {
            print(row("mccs", "\(version >> 8).\(version & 0xFF)"))
        }
        if let firmware = try? ddc.getVCP(0xC9).current {
            print(row("firmware", "0x\(String(format: "%04X", firmware))"))
        }
        if let refresh = try? ddc.getVCP(0xAE).current {
            print(row("refresh", String(format: "%.2f Hz", Double(refresh) / 100)))
        }

        for feature in Features.all {
            guard let reading = try? ddc.getVCP(feature.code) else { continue }
            print(row(feature.name, feature.describe(reading.current)))
        }
    }

    private static func probe(display: Display, verbose: Bool) throws {
        let ddc = display.ddc(verbose: verbose)
        let capabilities = Capabilities.parse(try ddc.capabilities())
        guard !capabilities.controls.isEmpty else { fail("the monitor advertised no controls") }

        print("code  control      value          advertised")
        for control in capabilities.controls {
            let feature = Features.named(code: control.code)
            let reading = try? ddc.getVCP(control.code)

            let value: String
            if let reading {
                value = feature.map { $0.describe(reading.current) }
                    ?? "\(reading.current) / \(reading.max)"
            } else {
                value = "-"
            }
            let advertised = control.values
                .map { feature?.describe($0) ?? "0x\(String(format: "%02X", $0))" }
                .joined(separator: " ")

            print("0x\(hex(control.code))  \(pad(feature?.name ?? "-", 11))  \(pad(value, 13))  \(advertised)")
        }
        print("")
        print("controls shown as - have no name in this tool; `dellmon watch` identifies them")
    }

    /// Polls every advertised control and reports changes, so that a control
    /// this tool has no name for can be identified by changing it in the
    /// monitor's own menu and seeing which code moves.
    private static func watch(display: Display, verbose: Bool) throws {
        let ddc = display.ddc(verbose: verbose)
        let capabilities = Capabilities.parse(try ddc.capabilities())
        // 0x02 and 0x52 report *that* something changed, so they move
        // whenever anything else does and would drown out the control itself.
        let noisy: Set<UInt8> = [0x02, 0x52]
        let codes = capabilities.controls.map(\.code).filter { !noisy.contains($0) }
        guard !codes.isEmpty else { fail("the monitor advertised no controls") }

        var known = [UInt8: UInt16]()
        for code in codes {
            if let reading = try? ddc.getVCP(code) { known[code] = reading.current }
        }
        warn("watching \(known.count) controls — change something in the monitor's menu (ctrl-c to stop)")

        while true {
            for code in codes {
                guard let reading = try? ddc.getVCP(code) else { continue }
                defer { known[code] = reading.current }
                guard let previous = known[code], previous != reading.current else { continue }

                let feature = Features.named(code: code)
                let describe = { (value: UInt16) in feature?.describe(value) ?? String(value) }
                print("0x\(hex(code))  \(pad(feature?.name ?? "-", 11))  \(describe(previous)) -> \(describe(reading.current))")
                fflush(stdout)
            }
        }
    }

    private static func reset(_ args: [String], display: Display, quiet: Bool, verbose: Bool) throws {
        let code: UInt8
        switch args.first {
        case "brightness", "contrast":
            code = 0x05
        case "color", "colour":
            code = 0x08
        case "all", "factory":
            code = 0x04
        default:
            fail("usage: dellmon reset brightness|color|all")
        }
        // These are write-only actions: the value is the trigger, not a setting.
        try display.ddc(verbose: verbose).setVCP(code, 1)
        if !quiet { print("reset \(args[0])") }
    }

    private static func raw(_ args: [String], display: Display, quiet: Bool, verbose: Bool) throws {
        let ddc = display.ddc(verbose: verbose)

        switch args.first {
        case "get":
            guard args.count == 2, let code = parseNumber(args[1]), (0...0xFF).contains(code) else {
                fail("usage: dellmon raw get <code>")
            }
            let (current, maximum) = try ddc.getVCP(UInt8(code))
            print(quiet ? "\(current)" : "0x\(hex(UInt8(code)))  current \(current)  max \(maximum)")
        case "set":
            guard args.count == 3, let code = parseNumber(args[1]), (0...0xFF).contains(code),
                  let value = parseNumber(args[2]), (0...0xFFFF).contains(value) else {
                fail("usage: dellmon raw set <code> <value>")
            }
            try ddc.setVCP(UInt8(code), UInt16(value))
            if !quiet { print("0x\(hex(UInt8(code)))  \(value)") }
        default:
            fail("usage: dellmon raw get <code> | dellmon raw set <code> <value>")
        }
    }

    // MARK: - Helpers

    private static func parseNumber(_ text: String) -> Int? {
        let lowered = text.lowercased()
        if lowered.hasPrefix("0x") { return Int(lowered.dropFirst(2), radix: 16) }
        return Int(text)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private static func row(_ label: String, _ value: String) -> String {
        "\(pad(label, 11))\(value)"
    }

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data("dellmon: \(message)\n".utf8))
    }

    static func fail(_ message: String) -> Never {
        warn(message)
        exit(1)
    }
}
