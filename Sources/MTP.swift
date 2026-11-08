import Foundation

struct AndroidEntry: Decodable {
    let Name: String
    let FullPath: String
    let IsDir: Bool
    let Size: Int64
    let Created: Date?
    let Modified: Date?
}

final class SearchRequest {
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
    private let queue = DispatchQueue(label: "Android Finder USB")

    func perform<T>(_ operation: @escaping () throws -> T, completion: @escaping (Result<T, Error>) -> Void) {
        submissions.lock()
        defer { submissions.unlock() }
        guard !closing else {
            DispatchQueue.main.async { completion(.failure(CocoaError(.userCancelled))) }
            return
        }
        queue.async {
            let result = Result(catching: operation)
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

    func command(_ arguments: [String], search: SearchRequest? = nil) throws -> Data {
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
        process.standardOutput = output
        process.standardError = errors
        if let search { try search.launch(process) } else { try process.run() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: errorFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "Android Finder", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: message.flatMap { $0.isEmpty ? nil : $0 } ?? "L’opération USB a échoué."
            ])
        }
        return data
    }

    func list(_ path: String) throws -> [AndroidEntry] {
        try entries(from: command(["list", path]))
    }

    func search(_ path: String, query: String, request: SearchRequest) throws -> [AndroidEntry] {
        try entries(from: command(["search", path, query], search: request))
    }

    private func entries(from data: Data) throws -> [AndroidEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode([AndroidEntry].self, from: data)
    }

    func download(_ entry: AndroidEntry, to destination: URL) throws {
        let files = FileManager.default
        let stage = destination.deletingLastPathComponent()
            .appendingPathComponent(".android-finder-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: stage) }
        _ = try command(["download", entry.FullPath, stage.path])
        let downloaded = stage.appendingPathComponent(entry.Name, isDirectory: entry.IsDir)
        try files.moveItem(at: downloaded, to: destination)
    }
}
