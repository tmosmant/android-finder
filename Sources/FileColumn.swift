import AppKit

enum FileColumn: String, CaseIterable {
    case name
    case kind
    case size
    case folder

    var title: String { L10n.text("column." + rawValue) }

    var minimumWidth: CGFloat {
        switch self {
        case .name: 120
        case .kind: 78
        case .size: 62
        case .folder: 120
        }
    }

    func displayValue(for entry: AndroidEntry) -> String {
        switch self {
        case .name: entry.Name
        case .kind: Self.kind(for: entry)
        case .size: entry.IsDir ? "—" : ByteCountFormatter.string(fromByteCount: entry.Size, countStyle: .file)
        case .folder: Self.folder(for: entry)
        }
    }

    func compare(_ a: AndroidEntry, _ b: AndroidEntry, ascending: Bool) -> Bool {
        let order: ComparisonResult
        switch self {
        case .name: order = a.Name.localizedStandardCompare(b.Name)
        case .kind: order = Self.kind(for: a).localizedStandardCompare(Self.kind(for: b))
        case .size: order = Self.compareValues(a.Size, b.Size)
        case .folder: order = Self.folder(for: a).localizedStandardCompare(Self.folder(for: b))
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

    private static func folder(for entry: AndroidEntry) -> String {
        (entry.FullPath as NSString).deletingLastPathComponent
    }

    private static func kind(for entry: AndroidEntry) -> String {
        if entry.IsDir { return FileColumn.folder.title }
        return fileType(entry).localizedDescription ?? L10n.text("file.generic")
    }
}

final class ColumnDivider: NSView {
    var beginResize: (() -> Void)?
    var resize: ((CGFloat) -> Void)?
    private var startX: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        beginResize?()
    }

    override func mouseDragged(with event: NSEvent) {
        resize?(event.locationInWindow.x - startX)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.midX, y: 3, width: 1, height: max(0, bounds.height - 6)).fill()
    }
}

func layoutColumns(_ cells: [NSView], in row: NSView, widths: [CGFloat]) -> [NSLayoutConstraint] {
    var previous: NSView?
    var widthConstraints: [NSLayoutConstraint] = []
    for (cell, width) in zip(cells, widths) {
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addSubview(cell)
        let fixedWidth = cell.widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([
            cell.leadingAnchor.constraint(equalTo: previous?.trailingAnchor ?? row.leadingAnchor,
                                          constant: previous == nil ? 0 : 7),
            cell.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            fixedWidth
        ])
        widthConstraints.append(fixedWidth)
        previous = cell
    }
    previous?.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
    return widthConstraints
}
