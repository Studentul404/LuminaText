import SwiftUI
import AppKit

// MARK: - OverlayWindowController (Mode A — autocomplete ghost text)

@MainActor
final class OverlayWindowController {
    static var currentSuggestion: String?

    private var window: NSWindow?
    private var viewModel = GhostOverlayViewModel()

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        let hosting = NSHostingView(rootView: GhostOverlayView(viewModel: viewModel))
        win.contentView = hosting
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.hasShadow = false

        self.window = win
    }

    func show(suggestion: String, near rect: CGRect) {
        Self.currentSuggestion = suggestion
        viewModel.suggestion = suggestion

        let screens = NSScreen.screens
        let targetScreen = screens.first(where: { $0.frame.contains(rect.origin) }) ?? NSScreen.main ?? screens.first!
        let screenFrame = targetScreen.frame

        let windowWidth: CGFloat = 1000
        let windowHeight: CGFloat = 100

        let x = rect.minX
        let y = screenFrame.maxY - rect.maxY - 5

        let frame = CGRect(x: x, y: y - windowHeight, width: windowWidth, height: windowHeight)

        viewModel.isVisible = true

        if window?.frame.origin != frame.origin {
            window?.setFrame(frame, display: true)
        }

        if window?.isVisible == false {
            window?.orderFront(nil)
        }
    }

    func hide() {
        Self.currentSuggestion = nil
        viewModel.isVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if !self.viewModel.isVisible {
                self.window?.orderOut(nil)
            }
        }
    }
}

// MARK: - ViewModel

class GhostOverlayViewModel: ObservableObject {
    @Published var suggestion: String = ""
    @Published var isVisible: Bool = false
}

// MARK: - GhostOverlayView

struct GhostOverlayView: View {
    @ObservedObject var viewModel: GhostOverlayViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if !viewModel.suggestion.isEmpty {
                    Text(viewModel.suggestion)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)

                    TabBadge()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                    )
            )
            .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 3)
            .opacity(viewModel.isVisible ? 1 : 0)
            .offset(y: viewModel.isVisible ? 0 : 5)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: viewModel.isVisible)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct TabBadge: View {
    var body: some View {
        Text("⇥")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.5))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.1))
            )
    }
}

// MARK: - FABWindowController (Mode B — floating action button on selection)

@MainActor
final class FABWindowController {
    private var window: NSWindow?
    private var viewModel = FABViewModel()

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        let hosting = NSHostingView(rootView: GhostFABView(viewModel: viewModel))
        win.contentView = hosting
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.ignoresMouseEvents = false   // FAB must receive clicks
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.hasShadow = false

        self.window = win
    }

    func show(selectedText: String, near rect: CGRect) {
        viewModel.selectedText = selectedText
        viewModel.actions = AppSettings.shared.userActions

        let screens = NSScreen.screens
        let targetScreen = screens.first(where: { $0.frame.contains(rect.origin) }) ?? NSScreen.main ?? screens.first!
        let screenFrame = targetScreen.frame

        let windowWidth: CGFloat = 300
        let windowHeight: CGFloat = 44

        // Position FAB just below the end of the selection rect
        let x = min(rect.maxX, screenFrame.maxX - windowWidth)
        let yFlipped = screenFrame.maxY - rect.maxY - 8   // 8pt gap below selection

        let frame = CGRect(
            x: max(x, screenFrame.minX),
            y: yFlipped - windowHeight,
            width: windowWidth,
            height: windowHeight
        )

        viewModel.isVisible = true

        if window?.frame != frame {
            window?.setFrame(frame, display: true)
        }

        if window?.isVisible == false {
            window?.orderFront(nil)
        }
    }

    func hide() {
        viewModel.isVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if !self.viewModel.isVisible {
                self.window?.orderOut(nil)
            }
        }
    }
}

// MARK: - FABViewModel

class FABViewModel: ObservableObject {
    @Published var selectedText: String = ""
    @Published var actions: [UserAction] = AppSettings.shared.userActions
    @Published var isVisible: Bool = false
    @Published var isProcessing: Bool = false
    @Published var resultText: String? = nil
}

// MARK: - GhostFABView

struct GhostFABView: View {
    @ObservedObject var viewModel: FABViewModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(viewModel.actions.prefix(4)) { action in
                FABActionButton(action: action, viewModel: viewModel)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
        .opacity(viewModel.isVisible ? 1 : 0)
        .scaleEffect(viewModel.isVisible ? 1 : 0.92)
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: viewModel.isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - FABActionButton

struct FABActionButton: View {
    let action: UserAction
    @ObservedObject var viewModel: FABViewModel
    @State private var isHovered = false

    var body: some View {
        Button {
            runAction()
        } label: {
            HStack(spacing: 4) {
                if viewModel.isProcessing {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: action.sfSymbol)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(action.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(isHovered ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(viewModel.isProcessing)
    }

    private func runAction() {
        guard !viewModel.isProcessing, !viewModel.selectedText.isEmpty else { return }
        viewModel.isProcessing = true
        Task {
            let result = await InferenceManager.shared.transform(
                selectedText: viewModel.selectedText,
                action: action
            )
            await MainActor.run {
                viewModel.isProcessing = false
                viewModel.resultText = result
                // Post so AppDelegate can inject the result
                NotificationCenter.default.post(
                    name: .fabActionCompleted,
                    object: result
                )
            }
        }
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let fabActionCompleted = Notification.Name("com.luminatext.fabActionCompleted")
}