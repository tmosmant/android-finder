import Foundation

// Both transports send depth-first records: path, metadata, then a terminal
// status. NUL framing preserves filenames with spaces and line breaks.
final class StorageInventory {
    enum Source {
        case adb(WirelessStorage)
        case mtp(serial: String, storageID: UInt32)
    }

    typealias Scan = (root: StorageNode, partial: Bool, usesUSBADB: Bool, source: Source?, cacheKey: StorageCache.Key?)

    private let scope: String
    private let request: OperationRequest
    private let progress: (StorageNode?, Int) -> Void
    private let identify: ((String, UInt32) -> Void)?
    private var rootChildren: [StorageNode] = []
    private var currentPath: String?
    private var currentEntries: [AndroidEntry] = []
    private var finished = false
    private var partial = false
    private var lastUpdate: UInt64?
    private var publishedChildren = 0
    private var scannedFiles = 0
    private var currentBytes: Double = 0
    private var currentFiles = 0
    private var usbSerial: String?
    private var storageID: UInt32?

    init(scope: String, request: OperationRequest, identify: ((String, UInt32) -> Void)? = nil,
         progress: @escaping (StorageNode?, Int) -> Void) {
        self.scope = scope
        self.request = request
        self.progress = progress
        self.identify = identify
    }

    static func scan(scope: String, request: OperationRequest, mtp: MTP, wireless: WirelessStorage?,
                     cache: StorageCache? = nil, cached: ((StorageCache.Snapshot, Bool) -> Void)? = nil,
                     progress: @escaping (StorageNode?, Int, Bool) -> Void)
        throws -> Scan {
        func read(_ inventory: StorageInventory,
                  run: (@escaping (FileHandle) -> Void) throws -> Void) throws -> (StorageNode, Bool) {
            var result: Result<(StorageNode, Bool), Error>?
            try run { handle in
                result = Result { try inventory.read(handle) }
                if case .failure = result { try? handle.close() }
            }
            guard let result else { throw CocoaError(.fileReadUnknown) }
            return try result.get()
        }

        func loadCache(_ key: StorageCache.Key, usesUSBADB: Bool) {
            if let snapshot = cache?.load(key) { cached?(snapshot, usesUSBADB) }
        }

        func scanADB(_ storage: WirelessStorage, usesUSBADB: Bool) throws -> Scan {
            var key: StorageCache.Key?
            if cache != nil, let serial = try? storage.deviceSerial(request: request),
               !serial.isEmpty, serial != "unknown" {
                let identity = StorageCache.Key(device: serial, volume: "adb-shared", scope: scope)
                key = identity
                loadCache(identity, usesUSBADB: usesUSBADB)
            }
            let inventory = StorageInventory(scope: scope, request: request) { progress($0, $1, usesUSBADB) }
            let (root, partial) = try read(inventory) { try storage.inventory(scope, request: request, consume: $0) }
            if let key { cache?.save(.init(root: root, partial: partial, date: Date()), for: key) }
            return (root, partial, usesUSBADB, .adb(storage), key)
        }

        if let wireless { return try scanADB(wireless, usesUSBADB: false) }

        let adb = scope == "/" ? ADB.locate() : nil
        var attemptedUSBADB = false
        if let adb, let serial = try? mtp.usbSerial(request: request), !serial.isEmpty,
           let usb = try? adb.usbStorage(serial: serial, request: request) {
            attemptedUSBADB = true
            progress(nil, 0, true)
            do {
                return try scanADB(usb, usesUSBADB: true)
            } catch {
                try request.checkCancellation()
                progress(nil, 0, false)
            }
        }

        var key: StorageCache.Key?
        let inventory = StorageInventory(scope: scope, request: request, identify: { serial, storageID in
            let identity = StorageCache.Key(device: serial, volume: "mtp-\(storageID)", scope: scope)
            key = identity
            loadCache(identity, usesUSBADB: false)
        }) { progress($0, $1, false) }
        do {
            let (root, partial) = try read(inventory) { try mtp.inventory(scope, request: request, consume: $0) }
            let source: Source?
            if let serial = inventory.usbSerial, let storageID = inventory.storageID {
                source = .mtp(serial: serial, storageID: storageID)
            } else {
                source = nil
            }
            if let key { cache?.save(.init(root: root, partial: partial, date: Date()), for: key) }
            return (root, partial, false, source, key)
        } catch {
            try request.checkCancellation()
            guard !attemptedUSBADB, let adb, error.localizedDescription.contains("LIBUSB_ERROR_TIMEOUT"),
                  let serial = inventory.usbSerial, let usb = try? adb.usbStorage(serial: serial, request: request)
            else { throw error }
            return try scanADB(usb, usesUSBADB: true)
        }
    }

