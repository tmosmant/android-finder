import Foundation

struct WirelessDevice {
    let target: String
    let label: String
    let connected: Bool
}

struct ADB {
    let executable: URL

    static func locate() -> ADB? {
        let environment = ProcessInfo.processInfo.environment
        let sdkPaths = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"]].compactMap { $0 }
        let paths = sdkPaths.map { $0 + "/platform-tools" }
            + [NSHomeDirectory() + "/Library/Android/sdk/platform-tools", "/opt/homebrew/bin", "/usr/local/bin"]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return paths.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent("adb") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }.map(ADB.init(executable:))
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "Android Finder ADB", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func run(_ arguments: [String], timeout: TimeInterval? = 10, request: OperationRequest? = nil,
             input: String? = nil, consume: ((FileHandle) -> Void)? = nil) throws -> Data {
        let process = Process()
        let output = Pipe()
        // The ADB server can outlive its client. Keep stderr away from the output pipe.
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: log) }
        let errors = try FileHandle(forWritingTo: log)
        defer { try? errors.close() }
        let stdin = input.map { _ in Pipe() }
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = stdin ?? FileHandle.nullDevice as Any
        if let request { try request.launch(process) } else { try process.run() }
        let deadline = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline) }
        defer { deadline.cancel() }
        if let input, let stdin {
            try stdin.fileHandleForWriting.write(contentsOf: Data((input + "\n").utf8))
            try stdin.fileHandleForWriting.close()
        }
        let data: Data
        if let consume {
            consume(output.fileHandleForReading)
            data = Data()
        } else {
            data = output.fileHandleForReading.readDataToEndOfFile()
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            if process.terminationReason == .uncaughtSignal {
                throw Self.error(L10n.text("adb.interrupted"))
            }
            let message = (try? String(contentsOf: log, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Self.error(message.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("adb.failed"))
        }
        return data
    }

    func devices() throws -> [WirelessDevice] {
        let connected = String(decoding: try run(["devices", "-l"]), as: UTF8.self)
            .split(separator: "\n").compactMap { line -> WirelessDevice? in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 2, fields[1] == "device", !fields[0].hasPrefix("emulator-"),
                      fields[0].contains(":") || fields[0].hasSuffix("._adb-tls-connect._tcp") else { return nil }
                let serial = String(fields[0])
                let model = fields.first { $0.hasPrefix("model:") }?.dropFirst(6)
                    .replacingOccurrences(of: "_", with: " ")
                return WirelessDevice(target: serial, label: model.map { "\($0) · \(serial)" } ?? serial, connected: true)
            }
        let discovered = (try? run(["mdns", "services"])) ?? Data()
        var seen = Set(connected.map(\.target))
        for device in connected where device.target.hasSuffix("._adb-tls-connect._tcp") {
            seen.insert(String(device.target.dropLast("._adb-tls-connect._tcp".count)))
        }
        return connected + String(decoding: discovered, as: UTF8.self)
            .split(separator: "\n").compactMap { line in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count == 3, fields[1] == "_adb-tls-connect._tcp",
                      seen.insert(String(fields[0])).inserted,
                      seen.insert(String(fields[2])).inserted else { return nil }
                return WirelessDevice(target: String(fields[2]), label: String(fields[2]), connected: false)
            }
    }

    func usbStorage(serial: String, request: OperationRequest) throws -> WirelessStorage? {
        let devices = String(decoding: try run(["devices", "-l"], timeout: 5, request: request), as: UTF8.self)
        let matches = devices.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 4, fields[0] == serial, fields[1] == "device",
                  fields.dropFirst(2).contains(where: { $0.hasPrefix("usb:") }),
                  let field = fields.dropFirst(2).first(where: { $0.hasPrefix("transport_id:") }),
                  let id = UInt64(field.dropFirst("transport_id:".count)) else { return nil }
            return String(id)
        }
        guard matches.count == 1, let id = matches.first else { return nil }
        return WirelessStorage(adb: self, target: serial, transportID: id)
    }

    func pair(_ address: String, code: String) throws {
        let result = String(decoding: try run(["pair", address], timeout: 20, input: code), as: UTF8.self)
        guard result.contains("Successfully paired") else {
            throw Self.error(L10n.text("adb.pair.failed"))
        }
    }

    func connect(_ device: WirelessDevice) throws -> WirelessStorage {
        let storage = WirelessStorage(adb: self, target: device.target)
        if !device.connected { _ = try run(["connect", device.target]) }
        guard storage.isReachable() else {
            throw Self.error(L10n.text("adb.connect.failed"))
        }
        return storage
    }
}

struct WirelessStorage {
    let adb: ADB
    let target: String
    var transportID: String? = nil

    private func run(_ arguments: [String], timeout: TimeInterval? = 10, request: OperationRequest? = nil,
                     consume: ((FileHandle) -> Void)? = nil) throws -> Data {
        let selector = transportID.map { ["-t", $0] } ?? ["-s", target]
        return try adb.run(selector + arguments, timeout: timeout, request: request, consume: consume)
    }

    func isReachable() -> Bool {
        (try? run(["shell", "true"], timeout: 4)) != nil
    }

