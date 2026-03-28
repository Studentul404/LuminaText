// File: GhostOverlayView.swift
import SwiftUI
import AppKit
import Combine

// MARK: - OverlayWindowController

@MainActor
final class OverlayWindowController {
    static var currentSuggestion: String?

    private var window: NSWindow?
    private var fabWindow: NSWindow?
    private let vm = GhostOverlayViewModel()
    private let fabVM = GhostFABViewModel()

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = NSHostingView(rootView: GhostOverlayView(vm: vm))
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.hasShadow = false
        self.window = win

        let fab = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 320),
            styleMask: [.borderless], backing: .buffered, defer: false)
        fab.contentView = NSHostingView(rootView: GhostFABView(vm: fabVM))
        fab.isOpaque = false
        fab.backgroundColor = .clear
        fab.level = .floating
        fab.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        fab.hasShadow = false
        self.fabWindow = fab
    }

    // MARK: - Suggestion overlay

    func show(suggestion: String, near rect: CGRect, isTransform: Bool = false) {
        Self.currentSuggestion = suggestion
        vm.suggestion  = suggestion
        vm.isTransform = isTransform
        vm.transformMode = AppSettings.shared.transformMode
        vm.isLoading   = false
        positionOverlay(near: rect)
        vm.isVisible = true
        if window?.isVisible == false { window?.orderFront(nil) }
    }

    func showLoading(near rect: CGRect) {
        vm.isLoading  = true
        vm.suggestion = ""
        vm.isVisible  = true
        positionOverlay(near: rect)
        if window?.isVisible == false { window?.orderFront(nil) }
    }

    func hideLoading() { vm.isLoading = false }

    func hide() {
        Self.currentSuggestion = nil
        vm.isVisible = false
        vm.isLoading = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.vm.isVisible else { return }
            self.window?.orderOut(nil)
        }
    }

    // MARK: - FAB menu

    /// Call this when the user has a text selection and you want to offer UserActions.
    func showFAB(near rect: CGRect, selectedText: String, appName: String) {
        fabVM.selectedText = selectedText
        fabVM.appName = appName
        fabVM.actions = AppSettings.shared.userActions
        fabVM.isExpanded = false
        positionFAB(near: rect)
        if fabWindow?.isVisible == false { fabWindow?.orderFront(nil) }
    }

    func hideFAB() {
        fabVM.isExpanded = false
        fabWindow?.orderOut(nil)
    }

    // MARK: - Positioning

    private func positionOverlay(near rect: CGRect) {
        guard let screen = screen(for: rect) else { return }
        let sf = screen.frame
        let w: CGFloat = 900, h: CGFloat = 120
        let x = min(rect.minX, sf.maxX - w)
        let y = sf.maxY - rect.maxY - 5 - h
        let frame = CGRect(x: x, y: y, width: w, height: h)
        if window?.frame.origin != frame.origin { window?.setFrame(frame, display: true) }
    }

    private func positionFAB(near rect: CGRect) {
        guard let screen = screen(for: rect) else { return }
        let sf = screen.frame
        let w: CGFloat = 260, h: CGFloat = 320
        // Place to the right of cursor, flip below screen edge if needed
        var x = rect.maxX + 8
        var y = sf.maxY - rect.minY - h
        if x + w > sf.maxX { x = rect.minX - w - 8 }
        if y < sf.minY { y = sf.minY + 8 }
        fabWindow?.setFrame(CGRect(x: x, y: y, width: w, height: h), display: true)
    }

    private func screen(for rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(rect.origin) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

// MARK: - Overlay ViewModel

final class GhostOverlayViewModel: ObservableObject {
    @Published var suggestion:    String        = ""
    @Published var isVisible:     Bool          = false
    @Published var isTransform:   Bool          = false
    @Published var transformMode: TransformMode = .autocomplete
    @Published var isLoading:     Bool          = false
}

// MARK: - FAB ViewModel

final class GhostFABViewModel: ObservableObject {
    @Published var actions:      [UserAction] = []
    @Published var isExpanded:   Bool         = false
    @Published var selectedText: String       = ""
    @Published var appName:      String       = ""
    @Published var resultText:   String?      = nil
    @Published var isRunning:    Bool         = false
}

// MARK: - Overlay root view

struct GhostOverlayView: View {
    @ObservedObject var vm: GhostOverlayViewModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if vm.isLoading {
                    LoadingPill(dark: settings.useDarkMode)
                } else if !vm.suggestion.isEmpty {
                    if vm.isTransform {
                        TransformPill(vm: vm, settings: settings)
                    } else {
                        AutocompletePill(vm: vm, settings: settings)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .opacity(vm.isVisible ? 1 : 0)
            .offset(y: vm.isVisible ? 0 : 6)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: vm.isVisible)
            .animation(.easeOut(duration: 0.15), value: vm.suggestion)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Ghost FAB view

struct GhostFABView: View {
    @ObservedObject var vm: GhostFABViewModel
    // NSAppearance drives this automatically — no manual dark mode toggle needed.
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Spacer()

            if vm.isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(vm.actions) { action in
                        ActionRow(action: action, isDark: isDark, isRunning: vm.isRunning) {
                            runAction(action)
                        }
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isDark
                              ? AnyShapeStyle(Color.black.opacity(0.92))
                              : AnyShapeStyle(Material.ultraThinMaterial))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.08),
                                              lineWidth: 0.5)
                        )
                )
                .shadow(color: .black.opacity(isDark ? 0.5 : 0.15), radius: 16, x: 0, y: 6)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity),
                    removal:   .scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity)
                ))
            }

            // FAB button
            Button {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
                    vm.isExpanded.toggle()
                }
            } label: {
                Image(systemName: vm.isExpanded ? "xmark" : "wand.and.stars")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isDark ? .white : .black)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(isDark
                                  ? AnyShapeStyle(Color.white.opacity(0.12))
                                  : AnyShapeStyle(Material.regularMaterial))
                            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 3)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: vm.isExpanded)
    }

    private func runAction(_ action: UserAction) {
        guard !vm.isRunning else { return }
        vm.isRunning = true
        let text    = vm.selectedText
        let appName = vm.appName
        Task { @MainActor in
            let result = await InferenceManager.shared.run(action: action, selectedText: text, appName: appName)
            vm.resultText = result
            vm.isRunning  = false
            vm.isExpanded = false
            // If there's a result, post it as an accepted suggestion so AccessibilityObserver injects it.
            if let r = result, !r.isEmpty {
                OverlayWindowController.currentSuggestion = r
                NotificationCenter.default.post(name: .suggestionAccepted, object: nil)
            }
        }
    }
}

