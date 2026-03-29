// ═══════════════════════════════════════════════════════════
// FABWindowController.swift
// ═══════════════════════════════════════════════════════════
import SwiftUI
import AppKit
import QuartzCore
import Combine

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

    private let panelWidth:  CGFloat = 224
    private let panelHeight: CGFloat = 46

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [
                .borderless,
                .nonactivatingPanel   // never steals key/main status — focus integrity
            ],
            backing: .buffered,
            defer: true
        )

        panel.isOpaque                      = false
        panel.backgroundColor               = .clear
        panel.hasShadow                     = true
        panel.level                         = .floating
        panel.ignoresMouseEvents            = false   // buttons must be clickable
        panel.isMovableByWindowBackground   = false
        panel.collectionBehavior            = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle     // exclude from Cmd-` cycling
        ]
        panel.animationBehavior             = .none   // we control animation

        panel.contentView = NSHostingView(rootView: FABView(viewModel: viewModel))
        self.panel = panel
    }

    // MARK: - Show

    /// `cgRect` is in CG global space as returned by AccessibilityObserver
    /// (origin = top-left of primary screen, Y increases downward).
    func show(selectedText: String, near cgRect: CGRect) {
        viewModel.selectedText       = selectedText
        viewModel.isProcessing       = false
        viewModel.processingActionID = nil

        guard let panel = panel else { return }

        let target = safeFrame(near: cgRect)

        // Zero-tearing: suppress implicit CA position animation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(target, display: false)
        CATransaction.commit()

        // orderFront — NOT makeKeyAndOrderFront.
        // makeKeyAndOrderFront steals key-window from the host text field,
        // collapsing the cursor in Xcode, TextEdit, Mail, browsers, etc.
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    // MARK: - Hide

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Coordinate translation + bounds clamping

    /// Converts a CG-space rect (Y-down, origin top-left of primary screen)
    /// to Cocoa screen-space (Y-up, origin bottom-left of primary screen),
    /// then positions the FAB panel just below the selection with safe clamping.
    ///
    /// Multi-monitor: picks the NSScreen whose CG-space frame best contains the rect.
    private func safeFrame(near cgRect: CGRect) -> NSRect {

        // 1. Primary screen height is the constant for CG ↔ Cocoa Y-flip
        guard let primaryScreen = NSScreen.screens.first else {
            return NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        }
        let primaryHeight = primaryScreen.frame.height

        // 2. Find which NSScreen owns this CG-space rect (multi-monitor safe)
        let targetScreen = nsScreen(containingCGRect: cgRect, primaryHeight: primaryHeight)
                           ?? primaryScreen

        // 3. CG → Cocoa Y-flip for the selection's edges
        //    CG:    y = pixels from top of primary screen, downward
        //    Cocoa: y = pixels from bottom of primary screen, upward
        //
        //    Cocoa y of CG rect's *bottom* edge = primaryHeight - cgRect.maxY
        //    Cocoa y of CG rect's *top*  edge   = primaryHeight - cgRect.minY
        let anchorBottom = primaryHeight - cgRect.maxY   // Cocoa y: bottom of selection
        let anchorTop    = primaryHeight - cgRect.minY   // Cocoa y: top of selection
        let anchorLeft   = cgRect.minX

        let margin: CGFloat = 8
        let sf = targetScreen.visibleFrame   // Cocoa-space, respects menu bar + Dock

        // 4. Preferred: place FAB just below the selection
        var x = anchorLeft
        var y = anchorBottom - panelHeight - margin

        // If not enough room below, flip the FAB above the selection
        if y < sf.minY + margin {
            y = anchorTop + margin
        }

        // 5. Horizontal clamp
        if x + panelWidth > sf.maxX - margin {
            x = sf.maxX - panelWidth - margin
        }
        x = max(sf.minX + margin, x)

        // 6. Final vertical safety clamp
        y = max(sf.minY + margin, min(y, sf.maxY - panelHeight - margin))

        return NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
    }

    /// Returns the NSScreen whose CG-space frame has the largest intersection with cgRect.
    private func nsScreen(containingCGRect cgRect: CGRect, primaryHeight: CGFloat) -> NSScreen? {
        NSScreen.screens.max { a, b in
            cgSpaceFrame(of: a, primaryHeight: primaryHeight).intersection(cgRect).area <
            cgSpaceFrame(of: b, primaryHeight: primaryHeight).intersection(cgRect).area
        }
    }

    /// Converts an NSScreen's Cocoa-space frame to CG-space for intersection testing.
    private func cgSpaceFrame(of screen: NSScreen, primaryHeight: CGFloat) -> CGRect {
        let f = screen.frame
        return CGRect(x: f.minX,
                      y: primaryHeight - f.maxY,
                      width: f.width,
                      height: f.height)
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
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
    }
}

// MARK: - Action Chip

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

                // Hide first — restores focus to the host text field before
                // CGEvent injection, ensuring keystrokes land in the right window.
                NSApp.hide(nil)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    AccessibilityObserver.shared.injectTransformResult(finalResult)
                }
            }
        }
    }
}
