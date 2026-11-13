// NotchPeek — shows the menu bar icons hiding behind the MacBook notch.
// Hover the notch (or press ⌃⌥Space) and a strip drops out of the notch with
// only the icons macOS can't fit. Click one and its real menu opens.
// Needs Accessibility permission only. No settings, never moves your icons.

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import Sparkle

// MARK: - Preferences

enum StripStyle: String, CaseIterable { case glass, black, color }

enum Prefs {
    static let d = UserDefaults.standard
    static func register() {
        d.register(defaults: ["style": StripStyle.glass.rawValue, "color": "#1E1E1EE6",
                              "hotKeyCode": kVK_Space, "hotKeyMods": controlKey | optionKey,
                              "hover": true, "menuBarIcon": true, "showAll": false])
    }
    static var style: StripStyle { StripStyle(rawValue: d.string(forKey: "style") ?? "") ?? .glass }
    static var color: NSColor { NSColor(hex: d.string(forKey: "color") ?? "") ?? .black }
    static var hotKeyCode: Int { d.integer(forKey: "hotKeyCode") }
    static var hotKeyMods: Int { d.integer(forKey: "hotKeyMods") }
    static var hover: Bool { d.bool(forKey: "hover") }
    static var showAll: Bool { d.bool(forKey: "showAll") }
    static var menuBarIcon: Bool { d.bool(forKey: "menuBarIcon") }
    static var shortcutText: String { hotKeyCode < 0 ? "none" : ShortcutText.describe(code: hotKeyCode, mods: hotKeyMods) }
}

extension NSColor {
    convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces); if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let a = h.count == 8 ? CGFloat(v & 0xFF) / 255 : 1
        let rgb = h.count == 8 ? v >> 8 : v
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: a)
    }
    var hex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255), Int(c.alphaComponent * 255))
    }
    var isLight: Bool {
        let c = usingColorSpace(.sRGB) ?? self
        return (0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent) > 0.6 && c.alphaComponent > 0.4
    }
}

enum ShortcutText {
    static func describe(code: Int, mods: Int) -> String {
        var t = ""
        if mods & controlKey != 0 { t += "⌃" }
        if mods & optionKey != 0 { t += "⌥" }
        if mods & shiftKey != 0 { t += "⇧" }
        if mods & cmdKey != 0 { t += "⌘" }
        return t + keyName(code)
    }
    static func keyName(_ code: Int) -> String {
        let special: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
            kVK_Delete: "⌫", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
            kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        if let s = special[code] { return s }
        let src = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0, len = 0
        var chars = [UniChar](repeating: 0, count: 4)
        data.withUnsafeBytes { raw in
            _ = UCKeyTranslate(raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!, UInt16(code), UInt16(kUCKeyActionDisplay),
                               0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }
    static func carbonMods(_ f: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if f.contains(.control) { m |= controlKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.shift) { m |= shiftKey }
        if f.contains(.command) { m |= cmdKey }
        return m
    }
}

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
    var onSettings: (() -> Void)?
    var onCheckUpdates: (() -> Void)?
    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard let notch = Notch.current() ?? fallbackAnchor() else { return }
        let all = MenuBarScanner.items()
        let hidden = all.filter { notch.isHidden($0) }
        let list = Prefs.showAll || hidden.isEmpty ? all : hidden
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

        let style = Prefs.style
        let bg = background(style: style, content: row)
        let menu = NSMenu()
        let allItem = NSMenuItem(title: "Show All Icons", action: #selector(toggleShowAll), keyEquivalent: "")
        allItem.target = self; allItem.state = Prefs.showAll ? .on : .off
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(allItem); menu.addItem(login); menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Shortcut: \(Prefs.shortcutText)\(Prefs.hover ? ", or hover the notch" : "")", action: nil, keyEquivalent: ""))
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let upd = NSMenuItem(title: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "")
        upd.target = self
        menu.addItem(upd)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NotchPeek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        bg.menu = menu

        let size = row.fittingSize
        let width = max(size.width, notch.rect.width)
        // Black grows straight out of the notch; glass and colours float just under the bar.
        let drop: CGFloat = style == .black ? 0 : 4
        let frame = NSRect(x: notch.rect.midX - width / 2, y: notch.rect.minY - size.height - drop,
                           width: width, height: size.height)
        // Keep it on screen.
        var f = frame
        let sf = notch.screen.frame
        f.origin.x = min(max(f.minX, sf.minX + 4), sf.maxX - f.width - 4)

        let p = panel ?? makePanel()
        p.contentView = bg
        p.appearance = style == .black ? NSAppearance(named: .darkAqua)
            : style == .color ? NSAppearance(named: Prefs.color.isLight ? .aqua : .darkAqua) : nil
        p.setFrame(f, display: true)
        p.orderFrontRegardless()
        panel = p
        startAutoHide(notch: notch)
    }

    func hide() {
        hideTimer?.invalidate(); hideTimer = nil
        panel?.orderOut(nil)
    }

    private func background(style: StripStyle, content: NSView) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        func pin(_ v: NSView) -> NSView {
            v.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: v.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                content.topAnchor.constraint(equalTo: v.topAnchor),
                content.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            ])
            return v
        }
        switch style {
        case .glass:
            if #available(macOS 26.0, *) {
                let g = NSGlassEffectView()
                g.cornerRadius = 14
                let holder = NSView()
                _ = pin(holder)
                g.contentView = holder
                return g
            }
            let v = NSVisualEffectView()
            v.material = .menu; v.blendingMode = .behindWindow; v.state = .active
            v.wantsLayer = true; v.layer?.cornerRadius = 14; v.layer?.masksToBounds = true
            return pin(v)
        case .black, .color:
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = (style == .black ? NSColor.black : Prefs.color).cgColor
            v.layer?.cornerRadius = style == .black ? 12 : 14
            if style == .black { v.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner] }
            return pin(v)
        }
    }

    @objc func openSettings() { hide(); onSettings?() }
    @objc func checkUpdates() { hide(); onCheckUpdates?() }

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
        UserDefaults.standard.set(!Prefs.showAll, forKey: "showAll")
        show()
    }

    @objc private func toggleLogin() { LoginItem.set(SMAppService.mainApp.status != .enabled) }
}

