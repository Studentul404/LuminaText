import SwiftUI
import AppKit

// MARK: - Root

struct SettingsView: View {
    @State private var selection: SettingsTab? = .general

    enum SettingsTab: String, Hashable, CaseIterable {
        case general    = "General"
        case models     = "Models"
        case actions    = "Actions"
        case exclusions = "Exclusions"
        case hotkeys    = "Hotkeys"
        case about      = "About"

        var icon: String {
            switch self {
            case .general:    return "gearshape"
            case .models:     return "cpu"
            case .actions:    return "bolt"
            case .exclusions: return "nosign"
            case .hotkeys:    return "keyboard"
            case .about:      return "info.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsTab.allCases, id: \.self, selection: $selection) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            Group {
                switch selection {
                case .general:    GeneralTab()
                case .models:     ModelTab()
                case .actions:    ActionsTab()
                case .exclusions: ExclusionsTab()
                case .hotkeys:    HotkeysTab()
                case .about:      AboutTab()
                case nil:         Text("Select a section").foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 500)
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
    @ObservedObject private var s         = AppSettings.shared
    @ObservedObject private var inference = InferenceManager.shared
    @State private var testOutput = ""
    @State private var isTesting  = false

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
            isTesting  = false
        }
    }
}

// MARK: - Actions Tab

struct ActionsTab: View {
    @ObservedObject private var s = AppSettings.shared
    @State private var selectedID:   UUID? = nil
    @State private var showingNew    = false
    @State private var showImportErr = false
    @State private var importErrMsg  = ""

    private var selectedIndex: Int? {
        guard let id = selectedID else { return nil }
        return s.userActions.firstIndex(where: { $0.id == id })
    }

    var body: some View {
        HSplitView {
            // Sidebar
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

                    Button("Import") { importYAML() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary).padding(.trailing, 8)
                    Button("Export") { exportYAML() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary).padding(.trailing, 8)
                }
                .padding(.vertical, 4).padding(.horizontal, 4)
                .background(Color(.controlBackgroundColor))
            }
            .frame(minWidth: 160, maxWidth: 200)

            // Editor
            Group {
                if let idx = selectedIndex {
                    ActionEditorView(action: $s.userActions[idx])
                } else {
                    VStack {
                        Spacer()
                        Text("Select an action to edit").foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .sheet(isPresented: $showingNew) {
            NewActionSheet { s.userActions.append($0); selectedID = $0.id }
        }
        .alert("Import Error", isPresented: $showImportErr) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importErrMsg)
        }
    }

    // MARK: YAML I/O

    private func exportYAML() {
        let yaml = s.userActions.map { $0.toYAML() }.joined(separator: "\n")
        let panel = NSSavePanel()
        panel.title             = "Export Actions"
        panel.allowedContentTypes = [.yaml]
        panel.nameFieldStringValue = "lumina-actions.yaml"
        if panel.runModal() == .OK, let url = panel.url {
            try? yaml.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func importYAML() {
        let panel = NSOpenPanel()
        panel.title             = "Import Actions"
        panel.allowedContentTypes = [.yaml]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                importErrMsg  = "Could not read the selected file."
                showImportErr = true
                return
            }
            let parsed = UserAction.fromYAML(content)
            if parsed.isEmpty {
                importErrMsg  = "No valid actions found in the file. Ensure it uses the Lumina YAML format."
                showImportErr = true
                return
            }
            // Merge — skip duplicates by ID
            let existingIDs = Set(s.userActions.map { $0.id })
            let newActions  = parsed.filter { !existingIDs.contains($0.id) }
            s.userActions.append(contentsOf: newActions)
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

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("PROMPT TEMPLATE").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text("Use {{input}} for selected text")
                        .font(.caption2).foregroundColor(.secondary)
                }
                TextEditor(text: $action.promptTemplate)
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

    @State private var title      = ""
    @State private var prompt     = ""
    @State private var iconName   = "sparkles"
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
                HStack {
                    Text("Prompt Template").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text("{{input}} = selected text").font(.caption2).foregroundColor(.secondary)
                }
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
                    onCreate(UserAction(title: title, promptTemplate: prompt, iconName: iconName))
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

// MARK: - Exclusions Tab

struct ExclusionsTab: View {
    @ObservedObject private var s = AppSettings.shared
    @State private var selectedBundleID: String? = nil
    @State private var showAddSheet = false
    @State private var manualBundleID = ""

    var body: some View {
        VStack(spacing: 0) {
            List(s.excludedBundleIDs, id: \.self, selection: $selectedBundleID) { bundleID in
                HStack(spacing: 10) {
                    appIcon(for: bundleID)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(appName(for: bundleID)).fontWeight(.medium)
                        Text(bundleID).font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.sidebar)
            .overlay {
                if s.excludedBundleIDs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "nosign").font(.system(size: 32)).foregroundColor(.secondary)
                        Text("No excluded apps").foregroundColor(.secondary)
                        Text("Completions are active in all apps.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            HStack(spacing: 0) {
                // Add current frontmost app
                Button {
                    if let app = NSWorkspace.shared.frontmostApplication,
                       let bid = app.bundleIdentifier,
                       bid != Bundle.main.bundleIdentifier {
                        s.addExclusion(bid)
                    }
                } label: {
                    Image(systemName: "plus").frame(width: 28, height: 24)
                }
                .buttonStyle(.plain)
                .help("Exclude the currently active app")

                Button {
                    guard let id = selectedBundleID else { return }
                    s.removeExclusion(id)
                    selectedBundleID = nil
                } label: {
                    Image(systemName: "minus").frame(width: 28, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(selectedBundleID == nil)

                Spacer()

                Button("Add by ID…") { showAddSheet = true }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary).padding(.trailing, 8)
            }
            .padding(.vertical, 4).padding(.horizontal, 4)
            .background(Color(.controlBackgroundColor))
        }
        .sheet(isPresented: $showAddSheet) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Add App by Bundle ID").font(.headline)
                TextField("com.example.app", text: $manualBundleID)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { showAddSheet = false; manualBundleID = "" }
                        .keyboardShortcut(.cancelAction)
                    Button("Add") {
                        s.addExclusion(manualBundleID.trimmingCharacters(in: .whitespaces))
                        showAddSheet = false; manualBundleID = ""
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(manualBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 340)
        }
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }

    @ViewBuilder
    private func appIcon(for bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.dashed").frame(width: 20, height: 20).foregroundColor(.secondary)
        }
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
                // Engineering Challenge answer — documented inline
                VStack(alignment: .leading, spacing: 6) {
                    Text("Global Hotkey Implementation Notes").font(.caption).fontWeight(.semibold)
                    Text("""
                    Arbitrary modifier combos (e.g. Cmd+Opt+G) are captured via a passive CGEvent tap \
                    (options: .listenOnly, tap: .cgSessionEventTap). This is read-only — the tap never \
                    consumes the event, so it never emits a system beep and never interferes with \
                    Accessibility API consumers. The event is inspected for keyCode + modifierFlags \
                    on the main run loop; if matched, a Task is dispatched to @MainActor. \
                    Under Sandbox, CGEvent taps require the com.apple.security.temporary-exception.\
                    mach-lookup entitlement for the Accessibility server, or the user must grant \
                    Accessibility permission — the same permission LuminaText already requests.
                    """)
                    .font(.caption).foregroundColor(.secondary)
                }
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

// MARK: - UTType extension for YAML

import UniformTypeIdentifiers
extension UTType {
    static let yaml = UTType(filenameExtension: "yaml") ?? .plainText
}
