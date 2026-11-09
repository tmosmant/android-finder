import SwiftUI

final class TreeFinderModel: ObservableObject {
    enum State {
        case scanning
        case deleting
        case ready(partial: Bool)
        case failed(String)
        case disconnected
    }

    @Published var state = State.scanning
    @Published var root: StorageNode? { didSet { rebuildRows() } }
    @Published var selection: Set<String> = []
    @Published var expanded: Set<String> = [] { didSet { rebuildRows() } }
    @Published var usesUSBADB = false
    @Published var scannedFiles = 0
    @Published var scope: String
    var source: StorageInventory.Source?
    var cacheKey: StorageCache.Key?
    var lastScanDate: Date?
    private var cachedPartial = false
    @Published private(set) var cacheDate: Date?
    private var cachedRoot: StorageNode?

    init(scope: String) { self.scope = scope }

    struct Row: Identifiable {
        let node: StorageNode
        let depth: Int
        let parentBytes: Double

        var id: String { node.id }
        var fraction: Double { parentBytes > 0 ? min(1, node.bytes / parentBytes) : 0 }
    }

    private(set) var rows: [Row] = []

    private func rebuildRows() {
        var visible: [Row] = []
        func append(_ parent: StorageNode, depth: Int) {
            for node in parent.children {
                visible.append(Row(node: node, depth: depth, parentBytes: parent.bytes))
                if expanded.contains(node.id) { append(node, depth: depth + 1) }
            }
        }
        if let root { append(root, depth: 0) }
        rows = visible
    }

    var canDelete: Bool {
        if case .ready = state { return source != nil }
        return false
    }

    func clearCachePreview() {
        cachedRoot = nil
        cacheDate = nil
    }

    func showCached(_ snapshot: StorageCache.Snapshot, usesUSBADB: Bool) {
        self.usesUSBADB = usesUSBADB
        cachedRoot = snapshot.root
        cacheDate = snapshot.date
        cachedPartial = snapshot.partial
        root = snapshot.root
    }

    var cacheAge: String? {
        guard let cacheDate else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: L10n.language)
        let age = formatter.localizedString(for: cacheDate, relativeTo: Date())
        return L10n.format(cachedPartial ? "tree.cache.age.partial" : "tree.cache.age", age)
    }

    func recordProgress(_ root: StorageNode?, files: Int, usesUSBADB: Bool) {
        if self.usesUSBADB != usesUSBADB {
            self.usesUSBADB = usesUSBADB
            selection = []
            clearCachePreview()
            self.root = nil
        }
        if let root {
            if let cachedRoot {
                let fresh = Set(root.children.lazy.filter { !$0.provisional }.map(\.id))
                let stale = cachedRoot.children.filter { !fresh.contains($0.id) }
                let staleIDs = Set(stale.map(\.id))
                let current = root.children.filter { !$0.provisional || !staleIDs.contains($0.id) }
                self.root = StorageNode.directory(root.id, name: root.name, children: current + stale)
            } else {
                self.root = root
            }
        }
        scannedFiles = files
    }

    func toggle(_ node: StorageNode) {
        guard node.isFolder, !node.provisional else { return }
        if expanded.remove(node.id) == nil { expanded.insert(node.id) }
    }
}

struct TreeFinderView: View {
    static let contentSize = CGSize(width: 980, height: 660)
    static let minimumSize = CGSize(width: 690, height: 440)

