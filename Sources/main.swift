import AppKit
import Quartz
import ServiceManagement
import UniformTypeIdentifiers

private final class EmptyStateView: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class BrowserView: NSCollectionView {
    var openSelection: (() -> Void)?
    var rangeSelectionChanged: (() -> Void)?
    var selectionAnchor: IndexPath?

    func selectRange(to target: IndexPath) {
        let anchor = selectionAnchor ?? selectionIndexPaths.sorted().first ?? target
        selectionAnchor = anchor
        let range = min(anchor.item, target.item)...max(anchor.item, target.item)
        selectionIndexPaths = Set(range.map { IndexPath(item: $0, section: target.section) })
        rangeSelectionChanged?()
    }

    override func mouseDown(with event: NSEvent) {
        let target = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if modifiers == .shift, let target {
            window?.makeFirstResponder(self)
            selectRange(to: target)
            return
        }
        selectionAnchor = target
        super.mouseDown(with: event)
        if event.clickCount == 2, target != nil {
            openSelection?()
        }
    }
}

final class FileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("file")
    private var columnConstraints: [NSLayoutConstraint] = []
    private var tileImage: NSImageView?
    private var imageDimensions: [NSLayoutConstraint] = []

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 5
    }

    func configure(_ entry: AndroidEntry, icons: Bool, columns: [FileColumn], widths: [CGFloat], thumbnail: NSImage?) {
        NSLayoutConstraint.deactivate(columnConstraints)
        columnConstraints = []
        view.subviews.forEach { $0.removeFromSuperview() }
        let image = NSImageView(image: NSWorkspace.shared.icon(for: fileType(entry)))
        image.imageScaling = .scaleProportionallyDown
        tileImage = nil
        imageDimensions = []
        let name = NSTextField(labelWithString: entry.Name)
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row: NSView
        if icons {
            let well = NSBox()
            well.boxType = .custom
            well.borderWidth = 0
            well.fillColor = .windowBackgroundColor
            well.cornerRadius = 8
            well.contentViewMargins = NSSize(width: 4, height: 4)
            let imageArea = NSView()
            well.contentView = imageArea
            image.translatesAutoresizingMaskIntoConstraints = false
            imageArea.addSubview(image)
            NSLayoutConstraint.activate([
                well.widthAnchor.constraint(equalToConstant: 112),
                well.heightAnchor.constraint(equalToConstant: 74),
                image.centerXAnchor.constraint(equalTo: imageArea.centerXAnchor),
                image.centerYAnchor.constraint(equalTo: imageArea.centerYAnchor)
            ])
            tileImage = image
            let stack = NSStackView(views: [well, name])
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = 7
            row = stack
        } else {
            let nameCell = NSStackView(views: [image, name])
            nameCell.spacing = 7
            nameCell.alignment = .centerY
            nameCell.distribution = .fill
            let metadata = columns.dropFirst().map { column in
                let cell = NSTextField(labelWithString: column.displayValue(for: entry))
                cell.lineBreakMode = .byTruncatingTail
                cell.toolTip = cell.stringValue
                return cell
            }
            let cells: [NSView] = [nameCell] + metadata
            row = NSView()
            columnConstraints = layoutColumns(cells, in: row, widths: widths)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        let imageWidth = image.widthAnchor.constraint(equalToConstant: icons ? 104 : 20)
        let imageHeight = image.heightAnchor.constraint(equalToConstant: icons ? 66 : 20)
        NSLayoutConstraint.activate([
            imageWidth, imageHeight,
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            row.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            name.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor)
        ])
        if icons {
            imageDimensions = [imageWidth, imageHeight]
            imageWidth.constant = 42
            imageHeight.constant = 42
            if let thumbnail { showThumbnail(thumbnail) }
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6).isActive = true
        } else {
            row.heightAnchor.constraint(equalTo: view.heightAnchor).isActive = true
        }
        name.alignment = icons ? .center : .left
        view.toolTip = entry.FullPath
        updateSelection()
    }

    func showThumbnail(_ thumbnail: NSImage) {
        tileImage?.image = thumbnail
        for (constraint, length) in zip(imageDimensions, [104.0, 66.0]) {
            constraint.constant = length
        }
    }

    func setColumnWidths(_ widths: [CGFloat]) {
        for (constraint, width) in zip(columnConstraints, widths) {
            constraint.constant = width
        }
    }

    override var isSelected: Bool { didSet { updateSelection() } }

    private func updateSelection() {
        view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor
            .withAlphaComponent(0.28).cgColor : nil
    }
}

func fileType(_ entry: AndroidEntry) -> UTType {
    if entry.IsDir { return .folder }
    return UTType(filenameExtension: (entry.Name as NSString).pathExtension) ?? .data
}

final class FilePromise: NSObject, NSFilePromiseProviderDelegate {
    private let entry: AndroidEntry
    private let transfer: (AndroidEntry, URL, @escaping (Error?) -> Void) -> Void

