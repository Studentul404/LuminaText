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

    // Fixed dimensions — NSHostingView must never negotiate size with the window.
    // Variable-height content (the FAB action list) lives in FABWindowController.
    private let panelWidth:  CGFloat = 320
    private let panelHeight: CGFloat = 36

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [
                .borderless,
                .nonactivatingPanel   // NSPanel-only flag — valid here, was invalid on NSWindow
            ],
            backing: .buffered,
            defer: false              // false: backing store created immediately, no deferred layout surprises
        )

        panel.isOpaque          = false
        panel.backgroundColor   = .clear
        panel.hasShadow         = false
        panel.level             = .floating
        panel.ignoresMouseEvents = true   // ghost text is display-only; Tab is handled via CGEvent tap
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.animationBehavior  = .none

        let hosting = NSHostingView(rootView: GhostOverlayView(viewModel: viewModel))
        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []
        }
        panel.contentView = hosting
                panel.contentView = hosting
                NSLayoutConstraint.activate([
                    hosting.widthAnchor.constraint(equalToConstant: panelWidth),
                    hosting.heightAnchor.constraint(equalToConstant: panelHeight),
                ])

                self.panel = panel
    }

    // MARK: - Show

    /// `cgRect` is in CG global space (Y-down, origin = top-left of primary screen).
    func show(suggestion: String, near cgRect: CGRect) {
        Self.currentSuggestion  = suggestion
        viewModel.suggestion    = suggestion

        guard let panel = panel,
              let primaryScreen = NSScreen.screens.first else { return }

        let primaryHeight = primaryScreen.frame.height

        // CG → Cocoa Y-flip:
        // Cocoa y of the selection's top edge = primaryHeight - cgRect.minY
        // Place the ghost text pill so its bottom sits just above the selection.
        let x = cgRect.minX
        let y = (primaryHeight - cgRect.minY) + 4   // 4pt gap above the text baseline

        // Zero-tearing: suppress implicit CA position animation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // display: false — never force a synchronous display inside show().
        // Triggering display:true during an AppKit layout pass is what causes
        // _postWindowNeedsUpdateConstraints to throw (frames 3-5 in the crash log).
        panel.setFrame(
            NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
            display: false
        )
        CATransaction.commit()

        // orderFront, not makeKeyAndOrderFront — preserves key window in host app.
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
// Intentionally minimal — fixed height, no conditional branches that change layout.

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

// MARK: - VisualEffectView (kept for FABWindowController use)

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material    = material
        view.blendingMode = blendingMode
        view.state       = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Notifications

extension Notification.Name {
    static let fabActionCompleted = Notification.Name("com.luminatext.fabActionCompleted")
}