// MARK: - Action row

private struct ActionRow: View {
    let action:    UserAction
    let isDark:    Bool
    let isRunning: Bool
    let onTap:     () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: action.iconName)
                    .font(.system(size: 13))
                    .foregroundColor(.accentColor)
                    .frame(width: 20)

                Text(action.title)
                    .font(.system(size: 13))
                    .foregroundColor(isDark ? .white : .primary)

                Spacer()

                if let shortcut = action.shortcut {
                    Text(shortcut.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(isDark ? .white.opacity(0.35) : .black.opacity(0.3))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        .opacity(isRunning ? 0.5 : 1)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(0.001)) // hit-test surface
        )
    }
}

// MARK: - Pill views (unchanged from original)

private struct AutocompletePill: View {
    @ObservedObject var vm: GhostOverlayViewModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 8) {
            Text(vm.suggestion)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundColor(textColor)
                .lineLimit(2)
            HotkeyBadge(label: settings.acceptHotkey.label, dark: settings.useDarkMode)
        }
        .pillStyle(dark: settings.useDarkMode)
    }

    private var textColor: Color {
        (settings.useDarkMode ? Color.white : Color.black).opacity(settings.overlayOpacity)
    }
}

private struct TransformPill: View {
    @ObservedObject var vm: GhostOverlayViewModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 8) {
            Text(vm.transformMode.rawValue.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Capsule())
            Text(vm.suggestion)
                .font(.system(size: 13))
                .foregroundColor(textColor)
                .lineLimit(3)
            Spacer(minLength: 4)
            HotkeyBadge(label: settings.acceptHotkey.label, dark: settings.useDarkMode)
        }
        .pillStyle(dark: settings.useDarkMode)
    }

    private var textColor: Color {
        (settings.useDarkMode ? Color.white : Color.black).opacity(settings.overlayOpacity)
    }
}

private struct LoadingPill: View {
    let dark: Bool
    @State private var phase = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(dark ? Color.white.opacity(0.55) : Color.black.opacity(0.45))
                    .frame(width: 5, height: 5)
                    .scaleEffect(phase ? 1 : 0.45)
                    .animation(
                        .easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(i) * 0.14),
                        value: phase)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .pillStyle(dark: dark)
        .onAppear { phase = true }
    }
}

private struct HotkeyBadge: View {
    let label: String
    let dark:  Bool

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(dark ? .white.opacity(0.4) : .black.opacity(0.3))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)))
    }
}

// MARK: - Pill style

private struct PillStyle: ViewModifier {
    let dark: Bool
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(dark
                          ? AnyShapeStyle(Color.black.opacity(0.88))
                          : AnyShapeStyle(Material.ultraThinMaterial))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08),
                                lineWidth: 0.5)
                    )
            )
            .shadow(color: .black.opacity(dark ? 0.45 : 0.12), radius: 10, x: 0, y: 4)
    }
}

private extension View {
    func pillStyle(dark: Bool) -> some View { modifier(PillStyle(dark: dark)) }
}
