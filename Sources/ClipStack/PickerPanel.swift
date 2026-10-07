import AppKit
import ImageIO
import QuickLookThumbnailing

/// The window the hotkey opens: search, tick several clips (numbered in the
/// order you tick them), then paste them merged (↩) or queue them (⌥↩).
final class PickerPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// Chosen clips, in tick order, and whether to queue them.
    var onCommit: (([Clip], Bool) -> Void)?
    /// Fresh history, most recent first; called when the panel opens or changes.
    var load: () -> [Clip] = { [] }
    var onPin: (Clip) -> Void = { _ in }
    var onDelete: (Clip) -> Void = { _ in }

    private let search = NSSearchField()
    private let table = PickerTable()
    private let footer = NSTextField(labelWithString: "")
    private let thumbnails = Thumbnails()
    private var all: [Clip] = []
    private var shown: [Clip] = []
    private var marks: [String] = []          // keys of ticked clips, in tick order
    /// Set by the scripted test, which runs while you may be using other windows.
    var staysOpen = false

    init() {
        // Non-activating, like Spotlight: it takes the keyboard while the app
        // you were in stays active, so the paste lands back there.
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 470),
                   styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        becomesKeyOnlyIfNeeded = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]   // shows over full-screen apps too
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        minSize = NSSize(width: 420, height: 280)
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { standardWindowButton($0)?.isHidden = true }

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        contentView = background

        search.placeholderString = "Search clipboard history"
        search.font = .systemFont(ofSize: 16)
        search.focusRingType = .none
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("clip"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 46
        table.style = .inset
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.doubleAction = #selector(doubleClicked)
        table.picker = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.translatesAutoresizingMaskIntoConstraints = false

        [search, scroll, footer].forEach(background.addSubview)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: background.topAnchor, constant: 30),
            search.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -4),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
        ])

        thumbnails.onLoad = { [weak self] key in
            guard let self, let row = self.shown.firstIndex(where: { $0.key == key }) else { return }
            self.table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
    }

    override var canBecomeKey: Bool { true }

    // MARK: Showing

    func present() {
        all = load()
        marks = []
        search.stringValue = ""
        refilter()

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: area.midX - frame.width / 2, y: area.minY + area.height * 0.62 - frame.height / 2))
        }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(search)
    }

    /// Clicking anywhere else closes the picker.
    override func resignKey() {
        super.resignKey()
        if !staysOpen { orderOut(nil) }
    }

    private func reloadKeepingSearch() {
        all = load()
        marks = marks.filter { key in all.contains { $0.key == key } }
        refilter()
    }

    private func refilter() {
        let terms = search.stringValue.lowercased().split(separator: " ").map(String.init)
        shown = terms.isEmpty ? all : all.filter { clip in
            let hay = [clip.text, clip.app ?? "", clip.label(width: 400)].joined(separator: " ").lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateFooter()
    }

    private func updateFooter() {
        if marks.isEmpty {
            footer.stringValue = shown.isEmpty
                ? (all.isEmpty ? "Nothing copied yet. Copy something and it will appear here." : "No matches.")
                : "↩ paste   ⇥ tick several   ⌥↩ queue   ⌘1–9 quick paste   ⌘P pin   ⌘⌫ delete   esc close"
        } else {
            footer.stringValue = "\(marks.count) ticked — ↩ paste them together, in this order   ⌥↩ queue them   ⇥ untick"
        }
    }

    // MARK: Actions

    private var current: Clip? {
        let row = table.selectedRow
        return shown.indices.contains(row) ? shown[row] : nil
    }

    func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        let row = max(0, min(shown.count - 1, (table.selectedRow < 0 ? 0 : table.selectedRow) + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func toggleMark(row: Int? = nil) {
        let row = row ?? table.selectedRow
        guard shown.indices.contains(row) else { return }
        let key = shown[row].key
        if let i = marks.firstIndex(of: key) { marks.remove(at: i) } else { marks.append(key) }
        table.reloadData(forRowIndexes: IndexSet(0..<shown.count), columnIndexes: IndexSet(integer: 0))
        updateFooter()
    }

    func commit(queue: Bool) {
        var chosen = marks.compactMap { key in all.first { $0.key == key } }
        if chosen.isEmpty, let current { chosen = [current] }
        guard !chosen.isEmpty else { return }
        orderOut(nil)
        onCommit?(chosen, queue)
    }

    func quickPaste(_ index: Int) {
        guard shown.indices.contains(index) else { return }
        orderOut(nil)
        onCommit?([shown[index]], false)
    }

    func typeIntoSearch(_ event: NSEvent) {
        makeFirstResponder(search)
        search.currentEditor()?.keyDown(with: event)
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard row >= 0 else { return }
        // The round marker on the left ticks and unticks.
        let point = table.convert(mouseLocationOutsideOfEventStream, from: nil)
        if point.x < 44 { toggleMark(row: row) }
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        commit(queue: false)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        let chars = event.charactersIgnoringModifiers ?? ""
        if let n = Int(chars), (1...9).contains(n) { quickPaste(n - 1); return true }
        if chars == "p", let clip = current {
            onPin(clip); reloadKeepingSearch(); return true
        }
        if event.keyCode == 51, let clip = current {      // ⌘⌫
            let row = table.selectedRow
            onDelete(clip); reloadKeepingSearch()
            if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: min(row, shown.count - 1)), byExtendingSelection: false) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Scripted test

    /// Feeds one key press to the panel the way the keyboard would, e.g.
    /// "type:jane", "tab", "down", "return", "opt+return", "cmd+p", "esc".
    func simulate(_ step: String) {
        func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: code) else { return }
            if flags.contains(.command), performKeyEquivalent(with: e) { return }
            sendEvent(e)
        }
        let arrow: NSEvent.ModifierFlags = [.numericPad, .function]
        switch step {
        case let s where s.hasPrefix("type:"): s.dropFirst(5).forEach { key(String($0), 0) }
        case "tab": key("\t", 48)
        case "down": key(String(UnicodeScalar(NSDownArrowFunctionKey)!), 125, arrow)
        case "up": key(String(UnicodeScalar(NSUpArrowFunctionKey)!), 126, arrow)
        case "return": key("\r", 36)
        case "opt+return": key("\r", 36, .option)
        case "esc": key("\u{1b}", 53)
        case "cmd+p": key("p", 35, .command)
        case "cmd+backspace": key("\u{7f}", 51, .command)
        case let s where s.hasPrefix("cmd+"): key(String(s.dropFirst(4)), 18, .command)
        default: err("picker: unknown step \(step)")
        }
    }

    // MARK: Search field keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): move(8)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): move(-8)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)): toggleMark()
        case #selector(NSResponder.insertNewline(_:)): commit(queue: NSEvent.modifierFlags.contains(.option))
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): commit(queue: true)
        case #selector(NSResponder.cancelOperation(_:)):
            if search.stringValue.isEmpty { orderOut(nil) } else { search.stringValue = ""; refilter() }
        default: return false
        }
        return true
    }

    func controlTextDidChange(_ notification: Notification) { refilter() }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: ClipRow.id, owner: nil) as? ClipRow) ?? ClipRow()
        let clip = shown[row]
        let order = marks.firstIndex(of: clip.key).map { $0 + 1 }
        cell.show(clip, order: order, image: thumbnails.image(for: clip))
        return cell
    }
}

