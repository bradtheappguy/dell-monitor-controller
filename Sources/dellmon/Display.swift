import Foundation
import IOKit

/// An external display reachable over DDC/CI.
struct Display {
    let index: Int
    let name: String
    let manufacturer: String
    let serial: String
    let service: CFTypeRef

    var label: String {
        serial.isEmpty ? name : "\(name) (\(serial))"
    }

    func ddc(verbose: Bool) -> DDC {
        DDC(service: service, verbose: verbose)
    }
}

enum DisplayFinder {
    /// Walks the IORegistry pairing each display's framebuffer with the
    /// `DCPAVServiceProxy` that owns its I2C bus.
    ///
    /// The two live in different branches of the tree with no direct link
    /// between them, but a recursive walk always visits a framebuffer's
    /// product attributes before the proxy it belongs to, so the most recent
    /// attributes seen identify the next proxy.
    static func all() throws -> [Display] {
        guard let lib = IOAVService.shared else { throw DDCError.unsupportedPlatform }

        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        let status = IORegistryEntryCreateIterator(
            root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator)
        guard status == KERN_SUCCESS else { throw DDCError.noDisplays }
        defer { IOObjectRelease(iterator) }

        var displays = [Display]()
        var pending: (name: String, manufacturer: String, serial: String)?

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }

            if let attributes = property(entry, "DisplayAttributes") as? [String: Any],
               let product = attributes["ProductAttributes"] as? [String: Any] {
                pending = (
                    name: product["ProductName"] as? String ?? "Unknown display",
                    manufacturer: product["ManufacturerID"] as? String ?? "",
                    serial: product["AlphanumericSerialNumber"] as? String
                        ?? (product["SerialNumber"] as? Int).map(String.init) ?? ""
                )
            }

            guard className(entry) == "DCPAVServiceProxy",
                  property(entry, "Location") as? String == "External",
                  let service = lib.createWithService(kCFAllocatorDefault, entry)?.takeRetainedValue()
            else { continue }

            let info = pending ?? (name: "Unknown display", manufacturer: "", serial: "")
            displays.append(Display(
                index: displays.count + 1,
                name: info.name,
                manufacturer: info.manufacturer,
                serial: info.serial,
                service: service))
            pending = nil
        }

        if displays.isEmpty { throw DDCError.noDisplays }
        return displays
    }

    /// Resolves `--display`: a 1-based index, or any case-insensitive
    /// substring of a display's name or serial. Defaults to the first display.
    static func select(_ wanted: String?) throws -> Display {
        let displays = try all()
        guard let wanted, !wanted.isEmpty else { return displays[0] }

        if let index = Int(wanted) {
            guard let display = displays.first(where: { $0.index == index }) else {
                throw DDCError.displayNotFound(wanted)
            }
            return display
        }

        let needle = wanted.lowercased()
        guard let display = displays.first(where: {
            $0.name.lowercased().contains(needle) || $0.serial.lowercased().contains(needle)
        }) else { throw DDCError.displayNotFound(wanted) }
        return display
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func className(_ entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &buffer) == KERN_SUCCESS else { return "" }
        return String(cString: buffer)
    }
}
