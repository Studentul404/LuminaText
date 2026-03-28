import SwiftUI
import AppKit

@main
struct LuminaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var overlayWindowController: OverlayWindowController?
    var fabWindowController: FABWindowController?
    var settingsWindow: NSWindow?

    private let inferenceManager = InferenceManager.shared
    private let accessibilityObserver = AccessibilityObserver.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)

        // Sync with system appearance automatically
        NSApp.appearance = nil

        setupMenuBar()
        setupOverlay()
        requestAccessibilityPermissions()

        // Mode A — autocomplete
        accessibilityObserver.onTextChanged = { [weak self] context, cursorRect in
            guard let self else { return }
            self.handleTextChange(context: context, cursorRect: cursorRect)
        }

        // Mode B — FAB on selection
        accessibilityObserver.onSelectionChanged = { [weak self] selectedText, rect in
            guard let self else { return }
            self.handleSelectionChange(selectedText: selectedText, rect: rect)
        }

        accessibilityObserver.startObserving()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(suggestionAccepted),
            name: .suggestionAccepted,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fabActionCompleted(_:)),
            name: .fabActionCompleted,
            object: nil
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
        enableItem.state = .on
        enableItem.tag = 101
        menu.addItem(enableItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",", target: self)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LuminaText", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem?.menu = menu

        Task {
            await inferenceManager.loadModel()
            await MainActor.run {
                if let item = menu.item(withTag: 100) {
                    item.title = inferenceManager.isReady
                        ? "Status: Model ready ✓"
                        : "Status: Using Ollama fallback"
                }
            }
        }
    }

    // MARK: - Overlay

    private func setupOverlay() {
        overlayWindowController = OverlayWindowController()
        fabWindowController = FABWindowController()
    }

    // MARK: - Text Handling (Mode A)

    private func handleTextChange(context: TextContext, cursorRect: CGRect) {
        guard AppSettings.shared.isEnabled else { return }
        guard !context.textBeforeCursor.trimmingCharacters(in: .whitespaces).isEmpty else {
            overlayWindowController?.hide()
            return
        }

        Task {
            let suggestion = await inferenceManager.complete(prompt: context.textBeforeCursor)
            await MainActor.run {
                if let suggestion, !suggestion.isEmpty {
                    self.overlayWindowController?.show(suggestion: suggestion, near: cursorRect)
                } else {
                    self.overlayWindowController?.hide()
                }
            }
        }
    }

    // MARK: - Selection Handling (Mode B)

    private func handleSelectionChange(selectedText: String, rect: CGRect) {
        guard AppSettings.shared.isEnabled else { return }

        if selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fabWindowController?.hide()
        } else {
            fabWindowController?.show(selectedText: selectedText, near: rect)
        }
    }

    // MARK: - FAB result injection

    @objc private func fabActionCompleted(_ notification: Notification) {
        guard let resultText = notification.object as? String, !resultText.isEmpty else { return }
        fabWindowController?.hide()
        // Inject the transformed text via the accessibility observer's injection path
        AccessibilityObserver.shared.injectTransformResult(resultText)
    }

    @objc private func suggestionAccepted() {
        overlayWindowController?.hide()
    }

    // MARK: - Actions

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
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "LuminaText Settings"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Accessibility

    private func requestAccessibilityPermissions() {
        let options: [String: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !trusted {
            showAccessibilityAlert()
        }
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = "LuminaText needs Accessibility access to read text context and inject completions.\n\nPlease grant access in System Settings → Privacy & Security → Accessibility."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
}

// MARK: - NSMenuItem convenience

extension NSMenu {
    @discardableResult
    func addItem(withTitle title: String, action: Selector?, keyEquivalent: String, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        addItem(item)
        return item
    }
}

extension Notification.Name {
    static let suggestionAccepted = Notification.Name("com.luminatext.suggestionAccepted")
}