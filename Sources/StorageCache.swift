import CryptoKit
import Foundation

struct StorageCache {
    struct Key {
        let device: String
        let volume: String
        let scope: String
    }

    struct Snapshot: Codable {
        let root: StorageNode
        let partial: Bool
        let date: Date
    }

    var directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("com.tmosmant.android-finder/TreeFinder-v1", isDirectory: true)

    func load(_ key: Key) -> Snapshot? {
        guard let file = file(for: key), let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.root.id == key.scope else { return nil }
        return snapshot
    }

    func save(_ snapshot: Snapshot, for key: Key) {
        guard let file = file(for: key) else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        } catch {
            // The cache is optional. A successful device read still succeeds.
        }
    }

    func invalidate(device: String) {
        if let folder = deviceDirectory(device) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func file(for key: Key) -> URL? {
        deviceDirectory(key.device)?.appendingPathComponent(digest(key.volume + "\0" + key.scope))
    }

    private func deviceDirectory(_ device: String) -> URL? {
        directory?.appendingPathComponent(digest(device), isDirectory: true)
    }

    private func digest(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
