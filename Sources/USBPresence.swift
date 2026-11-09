import Foundation
import IOKit

func usbInterfaces() -> Set<UInt64>? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator)
            == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    var media: Set<UInt64> = []
    var interfaces: Set<UInt64> = []
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
        interfaces.insert(id)
        let name = IORegistryEntryCreateCFProperty(service, "kUSBString" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        let interfaceClass = IORegistryEntryCreateCFProperty(service, "bInterfaceClass" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber
        if name?.localizedCaseInsensitiveContains("MTP") == true || interfaceClass?.intValue == 6 {
            media.insert(id)
        }
    }
    return media.isEmpty ? interfaces : media
}
