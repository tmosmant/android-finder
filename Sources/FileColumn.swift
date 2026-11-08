import AppKit

enum FileColumn: String, CaseIterable {
    case name = "Nom"
    case kind = "Type"
    case size = "Taille"
    case modified = "Modifié"
    case created = "Créé"

    var width: CGFloat? {
        switch self {
        case .name: nil
        case .kind: 112
        case .size: 75
        case .modified, .created: 112
        }
    }

    func displayValue(for entry: AndroidEntry) -> String {
        switch self {
        case .name: entry.Name
        case .kind: Self.kind(for: entry)
        case .size: entry.IsDir ? "—" : ByteCountFormatter.string(fromByteCount: entry.Size, countStyle: .file)
        case .modified: entry.Modified?.formatted(date: .numeric, time: .shortened) ?? "—"
        case .created: entry.Created?.formatted(date: .numeric, time: .shortened) ?? "—"
        }
    }

    func compare(_ a: AndroidEntry, _ b: AndroidEntry, ascending: Bool) -> Bool {
        let order: ComparisonResult
        switch self {
        case .name: order = a.Name.localizedStandardCompare(b.Name)
        case .kind: order = Self.kind(for: a).localizedStandardCompare(Self.kind(for: b))
        case .size: order = Self.compareValues(a.Size, b.Size)
        case .modified: order = Self.compareValues(a.Modified ?? .distantPast, b.Modified ?? .distantPast)
        case .created: order = Self.compareValues(a.Created ?? .distantPast, b.Created ?? .distantPast)
        }

        if order == .orderedSame {
            return a.FullPath.localizedStandardCompare(b.FullPath) == .orderedAscending
        }
        return ascending ? order == .orderedAscending : order == .orderedDescending
    }

    private static func compareValues<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        if a == b { return .orderedSame }
        return a < b ? .orderedAscending : .orderedDescending
    }

    private static func kind(for entry: AndroidEntry) -> String {
        if entry.IsDir { return "Dossier" }
        return fileType(entry).localizedDescription ?? "Fichier"
    }
}
