import SwiftUI
import AppKit

@main
struct LuminaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { SettingsView() }
    }
}

// MARK: - AppDelegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarItem:  NSStatusItem?
    private var overlayCtrl:    OverlayWindowController?
    private var settingsWindow: NSWindow?
    private let inference  = InferenceManager.shared
    private let axObserver = AccessibilityObserver.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        applyAppearance()
        buildMenuBar()
        overlayCtrl = OverlayWindowController()
        requestAccessibility()
        wireCallbacks()
        axObserver.startObserving()

        NotificationCenter.default.addObserver(self, selector: #selector(onAccepted),
            name: .suggestionAccepted,  object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onDismissed),
            name: .suggestionDismissed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onAppearance),
            name: .appearanceChanged,   object: nil)
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        axObserver.onTextChanged = { [weak self] ctx, rect in
            self?.handleText(ctx: ctx, rect: rect)
        }
        axObserver.onSelectionTransform = { [weak self] text, rect in
            self?.handleTransform(text: text, rect: rect)
        }
    }

    private func handleText(ctx: TextContext, rect: CGRect) {
        guard AppSettings.shared.isEnabled else { return }
        guard !ctx.textBeforeCursor.trimmingCharacters(in: .whitespaces).isEmpty else {
            overlayCtrl?.hide(); return
        }
        overlayCtrl?.showLoading(near: rect)
        Task {
            let result = await inference.complete(prompt: ctx.textBeforeCursor, appName: ctx.appName)
            overlayCtrl?.hideLoading()
            if let s = result, !s.isEmpty {
                overlayCtrl?.show(suggestion: s, near: rect, isTransform: false)
            } else {
                overlayCtrl?.hide()
            }
        }
    }

    private func handleTransform(text: String, rect: CGRect) {
        guard AppSettings.shared.isEnabled else { return }
        let mode = AppSettings.shared.transformMode
        guard mode != .autocomplete else { return }
        overlayCtrl?.showLoading(near: rect)
        Task {
            let result = await inference.transform(text: text, mode: mode)
            overlayCtrl?.hideLoading()
            if let s = result, !s.isEmpty {
                overlayCtrl?.show(suggestion: s, near: rect, isTransform: true)
            } else {
                overlayCtrl?.hide()
            }
        }
    }

    @objc private func onAccepted()  { overlayCtrl?.hide() }
    @objc private func onDismissed() { overlayCtrl?.hide() }
    @objc private func onAppearance() { applyAppearance() }

    // MARK: - Appearance

    private func applyAppearance() {
        NSApp.appearance = AppSettings.shared.useDarkMode
            ? NSAppearance(named: .darkAqua) : nil
    }

    // MARK: - Menu bar

    private func buildMenuBar() {
        let si = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = si.button {
            btn.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: "LuminaText")
            btn.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "LuminaText", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let statusItem = NSMenuItem(title: "Status: Initializing…", action: nil, keyEquivalent: "")
        statusItem.tag = 100
        menu.addItem(statusItem)
        menu.addItem(.separator())

        let enableItem = NSMenuItem(title: "Enable Completions",
                                    action: #selector(toggleEnabled(_:)), keyEquivalent: "e")
        enableItem.target = self
        enableItem.state  = AppSettings.shared.isEnabled ? .on : .off
        enableItem.tag    = 101
        menu.addItem(enableItem)

        // Transform mode submenu
        let tItem = NSMenuItem(title: "Transform Mode", action: nil, keyEquivalent: "")
        let tSub  = NSMenu()
        for mode in TransformMode.allCases {
            let item = NSMenuItem(title: mode.rawValue,
                                  action: #selector(setTransform(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = AppSettings.shared.transformMode == mode ? .on : .off
            tSub.addItem(item)
        }
        tItem.submenu = tSub
        menu.addItem(tItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…",
                     action: #selector(openSettings),
                     keyEquivalent: ",", target: self)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LuminaText",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        si.menu = menu
        statusBarItem = si

        Task {
            await inference.loadModel()
            if let item = menu.item(withTag: 100) {
                item.title = inference.isReady
                    ? "Status: \(inference.backendName) ✓"
                    : "Status: No backend available"
            }
        }
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        AppSettings.shared.isEnabled.toggle()
        sender.state = AppSettings.shared.isEnabled ? .on : .off
        if !AppSettings.shared.isEnabled { overlayCtrl?.hide() }
    }

    @objc private func setTransform(_ sender: NSMenuItem) {
        guard let raw  = sender.representedObject as? String,
              let mode = TransformMode(rawValue: raw) else { return }
        AppSettings.shared.transformMode = mode
        sender.menu?.items.forEach {
            $0.state = ($0.representedObject as? String) == raw ? .on : .off
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 490),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            win.title = "LuminaText Settings"
            win.contentView = NSHostingView(rootView: SettingsView())
            win.center()
            win.isReleasedWhenClosed = false
            settingsWindow = win
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Accessibility

    private func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        if !AXIsProcessTrustedWithOptions(opts as CFDictionary) { showAlert() }
    }

    private func showAlert() {
        let alert = NSAlert()
        alert.messageText     = "Accessibility Access Required"
        alert.informativeText = "LuminaText needs Accessibility access to read text and inject completions.\n\nSystem Settings → Privacy & Security → Accessibility."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
}

// MARK: - NSMenu helper

extension NSMenu {
    @discardableResult
    func addItem(withTitle title: String, action: Selector?,
                 keyEquivalent key: String, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        addItem(item)
        return item
    }
}
