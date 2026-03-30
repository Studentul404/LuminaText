// ═══════════════════════════════════════════════════════════
// AccessibilityObserver.swift — Fixed
// ═══════════════════════════════════════════════════════════
import AppKit
import ApplicationServices

// MARK: - TextContext

struct TextContext {
    let textBeforeCursor: String
    let selectedText: String
    let appBundleID: String
    let fimPrompt: String
}

// MARK: - AccessibilityObserver

final class AccessibilityObserver {
    static let shared = AccessibilityObserver()

    @MainActor var onTextChanged: ((TextContext, CGRect) -> Void)?
    @MainActor var onSelectionChanged: ((String, CGRect) -> Void)?

    private var observer: AXObserver?
    private var observedElement: AXUIElement?
    private var focusedElement: AXUIElement?
    private var lastPrompt: String = ""
    private var lastSelection: String = ""
    private var debounceTask: Task<Void, Never>?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private static let selectionMinChars = 3

    private var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }
    private init() {}

    // MARK: - Lifecycle

    func startObserving() {
        guard isAccessibilityTrusted else { return }
        setupKeyEventTap()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        if let app = NSWorkspace.shared.frontmostApplication {
            attachObserver(to: app)
        }
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

    // MARK: - Key Event Tap

    private func setupKeyEventTap() {
        guard isAccessibilityTrusted else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard type == .keyDown, let refcon = refcon else {
                    return Unmanaged.passRetained(event)
                }
                let keyCode    = event.getIntegerValueField(.keyboardEventKeycode)
                let acceptCode = Int64(AppSettings.shared.acceptHotkey.keyCode)
                if keyCode == acceptCode {
                    let obs = Unmanaged<AccessibilityObserver>.fromOpaque(refcon).takeUnretainedValue()
                    Task { @MainActor in await obs.handleTabPressed() }
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
        }
    }

    // MARK: - App Monitoring

    @objc private func frontAppChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        attachObserver(to: app)
    }

    private func attachObserver(to app: NSRunningApplication) {
        guard isAccessibilityTrusted else { return }
        let bid = app.bundleIdentifier ?? ""
        guard bid != Bundle.main.bundleIdentifier,
              !AppSettings.shared.excludedApps.contains(bid) else {
            removeCurrentObserver()
            return
        }

        removeCurrentObserver()
        let pid        = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var newObserver: AXObserver?
        guard AXObserverCreate(pid, AccessibilityObserver.axCallback, &newObserver) == .success,
              let obs = newObserver else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let notifs: [CFString] = [
            kAXFocusedUIElementChangedNotification as CFString,
            kAXValueChangedNotification as CFString,
        ]
        for notif in notifs {
            AXObserverAddNotification(obs, appElement, notif, selfPtr)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        self.observer        = obs
        self.observedElement = appElement

        Task { @MainActor in
            self.readFocusedElement(in: appElement)
            self.resubscribeSelectionNotification(obs: obs, appElement: appElement, selfPtr: selfPtr)
        }
    }

    @MainActor
    private func resubscribeSelectionNotification(obs: AXObserver, appElement: AXUIElement, selfPtr: UnsafeMutableRawPointer) {
        if let prev = focusedElement {
            AXObserverRemoveNotification(obs, prev, kAXSelectedTextChangedNotification as CFString)
        }

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let fv = focusedRef, CFGetTypeID(fv) == AXUIElementGetTypeID() else {
            focusedElement = nil
            return
        }

        let focused = fv as! AXUIElement
        focusedElement = focused
        AXObserverAddNotification(obs, focused, kAXSelectedTextChangedNotification as CFString, selfPtr)
    }

    private func removeCurrentObserver() {
        if let obs = observer, let el = observedElement {
            AXObserverRemoveNotification(obs, el, kAXFocusedUIElementChangedNotification as CFString)
            AXObserverRemoveNotification(obs, el, kAXValueChangedNotification as CFString)
        }
        if let obs = observer, let fe = focusedElement {
            AXObserverRemoveNotification(obs, fe, kAXSelectedTextChangedNotification as CFString)
        }
        observer        = nil
        observedElement = nil
        focusedElement  = nil
    }

    // FIX: axCallback must be a static (free) function, NOT a stored `let` property.
    //
    // In the original code:
    //   private let axCallback: AXObserverCallback = { ... }
    //
    // A Swift closure assigned to a variable of a C-function-pointer type
    // (AXObserverCallback = @convention(c) (...) -> Void) is only valid as long
    // as the closure literal itself is kept alive.  When stored in a `let`
    // property and passed to AXObserverCreate, the compiler may emit the address
    // of a temporary thunk — behaviour is undefined and causes SIGSEGV on ARM64
    // under certain optimization levels.
    //
    // A `static` (or top-level) function with `@convention(c)` is a true C
    // function pointer — stable address, no captures, no ARC involvement.
    private static let axCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon = refcon else { return }
        let obs   = Unmanaged<AccessibilityObserver>.fromOpaque(refcon).takeUnretainedValue()
        let notif = notification as String
        Task { @MainActor in obs.elementChanged(element, notification: notif) }
    }

    // MARK: - Logic & Extraction

    @MainActor
    private func elementChanged(_ element: AXUIElement, notification: String) {
        if notification == (kAXFocusedUIElementChangedNotification as String),
           let obs = observer, let appEl = observedElement {
            resubscribeSelectionNotification(
                obs: obs, appElement: appEl,
                selfPtr: Unmanaged.passUnretained(self).toOpaque()
            )
        }

        if notification == (kAXSelectedTextChangedNotification as String) {
            readSelectionOnly(from: resolveTarget(from: element))
            return
        }

        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(AppSettings.shared.triggerDelay * 1_000_000_000))
            if !Task.isCancelled { self.readFocusedElement(in: element) }
        }
    }

    @MainActor
    private func resolveTarget(from element: AXUIElement) -> AXUIElement {
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
           let value = focusedValue, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return value as! AXUIElement
        }
        return element
    }

    @MainActor
    private func readSelectionOnly(from element: AXUIElement) {
        var selValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selValue) == .success,
           let sel = selValue as? String, sel.count >= Self.selectionMinChars {
            guard sel != lastSelection else { return }
            lastSelection = sel
            onSelectionChanged?(sel, getCursorScreenRect(from: element))
        } else {
            if !lastSelection.isEmpty {
                lastSelection = ""
                onSelectionChanged?("", .zero)
            }
        }
    }

    @MainActor
    private func readFocusedElement(in element: AXUIElement) {
        let target = resolveTarget(from: element)
        guard let context = extractTextContext(from: target) else { return }

        if context.selectedText.count >= Self.selectionMinChars && context.selectedText != lastSelection {
            lastSelection = context.selectedText
            onSelectionChanged?(context.selectedText, getCursorScreenRect(from: target))
        }

        guard context.textBeforeCursor != lastPrompt else { return }
        lastPrompt = context.textBeforeCursor
        onTextChanged?(context, getCursorScreenRect(from: target))
    }

    private func extractTextContext(from element: AXUIElement) -> TextContext? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let fullText = valueRef as? String else { return nil }

        var cursorOffset = fullText.count
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &valueRef) == .success,
           let rv = valueRef, CFGetTypeID(rv) == AXValueGetTypeID() {
            let rangeRef = rv as! AXValue
            var range    = CFRange(location: 0, length: 0)
            if AXValueGetValue(rangeRef, .cfRange, &range) {
                cursorOffset = min(max(range.location, 0), fullText.count)
            }
        }

        let cursorIndex = fullText.index(fullText.startIndex, offsetBy: cursorOffset, limitedBy: fullText.endIndex) ?? fullText.endIndex
        let textBefore  = String(fullText[..<cursorIndex])
        let prefix      = String(textBefore.suffix(512))
        let suffix      = String(fullText[cursorIndex...].prefix(128))
        let fimPrompt   = !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "<|fim_prefix|>\(prefix)<|fim_suffix|>\(suffix)<|fim_middle|>"
            : ""

        var selectedText = ""
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &valueRef) == .success {
            selectedText = (valueRef as? String) ?? ""
        }

        return TextContext(
            textBeforeCursor: prefix,
            selectedText:     selectedText,
            appBundleID:      NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
            fimPrompt:        fimPrompt
        )
    }

    func getCursorScreenRect(from element: AXUIElement) -> CGRect {
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rv = rangeValue, CFGetTypeID(rv) == AXValueGetTypeID() {
            let rangeRef = rv as! AXValue
            var range    = CFRange(location: 0, length: 0)
            if AXValueGetValue(rangeRef, .cfRange, &range) {
                let anchor    = CFRange(location: range.location + max(range.length - 1, 0), length: 1)
                var anchorMut = anchor
                if let axRange = AXValueCreate(.cfRange, &anchorMut) {
                    var boundsRef: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &boundsRef) == .success,
                       let bv = boundsRef, CFGetTypeID(bv) == AXValueGetTypeID(),
                       let rect = extractCGRect(from: bv as! AXValue) {
                        return rect
                    }
                }
            }
        }
        return .zero
    }

    private func extractCGRect(from value: AXValue) -> CGRect? {
        var rect = CGRect.zero
        return AXValueGetValue(value, .cgRect, &rect) ? rect : nil
    }

    // MARK: - Injection

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
        let utf16 = Array(text.utf16)
        guard let dn = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        dn.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        dn.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
