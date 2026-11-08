import AppKit
import IOKit

func mtpInterfaces() -> Set<UInt64>? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator)
        == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    var interfaces: Set<UInt64> = []
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        let name = IORegistryEntryCreateCFProperty(service, "kUSBString" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        var id: UInt64 = 0
        if name?.localizedCaseInsensitiveContains("MTP") == true,
           IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS {
            interfaces.insert(id)
        }
    }
    return interfaces
}

if CommandLine.arguments.contains("--probe") {
    print(mtpInterfaces()?.count ?? 0)
    exit(0)
}

let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let application = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
var previous = mtpInterfaces() ?? []

Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    guard let current = mtpInterfaces() else { return }
    let connected = !current.subtracting(previous).isEmpty
    previous = current
    if connected {
        NSWorkspace.shared.openApplication(at: application, configuration: .init(), completionHandler: nil)
    }
}
RunLoop.main.run()
