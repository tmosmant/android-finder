import AppKit
import Quartz
import ServiceManagement
import UniformTypeIdentifiers

final class BrowserView: NSCollectionView {
    var preview: (() -> Void)?
    var openSelection: (() -> Void)?
    var deleteSelection: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: preview?()
        case 36, 76: openSelection?()
        case 51, 117: deleteSelection?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2,
           indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil {
            openSelection?()
        }
    }
}

final class FileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("file")

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 5
    }

    func configure(_ entry: AndroidEntry, icons: Bool) {
        view.subviews.forEach { $0.removeFromSuperview() }
        let image = NSImageView(image: NSWorkspace.shared.icon(for: fileType(entry)))
        image.imageScaling = .scaleProportionallyDown
        let name = NSTextField(labelWithString: entry.Name)
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        let stack = NSStackView(views: [image, name])
        stack.orientation = icons ? .vertical : .horizontal
        stack.alignment = icons ? .centerX : .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let size: CGFloat = icons ? 42 : 20
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: size),
            image.heightAnchor.constraint(equalToConstant: size),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            name.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
        ])
        name.alignment = icons ? .center : .left
        view.toolTip = entry.FullPath
        updateSelection()
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

final class App: NSObject, NSApplicationDelegate, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout,
                 QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let mtp = MTP()
    private let usbAgent = SMAppService.agent(plistName: "com.tmosmant.android-finder.usb.plist")
    private let browser = BrowserView()
    private let breadcrumbs = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
    private var path = "/"
    private var entries: [AndroidEntry] = []
    private var icons = false
    private var busy = false
    private var previewURL: URL?
    private let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "Android Finder"
        window.minSize = NSSize(width: 380, height: 260)
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
        browser.preview = { [weak self] in self?.preview() }
        browser.openSelection = { [weak self] in self?.openSelection() }
        browser.deleteSelection = { [weak self] in self?.deleteSelection() }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = browser

        let modes = NSSegmentedControl(labels: ["Liste", "Icônes"], trackingMode: .selectOne,
                                       target: self, action: #selector(changeMode(_:)))
        modes.selectedSegment = 0
        let reload = NSButton(title: "Actualiser", target: self, action: #selector(refresh))
        let delete = NSButton(title: "Supprimer", target: self, action: #selector(deleteSelection))
        let toolbar = NSStackView(views: [modes, reload, delete])
        let pathScroll = NSScrollView()
        pathScroll.hasHorizontalScroller = true
        pathScroll.autohidesScrollers = true
        pathScroll.documentView = breadcrumbs

        let stack = NSStackView(views: [toolbar, pathScroll, scroll, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        window.contentView = content
        content.addSubview(stack)
        status.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pathScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pathScroll.heightAnchor.constraint(equalToConstant: 27),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Ouverture automatique sur USB…", action: #selector(toggleUSBLaunch), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quitter Android Finder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(browser)
        NSApp.activate(ignoringOtherApps: true)
        updatePath()
        refresh()
    }

    @objc private func toggleUSBLaunch() {
        do {
            switch usbAgent.status {
            case .enabled:
                try usbAgent.unregister()
                status.stringValue = "Ouverture automatique désactivée."
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try usbAgent.register()
                if usbAgent.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
                status.stringValue = "Ouverture automatique configurée pour le mode Transfert de fichiers."
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

    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: cache)
    }

    @objc private func changeMode(_ sender: NSSegmentedControl) {
        icons = sender.selectedSegment == 1
        let selection = browser.selectionIndexPaths
        browser.collectionViewLayout?.invalidateLayout()
        browser.reloadData()
        browser.selectionIndexPaths = selection
        window.makeFirstResponder(browser)
    }

    @objc private func refresh() { navigate(path) }

    private func navigate(_ destination: String) {
        guard !busy else { return }
        busy = true
        status.stringValue = "Lecture du téléphone…"
        mtp.perform({ try self.mtp.list(destination) }) { result in
            self.busy = false
            switch result {
            case .success(let contents):
                self.path = destination
                self.entries = contents.sorted {
                    if $0.IsDir != $1.IsDir { return $0.IsDir }
                    return $0.Name.localizedStandardCompare($1.Name) == .orderedAscending
                }
                self.browser.deselectAll(nil)
                self.browser.reloadData()
                self.updatePath()
                self.status.stringValue = "\(self.entries.count) éléments"
            case .failure(let error):
                self.entries = []
                self.browser.reloadData()
                self.status.stringValue = "Vérifie que le téléphone est déverrouillé et en mode Transfert de fichiers. \(error.localizedDescription)"
                self.status.toolTip = self.status.stringValue
            }
        }
    }

    private func updatePath() {
        for view in breadcrumbs.arrangedSubviews {
            breadcrumbs.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var current = ""
        for part in ["Stockage interne"] + path.split(separator: "/").map(String.init) {
            let root = breadcrumbs.arrangedSubviews.isEmpty
            if !root {
                current += "/" + part
                breadcrumbs.addArrangedSubview(NSTextField(labelWithString: "›"))
            }
            let button = NSButton(title: part, target: self, action: #selector(openBreadcrumb(_:)))
            button.isBordered = false
            button.identifier = NSUserInterfaceItemIdentifier(root ? "/" : current)
            button.toolTip = root ? "/" : current
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
        if item.IsDir { navigate(item.FullPath) } else { preview() }
    }

    @objc private func deleteSelection() {
        let selected = selection
        guard !busy, !selected.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Supprimer \(selected.count) élément(s) du téléphone ?"
        alert.informativeText = "La suppression est définitive."
        alert.addButton(withTitle: "Annuler")
        alert.addButton(withTitle: "Supprimer").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn {
                self.mutate(["delete"] + selected.map(\.FullPath), status: "Suppression…")
            }
        }
    }

    private func mutate(_ arguments: [String], status message: String) {
        guard !busy else { return }
        busy = true
        status.stringValue = message
        mtp.perform({ try self.mtp.command(arguments) }) { result in
            self.busy = false
            self.refresh()
            if case .failure(let error) = result {
                if arguments.first == "upload" {
                    self.presentCopyError(error, direction: "vers Android")
                } else {
                    self.present(error)
                }
            }
        }
    }

    private func present(_ error: Error) {
        NSAlert(error: error).beginSheetModal(for: window)
    }

    private func presentCopyError(_ error: Error, direction: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Copie \(direction) interrompue"
        alert.informativeText = error.localizedDescription
            + "\n\nSi le câble a été débranché, reconnecte le téléphone, déverrouille-le, choisis Transfert de fichiers et recommence la copie de l’élément concerné."
        if window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            status.stringValue = alert.messageText
            status.toolTip = alert.informativeText
        }
    }

    private func preview() {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard !busy, let item = selection.first, !item.IsDir else { return }
        busy = true
        status.stringValue = "Préparation de l’aperçu…"
        mtp.perform({
            let folder = self.cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(item.Name)
            try self.mtp.download(item, to: url)
            return url
        }) { result in
            self.busy = false
            self.status.stringValue = "\(self.entries.count) éléments"
            switch result {
            case .success(let url):
                self.previewURL = url
                self.window.makeFirstResponder(self.browser)
                QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
            case .failure(let error):
                self.present(error)
            }
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURL as NSURL? }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 49 else { return false }
        panel.orderOut(nil)
        return true
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FileItem.identifier, for: indexPath) as! FileItem
        item.configure(entries[indexPath.item], icons: icons)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        if icons { return NSSize(width: 110, height: 77) }
        return NSSize(width: max(100, (collectionView.enclosingScrollView?.contentSize.width ?? 300) - 13), height: 28)
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard !busy else { return nil }
        let item = entries[indexPath.item]
        let promise = FilePromise(entry: item) { [weak self, mtp] entry, url, completion in
            mtp.perform({ try mtp.download(entry, to: url) }) { result in
                switch result {
                case .success: completion(nil)
                case .failure(let error):
                    completion(error)
                    self?.presentCopyError(error, direction: "vers le Mac")
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
        guard !busy, draggingInfo.draggingSource as? NSCollectionView !== collectionView,
              draggingInfo.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        else { return [] }
        dropOperation.pointee = .before
        return .copy
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard !busy,
              let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        mutate(["upload", path] + urls.map(\.path), status: "Copie vers le téléphone…")
        return true
    }
}

extension BrowserView {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        NSApp.delegate is App
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = NSApp.delegate as? App
        panel.delegate = NSApp.delegate as? App
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
