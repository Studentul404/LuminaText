// File: AccessibilityObserver.swift
import AppKit
import ApplicationServices

// MARK: - TextContext

struct TextContext {
    let textBeforeCursor: String
    let selectedText:     String
    let appBundleID:      String
    let appName:          String
    let fullText:         String
}

// MARK: - AccessibilityObserver

final class AccessibilityObserver {
    static let shared = AccessibilityObserver()

    @MainActor var onTextChanged:        ((TextContext, CGRect) -> Void)?
    @MainActor var onSelectionTransform: ((String, CGRect) -> Void)?

    private var axObserver:      AXObserver?
    private var observedElement:  AXUIElement?
    private var lastPrompt:      String = ""
    private var debounceTask:    Task<Void, Never>?
    private var eventTap:        CFMachPort?
    private var tapRunLoopSrc:   CFRunLoopSource?
    private var currentAppName:  String = ""
    private var currentBundle:   String = ""

    private var isInjecting = false
    private var isTrusted: Bool { AXIsProcessTrusted() }

    private init() {}

    func startObserving() {
        guard isTrusted else { print("[AX] No accessibility access."); return }
        setupEventTap()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if let app = NSWorkspace.shared.frontmostApplication { attach(to: app) }
    }

    func stopObserving() {
        detachCurrent()
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = tapRunLoopSrc {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            tapRunLoopSrc = nil
        }
        eventTap = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Event tap

    private func setupEventTap() {
        guard isTrusted else { return }

        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard type == .keyDown, let refcon = refcon else {
                    return Unmanaged.passRetained(event)
                }

                let obs = Unmanaged<AccessibilityObserver>.fromOpaque(refcon).takeUnretainedValue()
                let keyCode  = Int(event.getIntegerValueField(.keyboardEventKeycode))
                let rawFlags = event.flags.rawValue
                let s        = AppSettings.shared

                let matches: (HotkeyConfig) -> Bool = { hk in
                    guard keyCode == hk.keyCode else { return false }
                    if hk.modifierFlags == 0 { return true }
                    return rawFlags & hk.modifierFlags != 0
                }

                if keyCode == 48 { // Tab
                    if let suggestion = OverlayWindowController.currentSuggestion,
                       !suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Task { @MainActor in await obs.handleAccept() }
                        return nil
                    }
                    return Unmanaged.passRetained(event)
                }

                if matches(s.acceptHotkey) {
                    Task { @MainActor in await obs.handleAccept() }
                    return nil
                } else if matches(s.dismissHotkey) {
                    Task { @MainActor in obs.handleDismiss() }
                    return nil
                }

                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = eventTap else { print("[AX] Failed to create event tap"); return }
        tapRunLoopSrc = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let src = tapRunLoopSrc { CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: - App switching

    @objc private func frontAppChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        currentAppName = app.localizedName ?? ""
        currentBundle  = app.bundleIdentifier ?? ""
        attach(to: app)
    }

    private func attach(to app: NSRunningApplication) {
        guard AXIsProcessTrusted(), app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        detachCurrent()

        let pid        = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var raw: AXObserver?
        guard AXObserverCreate(pid, axCallbackFn, &raw) == .success, let obs = raw else { return }

        let ptr    = Unmanaged.passUnretained(self).toOpaque()
        let notifs: [CFString] = [
            kAXFocusedUIElementChangedNotification as CFString,
            kAXValueChangedNotification as CFString,
            kAXSelectedTextChangedNotification as CFString
        ]
        for n in notifs { AXObserverAddNotification(obs, appElement, n, ptr) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        axObserver      = obs
        observedElement = appElement
        Task { @MainActor in self.readFocused(in: appElement) }
    }

    private func detachCurrent() {
        guard let obs = axObserver, let el = observedElement else { return }
        let notifs: [CFString] = [
            kAXFocusedUIElementChangedNotification as CFString,
            kAXValueChangedNotification as CFString,
            kAXSelectedTextChangedNotification as CFString
        ]
        for n in notifs { AXObserverRemoveNotification(obs, el, n) }
        axObserver      = nil
        observedElement = nil
    }

    private let axCallbackFn: AXObserverCallback = { (_, element, _, refcon) in
        guard let refcon = refcon else { return }
        let obs = Unmanaged<AccessibilityObserver>.fromOpaque(refcon).takeUnretainedValue()
        Task { @MainActor in obs.elementChanged(element) }
    }

    @MainActor
    private func elementChanged(_ element: AXUIElement) {
        guard !isInjecting else { return }
        debounceTask?.cancel()
        debounceTask = Task {
            let ns = UInt64(AppSettings.shared.triggerDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            self.readFocused(in: element)
        }
    }

    @MainActor
    private func readFocused(in element: AXUIElement) {
        var focusedRef: CFTypeRef?
        var target = element
        if AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let v = focusedRef, CFGetTypeID(v) == AXUIElementGetTypeID() {
            target = v as! AXUIElement
        }

        guard let ctx = extractContext(from: target) else { return }
        guard ctx.textBeforeCursor != lastPrompt else { return }
        lastPrompt = ctx.textBeforeCursor

        let rect = selectedTextRect(for: target)

        if !ctx.selectedText.isEmpty && AppSettings.shared.transformMode != .autocomplete {
            onSelectionTransform?(ctx.selectedText, rect)
            return
        }
        onTextChanged?(ctx, rect)
    }

    private func extractContext(from element: AXUIElement) -> TextContext? {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return nil }

        var valRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valRef) == .success,
              let fullText = valRef as? String else { return nil }

        var rangeRef: CFTypeRef?
        var cursorIdx = fullText.endIndex
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let v = rangeRef, CFGetTypeID(v) == AXValueGetTypeID() {
            let axVal = v as! AXValue
            if AXValueGetType(axVal) == .cfRange {
                var cfr = CFRange(location: 0, length: 0)
                if AXValueGetValue(axVal, .cfRange, &cfr) {
                    let idx = min(cfr.location, fullText.count)
                    cursorIdx = fullText.index(fullText.startIndex, offsetBy: idx,
                                               limitedBy: fullText.endIndex) ?? fullText.endIndex
                }
            }
        }

        let before  = String(fullText[..<cursorIdx])
        guard !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let trimmed = before.count > 2048 ? String(before.suffix(2048)) : before

        var selText = ""
        var selRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selRef) == .success {
            selText = (selRef as? String) ?? ""
        }

        return TextContext(
            textBeforeCursor: trimmed,
            selectedText:     selText,
            appBundleID:      currentBundle,
            appName:          currentAppName,
            fullText:         fullText
        )
    }