/// Keys pressed while the list (not the search field) has focus.
final class PickerTable: NSTableView {
    weak var picker: PickerPanel?

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 36, 76: picker?.commit(queue: event.modifierFlags.contains(.option))   // return, enter
        case 48, 49: picker?.toggleMark()                                            // tab, space
        case 53: picker?.orderOut(nil)                                               // escape
        case 123, 124, 125, 126, 115, 119, 116, 121: super.keyDown(with: event)      // arrows, home/end, page
        default: picker?.typeIntoSearch(event)
        }
    }
}

/// One row: tick marker, thumbnail or icon, the clip, and where it came from.
final class ClipRow: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("ClipRow")
    private let marker = NSTextField(labelWithString: "")
    private let thumb = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = ClipRow.id
        marker.alignment = .center
        marker.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        marker.wantsLayer = true
        marker.layer?.cornerRadius = 10
        marker.layer?.borderWidth = 1.2
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 5
        thumb.layer?.masksToBounds = true
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        for v in [marker, thumb, title, detail] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            marker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            marker.centerYAnchor.constraint(equalTo: centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: 20),
            marker.heightAnchor.constraint(equalToConstant: 20),
            thumb.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: 10),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 36),
            thumb.heightAnchor.constraint(equalToConstant: 36),
            title.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ clip: Clip, order: Int?, image: NSImage?) {
        title.stringValue = clip.label(width: 300)
        var bits = [clip.app, Self.age(clip.at)].compactMap { $0 }
        if clip.pinned { bits.insert("📌 pinned", at: 0) }
        detail.stringValue = bits.joined(separator: " · ")
        thumb.image = image
        if let order {
            marker.stringValue = "\(order)"
            marker.textColor = .white
            marker.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            marker.layer?.borderColor = NSColor.controlAccentColor.cgColor
        } else {
            marker.stringValue = ""
            marker.layer?.backgroundColor = NSColor.clear.cgColor
            marker.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
        }
    }

    static func age(_ date: Date) -> String {
        let s = -date.timeIntervalSinceNow
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86400))d ago"
    }
}

/// Small previews, made off the main thread and kept for the session.
final class Thumbnails {
    var onLoad: ((String) -> Void)?
    private var cache: [String: NSImage] = [:]
    private var requested = Set<String>()

    func image(for clip: Clip) -> NSImage? {
        if let image = cache[clip.key] { return image }
        let symbol: String
        if let media = clip.media { symbol = media.isVideo ? "film" : "photo" }
        else if let files = clip.files { symbol = files.count > 1 ? "doc.on.doc" : "doc" }
        else { return NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "Text") }
        if !requested.contains(clip.key) {
            requested.insert(clip.key)
            load(clip)
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    private func load(_ clip: Clip) {
        let key = clip.key
        let done: (NSImage?) -> Void = { image in
            DispatchQueue.main.async {
                guard let image else { return }
                self.cache[key] = image
                self.onLoad?(key)
            }
        }
        if let media = clip.media, !media.isVideo {
            // Images: ImageIO makes a small thumbnail without decoding the whole picture.
            DispatchQueue.global(qos: .userInitiated).async {
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceThumbnailMaxPixelSize: 96,
                                                kCGImageSourceCreateThumbnailWithTransform: true]
                guard let source = CGImageSourceCreateWithURL(media.url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                else { return done(nil) }
                done(NSImage(cgImage: cg, size: NSSize(width: 36, height: 36)))
            }
            return
        }
        let url = clip.media?.url ?? URL(fileURLWithPath: clip.files?.first ?? "/")
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 36, height: 36),
                                                   scale: 2, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in done(rep?.nsImage) }
    }
}
