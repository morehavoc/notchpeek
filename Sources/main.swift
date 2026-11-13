// NotchPeek — shows the menu bar icons hiding behind the MacBook notch.
// Hover the notch (or press ⌃⌥Space) and a strip drops out of the notch with
// only the icons macOS can't fit. Click one and its real menu opens.
// Needs Accessibility permission only. No settings, never moves your icons.

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Menu bar items

struct BarItem {
    let element: AXUIElement
    let app: NSRunningApplication
    let frame: CGRect          // AX coordinates: global, top-left origin
    let label: String
}

enum MenuBarScanner {
    static func items() -> [BarItem] {
        var out: [BarItem] = []
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != me {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.25)
            guard let bar: AXUIElement = copy(ax, "AXExtrasMenuBar"),
                  let kids: [AXUIElement] = copy(bar, kAXChildrenAttribute) else { continue }
            for el in kids {
                // Apple's own items (clock, Control Center…) are anonymous groups with no press action
                // on macOS 27; they sit at the right end and stay visible, so only clickable items count.
                var acts: CFArray?
                AXUIElementCopyActionNames(el, &acts)
                guard ((acts as? [String]) ?? []).contains(kAXPressAction) else { continue }
                var pos = CGPoint.zero, size = CGSize.zero
                if let p: AXValue = copy(el, kAXPositionAttribute) { AXValueGetValue(p, .cgPoint, &pos) }
                if let s: AXValue = copy(el, kAXSizeAttribute) { AXValueGetValue(s, .cgSize, &size) }
                let desc: String? = copy(el, kAXDescriptionAttribute)
                let title: String? = copy(el, kAXTitleAttribute)
                let name = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
                let extra = [title, desc].compactMap { $0 }.first { !$0.isEmpty && $0 != name }
                out.append(BarItem(element: el, app: app, frame: CGRect(origin: pos, size: size),
                                   label: extra.map { "\(name): \($0)" } ?? name))
            }
        }
        return out.sorted { $0.frame.minX < $1.frame.minX }
    }

    private static func copy<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? T
    }
}

// MARK: - Notch geometry

struct Notch {
    let screen: NSScreen
    let rect: NSRect           // Cocoa coordinates (bottom-left origin)
    var axRect: CGRect {       // same rect in AX coordinates (top-left of primary screen)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
    var screenAX: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let f = screen.frame
        return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    /// The notched screen, or a fake notch for testing on a Mac without one:
    /// NOTCHPEEK_FAKE_NOTCH="<x>,<width>" (x from the left edge of the main screen) or "1" for centred.
    static func current() -> Notch? {
        for s in NSScreen.screens {
            if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
                let h = s.safeAreaInsets.top
                return Notch(screen: s, rect: NSRect(x: l.maxX, y: s.frame.maxY - h, width: r.minX - l.maxX, height: h))
            }
        }
        if let fake = ProcessInfo.processInfo.environment["NOTCHPEEK_FAKE_NOTCH"], let s = NSScreen.main {
            let h = NSStatusBar.system.thickness
            let parts = fake.split(separator: ",").compactMap { Double($0) }
            let w = parts.count == 2 ? parts[1] : 200
            let x = parts.count == 2 ? parts[0] : s.frame.midX - w / 2
            return Notch(screen: s, rect: NSRect(x: s.frame.minX + x, y: s.frame.maxY - h, width: w, height: h))
        }
        return nil
    }

    /// An item is hidden if any part of it is not in the visible strip right of the notch.
    func isHidden(_ item: BarItem) -> Bool {
        let f = item.frame
        if f.width < 1 || f.height < 1 { return true }
        let s = screenAX
        guard f.maxX > s.minX - 1, f.minX < s.maxX + 1 else { return false } // on another display's bar
        if f.minY > s.minY + rect.height + 4 { return true }                 // pushed off the bar
        return f.minX < axRect.maxX || f.maxX > s.maxX + 1
    }
}

// MARK: - Strip window

final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class ItemButton: NSButton {
    var item: BarItem?
}

final class Strip: NSObject {
    private var panel: StripPanel?
    private var hideTimer: Timer?
    var showAll = UserDefaults.standard.bool(forKey: "showAll")
    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard let notch = Notch.current() ?? fallbackAnchor() else { return }
        let all = MenuBarScanner.items()
        let hidden = all.filter { notch.isHidden($0) }
        let list = showAll || hidden.isEmpty ? all : hidden
        let note: String? = hidden.isEmpty ? (all.isEmpty ? "No menu bar icons found" : "Nothing is hiding. All icons:") : nil

