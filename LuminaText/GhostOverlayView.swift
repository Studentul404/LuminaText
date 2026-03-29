import SwiftUI
import AppKit
import Combine

// MARK: - View Model
@MainActor
final class GhostOverlayViewModel: ObservableObject {
    @Published var suggestion: String = ""
    @Published var selectedText: String = ""
    @Published var isProcessing: Bool = false
    @Published var resultText: String? = nil
}

// MARK: - Overlay Window Controller
@MainActor
final class OverlayWindowController {
    static var currentSuggestion: String?
    
    private var window: NSWindow?
    private let viewModel = GhostOverlayViewModel()
    
    init() {
        // We use a larger initial frame but a clear background.
        // The window will only "exist" where the SwiftUI content is opaque.
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 450),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        let hosting = NSHostingView(rootView: GhostOverlayView(viewModel: viewModel))
        win.contentView = hosting
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating // Above almost everything
        win.hasShadow = true
        win.ignoresMouseEvents = false // Must be false to allow button clicks
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        
        self.window = win
    }
    
    func show(suggestion: String, selectedText: String, near cgRect: CGRect) {
    Self.currentSuggestion = suggestion
    viewModel.suggestion   = suggestion
    viewModel.selectedText = selectedText

    guard let window = window,
          let primaryScreen = NSScreen.screens.first else { return }

    let primaryHeight = primaryScreen.frame.height
    let windowHeight: CGFloat = 450

    // CG → Cocoa Y-flip:
    // cgRect.minY is pixels from top of primary screen (Y-down).
    // Cocoa y of that same edge = primaryHeight - cgRect.minY.
    // Place overlay so its bottom aligns just above the selection's top edge.
    let x = cgRect.minX
    let y = (primaryHeight - cgRect.minY) - windowHeight - 10

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    window.setFrame(NSRect(x: x, y: y, width: 280, height: windowHeight), display: false)
    CATransaction.commit()

    // orderFront — not makeKeyAndOrderFront — preserves focus in host text field.
    window.orderFront(nil)
}
    
    func hide() {
        window?.orderOut(nil)
    }
}

// MARK: - Main View
struct GhostOverlayView: View {
    @ObservedObject var viewModel: GhostOverlayViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Section 1: The "Ghost" Suggestion / Caret
            HStack(spacing: 4) {
                Text("⎸").foregroundColor(.blue).bold()
                Text(viewModel.suggestion)
                    .foregroundColor(.secondary)
                    .italic()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.2))
            .cornerRadius(4)
            
            // Section 2: The Action List (The FAB)
            if !viewModel.selectedText.isEmpty {
                VStack(spacing: 0) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(UserAction.defaults) { action in
                                ActionButton(action: action, viewModel: viewModel)
                            }
                        }
                        .padding(4)
                    }
                }
               // .frame(width: 200, maxHeight: 280) // Prevents truncation
                .frame(width: 200)
                .frame(maxHeight: 280)
                .background(VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
                .shadow(radius: 15)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(10)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.selectedText)
    }
}

// MARK: - Subviews
struct ActionButton: View {
    let action: UserAction
    @ObservedObject var viewModel: GhostOverlayViewModel
    @State private var isHovered = false
    
    var body: some View {
        Button(action: runAction) {
            HStack(spacing: 8) {
                Image(systemName: action.iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                
                Text(action.title)
                    .font(.system(size: 12, weight: .medium))
                
                Spacer()
                
                if let shortcut = action.shortcut {
                    Text(shortcut.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(3)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(isHovered ? Color.blue.opacity(0.8) : Color.clear)
            .foregroundColor(isHovered ? .white : .primary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(viewModel.isProcessing)
    }
    
    private func runAction() {
        guard !viewModel.isProcessing else { return }
        viewModel.isProcessing = true
        
        Task {
            let result = await InferenceManager.shared.transform(
                selectedText: viewModel.selectedText,
                action: action
            )
            
            await MainActor.run {
                viewModel.isProcessing = false
                if let finalResult = result {
                    // CRITICAL: Hide our app so focus returns to the original text field
                    NSApp.hide(nil)
                    
                    // Small delay to ensure the OS completes the focus switch
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        AccessibilityObserver.shared.injectTransformResult(finalResult)
                    }
                }
            }
        }
    }
}

// MARK: - Helpers
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension Notification.Name {
    static let fabActionCompleted = Notification.Name("com.luminatext.fabActionCompleted")
}
