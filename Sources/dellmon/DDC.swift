import Foundation
import IOKit

enum DDCError: Error, CustomStringConvertible {
    case unsupportedPlatform
    case noDisplays
    case displayNotFound(String)
    case writeFailed(IOReturn)
    case readFailed(IOReturn)
    case noReply(UInt8)
    case unsupportedFeature(UInt8)

    var description: String {
        switch self {
        case .unsupportedPlatform:
            return "this build needs the IOAVService DDC interface, which this version of macOS does not expose"
        case .noDisplays:
            return "no external display found (built-in panels have no DDC/CI bus)"
        case .displayNotFound(let which):
            return "no display matching '\(which)' — run `dellmon list`"
        case .writeFailed(let code):
            return "I2C write failed (IOReturn 0x\(String(code, radix: 16)))"
        case .readFailed(let code):
            return "I2C read failed (IOReturn 0x\(String(code, radix: 16)))"
        case .noReply(let vcp):
            return "no valid reply for VCP 0x\(hex(vcp)) — the monitor may be asleep, on another input, or have DDC/CI disabled in its OSD menu"
        case .unsupportedFeature(let vcp):
            return "the monitor reports VCP 0x\(hex(vcp)) as unsupported"
        }
    }
}

func hex(_ value: UInt8) -> String {
    String(format: "%02X", value)
}

/// DDC/CI (MCCS) over the monitor's I2C bus.
struct DDC {
    /// 7-bit I2C address of the display's DDC/CI slave.
    private static let i2cAddress: UInt32 = 0x37
    /// Host (source) address that opens every packet we send.
    private static let hostAddress: UInt8 = 0x51
    /// Display address, folded into the checksum of packets we send.
    private static let displayAddress: UInt8 = 0x6E
    /// Virtual host address, which seeds the checksum of replies we receive.
    private static let virtualHostAddress: UInt8 = 0x50

    /// The spec asks for 40ms+ between transactions; Dell panels are happier
    /// with a little more, and the extra milliseconds are imperceptible for a
    /// one-shot CLI.
    private static let settleDelay: UInt32 = 50_000
    private static let attempts = 8

    /// How long to keep retrying a read before calling the monitor
    /// unreachable. A U3818DW stops answering DDC for up to three seconds
    /// after an input change, and NAKs the odd transaction even when idle, so
    /// the limit that matters is elapsed time rather than a count of tries.
    private static let retryBudget: TimeInterval = 4

    /// Backoff before retry `attempt`: doubling, then capped so a long wait
    /// stays responsive. The shift is clamped as well as the result, since an
    /// unsigned overshift yields zero and would spin the retry loop.
    private static func backoff(_ attempt: Int) -> UInt32 {
        min(settleDelay << UInt32(min(attempt - 1, 8)), 400_000)
    }

    let service: CFTypeRef
    var verbose = false

    // MARK: - Public operations

    /// Sets a VCP feature to an absolute value.
    func setVCP(_ code: UInt8, _ value: UInt16) throws {
        let packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        try write(packet)
        // An input change makes the monitor renegotiate the link; hold the
        // bus a little longer so a following command isn't talking to a
        // display that has stopped listening.
        usleep(code == Features.input.code ? 6 * DDC.settleDelay : DDC.settleDelay)
    }

