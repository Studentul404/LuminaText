import AppKit
import ApplicationServices

// MARK: - TextContext

struct TextContext {
    let textBeforeCursor: String
    let selectedText: String
    let appBundleID: String
}

// MARK: - AccessibilityObserver

final class AccessibilityObserver {
    static let shared = AccessibilityObserver()

    /// Called when the user is typing — Mode A (autocomplete).
    @MainActor var onTextChanged: ((TextContext, CGRect) -> Void)?

    /// Called when the user selects text — Mode B (FAB / transform).
    /// Passes the selected string and the bounding rect of the selection.
    /// Passes an empty string when the selection is cleared.
    @MainActor var onSelectionChanged: ((String, CGRect) -> Void)?

    private var observer: AXObserver?
    private var observedElement: AXUIElement?
    private var lastPrompt: String = ""
    private var lastSelection: String = ""
    private var debounceTask: Task<Void, Never>?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    private init() {}

    // MARK: - Start / Stop

    func startObserving() {
        guard isAccessibilityTrusted else {
            print("[AccessibilityObserver] Cannot start observing: accessibility access not granted.")
            return
        }

        setupKeyEventTap()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        if let app = NSWorkspace.shared.frontmostApplication {
            attachObserver(to: app)
        }
    }

    func stopObserving() {
        removeCurrentObserver()

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        eventTap = nil

        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Key event tap

    private func setupKeyEventTap() {
        guard isAccessibilityTrusted else {
            print("[AccessibilityObserver] Skipping event tap setup: not trusted.")
            return
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard type == .keyDown else { return Unmanaged.passRetained(event) }
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let acceptCode = Int64(AppSettings.shared.acceptHotkeyCode)
                if keyCode == acceptCode {
                    guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                    let observer = Unmanaged<AccessibilityObserver>.fromOpaque(refcon).takeUnretainedValue()
                    Task { @MainActor in
                        await observer.handleTabPressed()
                    }
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        if let tap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            print("[AccessibilityObserver] Could not create event tap — ensure Accessibility is granted and the app is not sandboxed.")
        }
    }

    // MARK: - App switching

    @objc private func frontAppChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        attachObserver(to: app)
    }

    private func attachObserver(to app: NSRunningApplication) {
        guard isAccessibilityTrusted else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        removeCurrentObserver()

        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var newObserver: AXObserver?
        let err = AXObserverCreate(pid, axCallback, &newObserver)
        guard err == .success, let obs = newObserver else {
            print("[AccessibilityObserver] Failed to create AXObserver for PID \(pid), error: \(err.rawValue)")
            return
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let notifications: [CFString] = [
            kAXFocusedUIElementChangedNotification as CFString,
            kAXValueChangedNotification as CFString,
            kAXSelectedTextChangedNotification as CFString
        ]

        for notification in notifications {
            let result = AXObserverAddNotification(obs, appElement, notification, selfPtr)
            if result != .success {
                print("[AccessibilityObserver] Failed to add notification \(notification): \(result.rawValue)")
                return
            }
        }

        let runLoopSource = AXObserverGetRunLoopSource(obs)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        observer = obs
        observedElement = appElement

        Task { @MainActor in
            self.readFocusedElement(in: appElement)
        }
    }

    private func removeCurrentObserver() {
        if let obs = observer, let el = observedElement {
            let notifications: [CFString] = [
                kAXFocusedUIElementChangedNotification as CFString,
                kAXValueChangedNotification as CFString,
                kAXSelectedTextChangedNotification as CFString
            ]
            for notification in notifications {
                AXObserverRemoveNotification(obs, el, notification)
            }
        }
        observer = nil
        observedElement = nil
    }

    // MARK: - AX Callback

    private let axCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon = refcon else { return }
        let observer = Unmanaged<AccessibilityObserver>.fromOpaque(refcon).takeUnretainedValue()
        let notif = notification as String
        Task { @MainActor in
            observer.elementChanged(element, notification: notif)
        }
    }

    // MARK: - Element reading

    @MainActor
    private func elementChanged(_ element: AXUIElement, notification: String) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(AppSettings.shared.triggerDelay * 1_000_000_000))
            if !Task.isCancelled {
                self.readFocusedElement(in: element)
            }
        }
    }

    @MainActor
    private func readFocusedElement(in element: AXUIElement) {
        var focusedValue: CFTypeRef?
        var target = element

        if AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
           let value = focusedValue,
           CFGetTypeID(value) == AXUIElementGetTypeID() {
            target = value as! AXUIElement
        }

        guard let context = extractTextContext(from: target) else { return }

        // --- Mode B: fire selection callback whenever selected text changes ---
        if context.selectedText != lastSelection {
            lastSelection = context.selectedText
            let selRect = getCursorScreenRect(from: target)
            onSelectionChanged?(context.selectedText, selRect)
        }

        // --- Mode A: fire autocomplete callback only when text-before-cursor changes ---
        guard context.textBeforeCursor != lastPrompt else { return }
        lastPrompt = context.textBeforeCursor

        let cursorRect = getCursorScreenRect(from: target)
        onTextChanged?(context, cursorRect)
    }

    private func extractTextContext(from element: AXUIElement) -> TextContext? {
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""
        let validRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
        guard validRoles.contains(role) else { return nil }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let fullText = valueRef as? String else { return nil }

        var rangeValue: CFTypeRef?
        var cursorIndex = fullText.endIndex
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let value = rangeValue,
           CFGetTypeID(value) == AXValueGetTypeID() {
            let rangeRef = value as! AXValue
            if AXValueGetType(rangeRef) == .cfRange {
                var range = CFRange(location: 0, length: 0)
                if AXValueGetValue(rangeRef, .cfRange, &range) {
                    let idx = min(range.location, fullText.count)
                    cursorIndex = fullText.index(fullText.startIndex, offsetBy: idx, limitedBy: fullText.endIndex) ?? fullText.endIndex
                }
            }
        }

        let textBefore = String(fullText[..<cursorIndex])
        guard !textBefore.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let trimmed = textBefore.count > 512 ? String(textBefore.suffix(512)) : textBefore

        var selectedText = ""
        var selValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selValue) == .success {
            selectedText = (selValue as? String) ?? ""
        }

        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        return TextContext(textBeforeCursor: trimmed, selectedText: selectedText, appBundleID: bundleID)
    }

    // MARK: - Cursor screen rect

    func getCursorScreenRect(from element: AXUIElement) -> CGRect {
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let value = rangeValue,
           CFGetTypeID(value) == AXValueGetTypeID() {
            let rangeRef = value as! AXValue
            if AXValueGetType(rangeRef) == .cfRange {
                var range = CFRange(location: 0, length: 0)
                if AXValueGetValue(rangeRef, .cfRange, &range) {
                    let insertionRange = CFRange(location: range.location, length: 0)
                    var mutableInsertionRange = insertionRange
                    if let axRange = AXValueCreate(.cfRange, &mutableInsertionRange) {
                        var boundsRef: CFTypeRef?
                        if AXUIElementCopyParameterizedAttributeValue(
                            element,
                            kAXBoundsForRangeParameterizedAttribute as CFString,
                            axRange,
                            &boundsRef
                        ) == .success,
                           let boundsValue = boundsRef,
                           CFGetTypeID(boundsValue) == AXValueGetTypeID() {
                            let boundsVal = boundsValue as! AXValue
                            if AXValueGetType(boundsVal) == .cgRect {
                                var rect = CGRect.zero
                                if AXValueGetValue(boundsVal, .cgRect, &rect), rect != .zero {
                                    return rect
                                }
                            }
                        }
                    }
                }
            }
        }

        var origin = CGPoint.zero
        var size = CGSize.zero

        var posRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
           let value = posRef,
           CFGetTypeID(value) == AXValueGetTypeID() {
            let pv = value as! AXValue
            if AXValueGetType(pv) == .cgPoint {
                AXValueGetValue(pv, .cgPoint, &origin)
            }
        }

        var sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let value = sizeRef,
           CFGetTypeID(value) == AXValueGetTypeID() {
            let sv = value as! AXValue
            if AXValueGetType(sv) == .cgSize {
                AXValueGetValue(sv, .cgSize, &size)
            }
        }

        return CGRect(x: origin.x, y: origin.y + size.height, width: size.width, height: 20)
    }

    // MARK: - Tab injection

    /// Injects the result of a Mode B (transform) action, replacing the current selection.
    @MainActor
    func injectTransformResult(_ text: String) {
        injectText(text)
    }

    @MainActor
    func handleTabPressed() async {
        guard let suggestion = OverlayWindowController.currentSuggestion, !suggestion.isEmpty else { return }

        NotificationCenter.default.post(name: .suggestionAccepted, object: nil)
        injectText(suggestion)
    }

    @MainActor
    private func injectText(_ text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        let utf16Chars = Array(text.utf16)
        guard let eventDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let eventUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }

        eventDown.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
        eventUp.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)

        eventDown.post(tap: .cgSessionEventTap)
        eventUp.post(tap: .cgSessionEventTap)

        lastPrompt = ""
    }
}