    @ObservedObject var model: TreeFinderModel
    let usb: Bool
    let scan: (String) -> Void
    let reveal: (StorageNode) -> Void
    let delete: (Set<String>) -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)
            Divider()
            Group {
                switch model.state {
                case .scanning:
                    if let folder = model.root {
                        dashboard(folder, scanning: true)
                    } else {
                        message("tree.scanning", detail: scanProgress ?? L10n.text("tree.scanning.hint"), symbol: nil)
                    }
                case .deleting:
                    if let root = model.root {
                        dashboard(root, warning: L10n.text("tree.deleting"))
                    }
                case .failed(let error):
                    interrupted("tree.failed", detail: [error, recoveryHint].joined(separator: "\n\n"))
                case .disconnected:
                    interrupted(usb ? "tree.usb.interrupted" : "tree.disconnected", detail: recoveryHint)
                case .ready(let partial):
                    if let folder = model.root {
                        dashboard(folder, warning: partial ? L10n.text("tree.partial") : nil)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(minWidth: Self.minimumSize.width, maxWidth: .infinity,
               minHeight: Self.minimumSize.height, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.linearGradient(colors: [.indigo, .blue], startPoint: .topLeading,
                                            endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("tree.title")).font(.title2.weight(.bold))
                Text(L10n.text("tree.subtitle")).foregroundStyle(.secondary)
            }
            Spacer()
            if canScan {
                if model.scope != "/" {
                    Button(L10n.text("tree.all")) { scan("/") }
                }
                Button { scan(model.scope) } label: {
                    Label(L10n.text("action.refresh"), systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .help(L10n.text("action.refresh"))
            }
        }
    }

    private var canScan: Bool {
        switch model.state {
        case .ready: return true
        case .scanning, .deleting, .failed, .disconnected: return false
        }
    }

    private var footer: some View {
        HStack {
            Text(model.usesUSBADB ? L10n.text("tree.usb.adb") : L10n.text("tree.scope") + "  " + model.scope)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.scope)
            Spacer()
            if let age = model.cacheAge {
                Text(age)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if needsRetry {
                Button(L10n.text("tree.retry")) { scan(model.scope) }
                    .buttonStyle(.borderedProminent)
            }
            if case .scanning = model.state {
                Button(L10n.text("tree.cancel"), action: close)
                    .keyboardShortcut(.cancelAction)
            } else {
                Button(L10n.text("tree.close"), action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var needsRetry: Bool {
        switch model.state {
        case .failed, .disconnected: return true
        case .scanning, .deleting, .ready: return false
        }
    }

    private var canReveal: Bool {
        if case .ready = model.state { return !model.usesUSBADB }
        return false
    }

    private var scanProgress: String? {
        guard model.scannedFiles > 0 else { return nil }
        return L10n.format("tree.files", model.scannedFiles)
    }

    private var recoveryHint: String {
        L10n.text(usb ? "tree.usb.recovery" : "tree.disconnected.hint")
    }

    private func interrupted(_ title: String, detail: String) -> some View {
        Group {
            if let folder = model.root {
                dashboard(folder, warning: L10n.text("tree.interrupted.partial") + " " + recoveryHint)
            } else {
                message(title, detail: detail, symbol: "exclamationmark.circle")
            }
        }
    }

    private func message(_ title: String, detail: String, symbol: String?) -> some View {
        VStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 27)).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.large).accessibilityHidden(true)
            }
            Text(L10n.text(title)).font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .frame(maxWidth: 500)
        .padding(20)
    }

    private func dashboard(_ folder: StorageNode, warning: String? = nil, scanning: Bool = false) -> some View {
        let rows = model.rows
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "internaldrive").foregroundStyle(.secondary)
                Text(folder.name).font(.headline).lineLimit(1)
                Spacer()
                if !scanning {
                    Text(L10n.format("tree.files", folder.files)).font(.caption).foregroundStyle(.secondary)
                }
                Text(Self.size(folder.bytes)).font(.title3.weight(.bold).monospacedDigit())
            }
            if scanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text(model.cacheDate == nil ? "tree.progress" : "tree.cache.refresh")).font(.caption)
                    Spacer()
                    if let scanProgress {
                        Text(scanProgress).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            } else if let warning {
                Label(warning, systemImage: "info.circle")
                    .font(.caption)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Text(L10n.text("tree.name")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(L10n.text("tree.share")).frame(width: 130, alignment: .leading)
                        .help(L10n.text("tree.share.help"))
                    Text(L10n.text("tree.size")).frame(width: 94, alignment: .trailing)
                    Text(L10n.text("tree.file.column")).frame(width: 72, alignment: .trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider()
                if rows.isEmpty {
                    Text(L10n.text("tree.empty"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $model.selection) {
                        ForEach(rows) { row in
                            outlineRow(row, scanning: scanning)
                                .tag(row.id)
                                .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                        }
                    }
                    .listStyle(.plain)
                    .contextMenu(forSelectionType: String.self) { ids in
                        if ids.count == 1, canReveal,
                           let item = rows.first(where: { ids.contains($0.id) })?.node {
                            Button(L10n.text("tree.reveal")) { reveal(item) }
                        }
                        if model.canDelete, !ids.isEmpty {
                            Button(role: .destructive) { delete(ids) } label: {
                                Label(L10n.text("action.delete"), systemImage: "trash")
                            }
                        }
                    } primaryAction: { ids in
                        guard ids.count == 1, let node = rows.first(where: { ids.contains($0.id) })?.node else { return }
                        if node.isFolder { model.toggle(node) } else if canReveal { reveal(node) }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.09)))
        }
        .padding(20)
    }

    private func outlineRow(_ row: TreeFinderModel.Row, scanning: Bool) -> some View {
        let node = row.node
        let expanded = model.expanded.contains(node.id)
        return HStack(spacing: 14) {
            HStack(spacing: 7) {
                if node.isFolder, !node.children.isEmpty {
                    Button { model.toggle(node) } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 14, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.text(expanded ? "tree.collapse" : "tree.expand"))
                } else {
                    Color.clear.frame(width: 14, height: 1)
                }
                Image(systemName: node.isFolder ? "folder.fill" : "doc")
                    .foregroundStyle(node.isFolder ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                Text(node.name).fontWeight(node.isFolder ? .medium : .regular).lineLimit(1)
                if node.provisional {
                    Text(L10n.text(scanning ? "tree.live" : "tree.provisional"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.10), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(min(row.depth, 12)) * 15)

            HStack(spacing: 7) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(Color.accentColor.opacity(node.provisional ? 0.45 : 0.8))
                            .frame(width: geometry.size.width * row.fraction)
                    }
                }
                .frame(height: 5)
                .accessibilityHidden(true)
                Text(row.fraction, format: .percent.precision(.fractionLength(0)))
                    .frame(width: 42, alignment: .trailing)
            }
            .font(.caption.monospacedDigit()).frame(width: 130)
            Text(Self.size(node.bytes)).frame(width: 94, alignment: .trailing)
            Text(node.files, format: .number).frame(width: 72, alignment: .trailing)
        }
        .font(.system(size: 12).monospacedDigit())
        .frame(minHeight: 29)
        .contentShape(Rectangle())
        .help(node.id)
    }

    private static func size(_ bytes: Double) -> String {
        let count = bytes >= Double(Int64.max) ? Int64.max : Int64(bytes)
        return ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

}