    func deviceSerial(request: OperationRequest) throws -> String {
        if transportID != nil { return target }
        let result = try run(["shell", "-T", "getprop ro.serialno"], timeout: 4, request: request)
        return String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func remote(_ path: String) -> String { "/sdcard" + path }
    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func entries(_ path: String, query: String? = nil, request: OperationRequest? = nil) throws -> [AndroidEntry] {
        let query = query?.lowercased()
        let depth = query == nil ? "-maxdepth 1" : ""
        let types = query == nil ? #"\( -type d -o -type f \)"# : "-type f"
        let metadata = """
        for file do
            info=$(stat -c '%f %s' "$file") || exit 1
            printf '%s\\0%s\\0' "$file" "$info"
        done
        """
        let script = "cd \(quote(remote(path))) && find . -mindepth 1 \(depth) \(types) -exec sh -c \(quote(metadata)) sh {} +"
        let output = try run(["shell", "-T", script], timeout: query == nil ? 30 : nil, request: request)
        let fields = output.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count % 2 == 1, fields.last?.isEmpty == true else {
            throw ADB.error(L10n.text("adb.list.incomplete"))
        }
        return try stride(from: 0, to: fields.count - 1, by: 2).compactMap { index in
            guard let relative = String(data: fields[index], encoding: .utf8), relative.hasPrefix("./") else {
                return nil
            }
            let suffix = relative.dropFirst(2)
            guard let name = suffix.split(separator: "/").last.map(String.init),
                  query.map({ name.lowercased().contains($0) }) ?? true else { return nil }
            let values = String(decoding: fields[index + 1], as: UTF8.self).split(separator: " ")
            guard values.count == 2, let mode = Int(values[0], radix: 16),
                  let size = Int64(values[1]) else {
                throw ADB.error(L10n.text("adb.list.invalid"))
            }
            let isDirectory = mode & 0xf000 == 0x4000
            let fullPath = (path == "/" ? "" : path) + "/" + suffix
            return AndroidEntry(Name: name, FullPath: fullPath, IsDir: isDirectory, Size: isDirectory ? 0 : size, Handle: nil)
        }
    }

    func inventory(_ path: String, request: OperationRequest, consume: @escaping (FileHandle) -> Void) throws {
        // Older Toybox versions lack -printf. Batch numeric sizes in that case
        // and pair them with the original arguments, which may contain newlines.
        let metadata = #"""
        if sizes=$(stat -c '%f %s' "$@"); then
            for file do
                IFS= read -r size || exit 1
                printf '%s\0m %s\0' "$file" "$size"
            done <<EOF
        $sizes
        EOF
        else
            for file do
                if size=$(stat -c '%f %s' "$file"); then
                    printf '%s\0m %s\0' "$file" "$size"
                else
                    printf '!\0skip\0'
                fi
            done
        fi
        """#
        let script = #"""
        cd \#(quote(remote(path))) || exit 1
        if [ -n "$(find . -maxdepth 0 -printf '%s' 2>/dev/null)" ]; then
            find . -mindepth 1 \( -type d -printf '%p\0d\0' -o -type f -printf '%p\0f %s\0' \)
        else
            find . -mindepth 1 \( -type d -o -type f \) -exec sh -c \#(quote(metadata)) sh {} +
        fi
        printf '!\0%s\0' "$?"
        """#
        _ = try run(["shell", "-T", script], timeout: nil, request: request, consume: consume)
    }

    func thumbnail(_ entry: AndroidEntry, limit: Int, request: OperationRequest) throws -> Data {
        try run(["shell", "-T", "head -c \(limit + 1) -- \(quote(remote(entry.FullPath)))"],
                timeout: nil, request: request)
    }

    func command(_ arguments: [String], request: OperationRequest) throws {
        switch arguments[0] {
        case "delete":
            for path in arguments.dropFirst() {
                guard path != "/" else { throw ADB.error(L10n.text("adb.delete.root")) }
                _ = try run(["shell", "rm -r -- \(quote(remote(path)))"], timeout: nil, request: request)
            }
        case "upload":
            let folder = remote(arguments[1])
            for source in arguments.dropFirst(2) {
                let name = URL(fileURLWithPath: source).lastPathComponent
                let destination = quote(folder + "/" + name)
                let stage = folder + "/AndroidFinder-incomplet-" + UUID().uuidString
                let staged = quote(stage)
                _ = try run(["shell", "test ! -e \(destination) && test ! -L \(destination)"], timeout: 5, request: request)
                do {
                    _ = try run(["push", source, stage], timeout: nil, request: request)
                    _ = try run(["shell", "mv -nT -- \(staged) \(destination) && test ! -e \(staged)"], request: request)
                } catch {
                    if (try? run(["shell", "rm -rf -- \(staged)"], timeout: 5)) == nil {
                        throw ADB.error(L10n.format("adb.copy.cleanup", error.localizedDescription, URL(fileURLWithPath: stage).lastPathComponent))
                    }
                    throw error
                }
            }
        default:
            throw ADB.error(L10n.text("adb.unknown"))
        }
    }

    func download(_ entry: AndroidEntry, to stage: URL, request: OperationRequest) throws {
        let destination = stage.appendingPathComponent(entry.Name, isDirectory: entry.IsDir)
        _ = try run(["pull", "-a", remote(entry.FullPath), destination.path], timeout: nil, request: request)
    }
}
