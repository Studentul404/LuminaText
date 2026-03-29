// ═══════════════════════════════════════════════════════════
// SettingsView.swift
// ═══════════════════════════════════════════════════════════
import SwiftUI
import AppKit

struct SettingsView: View {
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
        .frame(width: 560, height: 440)
        .padding()
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @ObservedObject private var s = AppSettings.shared

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Enable completions", isOn: $s.isEnabled)
                sliderRow("Trigger delay", value: $s.triggerDelay, range: 0.1...2.0, step: 0.1,
                          format: { String(format: "%.1fs", $0) })
                sliderRow("Max tokens",
                          value: Binding(get: { Double(s.maxTokens) }, set: { s.maxTokens = Int($0) }),
                          range: 10...200, step: 5, format: { "\(Int($0))" })
            }

            Section("Shortcuts") {
                shortcutRow("Accept suggestion", label: s.acceptHotkey.label)
                shortcutRow("Dismiss suggestion", label: s.dismissHotkey.label)
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
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: @escaping (Double) -> String) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 100, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(format(value.wrappedValue)).frame(width: 42).foregroundColor(.secondary).monospacedDigit()
        }
    }

    @ViewBuilder
    private func shortcutRow(_ label: String, label badge: String) -> some View {
        HStack {
            Image(systemName: "keyboard").foregroundColor(.secondary).frame(width: 18)
            Text(label)
            Spacer()
            Text(badge)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(5)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}

// MARK: - Model Tab

struct ModelTab: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var inference = InferenceManager.shared
    @State private var testOutput = ""
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("Active Backend") {
                HStack(spacing: 8) {
                    Circle().fill(inference.isReady ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(inference.backendName)
                    Spacer()
                    if inference.isGenerating { ProgressView().controlSize(.small) }
                }
            }

            Section("Ollama") {
                LabeledContent("Host") {
                    TextField("http://localhost:11434", text: $s.ollamaHost)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                }
                LabeledContent("Model") {
                    TextField("qwen2.5-coder:0.5b", text: $s.ollamaModel)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                }
                HStack(spacing: 12) {
                    Text("Temperature").frame(width: 100, alignment: .leading)
                    Slider(value: $s.temperature, in: 0...1, step: 0.05)
                    Text(String(format: "%.2f", s.temperature)).frame(width: 42).foregroundColor(.secondary).monospacedDigit()
                }
            }

            Section("LM Studio") {
                LabeledContent("Host") {
                    TextField("http://localhost:1234/v1", text: $s.lmStudioHost)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                }
                LabeledContent("Model") {
                    TextField("model-id", text: $s.lmStudioModel)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                }
            }

            Section("System Prompt") {
                Picker("Mode", selection: $s.inferenceMode) {
                    ForEach(InferenceMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
                TextEditor(text: $s.systemPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 100)
                    .scrollContentBackground(.hidden)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(6)
                HStack {
                    Button("Reset to default") { s.resetSystemPrompt() }.controlSize(.small)
                    Spacer()
                    Text("≤ 200 tokens recommended").font(.caption2).foregroundColor(.secondary)
                }
            }

            Section("Test") {
                HStack(alignment: .top, spacing: 10) {
                    Button("Run test completion") { runTest() }.disabled(isTesting || !inference.isReady)
                    if isTesting { ProgressView().controlSize(.small) }
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
    }

    private func runTest() {
        isTesting = true; testOutput = ""
        Task {
            let result = await InferenceManager.shared.complete(prompt: "func fibonacci(n: Int) -> Int {")
            testOutput = result ?? "(no result)"
            isTesting = false
        }
    }
}

// MARK: - Actions Tab

// UserAction must be Hashable for List selection — extend here (id-based)
extension UserAction: Hashable {
    static func == (lhs: UserAction, rhs: UserAction) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ActionsTab: View {
    @ObservedObject private var s = AppSettings.shared
    @State private var selectedID: UUID? = nil
    @State private var showingNew = false

    private var selectedIndex: Int? {
        guard let id = selectedID else { return nil }
        return s.userActions.firstIndex(where: { $0.id == id })
    }

    var body: some View {
        HSplitView {
            // Left sidebar
            VStack(spacing: 0) {
                List(s.userActions, id: \.id, selection: $selectedID) { action in
                    HStack(spacing: 8) {
                        Image(systemName: action.iconName).frame(width: 16).foregroundColor(.accentColor)
                        Text(action.title)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.sidebar)

                Divider()

                HStack(spacing: 0) {
                    Button { showingNew = true } label: {
                        Image(systemName: "plus").frame(width: 28, height: 24)
                    }
                    .buttonStyle(.plain)

                    Button {
                        guard let idx = selectedIndex else { return }
                        s.userActions.remove(at: idx)
                        selectedID = nil
                    } label: {
                        Image(systemName: "minus").frame(width: 28, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedIndex == nil)

                    Spacer()

                    Button("Import") { print("[Actions] Import stub") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary).padding(.trailing, 8)
                    Button("Export") { print("[Actions] Export stub") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary).padding(.trailing, 8)
                }
                .padding(.vertical, 4).padding(.horizontal, 4)
                .background(Color(.controlBackgroundColor))
            }
            .frame(minWidth: 160, maxWidth: 200)

            // Right editor
            Group {
                if let idx = selectedIndex {
                    ActionEditorView(action: $s.userActions[idx])
                } else {
                    VStack { Spacer(); Text("Select an action to edit").foregroundColor(.secondary); Spacer() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .sheet(isPresented: $showingNew) {
            NewActionSheet { s.userActions.append($0); selectedID = $0.id }
        }
    }
}

// MARK: - ActionEditorView

struct ActionEditorView: View {
    @Binding var action: UserAction
    @State private var showSymbolPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Button { showSymbolPicker = true } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.15)).frame(width: 40, height: 40)
                        Image(systemName: action.iconName).font(.system(size: 18)).foregroundColor(.accentColor)
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showSymbolPicker, arrowEdge: .bottom) {
                    SFSymbolPickerView(selected: $action.iconName).frame(width: 280, height: 280)
                }

                TextField("Action title", text: $action.title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14, weight: .medium))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("INSTRUCTION PROMPT").font(.caption).foregroundColor(.secondary)
                TextEditor(text: $action.systemPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(.separatorColor), lineWidth: 0.5))
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
    @State private var iconName = "sparkles"
    @State private var showSymbolPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Action").font(.headline)

            HStack(spacing: 12) {
                Button { showSymbolPicker = true } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.15)).frame(width: 40, height: 40)
                        Image(systemName: iconName).font(.system(size: 18)).foregroundColor(.accentColor)
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showSymbolPicker, arrowEdge: .bottom) {
                    SFSymbolPickerView(selected: $iconName).frame(width: 280, height: 280)
                }

                TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Instruction Prompt").font(.caption).foregroundColor(.secondary)
                TextEditor(text: $prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 100)
                    .scrollContentBackground(.hidden)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(.separatorColor), lineWidth: 0.5))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    onCreate(UserAction(title: title, systemPrompt: prompt, iconName: iconName))
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

// MARK: - SF Symbol Picker

private let pickerSymbols: [String] = [
    "sparkles","wand.and.stars","bolt","bolt.fill",
    "textformat.abc","text.badge.checkmark","pencil","pencil.and.scribble",
    "doc.plaintext","doc.text","arrow.down.right.and.arrow.up.left",
    "arrow.up.right.and.arrow.down.left","briefcase","briefcase.fill",
    "questionmark.circle","questionmark.circle.fill","lightbulb","lightbulb.fill",
    "checkmark.circle","bubble.left.and.bubble.right","bubble.left",
    "list.bullet","face.smiling","wand.and.stars.inverse",
    "magnifyingglass","text.magnifyingglass","globe","cpu",
    "paintbrush","scissors","arrow.triangle.2.circlepath","function",
]

struct SFSymbolPickerView: View {
    @Binding var selected: String
    private let columns = Array(repeating: GridItem(.fixed(44)), count: 6)

    var body: some View {
        VStack(spacing: 0) {
            Text("Choose Icon").font(.caption).foregroundColor(.secondary).padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(pickerSymbols, id: \.self) { sym in
                        Button { selected = sym } label: {
                            Image(systemName: sym)
                                .font(.system(size: 17))
                                .frame(width: 36, height: 36)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(selected == sym ? Color.accentColor.opacity(0.2) : Color.clear))
                                .foregroundColor(selected == sym ? .accentColor : .primary)
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
    @ObservedObject private var s = AppSettings.shared

    var body: some View {
        Form {
            Section("Ghost Text Overlay") {
                HStack(spacing: 12) {
                    Text("Opacity").frame(width: 60, alignment: .leading)
                    Slider(value: $s.overlayOpacity, in: 0.2...1.0, step: 0.05)
                    Text(String(format: "%.0f%%", s.overlayOpacity * 100))
                        .frame(width: 40).foregroundColor(.secondary).monospacedDigit()
                }
            }

            Section("Preview") {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color(.textBackgroundColor)).frame(height: 80)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("func fetchUser(id: String) ").font(.system(size: 13, design: .monospaced))
                        HStack(spacing: 6) {
                            Text("async throws -> User {")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.white.opacity(s.overlayOpacity * 0.8))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(.ultraThinMaterial))
                            Text("⇥")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
                        }
                    }
                    .padding()
                }
            }

            Section("Theme") {
                HStack(spacing: 8) {
                    Image(systemName: "circle.lefthalf.filled").foregroundColor(.secondary)
                    Text("Follows system appearance automatically").foregroundColor(.secondary).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Hotkeys Tab

struct HotkeysTab: View {
    @ObservedObject private var s = AppSettings.shared

    private static let keyOptions: [(code: Int, label: String)] = [
        (48, "Tab (⇥)"), (36, "Return (↩)"), (49, "Space"),
        (53, "Escape"), (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"),
    ]

    var body: some View {
        Form {
            Section("Keyboard Shortcuts") {
                LabeledContent("Accept suggestion") {
                    Picker("", selection: $s.acceptHotkey.keyCode) {
                        ForEach(Self.keyOptions, id: \.code) { o in Text(o.label).tag(o.code) }
                    }
                    .labelsHidden().frame(width: 160)
                }
                LabeledContent("Dismiss suggestion") {
                    Picker("", selection: $s.dismissHotkey.keyCode) {
                        ForEach(Self.keyOptions, id: \.code) { o in Text(o.label).tag(o.code) }
                    }
                    .labelsHidden().frame(width: 160)
                }
                LabeledContent("Manual trigger") {
                    Picker("", selection: $s.manualTriggerHotkey.keyCode) {
                        ForEach(Self.keyOptions, id: \.code) { o in Text(o.label).tag(o.code) }
                    }
                    .labelsHidden().frame(width: 160)
                }
            }
            Section {
                Text("Key conflicts with system shortcuts are not checked automatically.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About Tab

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "text.cursor")
                .font(.system(size: 48))
                .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))

            VStack(spacing: 4) {
                Text("LuminaText").font(.system(size: 22, weight: .bold))
                Text("System-wide LLM Autocompletion").foregroundColor(.secondary)
                Text("Version 1.0.0").font(.caption).foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                FeatureRow(icon: "cpu",           title: "MLX / Ollama / LMStudio", description: "Local inference, zero cloud required")
                FeatureRow(icon: "accessibility", title: "System-wide",             description: "Works in any app via Accessibility API")
                FeatureRow(icon: "keyboard",      title: "Ghost Text",              description: "Press Tab to accept • Esc to dismiss")
                FeatureRow(icon: "bolt",          title: "Actions FAB",             description: "Select text anywhere to transform with AI")
            }
            .padding(.horizontal, 20)

            Spacer()
            Link("View on GitHub", destination: URL(string: "https://github.com")!)
                .foregroundColor(.accentColor).font(.caption)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FeatureRow: View {
    let icon: String; let title: String; let description: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(description).font(.caption).foregroundColor(.secondary)
            }
        }
    }
}