        let iconSize: CGFloat = 22, pad: CGFloat = 8, gap: CGFloat = 6
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = gap
        row.edgeInsets = NSEdgeInsets(top: pad, left: pad + 4, bottom: pad, right: pad + 4)
        if let note {
            let t = NSTextField(labelWithString: note)
            t.textColor = .secondaryLabelColor
            t.font = .systemFont(ofSize: 12)
            row.addArrangedSubview(t)
        }
        for item in list {
            let b = ItemButton()
            b.item = item
            b.isBordered = false
            b.bezelStyle = .regularSquare
            let img = item.app.icon ?? NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil)!
            img.size = NSSize(width: iconSize, height: iconSize)
            b.image = img
            b.imageScaling = .scaleProportionallyUpOrDown
            b.toolTip = item.label
            b.setAccessibilityLabel(item.label)
            b.target = self
            b.action = #selector(clicked(_:))
            b.widthAnchor.constraint(equalToConstant: iconSize + 6).isActive = true
            b.heightAnchor.constraint(equalToConstant: iconSize + 6).isActive = true
            row.addArrangedSubview(b)
        }

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.cgColor
        bg.layer?.cornerRadius = 12
        bg.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner] // round bottom only: grows out of the notch
        row.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            row.topAnchor.constraint(equalTo: bg.topAnchor),
            row.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        let menu = NSMenu()
        let allItem = NSMenuItem(title: "Show All Icons", action: #selector(toggleShowAll), keyEquivalent: "")
        allItem.target = self; allItem.state = showAll ? .on : .off
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(allItem); menu.addItem(login); menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Shortcut: ⌃⌥Space, or hover the notch", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NotchPeek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        bg.menu = menu

        let size = row.fittingSize
        let width = max(size.width, notch.rect.width)
        let frame = NSRect(x: notch.rect.midX - width / 2, y: notch.rect.minY - size.height,
                           width: width, height: size.height)
        // Keep it on screen.
        var f = frame
        let sf = notch.screen.frame
        f.origin.x = min(max(f.minX, sf.minX + 4), sf.maxX - f.width - 4)

        let p = panel ?? makePanel()
        p.contentView = bg
        p.setFrame(f, display: true)
        p.orderFrontRegardless()
        panel = p
        startAutoHide(notch: notch)
    }

    func hide() {
        hideTimer?.invalidate(); hideTimer = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> StripPanel {
        let p = StripPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        return p
    }

    /// Hide once the pointer has been away from the strip and the notch for a moment.
    private func startAutoHide(notch: Notch) {
        hideTimer?.invalidate()
        var awayTicks = 0, wasInside = false
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let p = self.panel else { return }
            let m = NSEvent.mouseLocation
            let zone = p.frame.union(notch.rect).insetBy(dx: -24, dy: -24)
            if zone.contains(m) { wasInside = true; awayTicks = 0 } else { awayTicks += 1 }
            // Opened by the shortcut with the pointer elsewhere: give it 5 s to get there.
            if awayTicks >= (wasInside ? 4 : 25) { self.hide() }
        }
    }

    private func fallbackAnchor() -> Notch? {
        // No notch (external display, desktop Mac): anchor under the middle of the main screen's menu bar.
        guard let s = NSScreen.main else { return nil }
        let h = NSStatusBar.system.thickness
        return Notch(screen: s, rect: NSRect(x: s.frame.midX - 100, y: s.frame.maxY - h, width: 200, height: h))
    }

    @objc private func clicked(_ sender: ItemButton) {
        guard let item = sender.item else { return }
        hide()
        let el = item.element
        DispatchQueue.global(qos: .userInitiated).async {
            AXUIElementSetMessagingTimeout(el, 1.0)
            let r = AXUIElementPerformAction(el, kAXPressAction as CFString)
            // .cannotComplete is normal: the call blocks while the menu is open and times out.
            if r != .success && r != .cannotComplete {
                _ = AXUIElementPerformAction(el, "AXShowMenu" as CFString)
            }
        }
    }

    @objc private func toggleShowAll() {
        showAll.toggle()
        UserDefaults.standard.set(showAll, forKey: "showAll")
        show()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert(); a.messageText = "Couldn't change Open at Login"; a.informativeText = error.localizedDescription; a.runModal()
        }
    }
}

// MARK: - Triggers

final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handler: (() -> Void)?

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        HotKey.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in HotKey.handler?(); return noErr }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4E50_4B31), id: 1) // "NPK1"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}

final class NotchHover {
    private var enteredAt: Date?
    private var monitors: [Any] = []

    init(onHover: @escaping () -> Void) {
        let check: () -> Void = { [weak self] in
            guard let self, let notch = Notch.current() else { return }
            if notch.rect.insetBy(dx: 0, dy: -2).contains(NSEvent.mouseLocation) {
                if self.enteredAt == nil { self.enteredAt = Date() }
                if let t = self.enteredAt, Date().timeIntervalSince(t) > 0.15 { self.enteredAt = .distantFuture; onHover() }
            } else {
                self.enteredAt = nil
            }
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in check() } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { check(); return $0 } as Any)
        // A dwell with no further movement still counts.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in check() }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let strip = Strip()
    var hotKey: HotKey?
    var hover: NotchHover?
    var escMonitor: Any?, clickMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        if args.contains("--list") { listAndExit() }

        if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
            waitForTrust()
        } else {
            start()
        }
    }

    private func start() {
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)) { [weak self] in self?.strip.toggle() }
        hover = NotchHover { [weak self] in if self?.strip.isVisible == false { self?.strip.show() } }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == UInt16(kVK_Escape) { self?.strip.hide() }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.strip.hide()
        }
        if CommandLine.arguments.contains("--show") || !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.strip.show() }
        }
    }

    private func waitForTrust() {
        let a = NSAlert()
        a.messageText = "NotchPeek needs Accessibility access"
        a.informativeText = "It reads where your menu bar icons are and opens their menus. Turn NotchPeek on in System Settings → Privacy & Security → Accessibility. This window closes on its own once it's on."
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Quit")
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if AXIsProcessTrusted() { t.invalidate(); NSApp.abortModal() }
        }
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal()
        if AXIsProcessTrusted() { start(); return }
        if r == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                if AXIsProcessTrusted() { t.invalidate(); self?.start() }
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    private func listAndExit() -> Never {
        let notch = Notch.current()
        print("trusted:", AXIsProcessTrusted(), "notch:", notch.map { "\($0.rect)" } ?? "none")
        for i in MenuBarScanner.items() {
            print(notch?.isHidden(i) == true ? "HIDDEN " : "visible", i.frame, i.label)
        }
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
