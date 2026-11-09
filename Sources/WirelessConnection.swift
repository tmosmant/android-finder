import AppKit

final class WirelessConnection: NSObject {
    private let adb = ADB.locate()
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 570, height: 478),
                                styleMask: [.titled], backing: .buffered, defer: false)
    private let devices = NSPopUpButton()
    private let address = NSTextField()
    private let pairingAddress = NSTextField()
    private let code = NSSecureTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private var statusMessage = "" {
        didSet {
            status.stringValue = statusMessage
            status.toolTip = statusMessage
        }
    }
    private var detected: [WirelessDevice] = [] {
        didSet { openDeviceButton?.isEnabled = !detected.isEmpty }
    }
    private weak var openDeviceButton: NSButton?
    private var controls: [NSControl] = []
    private var working = false
    private let onConnect: (WirelessStorage?) -> Void

    init(onConnect: @escaping (WirelessStorage?) -> Void) {
        self.onConnect = onConnect
        super.init()
        panel.title = L10n.text("wifi.title")
        devices.addItem(withTitle: L10n.text("wifi.none"))
        address.placeholderString = L10n.text("wifi.address.placeholder")
        pairingAddress.placeholderString = L10n.text("wifi.pair.address")
        code.placeholderString = L10n.text("wifi.pair.code")
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.maximumNumberOfLines = 3
        status.lineBreakMode = .byWordWrapping
        status.setContentCompressionResistancePriority(.required, for: .vertical)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        let scan = button(L10n.text("action.scan"), #selector(refresh))
        let open = button(L10n.text("action.open"), #selector(openDevice))
        let connect = button(L10n.text("action.connect"), #selector(connectManually))
        let pair = button(L10n.text("action.pair"), #selector(pairDevice))
        let usb = button(L10n.text("action.useUSB"), #selector(useUSB))
        let close = button(L10n.text("action.close"), #selector(closeSheet))
        close.keyEquivalent = "\u{1b}"
        open.bezelColor = .controlAccentColor
        open.isEnabled = false
        openDeviceButton = open
        controls = [devices, address, pairingAddress, code, scan, open, connect, pair]
        [devices, address, pairingAddress, status].forEach {
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        code.widthAnchor.constraint(equalToConstant: 142).isActive = true
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let hero = NSImageView(image: NSImage(systemSymbolName: "wifi", accessibilityDescription: nil) ?? NSImage())
        hero.symbolConfiguration = .init(pointSize: 30, weight: .semibold)
        hero.contentTintColor = .controlAccentColor
        hero.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let title = NSTextField(labelWithString: L10n.text("wifi.title"))
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let intro = detail("wifi.instructions", width: 466)
        let heroText = vertical([title, intro], spacing: 4)
        let header = horizontal([hero, heroText])
        let devicesCard = card(L10n.text("wifi.devices"), rows: [
            horizontal([devices, scan, open]), horizontal([address, connect])
        ])
        let pairingCard = card(L10n.text("wifi.pair.title"), rows: [
            detail("wifi.pair.instructions", width: 488), horizontal([pairingAddress, code, pair])
        ])
        let divider = NSBox()
        divider.boxType = .separator
        let statusRow = horizontal([progress, status])
        status.preferredMaxLayoutWidth = 500
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = horizontal([usb, spacer, close])
        let stack = vertical([header, devicesCard, pairingCard, divider, statusRow, footer], spacing: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        panel.contentView = content
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18)
        ])
        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        intro.widthAnchor.constraint(equalTo: heroText.widthAnchor).isActive = true
    }

    private func detail(_ key: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: L10n.text(key))
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = width
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    private func horizontal(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = spacing
        return stack
    }

    private func card(_ title: String, rows: [NSView]) -> NSView {
        let surface = NSView()
        let background = NSBox()
        background.boxType = .custom
        background.borderColor = .separatorColor
        background.fillColor = .controlBackgroundColor
        background.cornerRadius = 10
        background.borderWidth = 1
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let body = vertical([heading] + rows, spacing: 9)
        background.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(background)
        surface.addSubview(body)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            background.topAnchor.constraint(equalTo: surface.topAnchor),
            background.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 14),
            body.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -14),
            body.topAnchor.constraint(equalTo: surface.topAnchor, constant: 12),
            body.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -12)
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        return surface
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    func show(on window: NSWindow, completion: @escaping () -> Void) {
        window.beginSheet(panel) { _ in completion() }
        refresh()
    }

    private func perform<T>(_ message: String, _ operation: @escaping (ADB) throws -> T,
                            completion: @escaping (T) -> Void) {
        guard !working else { return }
        guard let adb else {
            controls.forEach { $0.isEnabled = false }
            statusMessage = L10n.text("adb.missing")
            return
        }
        working = true
        progress.startAnimation(nil)
        controls.forEach { $0.isEnabled = false }
        statusMessage = message
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try operation(adb) }
            DispatchQueue.main.async {
                self.working = false
                self.progress.stopAnimation(nil)
                guard self.panel.sheetParent != nil else { return }
                self.controls.forEach { $0.isEnabled = true }
                self.openDeviceButton?.isEnabled = !self.detected.isEmpty
                switch result {
                case .success(let value): completion(value)
                case .failure(let error): self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    @objc private func refresh() { scan() }

    private func scan(afterPairing: Bool = false) {
        perform(L10n.text("wifi.scanning"), { try $0.devices() }) { found in
            let previous = self.detected.indices.contains(self.devices.indexOfSelectedItem)
                ? self.detected[self.devices.indexOfSelectedItem].target : nil
            self.detected = found
            self.devices.removeAllItems()
            if found.isEmpty {
                self.devices.addItem(withTitle: L10n.text("wifi.none"))
            } else {
                self.devices.addItems(withTitles: found.map { $0.connected ? L10n.format("wifi.device.connected", $0.label) : $0.label })
                self.devices.selectItem(at: found.firstIndex { $0.target == previous } ?? 0)
            }
            if afterPairing {
                self.statusMessage = L10n.text("wifi.paired")
            } else {
                self.statusMessage = found.isEmpty
                    ? L10n.text("wifi.none.hint")
                    : L10n.format("wifi.count", found.count)
            }
        }
    }

    private func endpoint(from field: NSTextField) -> String? {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^(?:[A-Za-z0-9][A-Za-z0-9.\-]*|\[[0-9A-Fa-f:]+\]):[0-9]{1,5}$"#,
                          options: .regularExpression) != nil,
              let port = value.split(separator: ":").last.flatMap({ UInt16($0) }), port > 0 else {
            statusMessage = L10n.text("wifi.address.invalid")
            return nil
        }
        return value
    }

    @objc private func pairDevice() {
        guard let target = endpoint(from: pairingAddress) else { return }
        let digits = code.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard digits.utf8.count == 6, digits.utf8.allSatisfy({ (48...57).contains($0) }) else {
            statusMessage = L10n.text("wifi.code.invalid")
            return
        }
        code.stringValue = ""
        perform(L10n.text("wifi.pairing"), { try $0.pair(target, code: digits) }) { _ in
            self.scan(afterPairing: true)
        }
    }

    @objc private func openDevice() {
        let index = devices.indexOfSelectedItem
        guard detected.indices.contains(index) else { return }
        connect(detected[index])
    }

    @objc private func connectManually() {
        guard let target = endpoint(from: address) else { return }
        connect(WirelessDevice(target: target, label: target, connected: false))
    }

    private func connect(_ device: WirelessDevice) {
        perform(L10n.text("wifi.connecting"), { try $0.connect(device) }) { storage in
            self.closeSheet()
            self.onConnect(storage)
        }
    }

    @objc private func useUSB() {
        closeSheet()
        onConnect(nil)
    }

    @objc private func closeSheet() {
        panel.sheetParent?.endSheet(panel)
    }
}
