import AppKit

final class TransferWindow: NSObject {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 168),
                                styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let file = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let position = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let destination = NSTextField(labelWithString: "")
    private var current: UUID?
    private var total = 0
    private var finished = 0
    private var failures = 0
    private var lastError: String?
    private var sampleTimer: Timer?
    private var dismissWork: DispatchWorkItem?

    var isTransferring: Bool { finished < total }

    override init() {
        super.init()
        panel.title = L10n.text("transfer.window")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        icon.symbolConfiguration = .init(pointSize: 28, weight: .medium)
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        file.font = .systemFont(ofSize: 13, weight: .medium)
        for label in [detail, destination, position] {
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        for label in [title, file, detail, destination] {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        progress.style = .bar
        progress.controlSize = .small
        progress.maxValue = 1
        let close = NSButton(title: L10n.text("action.close"), target: self, action: #selector(closePanel))
        let spacer = NSView()
        position.alignment = .right
        let header = NSStackView(views: [icon, title, NSView(), position])
        header.distribution = .fill
        header.alignment = .centerY
        header.spacing = 9
        let footer = NSStackView(views: [destination, spacer, close])
        footer.distribution = .fill
        footer.alignment = .centerY
        let stack = NSStackView(views: [header, file, progress, detail, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        panel.contentView = content
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            file.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    func enqueue(_ id: UUID, entry: AndroidEntry, to url: URL) {
        if !isTransferring {
            dismissWork?.cancel()
            total = 0
            finished = 0
            failures = 0
            lastError = nil
            if !panel.isVisible { panel.center() }
            panel.orderFrontRegardless()
        }
        total += 1
        if current == nil { show(id, entry: entry, to: url) }
        updatePosition()
    }

    func started(_ id: UUID, entry: AndroidEntry, to url: URL, staging: URL) {
        show(id, entry: entry, to: url)
        guard !entry.IsDir, entry.Size > 0 else {
            detail.stringValue = L10n.text("transfer.copying.contents")
            return
        }
        progress.stopAnimation(nil)
        progress.isIndeterminate = false
        progress.doubleValue = 0
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, self.current == id else { return }
            let attributes = try? FileManager.default.attributesOfItem(atPath: staging.path)
            let written = min((attributes?[.size] as? NSNumber)?.int64Value ?? 0, entry.Size)
            let fraction = min(Double(written) / Double(entry.Size), 0.99)
            guard fraction > self.progress.doubleValue else { return }
            self.progress.doubleValue = fraction
            let bytes = ByteCountFormatter.string(fromByteCount: written, countStyle: .file)
            let size = ByteCountFormatter.string(fromByteCount: entry.Size, countStyle: .file)
            self.detail.stringValue = L10n.format("transfer.bytes", bytes, size)
        }
    }

    private func show(_ id: UUID, entry: AndroidEntry, to url: URL) {
        sampleTimer?.invalidate()
        sampleTimer = nil
        current = id
        setHeading("transfer.copying", symbol: "arrow.down.circle.fill", tint: .controlAccentColor)
        file.stringValue = entry.Name
        file.toolTip = entry.Name
        let folder = url.deletingLastPathComponent()
        destination.stringValue = L10n.format("transfer.destination", folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent)
        destination.toolTip = folder.path
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        detail.stringValue = L10n.text("transfer.preparing")
        detail.toolTip = nil
    }

    func completed(_ id: UUID, error: Error?) {
        finished += 1
        updatePosition()
        if let error {
            failures += 1
            lastError = error.localizedDescription
        }
        if current == id {
            current = nil
            sampleTimer?.invalidate()
            sampleTimer = nil
            if isTransferring { detail.stringValue = L10n.text("transfer.preparing") }
        }
        guard !isTransferring else { return }
        progress.stopAnimation(nil)
        progress.isIndeterminate = false
        progress.doubleValue = Double(total - failures) / Double(total)
        if let lastError {
            setHeading("transfer.failed", symbol: "exclamationmark.triangle.fill", tint: .systemOrange)
            detail.stringValue = lastError
            detail.toolTip = lastError
            return
        }
        setHeading("transfer.complete", symbol: "checkmark.circle.fill", tint: .systemGreen)
        detail.stringValue = L10n.format("transfer.copied", finished)
        let work = DispatchWorkItem { [weak self] in self?.closePanel() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func updatePosition() {
        position.stringValue = total > 1 && isTransferring ? L10n.format("transfer.position", finished + 1, total) : ""
    }

    private func setHeading(_ key: String, symbol: String, tint: NSColor) {
        title.stringValue = L10n.text(key)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
    }

    @objc private func closePanel() { panel.orderOut(nil) }
}