    /// Reads a VCP feature, returning its current and maximum value.
    func getVCP(_ code: UInt8) throws -> (current: UInt16, max: UInt16) {
        let deadline = Date().addingTimeInterval(DDC.retryBudget)
        var lastError: DDCError?
        var attempt = 0

        repeat {
            attempt += 1
            if attempt > 1 { usleep(DDC.backoff(attempt)) }
            do {
                try write([0x82, 0x01, code])
                usleep(DDC.settleDelay)
                let reply = try read(count: 11)

                // Expected frame: 6E 88 02 <result> <vcp> <type> <max hi> <max lo> <cur hi> <cur lo> <checksum>
                // A busy monitor leaves the bus undriven, so the read comes
                // back as zeroes or an echo of the bytes we just sent.
                guard reply[0] == DDC.displayAddress, reply[2] == 0x02, reply[4] == code else {
                    lastError = .noReply(code)
                    continue
                }
                guard reply[3] == 0x00 else { throw DDCError.unsupportedFeature(code) }
                guard checksumIsValid(reply) else {
                    lastError = .noReply(code)
                    continue
                }
                return (UInt16(reply[8]) << 8 | UInt16(reply[9]), UInt16(reply[6]) << 8 | UInt16(reply[7]))
            } catch let error as DDCError {
                if case .unsupportedFeature = error { throw error }
                lastError = error
            }
        } while Date() < deadline

        throw lastError ?? DDCError.noReply(code)
    }

    /// Fetches the monitor's capability string, which lists every VCP code it
    /// supports and the discrete values each one accepts.
    func capabilities() throws -> String {
        var result = [UInt8]()
        var offset: UInt16 = 0
        // Each reply carries at most 32 bytes, so cap the loop well above any
        // real capability string rather than trusting the monitor to terminate.
        for _ in 0..<64 {
            var chunk: [UInt8]?
            for attempt in 1...DDC.attempts {
                if attempt > 1 { usleep(DDC.backoff(attempt)) }
                try write([0x83, 0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF)])
                usleep(DDC.settleDelay)
                guard let reply = try? read(count: 38) else { continue }
                guard reply[0] == DDC.displayAddress, reply[2] == 0xE3 else { continue }
                let replyOffset = UInt16(reply[3]) << 8 | UInt16(reply[4])
                guard replyOffset == offset else { continue }
                let length = Int(reply[1] & 0x7F)
                guard length >= 3 else { continue }
                chunk = Array(reply[5..<(5 + length - 3)])
                break
            }
            guard let chunk else { throw DDCError.noReply(0xF3) }
            if chunk.isEmpty { break }
            result.append(contentsOf: chunk)
            offset += UInt16(chunk.count)
        }
        return String(decoding: result, as: UTF8.self)
    }

    // MARK: - Transport

    private func write(_ payload: [UInt8]) throws {
        guard let lib = IOAVService.shared else { throw DDCError.unsupportedPlatform }
        var packet = payload
        var checksum = DDC.displayAddress ^ DDC.hostAddress
        for byte in payload { checksum ^= byte }
        packet.append(checksum)

        if verbose { log("->", packet) }
        let result = packet.withUnsafeBytes { buffer in
            lib.writeI2C(service, DDC.i2cAddress, UInt32(DDC.hostAddress), buffer.baseAddress!, UInt32(packet.count))
        }
        guard result == KERN_SUCCESS else { throw DDCError.writeFailed(result) }
    }

    private func read(count: Int) throws -> [UInt8] {
        guard let lib = IOAVService.shared else { throw DDCError.unsupportedPlatform }
        var buffer = [UInt8](repeating: 0, count: count)
        let result = buffer.withUnsafeMutableBytes { raw in
            lib.readI2C(service, DDC.i2cAddress, UInt32(DDC.hostAddress), raw.baseAddress!, UInt32(count))
        }
        guard result == KERN_SUCCESS else { throw DDCError.readFailed(result) }
        if verbose { log("<-", buffer) }
        return buffer
    }

    /// A reply's checksum covers every byte it contains, seeded with the
    /// virtual host address that the display answered to.
    private func checksumIsValid(_ reply: [UInt8]) -> Bool {
        let length = Int(reply[1] & 0x7F) + 2
        guard length < reply.count else { return false }
        var checksum = DDC.virtualHostAddress
        for byte in reply[0..<length] { checksum ^= byte }
        return checksum == reply[length]
    }

    private func log(_ direction: String, _ bytes: [UInt8]) {
        let text = bytes.map(hex).joined(separator: " ")
        FileHandle.standardError.write(Data("\(direction) \(text)\n".utf8))
    }
}