// MARK: - Triggers

enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
        catch {
            let a = NSAlert(); a.messageText = "Couldn't change Open at Login"; a.informativeText = error.localizedDescription; a.runModal()
        }
    }
}

final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handler: (() -> Void)?

    init(handler: @escaping () -> Void) {
        HotKey.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in HotKey.handler?(); return noErr }, 1, &spec, nil, nil)
    }

    func set(code: Int, mods: Int) {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        guard code >= 0 else { return }
        let id = EventHotKeyID(signature: OSType(0x4E50_4B31), id: 1) // "NPK1"
        RegisterEventHotKey(UInt32(code), UInt32(mods), id, GetApplicationEventTarget(), 0, &ref)
    }
}

final class NotchHover {
    private var enteredAt: Date?
    private var monitors: [Any] = []

    init(onHover: @escaping () -> Void) {
        let check: () -> Void = { [weak self] in
            guard let self, Prefs.hover, let notch = Notch.current() else { return }
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

// MARK: - Settings

final class RecorderButton: NSButton {
    var onChange: (() -> Void)?
    private var recording = false { didSet { refresh() } }
    private var monitor: Any?

    func refresh() { title = recording ? "Type a shortcut…" : Prefs.shortcutText }

    override func mouseDown(with event: NSEvent) {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            let mods = ShortcutText.carbonMods(e.modifierFlags)
            if Int(e.keyCode) == kVK_Escape && mods == 0 { self.stop(); return nil }
            if mods == 0 || mods == shiftKey { NSSound.beep(); return nil } // needs ⌃, ⌥ or ⌘
            UserDefaults.standard.set(Int(e.keyCode), forKey: "hotKeyCode")
            UserDefaults.standard.set(mods, forKey: "hotKeyMods")
            self.stop()
            return nil
        }
    }
    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recording = false; onChange?()
    }
}

struct ShortcutField: NSViewRepresentable {
    @Binding var tick: Int
    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton()
        b.bezelStyle = .rounded
        b.onChange = { tick += 1 }
        b.refresh()
        return b
    }
    func updateNSView(_ b: RecorderButton, context: Context) { b.refresh() }
}

final class SettingsModel: ObservableObject {
    @Published var tick = 0
    @Published var login = LoginItem.isOn { didSet { if login != LoginItem.isOn { LoginItem.set(login) } } }
}

