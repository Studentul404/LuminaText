// ═══════════════════════════════════════════════════════════
// LuminaApp.swift — Fixed
// ═══════════════════════════════════════════════════════════
import SwiftUI
import AppKit

@main
struct LuminaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { SettingsView() }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var overlayWindowController: OverlayWindowController?
    var fabWindowController: FABWindowController?
    var settingsWindow: NSWindow?

    private let inferenceManager    = InferenceManager.shared
    private let accessibilityObserver = AccessibilityObserver.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // FIX: Use .accessory (not .regular) for a menu-bar-only app.
        //
        // .regular makes the app appear in the Dock and Cmd-Tab switcher.
        // More critically it changes how WindowServer assigns focus and how
        // NSApplication processes activation events — this conflicts with the
        // nonactivatingPanel windows used by OverlayWindowController and
        // FABWindowController, producing a race in the WindowServer focus
        // pipeline that results in SIGSEGV on launch.
        //
        // .accessory keeps the process invisible to the user (no Dock icon,
        // no Cmd-Tab entry) while still allowing NSPanel floating windows and
        // the menu-bar status item to work correctly.
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = nil

        setupMenuBar()
        setupOverlay()
        requestAccessibilityPermissions()

        accessibilityObserver.onTextChanged = { [weak self] context, cursorRect in
            self?.handleTextChange(context: context, cursorRect: cursorRect)
        }
        accessibilityObserver.onSelectionChanged = { [weak self] selectedText, rect in
            self?.handleSelectionChange(selectedText: selectedText, rect: rect)
        }
        accessibilityObserver.startObserving()

        NotificationCenter.default.addObserver(
            self, selector: #selector(suggestionAccepted),
            name: .suggestionAccepted, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(fabActionCompleted(_:)),
            name: .fabActionCompleted, object: nil
        )
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: "LuminaText")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "LuminaText", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let statusMenuItem = NSMenuItem(title: "Status: Loading model…", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 100
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        let enableItem = NSMenuItem(title: "Enable Completions", action: #selector(toggleEnabled(_:)), keyEquivalent: "e")
        enableItem.target = self
        enableItem.state  = AppSettings.shared.isEnabled ? .on : .off
        enableItem.tag    = 101
        menu.addItem(enableItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",", target: self)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LuminaText", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        self.statusItem?.menu = menu

        Task {
            await inferenceManager.loadModel()
            if let item = menu.item(withTag: 100) {
                item.title = inferenceManager.isReady
                    ? "Status: Model ready ✓"
                    : "Status: No backend available"
            }
        }
    }

    private func setupOverlay() {
        overlayWindowController = OverlayWindowController()
        fabWindowController     = FABWindowController()
    }

    // MARK: - Text / Selection handling

    private func handleTextChange(context: TextContext, cursorRect: CGRect) {
        guard !context.textBeforeCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.overlayWindowController?.hide()
            return
        }
        Task {
            if let result = await inferenceManager.complete(prompt: context.fimPrompt) {
                await MainActor.run {
                    self.overlayWindowController?.show(suggestion: result, near: cursorRect)
                }
            }
        }
    }

    private func handleSelectionChange(selectedText: String, rect: CGRect) {
        guard AppSettings.shared.isEnabled else { return }
        if selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fabWindowController?.hide()
        } else {
            fabWindowController?.show(selectedText: selectedText, near: rect)
        }
    }

    @objc private func fabActionCompleted(_ notification: Notification) {
        guard let result = notification.object as? String, !result.isEmpty else { return }
        fabWindowController?.hide()
        AccessibilityObserver.shared.injectTransformResult(result)
    }

    @objc private func suggestionAccepted() {
        overlayWindowController?.hide()
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        AppSettings.shared.isEnabled.toggle()
        sender.state = AppSettings.shared.isEnabled ? .on : .off
        if !AppSettings.shared.isEnabled {
            overlayWindowController?.hide()
            fabWindowController?.hide()
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            win.title               = "LuminaText Settings"
            win.contentView         = NSHostingView(rootView: SettingsView())
            win.center()
            win.isReleasedWhenClosed = false
            settingsWindow          = win
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func requestAccessibilityPermissions() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            showAccessibilityAlert()
        }
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText     = "Accessibility Access Required"
        alert.informativeText = """
            LuminaText needs Accessibility access to read text context and inject completions.

            Please grant access in System Settings → Privacy & Security → Accessibility.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
        }
    }
}

// MARK: - NSMenu Extension

extension NSMenu {
    @discardableResult
    func addItem(withTitle title: String, action: Selector?, keyEquivalent: String, target: AnyObject?) -> NSMenuItem {
        let item    = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        addItem(item)
        return item
    }
}
