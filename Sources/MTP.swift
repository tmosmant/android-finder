import Foundation

struct AndroidEntry: Decodable {
    let Name: String
    let FullPath: String
    let IsDir: Bool
    let Size: Int64
    let Handle: UInt32?
}

final class OperationRequest {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    func launch(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CocoaError(.userCancelled) }
        try process.run()
        self.process = process
    }

    func checkCancellation() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CocoaError(.userCancelled) }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}

final class MTP {
    private let submissions = NSLock()
    private var closing = false
    private let queue = DispatchQueue(label: "Android Finder Transferts")

    func perform<T>(session: OperationRequest, _ operation: @escaping () throws -> T, completion: @escaping (Result<T, Error>) -> Void) {
        submissions.lock()
        defer { submissions.unlock() }
        guard !closing else {
            DispatchQueue.main.async { completion(.failure(CocoaError(.userCancelled))) }
            return
        }
        queue.async {
            let result = Result {
                try session.checkCancellation()
                return try operation()
            }
            RunLoop.main.perform(inModes: [.default, .modalPanel]) { completion(result) }
        }
    }

    func finish(_ completion: @escaping () -> Void) {
        submissions.lock()
        defer { submissions.unlock() }
        closing = true
        queue.async {
            RunLoop.main.perform(inModes: [.default, .modalPanel], block: completion)
        }
    }

    func command(_ arguments: [String], request: OperationRequest? = nil, timeout: TimeInterval? = nil,
                 consume: ((FileHandle) -> Void)? = nil) throws -> Data {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/android-mtp")
        let process = Process()
        let output = Pipe()
        let errorFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: errorFile.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: errorFile) }
        let errors = try FileHandle(forWritingTo: errorFile)
        defer { try? errors.close() }
        process.executableURL = helper
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["ANDROID_FINDER_LANGUAGE"] = L10n.language
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        if let request { try request.launch(process) } else { try process.run() }
        let deadline = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline) }
        defer { deadline.cancel() }
        let data: Data
        if let consume {
            consume(output.fileHandleForReading)
            data = Data()
        } else {
            data = output.fileHandleForReading.readDataToEndOfFile()
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: errorFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "Android Finder", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: message.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("usb.failed")
            ])
        }
        return data
    }

    func list(_ path: String) throws -> [AndroidEntry] {
        try entries(from: command(["list", path]))
    }

    func search(_ path: String, query: String, request: OperationRequest) throws -> [AndroidEntry] {
        try entries(from: command(["search", path, query], request: request))
    }

    func usbSerial(request: OperationRequest) throws -> String {
        let data = try command(["usb-identity", "/"], request: request, timeout: 2)
        return try JSONDecoder().decode(String.self, from: data)
    }

    func inventory(_ path: String, request: OperationRequest, consume: @escaping (FileHandle) -> Void) throws {
        _ = try command(["inventory", path], request: request, consume: consume)
    }

    private func entries(from data: Data) throws -> [AndroidEntry] {
        try JSONDecoder().decode([AndroidEntry].self, from: data)
    }

    func download(_ entry: AndroidEntry, to destination: URL, wireless: WirelessStorage?, request: OperationRequest,
                  onStage: ((URL) -> Void)? = nil) throws {
        let files = FileManager.default
        let stage = destination.deletingLastPathComponent()
            .appendingPathComponent(".android-finder-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: stage) }
        let downloaded = stage.appendingPathComponent(entry.Name, isDirectory: entry.IsDir)
        onStage?(downloaded)
        if let wireless {
            try wireless.download(entry, to: stage, request: request)
        } else {
            _ = try command(["download", entry.FullPath, stage.path])
        }
        try files.moveItem(at: downloaded, to: destination)
    }
}
