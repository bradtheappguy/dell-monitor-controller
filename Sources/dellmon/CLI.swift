import Foundation

enum CLI {
    static let usage = """
    dellmon — control a Dell monitor over DDC/CI

    USAGE
      dellmon <feature> [value]          read a feature, or set it
      dellmon get [feature ...]          read features (all four by default)
      dellmon set <feature> <value>      set a feature
      dellmon list                       list DDC-capable displays
      dellmon caps                       print the monitor's capability string
      dellmon raw get <code>             read any VCP code
      dellmon raw set <code> <value>     write any VCP code

    FEATURES
      brightness    0-100
      contrast      0-100
      volume        0-100
      input         dp, hdmi1, hdmi2, usbc (or a raw code)

    VALUES
      60            absolute
      +10  -10      relative to the current value

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
            case "list":
                try list()
            case "help":
                print(usage)
            case "caps":
                let display = try DisplayFinder.select(displaySelector)
                print(try display.ddc(verbose: verbose).capabilities())
            case "raw":
                try raw(rest, displaySelector: displaySelector, quiet: quiet, verbose: verbose)
            case "get":
                let display = try DisplayFinder.select(displaySelector)
                try get(rest, display: display, quiet: quiet, verbose: verbose)
            case "set":
                guard rest.count == 2 else { fail("usage: dellmon set <feature> <value>") }
                let display = try DisplayFinder.select(displaySelector)
                try set(rest[0], to: rest[1], display: display, quiet: quiet, verbose: verbose)
            default:
                guard Features.named(command) != nil else {
                    fail("unknown command or feature '\(command)' — try `dellmon --help`")
                }
                let display = try DisplayFinder.select(displaySelector)
                if let value = rest.first {
                    try set(command, to: value, display: display, quiet: quiet, verbose: verbose)
                } else {
                    try get([command], display: display, quiet: quiet, verbose: verbose)
                }
            }
        } catch let error as DDCError {
            fail(error.description)
        } catch {
            fail("\(error)")
        }
    }

    // MARK: - Commands

    private static func list() throws {
        for display in try DisplayFinder.all() {
            let maker = display.manufacturer.isEmpty ? "" : "  \(display.manufacturer)"
            let serial = display.serial.isEmpty ? "" : "  serial \(display.serial)"
            print("\(display.index)  \(display.name)\(maker)\(serial)")
        }
    }

    private static func get(_ names: [String], display: Display, quiet: Bool, verbose: Bool) throws {
        let readingEverything = names.isEmpty
        let features = (readingEverything ? Features.all.map(\.name) : names).map { name -> Feature in
            guard let feature = Features.named(name) else {
                fail("unknown feature '\(name)' — try `dellmon --help`")
            }
            return feature
        }

        let ddc = display.ddc(verbose: verbose)
        for feature in features {
            do {
                let (current, _) = try ddc.getVCP(feature.code)
                if quiet {
                    print(feature.describe(current))
                } else {
                    print("\(feature.name.padding(toLength: 11, withPad: " ", startingAt: 0))\(feature.describe(current))")
                }
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
    }

    private static func raw(_ args: [String], displaySelector: String?, quiet: Bool, verbose: Bool) throws {
        let display = try DisplayFinder.select(displaySelector)
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

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data("dellmon: \(message)\n".utf8))
    }

    static func fail(_ message: String) -> Never {
        warn(message)
        exit(1)
    }
}