    // MARK: - Bounding box (refactored)
    //
    // Priority:
    //   1. kAXBoundsForRangeParameterizedAttribute on the insertion-point range — most accurate.
    //   2. kAXBoundsForRangeParameterizedAttribute on the full selected range — good for multi-char selections.
    //   3. Element position + height fallback — last resort.
    //
    // All CGRect values coming from AX are in screen coordinates (top-left origin).
    // NSWindow/NSScreen use bottom-left origin, so we do NOT flip here;
    // callers that need flipping (OverlayWindowController) handle it in positionOverlay/positionFAB.

    func selectedTextRect(for element: AXUIElement) -> CGRect {
        // --- 1. Read the current selected-text range ---
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                                            kAXSelectedTextRangeAttribute as CFString,
                                            &rangeRef) == .success,
              let rv = rangeRef,
              CFGetTypeID(rv) == AXValueGetTypeID()
        else { return elementFallbackRect(for: element) }

        let axRangeVal = rv as! AXValue
        guard AXValueGetType(axRangeVal) == .cfRange else { return elementFallbackRect(for: element) }
        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axRangeVal, .cfRange, &cfRange) else { return elementFallbackRect(for: element) }

        // --- 2. Try insertion-point rect (zero-length range at cursor) ---
        let insertionRange = CFRange(location: max(cfRange.location + cfRange.length - 1, 0), length: 0)
        if let rect = boundsForRange(insertionRange, in: element), rect != .zero {
            return rect
        }

        // --- 3. Try full selection rect ---
        if cfRange.length > 0, let rect = boundsForRange(cfRange, in: element), rect != .zero {
            return rect
        }

        // --- 4. Element-level fallback ---
        return elementFallbackRect(for: element)
    }

    /// Asks the AX API for the screen rect of a given CFRange within an element.
    private func boundsForRange(_ range: CFRange, in element: AXUIElement) -> CGRect? {
        var mutableRange = range
        guard let axValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            axValue,
            &boundsRef
        ) == .success,
              let bv = boundsRef,
              CFGetTypeID(bv) == AXValueGetTypeID()
        else { return nil }

        let bAxVal = bv as! AXValue
        guard AXValueGetType(bAxVal) == .cgRect else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(bAxVal, .cgRect, &rect)
        return rect == .zero ? nil : rect
    }

    /// Falls back to the element's own position + size when range-based lookup fails.
    private func elementFallbackRect(for element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero
        var size   = CGSize.zero

        var posRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
           let v = posRef, CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgPoint, &origin)
        }

        var sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let v = sizeRef, CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgSize, &size)
        }

        // Position the overlay just below the element
        return CGRect(x: origin.x, y: origin.y + size.height, width: size.width, height: 20)
    }

    // Keep old name as an alias so existing call-sites in LuminaApp.swift don't break.
    func cursorRect(for element: AXUIElement) -> CGRect {
        selectedTextRect(for: element)
    }

    // MARK: - Actions

    @MainActor
    func handleAccept() async {
        guard let suggestion = OverlayWindowController.currentSuggestion,
              !suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        NotificationCenter.default.post(name: .suggestionAccepted, object: nil)
        inject(suggestion)
    }

    @MainActor
    func handleDismiss() {
        guard OverlayWindowController.currentSuggestion != nil else { return }
        NotificationCenter.default.post(name: .suggestionDismissed, object: nil)
    }

    @MainActor
    private func inject(_ text: String) {
        isInjecting = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.isInjecting = false }
        }

        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let utf16 = Array(text.utf16)
        guard let dn = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return }

        dn.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        dn.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)

        lastPrompt = ""
    }
}