    init(entry: AndroidEntry, transfer: @escaping (AndroidEntry, URL, @escaping (Error?) -> Void) -> Void) {
        self.entry = entry
        self.transfer = transfer
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        entry.Name
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        transfer(entry, url, completionHandler)
    }
}

final class App: NSObject, NSApplicationDelegate, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSSearchFieldDelegate {
    private let mtp = MTP()
    private var transferPanel: TransferWindow?
    private var transferWindow: TransferWindow {
        if let transferPanel { return transferPanel }
        let panel = TransferWindow()
        transferPanel = panel
        return panel
    }
    private var wireless: WirelessStorage?
    private var connectionSheet: WirelessConnection?
    private let connectionStatus = NSTextField(labelWithString: "")
    private let connectionIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyHint = NSTextField(labelWithString: "")
    private let emptyIcon = NSImageView()
    private let emptyState = EmptyStateView()
    private var listingFailed = false
    private let thumbnailWarning = NSStackView()
    private let thumbnailCache: NSCache<NSString, ThumbnailResult> = {
        let cache = NSCache<NSString, ThumbnailResult>()
        cache.countLimit = 160
        return cache
    }()
    private var thumbnailWork: DispatchWorkItem?
    private var thumbnailRequest: OperationRequest?
    private var presenceTimer: Timer?
    private var usbSnapshot: Set<UInt64>?
    private var checkingWireless = false
    private var connected = false { didSet { updateBrowserState() } }
    private var session = OperationRequest()
    private let usbAgent = SMAppService.agent(plistName: "com.tmosmant.android-finder.usb.plist")
    private let browser = BrowserView()
    private let breadcrumbs = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let columnHeader = NSView()
    private var headerLeading: NSLayoutConstraint?
    private var columns: [FileColumn] { showingSearchResults ? FileColumn.allCases : [.name, .kind, .size] }
    private var columnMinimums: [CGFloat] { columns.map(\.minimumWidth) }
    private var columnWeights: [Bool: [CGFloat]] = [false: [0.76, 0.16, 0.08], true: [0.52, 0.12, 0.06, 0.30]]
    private var columnWidths: [CGFloat] = []
    private var headerWidths: [NSLayoutConstraint] = []
    private var columnButtons: [NSButton] = []
    private var sortColumn = FileColumn.name
    private var sortAscending = true
    private var searchRequest: OperationRequest?
    private var pendingSearch: DispatchWorkItem?
    private var showingSearchResults = false {
        didSet {
            guard oldValue != showingSearchResults else { return }
            if !columns.contains(sortColumn) {
                sortColumn = .name
                sortAscending = true
            }
            configureColumnHeader()
            updateColumnWidths()
        }
    }
    private var searchQuery: String { searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 470),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
    private var path = "/"
    private var entries: [AndroidEntry] = [] { didSet { updateBrowserState() } }
    private var icons = false
    private var busy = false { didSet { updateBrowserState() } }
    private var isQuitting = false
    private var keyMonitor: Any?
    private var previewView: QLPreviewView?
    private lazy var previewPanel: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let view = QLPreviewView(frame: .zero, style: .normal)
        view?.shouldCloseWithWindow = false
        panel.contentView = view
        previewView = view
        panel.center()
        return panel
    }()
    private var previewURL: URL? {
        didSet { previewView?.previewItem = previewURL as NSURL? }
    }
    private var previewPath: String?
    private var previewLoading = false
    private let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "Android Finder"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 300)
        let layout = NSCollectionViewFlowLayout()
        layout.minimumLineSpacing = 3
        layout.minimumInteritemSpacing = 5
        layout.sectionInset = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        browser.collectionViewLayout = layout
        browser.register(FileItem.self, forItemWithIdentifier: FileItem.identifier)
        browser.delegate = self
        browser.dataSource = self
        browser.isSelectable = true
        browser.allowsMultipleSelection = true
        browser.registerForDraggedTypes([.fileURL])
        browser.setDraggingSourceOperationMask(.copy, forLocal: false)
        browser.openSelection = { [weak self] in self?.openSelection() }
        browser.rangeSelectionChanged = { [weak self] in self?.updatePreview() }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.masksToBounds = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.documentView = browser
        scroll.contentView.postsFrameChangedNotifications = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleThumbnails),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(updateColumnWidths),
                                               name: NSView.frameDidChangeNotification, object: scroll.contentView)

        let modes = NSSegmentedControl(labels: [L10n.text("view.list"), L10n.text("view.icons")], trackingMode: .selectOne,
                                       target: self, action: #selector(changeMode(_:)))
        modes.selectedSegment = 0
        let reload = toolbarButton("arrow.clockwise", label: "action.refresh", action: #selector(refresh))
        let delete = toolbarButton("trash", label: "action.delete", action: #selector(deleteSelection))
        let spacer = NSView()
        searchField.placeholderString = L10n.text("search.placeholder")
        searchField.toolTip = L10n.text("search.help")
        searchField.delegate = self
        searchField.widthAnchor.constraint(equalToConstant: 165).isActive = true
        let connect = NSButton(title: L10n.text("wifi.open"), target: self, action: #selector(showWirelessConnection))
        connect.image = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)
        connect.imagePosition = .imageLeading
        let actions = NSStackView(views: [reload, delete])
        actions.spacing = 4
        let toolbar = NSStackView(views: [modes, actions, spacer, searchField, connect])
        toolbar.spacing = 12
        connectionStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        connectionIcon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        let connection = NSStackView(views: [connectionIcon, connectionStatus])
        connection.spacing = 4
        let footer = NSStackView(views: [connection, status])
        footer.spacing = 10
        footer.distribution = .fill
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let pathScroll = NSScrollView()
        pathScroll.drawsBackground = false
        pathScroll.hasHorizontalScroller = true
        pathScroll.autohidesScrollers = true
        pathScroll.documentView = breadcrumbs

        columnHeader.heightAnchor.constraint(equalToConstant: 18).isActive = true
        configureColumnHeader()
        updateColumnWidths()
        configureThumbnailWarning()
        let stack = NSStackView(views: [toolbar, pathScroll, columnHeader, scroll, thumbnailWarning, footer])
        stack.setCustomSpacing(2, after: columnHeader)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        window.contentView = content
        content.addSubview(stack)
        configureEmptyState(in: content, over: scroll)
        status.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pathScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pathScroll.heightAnchor.constraint(equalToConstant: 27),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.text("usb.autolaunch.menu"), action: #selector(toggleUSBLaunch), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.text("app.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(browser)
        NSApp.activate(ignoringOtherApps: true)
        usbSnapshot = usbInterfaces()
        resetBrowser(message: L10n.text("usb.scanning"))
        refresh()
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkPresence()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleThumbnails),
                                               name: NSWindow.didDeminiaturizeNotification, object: window)
    }

    private func configureEmptyState(in content: NSView, over scroll: NSView) {
        emptyIcon.symbolConfiguration = .init(pointSize: 32, weight: .light)
        emptyIcon.contentTintColor = .secondaryLabelColor
        emptyTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        emptyHint.textColor = .secondaryLabelColor
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        [emptyIcon, emptyTitle, emptyHint].forEach { emptyState.addArrangedSubview($0) }
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
        updateBrowserState()
    }

    private func updateBrowserState() {
        let transport = wireless == nil ? "USB" : "Wi-Fi"
        connectionIcon.image = NSImage(systemSymbolName: wireless == nil ? "cable.connector" : "wifi",
                                       accessibilityDescription: nil)
        connectionIcon.contentTintColor = connected ? .systemGreen : .secondaryLabelColor
        connectionStatus.stringValue = transport
        emptyState.isHidden = busy || listingFailed || !entries.isEmpty || searchRequest != nil
        guard !emptyState.isHidden else { return }
        let key = connected ? (showingSearchResults ? "empty.search" : "empty.folder") : "empty.connection"
        let symbol = connected ? (showingSearchResults ? "magnifyingglass" : "folder") : "iphone"
        emptyIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        emptyTitle.stringValue = L10n.text(key)
        emptyHint.stringValue = L10n.text(key + ".hint")
    }

    private func configureThumbnailWarning() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: L10n.text("thumbnails.slow"))
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        thumbnailWarning.spacing = 6
        thumbnailWarning.addArrangedSubview(icon)
        thumbnailWarning.addArrangedSubview(label)
        thumbnailWarning.isHidden = true
    }

    private func cancelThumbnail() {
        thumbnailWork?.cancel()
        thumbnailWork = nil
        thumbnailRequest?.cancel()
        thumbnailRequest = nil
    }

    private func resetThumbnails() {
        cancelThumbnail()
        thumbnailWarning.isHidden = true
    }

    @objc private func scheduleThumbnails() {
        guard icons, connected, !isQuitting else { return }
        thumbnailWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.loadVisibleThumbnail() }
        thumbnailWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }

    private func loadVisibleThumbnail() {
        thumbnailWork = nil
        guard icons, connected, !busy, !isQuitting, searchRequest == nil, !previewLoading,
              connectionSheet == nil, thumbnailRequest == nil, transferPanel?.isTransferring != true, window.isVisible,
              !window.isMiniaturized else { return }
        let wireless = self.wireless
        let candidates = browser.indexPathsForVisibleItems().sorted().prefix(96).compactMap { index in
            entries.indices.contains(index.item) ? entries[index.item] : nil
        }
        guard let entry = candidates.first(where: {
            thumbnailCache.object(forKey: Thumbnails.key(for: $0)) == nil
                && Thumbnails.canLoad($0, wireless: wireless != nil)
        }) else { return }

        let key = Thumbnails.key(for: entry)
        let request = OperationRequest()
        thumbnailRequest = request
        mtp.perform(session: request, { [weak self, mtp] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if self?.thumbnailRequest === request { self?.thumbnailWarning.isHidden = false }
            }
            let timeout = DispatchWorkItem { request.cancel() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: timeout)
            defer { timeout.cancel() }
            return try Thumbnails.load(entry, mtp: mtp, wireless: wireless, request: request)
        }) { result in
            guard self.thumbnailRequest === request else { return }
            self.thumbnailRequest = nil
            let thumbnail = (try? result.get()) ?? ThumbnailResult(nil)
            self.thumbnailCache.setObject(thumbnail, forKey: key)
            if let image = thumbnail.image {
                for index in self.browser.indexPathsForVisibleItems() where self.entries.indices.contains(index.item) {
                    if Thumbnails.key(for: self.entries[index.item]) == key {
                        (self.browser.item(at: index) as? FileItem)?.showThumbnail(image)
                    }
                }
            }
            self.scheduleThumbnails()
        }
    }

    private func toolbarButton(_ symbol: String, label key: String, action: Selector) -> NSButton {
        let label = L10n.text(key)
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    @objc private func showWirelessConnection() {
        guard window.attachedSheet == nil, connectionSheet == nil, !isQuitting else { return }
        let sheet = WirelessConnection { [weak self] storage in
            guard let self, !self.isQuitting else { return }
            self.wireless = storage
            self.usbSnapshot = storage == nil ? usbInterfaces() : nil
            self.resetBrowser(message: L10n.text("phone.opening"))
            self.refresh()
        }
        cancelThumbnail()
        connectionSheet = sheet
        sheet.show(on: window) { [weak self] in
            self?.connectionSheet = nil
            self?.scheduleThumbnails()
        }
    }

    private func resetBrowser(message: String) {
        resetThumbnails()
        thumbnailCache.removeAllObjects()
        listingFailed = false
        session.cancel()
        session = OperationRequest()
        connected = false
        busy = false
        cancelSearch()
        searchField.stringValue = ""
        showingSearchResults = false
        path = "/"
        entries = []
        browser.selectionAnchor = nil
        browser.deselectAll(nil)
        browser.reloadData()
        if previewView != nil { previewPanel.orderOut(nil) }
        previewPath = nil
        previewURL = nil
        previewLoading = false
        updatePath()
        updateBrowserState()
        status.stringValue = message
        status.toolTip = message
    }

    private func checkPresence() {
        guard !isQuitting else { return }
        if let wireless {
            guard connected || busy, !checkingWireless else { return }
            checkingWireless = true
            let session = self.session
            DispatchQueue.global(qos: .utility).async {
                let reachable = wireless.isReachable()
                DispatchQueue.main.async {
                    self.checkingWireless = false
                    guard self.session === session, !self.isQuitting, !reachable else { return }
                    self.resetBrowser(message: L10n.text("wifi.disconnected"))
                }
            }
        } else if let current = usbInterfaces() {
            let previous = usbSnapshot ?? current
            usbSnapshot = current
            if !previous.isSubset(of: current), connected || busy {
                resetBrowser(message: L10n.text("usb.disconnected"))
            }
            if !current.subtracting(previous).isEmpty, !connected, !busy {
                refresh()
            }
        }
    }

    @objc private func toggleUSBLaunch() {
        do {
            switch usbAgent.status {
            case .enabled:
                try usbAgent.unregister()
                status.stringValue = L10n.text("usb.autolaunch.disabled")
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try usbAgent.register()
                if usbAgent.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
                status.stringValue = L10n.text("usb.autolaunch.enabled")
            }
        } catch {
            present(error)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        refresh()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitting else { return .terminateLater }
        isQuitting = true
        cancelThumbnail()
        presenceTimer?.invalidate()
        cancelSearch()
        status.stringValue = L10n.text("app.finishing")
        if previewView != nil {
            previewPanel.orderOut(nil)
            previewURL = nil
            previewView?.close()
        }
        mtp.finish {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        try? FileManager.default.removeItem(at: cache)
    }

    @objc private func changeMode(_ sender: NSSegmentedControl) {
        resetThumbnails()
        icons = sender.selectedSegment == 1
        if let layout = browser.collectionViewLayout as? NSCollectionViewFlowLayout {
            layout.minimumLineSpacing = icons ? 10 : 3
            layout.minimumInteritemSpacing = icons ? 8 : 5
        }
        columnHeader.isHidden = icons
        updateColumnWidths()
        let selection = browser.selectionIndexPaths
        browser.collectionViewLayout?.invalidateLayout()
        browser.reloadData()
        browser.selectionIndexPaths = selection
        window.makeFirstResponder(browser)
        scheduleThumbnails()
    }

    private func configureColumnHeader() {
        columnHeader.subviews.forEach { $0.removeFromSuperview() }
        columnButtons.removeAll()
        let strip = NSView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        columnHeader.addSubview(strip)
        let leading = strip.leadingAnchor.constraint(equalTo: columnHeader.leadingAnchor, constant: 13)
        headerLeading = leading
        NSLayoutConstraint.activate([
            leading,
            strip.topAnchor.constraint(equalTo: columnHeader.topAnchor),
            strip.bottomAnchor.constraint(equalTo: columnHeader.bottomAnchor),
            strip.trailingAnchor.constraint(equalTo: columnHeader.trailingAnchor)
        ])
        var cells: [NSView] = []
        for (index, column) in columns.enumerated() {
            let button = NSButton(title: column.title, target: self, action: #selector(sortByColumn(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(column.rawValue)
            button.isBordered = false
            button.alignment = .left
            button.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            columnButtons.append(button)
            let cell = NSStackView(views: [button])
            cell.spacing = 0
            cell.distribution = .fill
            if index + 1 < columns.count {
                let divider = ColumnDivider()
                divider.widthAnchor.constraint(equalToConstant: 8).isActive = true
                divider.heightAnchor.constraint(equalToConstant: 18).isActive = true
                var startWidths: [CGFloat] = []
                divider.beginResize = { [weak self] in startWidths = self?.columnWidths ?? [] }
                divider.resize = { [weak self] delta in
                    self?.resizeColumn(at: index, from: startWidths, by: delta)
                }
                cell.addArrangedSubview(divider)
            }
            cells.append(cell)
        }
        headerWidths = layoutColumns(cells, in: strip, widths: columnMinimums)
        updateSortHeader()
    }

    @objc private func updateColumnWidths() {
        let scroll = browser.enclosingScrollView
        headerLeading?.constant = 12 + (scroll?.contentView.frame.minX ?? 1)
        let viewport = scroll?.contentSize.width ?? 0
        let available = (viewport > 0 ? viewport : window.frame.width - 24) - 13 - 12 - 7 * CGFloat(columnMinimums.count - 1)
        let extra = max(0, available - columnMinimums.reduce(0, +))
        let weights = columnWeights[showingSearchResults, default: []]
        applyColumnWidths(zip(columnMinimums, weights).map { $0 + extra * $1 })
        browser.collectionViewLayout?.invalidateLayout()
    }

    private func resizeColumn(at index: Int, from start: [CGFloat], by delta: CGFloat) {
        guard start.count == columnMinimums.count else { return }
        let next = index + 1
        let minimumDelta = columnMinimums[index] - start[index]
        let maximumDelta = start[next] - columnMinimums[next]
        let movement = min(maximumDelta, max(minimumDelta, delta))
        var widths = start
        widths[index] += movement
        widths[next] -= movement
        let extra = widths.reduce(0, +) - columnMinimums.reduce(0, +)
        if extra > 0 {
            columnWeights[showingSearchResults] = zip(widths, columnMinimums).map { ($0 - $1) / extra }
        }
        applyColumnWidths(widths)
    }

    private func applyColumnWidths(_ widths: [CGFloat]) {
        columnWidths = widths
        for (constraint, width) in zip(headerWidths, widths) {
            constraint.constant = width
        }
        for case let item as FileItem in browser.visibleItems() {
            item.setColumnWidths(widths)
        }
    }

    @objc private func sortByColumn(_ sender: NSButton) {
        guard let label = sender.identifier?.rawValue, let column = FileColumn(rawValue: label) else { return }
        let selectedPaths = Set(selection.map(\.FullPath))
        let anchorPath = browser.selectionAnchor.flatMap { entries.indices.contains($0.item) ? entries[$0.item].FullPath : nil }
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = true
        }
        sortEntries()
        browser.reloadData()
        browser.selectionIndexPaths = Set(entries.indices.compactMap { index in
            selectedPaths.contains(entries[index].FullPath) ? IndexPath(item: index, section: 0) : nil
        })
        browser.selectionAnchor = entries.firstIndex { $0.FullPath == anchorPath }.map { IndexPath(item: $0, section: 0) }
        updateSortHeader()
        updatePreview()
    }

    private func sortEntries() {
        entries.sort {
            if sortColumn == .name, $0.IsDir != $1.IsDir { return $0.IsDir }
            return sortColumn.compare($0, $1, ascending: sortAscending)
        }
    }

    private func updateSortHeader() {
        for button in columnButtons {
            guard let key = button.identifier?.rawValue, let column = FileColumn(rawValue: key) else { continue }
            button.title = column == sortColumn ? column.title + (sortAscending ? " ↑" : " ↓") : column.title
        }
    }

    @objc private func refresh() {
        resetThumbnails()
        thumbnailCache.removeAllObjects()
        if searchQuery.isEmpty { navigate(path) } else { scheduleSearch() }
    }

    func controlTextDidChange(_ notification: Notification) {
        if searchQuery.isEmpty {
            cancelSearch()
            refresh()
        } else {
            scheduleSearch()
        }
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        guard searchQuery.isEmpty, showingSearchResults else { return }
        cancelSearch()
        refresh()
    }

    private func focusSearchResults() {
        window.makeFirstResponder(browser)
        selectEntry(at: 0)
    }

    private func cancelSearch() {
        pendingSearch?.cancel()
        pendingSearch = nil
        searchRequest?.cancel()
        searchRequest = nil
    }

    private func scheduleSearch() {
        cancelSearch()
        guard !isQuitting, connected else { return }
        resetThumbnails()
        listingFailed = false
        let wireless = self.wireless
        let session = self.session
        let query = searchQuery
        let folder = path
        let request = OperationRequest()
        searchRequest = request
        showingSearchResults = true
        browser.selectionAnchor = nil
        browser.deselectAll(nil)
        entries = []
        browser.reloadData()
        updatePreview()
        status.stringValue = L10n.text("search.running")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.searchRequest === request else { return }
            self.mtp.perform(session: session, {
                if let wireless { return try wireless.entries(folder, query: query, request: request) }
                return try self.mtp.search(folder, query: query, request: request)
            }) { result in
                guard !self.isQuitting, self.searchRequest === request else { return }
                self.searchRequest = nil
                switch result {
                case .success(let matches):
                    self.entries = matches
                    self.sortEntries()
                    self.browser.reloadData()
                    self.status.stringValue = L10n.format("search.count", matches.count)
                case .failure(let error):
                    self.listingFailed = true
                    self.status.stringValue = L10n.format("search.failed", error.localizedDescription)
                }
                self.status.toolTip = self.status.stringValue
                self.updateBrowserState()
                self.scheduleThumbnails()
            }
        }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
    }

    private func navigate(_ destination: String, selecting child: String? = nil, focusFiles: Bool = false) {
        guard !isQuitting, !busy else { return }
        resetThumbnails()
        listingFailed = false
        cancelSearch()
        if destination != path { searchField.stringValue = "" }
        showingSearchResults = false
        busy = true
        status.stringValue = L10n.text("phone.reading")
        let wireless = self.wireless
        let session = self.session
        mtp.perform(session: session, {
            if let wireless { return try wireless.entries(destination, request: session) }
            return try self.mtp.list(destination)
        }) { result in
            guard !self.isQuitting, self.session === session else { return }
            self.busy = false
            self.checkPresence()
            guard self.session === session else { return }
            switch result {
            case .success(let contents):
                self.connected = true
                self.path = destination
                if !self.searchQuery.isEmpty {
                    self.updatePath()
                    self.scheduleSearch()
                    return
                }
                self.entries = contents
                self.sortEntries()
                self.browser.selectionAnchor = nil
                self.browser.deselectAll(nil)
                self.browser.reloadData()
                self.updatePath()
                self.status.stringValue = L10n.format("file.count", self.entries.count)
                if focusFiles {
                    self.window.makeFirstResponder(self.browser)
                    self.selectEntry(at: self.entries.firstIndex { $0.FullPath == child } ?? 0)
                }
                self.updatePreview()
                self.scheduleThumbnails()
            case .failure(let error):
                self.listingFailed = true
                self.entries = []
                self.browser.reloadData()
                let hint = wireless == nil
                    ? L10n.text("usb.read.hint")
                    : L10n.text("wifi.read.hint")
                self.status.stringValue = "\(hint) \(error.localizedDescription)"
                self.status.toolTip = self.status.stringValue
                self.updatePreview()
            }
        }
    }

    private func updatePath() {
        for view in breadcrumbs.arrangedSubviews {
            breadcrumbs.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var current = ""
        breadcrumbs.spacing = 8
        breadcrumbs.alignment = .centerY
        for part in [L10n.text("storage.internal")] + path.split(separator: "/").map(String.init) {
            let root = breadcrumbs.arrangedSubviews.isEmpty
            if !root {
                current += "/" + part
                let separator = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
                separator.symbolConfiguration = .init(pointSize: 9, weight: .medium)
                separator.contentTintColor = .tertiaryLabelColor
                breadcrumbs.addArrangedSubview(separator)
            }
            let button = NSButton(title: part, target: self, action: #selector(openBreadcrumb(_:)))
            button.isBordered = false
            let target = root ? "/" : current
            let active = target == path
            button.attributedTitle = NSAttributedString(string: part, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: active ? .semibold : .regular),
                .foregroundColor: active ? NSColor.labelColor : NSColor.secondaryLabelColor
            ])
            if root {
                button.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)
                button.imagePosition = .imageLeading
            }
            button.identifier = NSUserInterfaceItemIdentifier(target)
            button.toolTip = target
            breadcrumbs.addArrangedSubview(button)
        }
        breadcrumbs.frame.size = breadcrumbs.fittingSize
    }

    @objc private func openBreadcrumb(_ sender: NSButton) {
        if let target = sender.identifier?.rawValue { navigate(target) }
    }

    private var selection: [AndroidEntry] {
        browser.selectionIndexPaths.sorted().compactMap {
            entries.indices.contains($0.item) ? entries[$0.item] : nil
        }
    }

    private func openSelection() {
        guard let item = selection.first else { return }
        if item.IsDir { navigate(item.FullPath, focusFiles: true) } else { showPreview() }
    }

    @objc private func deleteSelection() {
        let selected = selection
        let session = self.session
        guard !isQuitting, !busy, !selected.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L10n.format("delete.confirm", selected.count)
        alert.informativeText = L10n.text("delete.warning")
        alert.addButton(withTitle: L10n.text("action.cancel"))
        alert.addButton(withTitle: L10n.text("action.delete")).hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn, self.session === session {
                self.mutate(["delete"] + selected.map(\.FullPath), status: "Suppression…")
            }
        }
    }

    private func mutate(_ arguments: [String], status message: String) {
        guard !isQuitting, connected, !busy else { return }
        cancelThumbnail()
        let wireless = self.wireless
        let session = self.session
        busy = true
        status.stringValue = message
        mtp.perform(session: session, {
            if let wireless { try wireless.command(arguments, request: session) }
            else { _ = try self.mtp.command(arguments) }
        }) { result in
            guard !self.isQuitting, self.session === session else { return }
            self.busy = false
            self.refresh()
            if case .failure(let error) = result {
                if arguments.first == "upload" {
                    self.presentCopyError(error, messageKey: "copy.upload.failed")
                } else {
                    self.present(error)
                }
            }
        }
    }

    private func present(_ error: Error) {
        NSAlert(error: error).beginSheetModal(for: window)
    }

    private func presentCopyError(_ error: Error, messageKey: String) {
        guard !isQuitting else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text(messageKey)
        let hint = wireless == nil
            ? L10n.text("usb.copy.hint")
            : L10n.text("wifi.copy.hint")
        alert.informativeText = error.localizedDescription + "\n\n" + hint
        if window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            status.stringValue = alert.messageText
            status.toolTip = alert.informativeText
        }
    }

    private var visiblePreview: NSPanel? { previewPanel.isVisible ? previewPanel : nil }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard !isQuitting else { return false }
        let panel = visiblePreview
        let inPreview = panel != nil && event.window === panel
        guard window.attachedSheet == nil, event.window === window || inPreview else { return false }

        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if modifiers == .command {
            if event.charactersIgnoringModifiers?.lowercased() == "a" {
                guard !inPreview, !(window.firstResponder is NSTextView) else { return false }
                window.makeFirstResponder(browser)
                browser.selectionIndexPaths = Set(entries.indices.map { IndexPath(item: $0, section: 0) })
                updatePreview()
                return true
            }
            switch event.keyCode {
            case 126:
                if path != "/" {
                    navigate((path as NSString).deletingLastPathComponent, selecting: path, focusFiles: true)
                }
                return true
            case 125:
                openSelection()
                return true
            case 3: // F
                window.makeFirstResponder(searchField)
                searchField.selectText(nil)
                return true
            case 15: // R
                refresh()
                return true
            default:
                return false
            }
        }
        guard modifiers.isEmpty else { return false }
        let focused = window.firstResponder === browser
        if let editor = searchField.currentEditor(), window.firstResponder === editor {
            switch event.keyCode {
            case 123, 124:
                return false
            case 36, 76:
                focusSearchResults()
                return true
            default:
                break
            }
        }
        switch event.keyCode {
        case 123...126:
            if !focused && !inPreview {
                window.makeFirstResponder(browser)
                selectEntry(at: 0)
            } else {
                moveSelection(with: event)
            }
            return true
        case 49 where focused || inPreview:
            if !event.isARepeat {
                if let panel { panel.close() } else { showPreview() }
            }
            return true
        case 53 where panel != nil:
            panel?.close()
            return true
        case 53 where !searchQuery.isEmpty:
            searchField.stringValue = ""
            cancelSearch()
            refresh()
            return true
        case 36, 76:
            guard focused || inPreview else { return false }
            openSelection()
            return true
        case 51, 117:
            guard focused || inPreview else { return false }
            if !event.isARepeat {
                panel?.close()
                deleteSelection()
            }
            return true
        default:
            return false
        }
    }

    private func moveSelection(with event: NSEvent) {
        guard !entries.isEmpty else { return }
        guard let current = browser.selectionIndexPaths.sorted().first?.item else {
            selectEntry(at: 0)
            return
        }
        if icons {
            // AppKit uses the actual grid layout, including a partially filled last row.
            browser.keyDown(with: event)
            browser.selectionAnchor = browser.selectionIndexPaths.sorted().first
            updatePreview()
        } else {
            switch event.keyCode {
            case 125: selectEntry(at: min(current + 1, entries.count - 1))
            case 126: selectEntry(at: max(current - 1, 0))
            default: break
            }
        }
    }

    private func selectEntry(at index: Int) {
        if entries.indices.contains(index) {
            let item = IndexPath(item: index, section: 0)
            browser.selectionIndexPaths = [item]
            browser.selectionAnchor = item
            browser.scrollToItems(at: [item], scrollPosition: .nearestVerticalEdge)
        }
        updatePreview()
    }

    private func showPreview() {
        guard !isQuitting, let item = selection.first, !item.IsDir else { return }
        let panel = previewPanel
        guard previewView != nil else { return }
        if !panel.isVisible {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(browser)
            previewPath = nil
            previewURL = nil
            panel.orderFront(nil)
        }
        updatePreview()
    }

    private func updatePreview() {
        guard !isQuitting, let panel = visiblePreview else { return }
        let item = selection.first.flatMap { $0.IsDir ? nil : $0 }
        if previewPath != item?.FullPath {
            previewPath = nil
            previewURL = nil
            panel.title = item.map { L10n.format("preview.file", $0.Name) } ?? L10n.text("preview.title")
        }
        guard let item, previewPath != item.FullPath, !previewLoading else { return }
        cancelThumbnail()
        previewLoading = true
        let wireless = self.wireless
        let session = self.session
        if !busy { status.stringValue = L10n.text("preview.loading") }
        mtp.perform(session: session, {
            let folder = self.cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(item.Name)
            try self.mtp.download(item, to: url, wireless: wireless, request: session)
            return url
        }) { result in
            guard !self.isQuitting, self.session === session else { return }
            self.previewLoading = false
            defer { self.scheduleThumbnails() }
            if !self.busy { self.status.stringValue = L10n.format("file.count", self.entries.count) }
            guard self.visiblePreview != nil else { return }
            guard self.selection.first?.FullPath == item.FullPath else {
                self.updatePreview()
                return
            }
            switch result {
            case .success(let url):
                self.previewPath = item.FullPath
                self.previewURL = url
            case .failure(let error):
                if !self.busy {
                    self.status.stringValue = L10n.format("preview.failed", error.localizedDescription)
                    self.status.toolTip = self.status.stringValue
                }
            }
        }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updatePreviewAfterSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updatePreviewAfterSelection()
    }

    private func updatePreviewAfterSelection() {
        DispatchQueue.main.async { [weak self] in self?.updatePreview() }
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FileItem.identifier, for: indexPath) as! FileItem
        let entry = entries[indexPath.item]
        let thumbnail = icons ? thumbnailCache.object(forKey: Thumbnails.key(for: entry))?.image : nil
        item.configure(entry, icons: icons, columns: columns, widths: columnWidths, thumbnail: thumbnail)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        scheduleThumbnails()
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        if icons { return NSSize(width: 126, height: 105) }
        return NSSize(width: max(100, (collectionView.enclosingScrollView?.contentSize.width ?? 300) - 13), height: 28)
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard !isQuitting, !busy, entries.indices.contains(indexPath.item) else { return nil }
        let item = entries[indexPath.item]
        let wireless = self.wireless
        let session = self.session
        let promise = FilePromise(entry: item) { [weak self, mtp] entry, url, completion in
            RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                guard let self, self.session === session, !self.isQuitting else {
                    completion(CocoaError(.userCancelled))
                    return
                }
                self.cancelThumbnail()
                let id = UUID()
                self.transferWindow.enqueue(id, entry: entry, to: url)
                mtp.perform(session: session, {
                    try mtp.download(entry, to: url, wireless: wireless, request: session) { stagedFile in
                        RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                            self.transferWindow.started(id, entry: entry, to: url, staging: stagedFile)
                        }
                    }
                }) { result in
                    let error: Error?
                    switch result {
                    case .success: error = nil
                    case .failure(let failure): error = failure
                    }
                    self.transferWindow.completed(id, error: error)
                    completion(error)
                    self.scheduleThumbnails()
                }
            }
        }
        let provider = NSFilePromiseProvider(fileType: fileType(item).identifier, delegate: promise)
        provider.userInfo = promise
        return provider
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard !isQuitting, connected, !busy, draggingInfo.draggingSource as? NSCollectionView !== collectionView,
              draggingInfo.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        else { return [] }
        dropOperation.pointee = .before
        return .copy
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard !isQuitting, connected, !busy,
              let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        mutate(["upload", path] + urls.map(\.path), status: L10n.text("copy.upload.running"))
        return true
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
