import Foundation
import IOKit

/// Thin binding to the private `IOAVService` C API inside IOKit.
///
/// Apple Silicon does not expose the old `IOFramebufferI2C` interface that
/// Intel Macs used for DDC/CI, so the only route to the monitor's I2C bus is
/// this unpublished set of functions. They are resolved with `dlsym` at
/// runtime rather than linked, so a future macOS that drops them produces a
/// clean error instead of a dyld crash on launch.
final class IOAVService {
    typealias CreateWithService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias ReadI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias WriteI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeRawPointer, UInt32) -> IOReturn

    let createWithService: CreateWithService
    let readI2C: ReadI2C
    let writeI2C: WriteI2C

    static let shared: IOAVService? = IOAVService()

    private init?() {
        let path = "/System/Library/Frameworks/IOKit.framework/IOKit"
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        guard let create = dlsym(handle, "IOAVServiceCreateWithService"),
              let read = dlsym(handle, "IOAVServiceReadI2C"),
              let write = dlsym(handle, "IOAVServiceWriteI2C")
        else { return nil }
        createWithService = unsafeBitCast(create, to: CreateWithService.self)
        readI2C = unsafeBitCast(read, to: ReadI2C.self)
        writeI2C = unsafeBitCast(write, to: WriteI2C.self)
    }
}
