import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

/// ClipStack.app: the recorder, a menu bar icon, and a hotkey for the picker.
enum ClipStackApp {
    static func run() -> Never {
        let app = NSApplication.shared
        let controller = AppController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)      // menu bar only, no Dock icon
        withExtendedLifetime(controller) { app.run() }
        exit(0)
    }
}

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config.load()
    private var watcher: Watcher?
    private var statusItem: NSStatusItem?
    private let picker = PickerPanel()
    private let hud = HUD()
    private let defaults = UserDefaults.standard
    /// Tests run the app straight from the build folder; leave the Mac's setup alone then.
    private let managesSetup = ProcessInfo.processInfo.environment["CLIPSTACK_NO_SETUP"] != "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if managesSetup, Installer.moveToApplicationsIfWanted() { return }
        if Installer.anotherCopyIsRunning() { NSApp.terminate(nil); return }

        watcher = Watcher(store: Store(config: config), config: config)
        watcher?.start()

        picker.load = { Store(config: Config.load()).ordered(limit: 500) }
        picker.onCommit = { [weak self] clips, queue in self?.paste(clips, queue: queue) }
        picker.onPin = { clip in Store(config: Config.load()).setPinned(key: clip.key, pinned: !clip.pinned) }
        picker.onDelete = { clip in Store(config: Config.load()).delete(key: clip.key) }

        setUpStatusItem()
        registerHotkeys(warn: true)
        if managesSetup { firstRunSetup() }
        if let script = ProcessInfo.processInfo.environment["CLIPSTACK_PICKER_SCRIPT"] { runPickerScript(script) }
    }

    /// For tests: opens the picker and plays key presses into it, without
    /// touching the real keyboard, then reports what the picker showed.
    private func runPickerScript(_ script: String) {
        picker.staysOpen = true
        showPicker()
        var at = 0.8
        for step in script.split(separator: ";").map(String.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                if step == "wait" { return }
                self.picker.simulate(step)
                err("script: \(step)")
            }
            at += 0.4
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + at + 0.3) {
            err("script: done (picker \(self.picker.isVisible ? "open" : "closed"))")
        }
    }

    // MARK: Hotkeys

    private func registerHotkeys(warn: Bool) {
        Hotkeys.shared.unregisterAll()
        var taken: [String] = []
        if !Hotkeys.shared.register(config.pickerHotkey, handler: { [weak self] in self?.showPicker() }) {
            taken.append(Hotkeys.symbols(config.pickerHotkey))
        }
        if !Hotkeys.shared.register(config.nextHotkey, handler: { [weak self] in self?.pasteNext() }) {
            taken.append(Hotkeys.symbols(config.nextHotkey))
        }
        if warn, !taken.isEmpty {
            alert("\(taken.joined(separator: " and ")) can't be used",
                  "Another app already uses it, or it isn't a valid shortcut. You can still open ClipStack from the menu bar, and choose different keys in Settings (pickerHotkey, nextHotkey).")
        }
    }

    // MARK: Picking and pasting

    @objc func showPicker() {
        picker.present()
    }

    private func paste(_ clips: [Clip], queue: Bool) {
        if queue {
            startQueue(clips)
        } else {
            mergeOntoClipboard(clips, separator: config.separator)
        }
        // The picker never took focus from the app you were in, so ⌘V lands there.
        if config.autoPaste && AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Self.pressCommandV() }
            if queue { hud.show("Queued \(clips.count) — \(Hotkeys.symbols(config.nextHotkey)) pastes the next one") }
        } else if queue {
            hud.show("Queued \(clips.count). First one copied — \(Hotkeys.symbols(config.nextHotkey)) loads the next")
        } else {
            hud.show(clips.count == 1 ? "Copied — press ⌘V to paste" : "\(clips.count) clips copied together — press ⌘V")
        }
    }

    @objc func pasteNext() {
        var q = loadQueue()
        guard q.index < q.items.count else {
            saveQueue(PasteQueue())
            hud.show("The paste queue is empty")
            return
        }
        setClipboard(q.items[q.index])
        q.index += 1
        saveQueue(q)
        if config.autoPaste && AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Self.pressCommandV() }
        }
        hud.show("\(q.index) of \(q.items.count) on the clipboard")
    }

    /// Presses ⌘V for the user. Needs Accessibility permission.
    static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "ClipStack")
            ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipStack")
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Rebuilt each time it opens, so it always shows current settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let fresh = Config.load()
        let hotkeysChanged = fresh.pickerHotkey != config.pickerHotkey || fresh.nextHotkey != config.nextHotkey
        config = fresh
        watcher?.config = fresh
        if hotkeysChanged { registerHotkeys(warn: true) }

        menu.removeAllItems()
        add(menu, "Show Clipboard History", #selector(showPicker), hotkey: config.pickerHotkey)
        let q = loadQueue()
        let queued = q.items.isEmpty ? "" : (q.index < q.items.count ? "  (\(q.index) of \(q.items.count) done)" : "  (finished)")
        let next = add(menu, "Paste Next in Queue" + queued, #selector(pasteNext), hotkey: config.nextHotkey)
        next.isEnabled = q.index < q.items.count
        menu.addItem(.separator())

        let separators: [(String, String)] = [("New Line", "\n"), ("Blank Line", "\n\n"), ("Comma", ", "), ("Space", " "), ("Tab", "\t")]
        let sepMenu = NSMenu()
        for (title, value) in separators {
            let item = add(sepMenu, title, #selector(chooseSeparator(_:)))
            item.representedObject = value
            item.state = config.separator == value ? .on : .off
        }
        let sepItem = NSMenuItem(title: "Merge Clips With", action: nil, keyEquivalent: "")
        sepItem.submenu = sepMenu
        menu.addItem(sepItem)
        add(menu, "Paste Automatically", #selector(toggleAutoPaste)).state = config.autoPaste ? .on : .off
        add(menu, "Keep Images and Videos", #selector(toggleMedia)).state = config.recordMedia ? .on : .off
        add(menu, "Open at Login", #selector(toggleLogin)).state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        add(menu, "Clear History…", #selector(clearHistory))
        add(menu, "Settings…", #selector(openSettings))
        add(menu, "Show Data Folder", #selector(openDataFolder))
        menu.addItem(.separator())
        add(menu, "About ClipStack", #selector(about))
        add(menu, "Quit ClipStack", #selector(NSApplication.terminate(_:)), key: "q").target = NSApp
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, hotkey: String? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let hotkey, let last = hotkey.lowercased().split(separator: "+").last {
            // Shown for reference; the hotkey itself works everywhere.
            item.keyEquivalent = String(last)
            var mask: NSEvent.ModifierFlags = []
            let parts = hotkey.lowercased()
            if parts.contains("cmd") || parts.contains("command") { mask.insert(.command) }
            if parts.contains("shift") { mask.insert(.shift) }
            if parts.contains("opt") || parts.contains("alt") { mask.insert(.option) }
            if parts.contains("ctrl") || parts.contains("control") { mask.insert(.control) }
            item.keyEquivalentModifierMask = mask
        }
        menu.addItem(item)
        return item
    }

    @objc private func chooseSeparator(_ sender: NSMenuItem) {
        config.separator = sender.representedObject as? String ?? "\n"
        config.save()
    }

    @objc private func toggleAutoPaste() {
        config.autoPaste.toggle()
        config.save()
        if config.autoPaste && !AXIsProcessTrusted() {
            // Shows the system prompt that leads to Privacy & Security › Accessibility.
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
    }

    @objc private func toggleMedia() {
        config.recordMedia.toggle()
        config.save()
        watcher?.config = config
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            alert("Couldn't change Open at Login", error.localizedDescription)
        }
    }

    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Clear clipboard history?"
        a.informativeText = "Everything except pinned clips is deleted, including saved images and videos."
        a.addButton(withTitle: "Clear")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        saveQueue(PasteQueue())
        let removed = Store(config: config).clearUnpinned()
        hud.show("Cleared \(removed) clips")
    }

    @objc private func openSettings() {
        if !FileManager.default.fileExists(atPath: Paths.config.path) { config.save() }
        NSWorkspace.shared.open(Paths.config)
        hud.show("Changes apply the next time you open the ClipStack menu")
    }

    @objc private func openDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.history])
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    // MARK: First run

    private func firstRunSetup() {
        guard !defaults.bool(forKey: "setUp") else { return }
        defaults.set(true, forKey: "setUp")
        try? SMAppService.mainApp.register()
        Installer.offerToRetireLaunchAgent()
        alert("ClipStack is running",
              "It lives in the menu bar, recording what you copy.\n\nPress \(Hotkeys.symbols(config.pickerHotkey)) anywhere to see your clipboard history. Tick clips with Tab, then press Return to paste them together, or Option-Return to queue them and paste one at a time with \(Hotkeys.symbols(config.nextHotkey)).")
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

/// A short message near the bottom of the screen that fades on its own.
final class HUD {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String) {
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        let size = label.intrinsicContentSize
        let frame = NSRect(x: 0, y: 0, width: size.width + 40, height: size.height + 22)

        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        let bg = NSVisualEffectView(frame: frame)
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        label.frame = frame.insetBy(dx: 20, dy: 11)
        bg.addSubview(label)
        p.contentView = bg
        if let area = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: area.midX - frame.width / 2, y: area.minY + 90))
        }
        p.orderFrontRegardless()
        panel = p

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak p] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p?.animator().alphaValue = 0 },
                                                 completionHandler: { p?.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}

/// Getting the app into place: Applications, one copy running, the old recorder retired.
enum Installer {
    static var isInApplications: Bool {
        let path = Bundle.main.bundleURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    static func anotherCopyIsRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != me }
    }

    /// Offers to move a freshly downloaded app into Applications, replacing an
    /// older copy, then relaunches from there. Returns true if relaunching.
    static func moveToApplicationsIfWanted() -> Bool {
        let here = Bundle.main.bundleURL
        guard here.pathExtension == "app", !isInApplications,
              !UserDefaults.standard.bool(forKey: "declinedMove") else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Move ClipStack to Applications?"
        a.informativeText = "That way it can start when you log in and keeps working after you tidy up Downloads."
        a.addButton(withTitle: "Move to Applications")
        a.addButton(withTitle: "Not Now")
        guard a.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: "declinedMove")
            return false
        }

        // A copy that is already installed and running makes way for this one.
        if let id = Bundle.main.bundleIdentifier {
            let me = ProcessInfo.processInfo.processIdentifier
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where app.processIdentifier != me {
                app.terminate()
            }
            Thread.sleep(forTimeInterval: 0.6)
        }

        let fm = FileManager.default
        var destination = URL(fileURLWithPath: "/Applications/ClipStack.app")
        do {
            if fm.fileExists(atPath: destination.path) { try fm.trashItem(at: destination, resultingItemURL: nil) }
            try fm.copyItem(at: here, to: destination)
        } catch {
            destination = URL(fileURLWithPath: NSHomeDirectory() + "/Applications/ClipStack.app")
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            guard (try? fm.copyItem(at: here, to: destination)) != nil else { return false }
        }
        // You already chose to open it, so the download flag can go; leaving it
        // would make macOS run the copy from a temporary location every time.
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])
        if let original = originalLocation(of: here), original != destination {
            try? fm.trashItem(at: original, resultingItemURL: nil)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    /// Where the app really is: macOS runs downloaded apps from a temporary
    /// copy ("App Translocation") until they are moved.
    static func originalLocation(of url: URL) -> URL? {
        guard let lib = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isSym = dlsym(lib, "SecTranslocateIsTranslocatedURL"),
              let origSym = dlsym(lib, "SecTranslocateCreateOriginalPathForURL") else { return url }
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<DarwinBoolean>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        var translocated: DarwinBoolean = false
        _ = unsafeBitCast(isSym, to: IsTranslocated.self)(url as CFURL, &translocated, nil)
        guard translocated.boolValue else { return url }
        return unsafeBitCast(origSym, to: OriginalPath.self)(url as CFURL, nil)?.takeRetainedValue() as URL?
    }

    /// The recorder that macos/install.sh set up does the same job as the app.
    static func offerToRetireLaunchAgent() {
        let plist = NSHomeDirectory() + "/Library/LaunchAgents/com.clipstack.watcher.plist"
        guard FileManager.default.fileExists(atPath: plist) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Turn off the old background recorder?"
        a.informativeText = "You set up ClipStack with install.sh before. The app now does the recording, so that copy isn't needed. Your history stays as it is."
        a.addButton(withTitle: "Turn Off")
        a.addButton(withTitle: "Keep It")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/com.clipstack.watcher"])
        try? FileManager.default.removeItem(atPath: plist)
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