    func read(_ handle: FileHandle) throws -> (root: StorageNode, partial: Bool) {
        var field = Data()
        var path: Data?
        // availableData returns as soon as a pipe has bytes. A sized
        // FileHandle read can wait for its buffer to fill or for EOF.
        while case let chunk = handle.availableData, !chunk.isEmpty {
            try request.checkCancellation()
            var start = chunk.startIndex
            while let end = chunk[start...].firstIndex(of: 0) {
                field.append(contentsOf: chunk[start..<end])
                if let relative = path {
                    try receive(relative, metadata: field)
                    path = nil
                } else {
                    path = field
                }
                field = Data()
                start = end + 1
            }
            field.append(contentsOf: chunk[start...])
        }
        guard finished, field.isEmpty, path == nil else {
            throw ADB.error(L10n.text("adb.list.incomplete"))
        }
        try request.checkCancellation()
        try completeChild()
        return (snapshot(), partial)
    }

    private func receive(_ path: Data, metadata: Data) throws {
        guard !finished else { throw ADB.error(L10n.text("adb.list.invalid")) }
        let info = String(decoding: metadata, as: UTF8.self)
        if path.elementsEqual("!".utf8) {
            if info.hasPrefix("usb "), usbSerial == nil {
                usbSerial = String(info.dropFirst(4))
                return
            }
            if info.hasPrefix("storage "), storageID == nil, let id = UInt32(info.dropFirst(8)) {
                storageID = id
                if let usbSerial, !usbSerial.isEmpty { identify?(usbSerial, id) }
                return
            }
            if info == "child" {
                try completeChild()
                publish()
                return
            }
            if info == "skip" {
                partial = true
                return
            }
            guard let status = Int(info) else { throw ADB.error(L10n.text("adb.list.invalid")) }
            partial = partial || status != 0
            finished = true
            return
        }

        guard let relative = String(data: path, encoding: .utf8) else {
            partial = true
            return
        }
        let components = relative.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false)
        guard relative.hasPrefix("./"), let first = components.first, let name = components.last,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ADB.error(L10n.text("adb.list.invalid"))
        }

        let values = info.split(separator: " ")
        let directory: Bool
        let size: Int64
        switch values.first {
        case "d" where values.count == 1:
            directory = true
            size = 0
        case "f" where values.count == 2:
            guard let bytes = Int64(values[1]), bytes >= 0 else {
                throw ADB.error(L10n.text("adb.list.invalid"))
            }
            directory = false
            size = bytes
        case "m" where values.count == 3:
            guard let mode = Int(values[1], radix: 16), let bytes = Int64(values[2]), bytes >= 0 else {
                throw ADB.error(L10n.text("adb.list.invalid"))
            }
            let kind = mode & 0xf000
            guard kind == 0x4000 || kind == 0x8000 else {
                partial = true
                return
            }
            directory = kind == 0x4000
            size = directory ? 0 : bytes
        default:
            throw ADB.error(L10n.text("adb.list.invalid"))
        }

        let prefix = scope == "/" ? "/" : scope + "/"
        let top = prefix + first
        if currentPath != top {
            try completeChild()
            currentPath = top
        }
        currentEntries.append(AndroidEntry(Name: String(name), FullPath: prefix + relative.dropFirst(2),
                                           IsDir: directory, Size: size, Handle: nil))
        if !directory {
            scannedFiles += 1
            currentFiles += 1
            currentBytes += Double(size)
            if components.count == 1 { try completeChild() }
        }
        publish()
    }

    private func completeChild() throws {
        guard let currentPath else { return }
        // A missing or unreadable directory can leave descendants without their
        // parent record. Keep the partial indicator and omit that orphan branch.
        if let top = currentEntries.first, top.FullPath == currentPath {
            if top.IsDir {
                rootChildren.append(try StorageNode.build(currentPath, entries: currentEntries.dropFirst(),
                                                          request: request))
            } else {
                rootChildren.append(StorageNode.file(top))
            }
        } else {
            partial = true
        }
        self.currentPath = nil
        currentBytes = 0
        currentFiles = 0
        currentEntries.removeAll(keepingCapacity: true)
    }

    private func publish() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard !currentEntries.isEmpty || !rootChildren.isEmpty,
              lastUpdate.map({ now - $0 >= 300_000_000 }) ?? true else { return }
        lastUpdate = now
        let liveFolder = currentEntries.first.flatMap { entry -> StorageNode? in
            guard entry.IsDir, entry.FullPath == currentPath else { return nil }
            return StorageNode(id: entry.FullPath, name: entry.Name, isFolder: true,
                               bytes: currentBytes, files: currentFiles, children: [], provisional: true)
        }
        let root = rootChildren.count > publishedChildren || liveFolder != nil ? snapshot(including: liveFolder) : nil
        publishedChildren = rootChildren.count
        progress(root, scannedFiles)
    }

    private func snapshot(including liveFolder: StorageNode? = nil) -> StorageNode {
        let name = scope == "/" ? L10n.text("tree.storage") : (scope as NSString).lastPathComponent
        let children = liveFolder.map { rootChildren + [$0] } ?? rootChildren
        return StorageNode.directory(scope, name: name, children: children)
    }
}