struct SettingsView: View {
    let preview: () -> Void
    let checkUpdates: () -> Void
    @AppStorage("SUAutomaticallyUpdate") var autoUpdate = true
    @AppStorage("hover") var hover = true
    @AppStorage("style") var style = StripStyle.glass.rawValue
    @AppStorage("color") var colorHex = "#1E1E1EE6"
    @AppStorage("menuBarIcon") var menuBarIcon = true
    @AppStorage("showAll") var showAll = false
    @ObservedObject var model = SettingsModel()

    var body: some View {
        Form {
            Section("Open") {
                LabeledContent("Keyboard shortcut") {
                    HStack {
                        ShortcutField(tick: $model.tick).frame(width: 150)
                        Button("Clear") {
                            UserDefaults.standard.set(-1, forKey: "hotKeyCode"); model.tick += 1
                        }
                    }
                }
                Toggle("Open when the pointer touches the notch", isOn: $hover)
            }
            Section("Look") {
                Picker("Background", selection: $style) {
                    Text("Glass (matches the menu bar)").tag(StripStyle.glass.rawValue)
                    Text("Black (grows out of the notch)").tag(StripStyle.black.rawValue)
                    Text("Custom colour").tag(StripStyle.color.rawValue)
                }
                if style == StripStyle.color.rawValue {
                    ColorPicker("Colour", selection: Binding(
                        get: { Color(nsColor: NSColor(hex: colorHex) ?? .black) },
                        set: { colorHex = NSColor($0).hex }), supportsOpacity: true)
                }
                Button("Preview") { preview() }
            }
            Section("General") {
                Toggle("Always show every icon, not just hidden ones", isOn: $showAll)
                Toggle("Show NotchPeek in the menu bar", isOn: $menuBarIcon)
                Toggle("Open at login", isOn: $model.login)
            }
            Section("Updates") {
                Toggle("Install updates automatically", isOn: $autoUpdate)
                LabeledContent("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")") {
                    Button("Check Now") { checkUpdates() }
                }
            }
            Text("Lost the menu bar icon behind the notch? Open NotchPeek from Applications again to get back here.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let strip = Strip()
    var hotKey: HotKey?
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    var updater: SPUStandardUpdaterController?
    var hover: NotchHover?
    var escMonitor: Any?, clickMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        Prefs.register()
        let args = CommandLine.arguments
        if args.contains("--list") { listAndExit() }
        strip.onSettings = { [weak self] in self?.showSettings() }
        strip.onCheckUpdates = { [weak self] in self?.checkForUpdates() }
        // Updates run even before Accessibility is granted, so a copy stuck at the permission screen still gets fixes.
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

        if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
            waitForTrust()
        } else {
            start()
        }
    }

    private func start() {
        hotKey = HotKey { [weak self] in self?.strip.toggle() }
        applyPrefs()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyPrefs()
        }
        hover = NotchHover { [weak self] in if self?.strip.isVisible == false { self?.strip.show() } }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == UInt16(kVK_Escape) { self?.strip.hide() }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.strip.hide()
        }
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.strip.show() }
        }
        if CommandLine.arguments.contains("--settings") || !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            showSettings()
        }
    }

    private var appliedHotKey: (Int, Int)?
    private func applyPrefs() {
        let hk = (Prefs.hotKeyCode, Prefs.hotKeyMods)
        if appliedHotKey == nil || appliedHotKey! != hk { hotKey?.set(code: hk.0, mods: hk.1); appliedHotKey = hk }
        if Prefs.menuBarIcon && statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "NotchPeek")
            let m = NSMenu()
            m.addItem(withTitle: "Show Hidden Icons", action: #selector(showStrip), keyEquivalent: "").target = self
            m.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
            m.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Quit NotchPeek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = m
            statusItem = item
        } else if !Prefs.menuBarIcon, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item); statusItem = nil
        }
    }

    @objc func showStrip() { strip.show() }

    @objc func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updater?.checkForUpdates(nil)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 400), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "NotchPeek Settings"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView(preview: { [weak self] in self?.strip.show() }, checkUpdates: { [weak self] in self?.checkForUpdates() }))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // Double-clicking the app while it's running opens Settings (the way back if the menu bar icon is off or hidden).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return false
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
