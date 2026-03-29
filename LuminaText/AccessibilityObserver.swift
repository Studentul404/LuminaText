    
import AppKit
import ApplicationServices

// MARK: - TextContext

struct TextContext {
    let textBeforeCursor: String
    let selectedText: String
    let appBundleID: String
    /// FIM prompt ready for direct injection into the backend.
    /// Format: <|fim_prefix|>{prefix}<|fim_suffix|>{suffix}<|fim_middle|>
    /// Empty when there is no text after the cursor (falls back to plain completion).
    let fimPrompt: String
}

// MARK: - AccessibilityObserver

final class AccessibilityObserver {
    static let shared = AccessibilityObserver()

    @MainActor var onTextChanged: ((TextContext, CGRect) -> Void)?
    @MainActor var onSelectionChanged: ((String, CGRect) -> Void)?

    private var observer: AXObserver?
    private var observedElement: AXUIElement?   // app-level element
    private var focusedElement: AXUIElement?    // current focused text element
    private var lastPrompt: String = ""
    private var lastSelection: String = ""
    private var debounceTask: Task<Void, Never>?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private static let selectionMinChars = 3    // suppress FAB for tiny accidental selections

    private var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }
    private init() {}

    // MARK: - Start / Stop

    func startObserving() {
        guard isAccessibilityTrusted else { return }
        setupKeyEventTap()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        if let app = NSWorkspace.shared.frontmostApplication { attachObserver(to: app) }
    }

    func stopObserving() {
        removeCurrentObserver()
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        eventTap = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Key event tap (unchanged)

    private func setupKeyEventTap() {
        guard isAccessibilityTrusted else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard type == .keyDown else { return Unmanaged.passRetained(event) }
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let acceptCode = Int64(AppSettings.shared.acceptHotkey.keyCode)
                if keyCode == acceptCode {
                    guard let refcon else { return Unmanaged.passRetained(event) }
                    let obs = Unmanaged<AccessibilityObserver>.fromOpaque(refcon).takeUnretainedValue()
                    Task { @MainActor in await obs.handleTabPressed() }
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        if let tap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = runLoopSource { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
            CGEvent.tapEnable(tap: tap, enable: true)
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
        guard AXObserverCreate(pid, axCallback, &newObserver) == .success, let obs = newObserver else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Register focus + value changes on the app element — these are reliably delivered
        // at the app level. kAXSelectedTextChangedNotification is NOT reliable at app level;
        // we re-subscribe it on the focused element each time focus changes (see resubscribeSelectionNotification).
        let appLevelNotifs: [CFString] = [
            kAXFocusedUIElementChangedNotification as CFString,
            kAXValueChangedNotification as CFString,
        ]
        for notif in appLevelNotifs {
            // Non-fatal if a notification isn't supported by this app
            AXObserverAddNotification(obs, appElement, notif, selfPtr)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedElement = appElement

        Task { @MainActor in
            self.readFocusedElement(in: appElement)
            // Subscribe kAXSelectedTextChangedNotification on the currently focused element
            self.resubscribeSelectionNotification(obs: obs, appElement: appElement, selfPtr: selfPtr)
        }
    }

    /// Finds the currently focused element and registers kAXSelectedTextChangedNotification on it.
    /// Must be called on MainActor so `focusedElement` is safe to write.
    @MainActor
    private func resubscribeSelectionNotification(obs: AXObserver, appElement: AXUIElement, selfPtr: UnsafeMutableRawPointer) {
        // Remove from previous focused element if any
        if let prev = focusedElement {
            AXObserverRemoveNotification(obs, prev, kAXSelectedTextChangedNotification as CFString)
        }

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let fv = focusedRef, CFGetTypeID(fv) == AXUIElementGetTypeID()
        else {
            focusedElement = nil
            return
        }
        let focused = fv as! AXUIElement
        focusedElement = focused
        AXObserverAddNotification(obs, focused, kAXSelectedTextChangedNotification as CFString, selfPtr)
    }

    private func removeCurrentObserver() {
        if let obs = observer, let el = observedElement {
            let appNotifs: [CFString] = [
                kAXFocusedUIElementChangedNotification as CFString,
                kAXValueChangedNotification as CFString,
            ]
            for n in appNotifs { AXObserverRemoveNotification(obs, el, n) }
        }
        if let obs = observer, let fe = focusedElement {
            AXObserverRemoveNotification(obs, fe, kAXSelectedTextChangedNotification as CFString)
        }
        observer = nil
        observedElement = nil
        focusedElement = nil
    }

    // MARK: - AX Callback

    private let axCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let obs = Unmanaged<AccessibilityObserver>.fromOpaque(refcon).takeUnretainedValue()
        let notif = notification as String
        Task { @MainActor in obs.elementChanged(element, notification: notif) }
    }

    // MARK: - Element reading

    @MainActor
    private func elementChanged(_ element: AXUIElement, notification: String) {
        // When focus changes, re-bind kAXSelectedTextChangedNotification to the new focused element
        if notification == (kAXFocusedUIElementChangedNotification as String),
           let obs = observer, let appEl = observedElement {
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            resubscribeSelectionNotification(obs: obs, appElement: appEl, selfPtr: selfPtr)
        }

        // For selection changes: skip autocomplete debounce, read immediately
        if notification == (kAXSelectedTextChangedNotification as String) {
            let target = resolveTarget(from: element)
            readSelectionOnly(from: target)
            return
        }

        // For value/focus changes: debounce before full read
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(AppSettings.shared.triggerDelay * 1_000_000_000))
            if !Task.isCancelled { self.readFocusedElement(in: element) }
        }
    }

    /// Resolves the focused text element from a given element (app or focused element).
    @MainActor
    private func resolveTarget(from element: AXUIElement) -> AXUIElement {
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
           let value = focusedValue, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return value as! AXUIElement
        }
        return element
    }

    /// Fast path for kAXSelectedTextChangedNotification — only fires onSelectionChanged.
    @MainActor
    private func readSelectionOnly(from element: AXUIElement) {
        var selValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selValue) == .success,
              let sel = selValue as? String
        else {
            if lastSelection != "" {
                lastSelection = ""
                onSelectionChanged?("", .zero)
            }
            return
        }

        guard sel != lastSelection else { return }
        lastSelection = sel

        // Minimum character threshold — suppress FAB for tiny accidental selections
        guard sel.count >= Self.selectionMinChars else {
            onSelectionChanged?("", .zero)
            return
        }

        let rect = axCGRectToScreen(getCursorScreenRect(from: element))
        onSelectionChanged?(sel, rect)
    }

    @MainActor
    private func readFocusedElement(in element: AXUIElement) {
        let target = resolveTarget(from: element)
        guard let context = extractTextContext(from: target) else { return }

        if context.selectedText != lastSelection {
            lastSelection = context.selectedText
            if context.selectedText.count >= Self.selectionMinChars {
                let rect = axCGRectToScreen(getCursorScreenRect(from: target))
                onSelectionChanged?(context.selectedText, rect)
            } else {
                onSelectionChanged?("", .zero)
            }
        }
        guard context.textBeforeCursor != lastPrompt else { return }
        lastPrompt = context.textBeforeCursor
        let rect = axCGRectToScreen(getCursorScreenRect(from: target))
        onTextChanged?(context, rect)
    }

    private func extractTextContext(from element: AXUIElement) -> TextContext? {
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return nil }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let fullText = valueRef as? String else { return nil }

        // Resolve cursor position from selected-text range
        var rangeValue: CFTypeRef?
        var cursorOffset = fullText.count   // default: end of text
        var selectionLength = 0
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rv = rangeValue, CFGetTypeID(rv) == AXValueGetTypeID() {
            let rangeRef = rv as! AXValue
            if AXValueGetType(rangeRef) == .cfRange {
                var range = CFRange(location: 0, length: 0)
                if AXValueGetValue(rangeRef, .cfRange, &range) {
                    cursorOffset = min(range.location, fullText.count)
                    selectionLength = range.length
                }
            }
        }

        let cursorIndex = fullText.index(fullText.startIndex, offsetBy: cursorOffset, limitedBy: fullText.endIndex) ?? fullText.endIndex
        let textBefore = String(fullText[..<cursorIndex])
        guard !textBefore.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let prefix = textBefore.count > 512 ? String(textBefore.suffix(512)) : textBefore

        // Suffix for FIM: text after cursor, capped at 128 chars
        let textAfter: String
        if cursorIndex < fullText.endIndex {
            let raw = String(fullText[cursorIndex...])
            textAfter = raw.count > 128 ? String(raw.prefix(128)) : raw
        } else {
            textAfter = ""
        }

        // Build FIM prompt only when there is meaningful suffix
        let fimPrompt: String
        if !textAfter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fimPrompt = "<|fim_prefix|>\(prefix)<|fim_suffix|>\(textAfter)<|fim_middle|>"
        } else {
            fimPrompt = ""
        }

        var selectedText = ""
        var selValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selValue) == .success {
            selectedText = (selValue as? String) ?? ""
        }

        return TextContext(
            textBeforeCursor: prefix,
            selectedText: selectedText,
            appBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
            fimPrompt: fimPrompt
        )
    }

    // MARK: - Coordinate translation

    /// AX reports rects in CG global coordinates (origin top-left of primary screen, y increases downward).
    /// NSWindow.setFrame also uses CG global coordinates, so no conversion is needed for window placement.
    /// However, to find the *correct* NSScreen for multi-monitor support we match against CG-space screen frames.
    /// Returns the rect unchanged — callers may use it directly with setFrame.
    /// The screen-matching in FABWindowController.show() is what needs to use this correctly.
    private func axCGRectToScreen(_ rect: CGRect) -> CGRect {
        // AX rect is already in CG screen space. Validate it falls within a known screen.
        // If not (e.g., zero rect from fallback), return as-is — callers handle .zero.
        guard rect != .zero else { return rect }
        return rect
    }

    func getCursorScreenRect(from element: AXUIElement) -> CGRect {
        // Primary path: parameterized bounds for the selection/insertion range
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rv = rangeValue, CFGetTypeID(rv) == AXValueGetTypeID() {
            let rangeRef = rv as! AXValue
            if AXValueGetType(rangeRef) == .cfRange {
                var range = CFRange(location: 0, length: 0)
                if AXValueGetValue(rangeRef, .cfRange, &range) {
                    // Use the end of the selection as anchor for FAB placement
                    let anchor = CFRange(location: range.location + max(range.length - 1, 0), length: 1)
                    var anchorMut = anchor
                    if let axRange = AXValueCreate(.cfRange, &anchorMut) {
                        var boundsRef: CFTypeRef?
                        if AXUIElementCopyParameterizedAttributeValue(
                            element, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &boundsRef
                        ) == .success,
                           let bv = boundsRef, CFGetTypeID(bv) == AXValueGetTypeID() {
                            let bav = bv as! AXValue
                            if AXValueGetType(bav) == .cgRect {
                                var rect = CGRect.zero
                                if AXValueGetValue(bav, .cgRect, &rect), rect != .zero {
                                    return rect
                                }
                            }
                        }
                    }
                }
            }
        }

        // Fallback: element bounding box — bottom-left corner in CG space
        var origin = CGPoint.zero
        var size = CGSize.zero
        var posRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
           let v = posRef, CFGetTypeID(v) == AXValueGetTypeID() {
            let pv = v as! AXValue
            if AXValueGetType(pv) == .cgPoint { AXValueGetValue(pv, .cgPoint, &origin) }
        }
        var sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let v = sizeRef, CFGetTypeID(v) == AXValueGetTypeID() {
            let sv = v as! AXValue
            if AXValueGetType(sv) == .cgSize { AXValueGetValue(sv, .cgSize, &size) }
        }
        // origin.y is the top of the element in CG space (y increases downward).
        // Return bottom edge: origin.y + size.height, width = element width, height = 1pt sentinel.
        return CGRect(x: origin.x, y: origin.y + size.height, width: size.width, height: 1)
    }

    // MARK: - Injection (unchanged)

    @MainActor func injectTransformResult(_ text: String) { injectText(text) }

    @MainActor
    func handleTabPressed() async {
        guard let suggestion = OverlayWindowController.currentSuggestion, !suggestion.isEmpty else { return }
        NotificationCenter.default.post(name: .suggestionAccepted, object: nil)
        injectText(suggestion)
    }

    @MainActor
    private func injectText(_ text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let utf16 = Array(text.utf16)
        guard let dn = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        dn.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        dn.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        lastPrompt = ""
    }
}