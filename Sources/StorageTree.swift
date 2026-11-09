import Foundation

struct StorageNode: Identifiable, Codable {
    let id: String
    let name: String
    let isFolder: Bool
    let bytes: Double
    let files: Int
    let children: [StorageNode]
    var provisional = false

    static func directory(_ path: String, name: String, children: [StorageNode]) -> StorageNode {
        let sorted = children.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return StorageNode(id: path, name: name, isFolder: true,
                           bytes: sorted.reduce(0) { $0 + $1.bytes },
                           files: sorted.reduce(0) { $0 + $1.files }, children: sorted)
    }

    func removing(_ paths: [String]) -> StorageNode {
        let targets = Set(paths)
        var ancestors: Set<String> = []
        for path in targets {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty, ancestors.insert(parent).inserted, parent != "/" {
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        func update(_ node: StorageNode) -> StorageNode {
            guard ancestors.contains(node.id) else { return node }
            let children = node.children.compactMap { child in
                targets.contains(child.id) ? nil : update(child)
            }
            return Self.directory(node.id, name: node.name, children: children)
        }
        return update(self)
    }

    static func file(_ entry: AndroidEntry) -> StorageNode {
        StorageNode(id: entry.FullPath, name: entry.Name, isFolder: false,
                    bytes: Double(entry.Size), files: 1, children: [])
    }

    static func build(_ path: String, entries: ArraySlice<AndroidEntry>, request: OperationRequest) throws -> StorageNode {
        var folders: [String: [AndroidEntry]] = [:]
        for entry in entries {
            try request.checkCancellation()
            folders[(entry.FullPath as NSString).deletingLastPathComponent, default: []].append(entry)
        }

        func folder(_ path: String, name: String) throws -> StorageNode {
            try request.checkCancellation()
            let children = try (folders.removeValue(forKey: path) ?? []).map { entry in
                if entry.IsDir { return try folder(entry.FullPath, name: entry.Name) }
                return file(entry)
            }
            return directory(path, name: name, children: children)
        }

        let name = path == "/" ? L10n.text("tree.storage") : (path as NSString).lastPathComponent
        return try folder(path, name: name)
    }
}
