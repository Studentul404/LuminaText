import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var inference = InferenceManager.shared
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(0)

            ModelTab()
                .tabItem { Label("Model", systemImage: "cpu") }
                .tag(1)

            ActionsTab()
                .tabItem { Label("Actions", systemImage: "bolt") }
                .tag(2)

            AppearanceTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(3)

            HotkeysTab()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
                .tag(4)

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(5)
        }
        .frame(width: 520, height: 420)
        .padding()
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Enable completions", isOn: $settings.isEnabled)

                HStack(spacing: 12) {
                    Text("Trigger delay")
                        .frame(width: 100, alignment: .leading)
                    Slider(value: $settings.triggerDelay, in: 0.1...2.0, step: 0.1)
                    Text(String(format: "%.1fs", settings.triggerDelay))
                        .frame(width: 38)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                HStack(spacing: 12) {
                    Text("Max tokens")
                        .frame(width: 100, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(settings.maxTokens) },
                        set: { settings.maxTokens = Int($0) }
                    ), in: 10...200, step: 5)
                    Text("\(settings.maxTokens)")
                        .frame(width: 38)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }

            Section("Shortcuts") {
                shortcutRow(label: "Accept suggestion", keys: "⇥ Tab")
                shortcutRow(label: "Dismiss suggestion", keys: "Esc")
            }

            Section("Permissions") {
                HStack(spacing: 10) {
                    Image(systemName: AXIsProcessTrusted() ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(AXIsProcessTrusted() ? .green : .red)
                    Text(AXIsProcessTrusted() ? "Accessibility access granted" : "Accessibility access required")
                    Spacer()
                    if !AXIsProcessTrusted() {
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func shortcutRow(label: String, keys: String) -> some View {
        HStack {
            Image(systemName: "keyboard")
                .foregroundColor(.secondary)
                .frame(width: 18)
            Text(label)
            Spacer()
            Text(keys)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(5)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}

// MARK: - Model Tab

struct ModelTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var inference = InferenceManager.shared
    @State private var testOutput = ""
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("Active Backend") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(inference.isReady ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(inference.backendName)
                        .foregroundColor(.primary)
                    Spacer()
                    if inference.isGenerating {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            Section("MLX (Local)") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model: mlx-community/Qwen2.5-Coder-0.5B-Instruct-4bit")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Add the mlx-swift-examples package to your Xcode project to enable MLX inference. The app auto-detects and prefers MLX over Ollama.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }

            Section("Ollama (Fallback)") {
                LabeledContent("Host") {
                    TextField("http://localhost:11434", text: $settings.ollamaHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                LabeledContent("Model") {
                    TextField("qwen2.5-coder:0.5b", text: $settings.ollamaModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                HStack(spacing: 12) {
                    Text("Temperature")
                        .frame(width: 100, alignment: .leading)
                    Slider(value: $settings.temperature, in: 0...1, step: 0.05)
                    Text(String(format: "%.2f", settings.temperature))
                        .frame(width: 38)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }

            Section("System Prompt") {
                TextEditor(text: $settings.systemPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 120)
                    .scrollContentBackground(.hidden)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(6)

                Text("Changes apply instantly. Keep the prompt concise (≤ 200 tokens).")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Section("Test") {
                HStack(alignment: .top, spacing: 10) {
                    Button("Run test completion") { runTest() }
                        .disabled(isTesting || !inference.isReady)
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                }
                if !testOutput.isEmpty {
                    Text(testOutput)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.textBackgroundColor))
                        .cornerRadius(6)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
    }

    private func runTest() {
        isTesting = true
        testOutput = ""
        Task {
            let result = await InferenceManager.shared.complete(prompt: "func fibonacci(n: Int) -> Int {")
            await MainActor.run {
                testOutput = result ?? "(no result)"
                isTesting = false
            }
        }
    }
}

// MARK: - Actions Tab

struct ActionsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedAction: UserAction? = nil
    @State private var isEditing = false
    @State private var isCreating = false

    var body: some View {
        HSplitView {
            // Left — list
            VStack(spacing: 0) {
                List(settings.userActions, id: \.id, selection: $selectedAction) { action in
                    HStack(spacing: 10) {
                        Image(systemName: action.sfSymbol)
                            .frame(width: 18)
                            .foregroundColor(.accentColor)
                        Text(action.title)
                    }
                    .tag(action)
                    .padding(.vertical, 2)
                }
                .listStyle(.sidebar)

                Divider()

                HStack(spacing: 0) {
                    Button {
                        isCreating = true
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.plain)

                    Button {
                        guard let sel = selectedAction,
                              let idx = settings.userActions.firstIndex(where: { $0.id == sel.id })
                        else { return }
                        settings.userActions.remove(at: idx)
                        selectedAction = nil
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedAction == nil)

                    Spacer()

                    Button("Import") {
                        print("[ActionsTab] Import stub — not yet implemented")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 8)

                    Button("Export") {
                        print("[ActionsTab] Export stub — not yet implemented")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 8)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .background(Color(.controlBackgroundColor))
            }
            .frame(minWidth: 160, maxWidth: 200)

            // Right — editor
            Group {
                if let sel = selectedAction,
                   let idx = settings.userActions.firstIndex(where: { $0.id == sel.id }) {
                    ActionEditorView(
                        action: $settings.userActions[idx],
                        onDone: { selectedAction = settings.userActions[idx] }
                    )
                } else {
                    VStack {
                        Spacer()
                        Text("Select an action to edit")
                            .foregroundColor(.secondary)
                            .font(.callout)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            NewActionSheet { newAction in
                settings.userActions.append(newAction)
                selectedAction = newAction
            }
        }
    }
}

// MARK: - ActionEditorView

struct ActionEditorView: View {
    @Binding var action: UserAction
    var onDone: () -> Void

    @State private var showSymbolPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title + icon row
            HStack(spacing: 12) {
                Button {
                    showSymbolPicker = true
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: action.sfSymbol)
                            .font(.system(size: 18))
                            .foregroundColor(.accentColor)
                    }
                }
                .buttonStyle(.plain)
                .help("Pick icon")
                .popover(isPresented: $showSymbolPicker, arrowEdge: .bottom) {
                    SFSymbolPickerView(selected: $action.sfSymbol)
                        .frame(width: 280, height: 280)
                }

                TextField("Action title", text: $action.title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14, weight: .medium))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Instruction Prompt")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                TextEditor(text: $action.prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
                    )
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - NewActionSheet

struct NewActionSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onCreate: (UserAction) -> Void

    @State private var title = ""
    @State private var prompt = ""
    @State private var sfSymbol = "sparkles"
    @State private var showSymbolPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Action")
                .font(.headline)

            HStack(spacing: 12) {
                Button {
                    showSymbolPicker = true
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: sfSymbol)
                            .font(.system(size: 18))
                            .foregroundColor(.accentColor)
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showSymbolPicker, arrowEdge: .bottom) {
                    SFSymbolPickerView(selected: $sfSymbol)
                        .frame(width: 280, height: 280)
                }

                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Instruction Prompt")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 100)
                    .scrollContentBackground(.hidden)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
                    )
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let action = UserAction(title: title, prompt: prompt, sfSymbol: sfSymbol)
                    onCreate(action)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - SFSymbolPickerView

private let pickerSymbols: [String] = [
    "sparkles", "wand.and.stars", "bolt", "bolt.fill",
    "textformat.abc", "pencil", "pencil.and.scribble", "doc.text",
    "arrow.down.right.and.arrow.up.left", "arrow.up.right.and.arrow.down.left",
    "briefcase", "briefcase.fill",
    "questionmark.circle", "questionmark.circle.fill",
    "lightbulb", "lightbulb.fill",
    "checkmark.circle", "checkmark.circle.fill",
    "xmark.circle", "exclamationmark.circle",
    "bubble.left.and.bubble.right", "bubble.left",
    "magnifyingglass", "text.magnifyingglass",
    "globe", "network",
    "cpu", "memorychip",
    "paintbrush", "paintbrush.fill",
    "scissors", "scissors.badge.ellipsis",
    "arrow.triangle.2.circlepath", "repeat",
    "waveform", "function",
]

struct SFSymbolPickerView: View {
    @Binding var selected: String

    private let columns = Array(repeating: GridItem(.fixed(44)), count: 6)

    var body: some View {
        VStack(spacing: 0) {
            Text("Choose Icon")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 10)
                .padding(.bottom, 6)

            Divider()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(pickerSymbols, id: \.self) { symbol in
                        Button {
                            selected = symbol
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 17))
                                .frame(width: 36, height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(selected == symbol ? Color.accentColor.opacity(0.2) : Color.clear)
                                )
                                .foregroundColor(selected == symbol ? .accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
    }
}

// MARK: - Appearance Tab

struct AppearanceTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Ghost Text Overlay") {
                HStack(spacing: 12) {
                    Text("Opacity")
                        .frame(width: 60, alignment: .leading)
                    Slider(value: $settings.overlayOpacity, in: 0.2...1.0, step: 0.05)
                    Text(String(format: "%.0f%%", settings.overlayOpacity * 100))
                        .frame(width: 40)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }

            Section("Preview") {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.textBackgroundColor))
                        .frame(height: 80)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("func fetchUser(id: String) ")
                            .font(.system(size: 13, design: .monospaced))
                        HStack(spacing: 6) {
                            Text("async throws -> User {")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.white.opacity(settings.overlayOpacity * 0.8))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(.ultraThinMaterial)
                                )
                            Text("⇥")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
                        }
                    }
                    .padding()
                }
            }

            Section("Theme") {
                HStack(spacing: 8) {
                    Image(systemName: "circle.lefthalf.filled")
                        .foregroundColor(.secondary)
                    Text("Follows system appearance automatically")
                        .foregroundColor(.secondary)
                        .font(.callout)
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
    }
}

// MARK: - Hotkeys Tab

struct HotkeysTab: View {
    @ObservedObject private var settings = AppSettings.shared

    // Maps key-code → readable label for the subset we care about
    private static let keyLabels: [(code: Int, label: String)] = [
        (48,  "Tab (⇥)"),
        (36,  "Return (↩)"),
        (49,  "Space"),
        (53,  "Escape"),
        (122, "F1"),
        (120, "F2"),
        (99,  "F3"),
        (118, "F4"),
        (96,  "F5"),
        (97,  "F6"),
    ]

    var body: some View {
        Form {
            Section("Keyboard Shortcuts") {
                LabeledContent("Accept suggestion") {
                    Picker("", selection: $settings.acceptHotkeyCode) {
                        ForEach(Self.keyLabels, id: \.code) { pair in
                            Text(pair.label).tag(pair.code)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }

                LabeledContent("Dismiss suggestion") {
                    Picker("", selection: $settings.dismissHotkeyCode) {
                        ForEach(Self.keyLabels, id: \.code) { pair in
                            Text(pair.label).tag(pair.code)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            Section {
                Text("Changing these remaps the Accept/Dismiss keys inside LuminaText. Conflicts with system shortcuts are not checked automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
    }
}

// MARK: - About Tab

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "text.cursor")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            VStack(spacing: 4) {
                Text("LuminaText")
                    .font(.system(size: 22, weight: .bold))
                Text("System-wide LLM Autocompletion")
                    .foregroundColor(.secondary)
                Text("Version 1.0.0")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                FeatureRow(icon: "cpu", title: "MLX Inference", description: "Runs Qwen2.5-Coder-0.5B locally via mlx-swift")
                FeatureRow(icon: "server.rack", title: "Ollama Fallback", description: "Seamlessly falls back to Ollama if MLX unavailable")
                FeatureRow(icon: "accessibility", title: "System-wide", description: "Works in any app via Accessibility API")
                FeatureRow(icon: "keyboard", title: "Ghost Text", description: "Press Tab to accept • Esc to dismiss")
                FeatureRow(icon: "bolt", title: "Actions FAB", description: "Select text anywhere to transform it with AI")
            }
            .padding(.horizontal, 20)

            Spacer()

            Link("View on GitHub", destination: URL(string: "https://github.com")!)
                .foregroundColor(.accentColor)
                .font(.caption)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(description).font(.caption).foregroundColor(.secondary)
            }
        }
    }
}