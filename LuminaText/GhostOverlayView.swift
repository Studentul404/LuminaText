import SwiftUI
import AppKit
import QuartzCore
import Combine

// MARK: - View Model

@MainActor
final class GhostOverlayViewModel: ObservableObject {
    @Published var suggestion: String = ""
}

// MARK: - Overlay Window Controller

@MainActor
final class OverlayWindowController {

    static var currentSuggestion: String?

    private var panel: NSPanel?
    private let viewModel = GhostOverlayViewModel()

    private let panelWidth:  CGFloat = 320
    private let panelHeight: CGFloat = 36

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [
                .borderless,
                .nonactivatingPanel
            ],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque           = false
        panel.backgroundColor    = .clear
        panel.hasShadow          = false
        panel.level              = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.animationBehavior  = .none

        // FIX: Single assignment of contentView — never assign twice.
        // NSHostingView must NOT have external NSLayoutConstraints added to it
        // when it lives inside an NSPanel: the panel owns the frame, and adding
        // constraints triggers a deferred layout pass (_postWindowNeedsUpdateConstraints)
        // that races with NSPanel internals and causes SIGSEGV.
        let hosting = NSHostingView(rootView: GhostOverlayView(viewModel: viewModel))
        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        // sizingOptions = [] tells NSHostingView not to negotiate its size with
        // the window, which prevents the unsolicited layout pass that crashes.
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []
        }

        panel.contentView = hosting  // single assignment — no duplicate below
        self.panel = panel
    }

    // MARK: - Show

    func show(suggestion: String, near cgRect: CGRect) {
        Self.currentSuggestion = suggestion
        viewModel.suggestion   = suggestion

        guard let panel = panel,
              let primaryScreen = NSScreen.screens.first else { return }

        let primaryHeight = primaryScreen.frame.height
        let x = cgRect.minX
        let y = (primaryHeight - cgRect.minY) + 4

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(
            NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
            display: false
        )
        CATransaction.commit()

        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    // MARK: - Hide

    func hide() {
        panel?.orderOut(nil)
        viewModel.suggestion   = ""
        Self.currentSuggestion = nil
    }
}

// MARK: - Ghost Text View

struct GhostOverlayView: View {
    @ObservedObject var viewModel: GhostOverlayViewModel

    var body: some View {
        HStack(spacing: 6) {
            Text("⎸")
                .foregroundColor(.blue)
                .bold()

            Text(viewModel.suggestion)
                .foregroundColor(.secondary)
                .italic()
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            Text("⇥")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.1))
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }
}

// MARK: - VisualEffectView

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material     = material
        view.blendingMode = blendingMode
        view.state        = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Notifications

extension Notification.Name {
    static let fabActionCompleted = Notification.Name("com.luminatext.fabActionCompleted")
}
