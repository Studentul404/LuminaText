// ═══════════════════════════════════════════════════════════
// FABWindowController.swift
// ═══════════════════════════════════════════════════════════
import SwiftUI
import AppKit
import QuartzCore

// MARK: - FAB View Model

@MainActor
final class FABViewModel: ObservableObject {
    @Published var selectedText: String = ""
    @Published var isProcessing: Bool = false
    @Published var processingActionID: UUID? = nil
}

// MARK: - FAB Window Controller

@MainActor
final class FABWindowController {

    private var panel: NSPanel?
    private let viewModel = FABViewModel()

    // Fixed panel dimensions
    private let panelWidth:  CGFloat = 220
    private let panelHeight: CGFloat = 46   // single-row pill; expands via SwiftUI

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [
                .borderless,
                .nonactivatingPanel,   // CRITICAL: never steals key/main status
                .hudWindow             // macOS HUD look — glass dark blur
            ],
            backing: .buffered,
            defer: true
        )

        panel.isOpaque            = false
        panel.backgroundColor     = .clear
        panel.hasShadow           = true
        panel.level               = .floating
        panel.ignoresMouseEvents  = false   // must be false for button clicks
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior  = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle           // cmd-` won't cycle into us
        ]
        panel.animationBehavior   = .none   // we drive animation ourselves

        let hosting = NSHostingView(rootView: FABView(viewModel: viewModel))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting

        self.panel = panel
    }

    // MARK: - Show

    func show(selectedText: String, near rect: CGRect) {
        viewModel.selectedText    = selectedText
        viewModel.isProcessing    = false
        viewModel.processingActionID = nil

        guard let panel = panel,
              let screen = NSScreen.main else { return }

        let targetFrame = safeFrame(near: rect, screen: screen)

        // Zero-tearing: disable implicit CA animations for the move
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(targetFrame, display: false)
        CATransaction.commit()

        if !panel.isVisible {
            panel.orderFront(nil)   // orderFront, NOT makeKey — focus integrity
        }
    }

    // MARK: - Hide

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Bounds-safe frame calculation

    private func safeFrame(near rect: CGRect, screen: NSScreen) -> NSRect {
        let sf = screen.visibleFrame          // respects menu bar + Dock
        let margin: CGFloat = 8

        // Prefer: just below the selection rectangle
        var x = rect.minX
        var y = rect.minY - panelHeight - margin

        // Clamp horizontally
        if x + panelWidth > sf.maxX - margin {
            x = sf.maxX - panelWidth - margin
        }
        if x < sf.minX + margin {
            x = sf.minX + margin
        }

        // If below-rect placement goes off-screen bottom, flip above
        if y < sf.minY + margin {
            y = rect.maxY + margin
        }

        // Final vertical clamp
        y = max(sf.minY + margin, min(y, sf.maxY - panelHeight - margin))

        return NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
    }
}

// MARK: - FAB SwiftUI View

struct FABView: View {
    @ObservedObject var viewModel: FABViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(UserAction.defaults) { action in
                    FABActionChip(action: action, viewModel: viewModel)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(height: 46)
        // Capsule clip — the defining visual of the FAB
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 4)
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Individual Action Chip

struct FABActionChip: View {
    let action: UserAction
    @ObservedObject var viewModel: FABViewModel
    @State private var isHovered = false

    private var isThisProcessing: Bool {
        viewModel.processingActionID == action.id
    }

    var body: some View {
        Button(action: runAction) {
            HStack(spacing: 4) {
                if isThisProcessing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: action.iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 13)
                }
                Text(action.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isHovered
                          ? Color.accentColor.opacity(0.85)
                          : Color.white.opacity(0.08))
            )
            .foregroundColor(isHovered ? .white : .primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(viewModel.isProcessing)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    // MARK: Run

    private func runAction() {
        guard !viewModel.isProcessing else { return }
        viewModel.isProcessing       = true
        viewModel.processingActionID = action.id

        let text = viewModel.selectedText

        Task {
            let result = await InferenceManager.shared.transform(
                selectedText: text,
                action: action
            )

            await MainActor.run {
                viewModel.isProcessing       = false
                viewModel.processingActionID = nil

                guard let finalResult = result, !finalResult.isEmpty else { return }

                // Hide BEFORE injecting so focus returns to originating text field
                NSApp.hide(nil)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    AccessibilityObserver.shared.injectTransformResult(finalResult)
                }
            }
        }
    }
}