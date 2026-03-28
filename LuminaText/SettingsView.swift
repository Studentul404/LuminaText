// File: SettingsView.swift
import SwiftUI

// MARK: - Root

struct SettingsView: View {
    @State private var selection: Int? = 1  // Default to Model tab
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("General",    systemImage: "gearshape").tag(0)
                Label("Model",      systemImage: "cpu").tag(1)
                Label("Cloud",      systemImage: "cloud").tag(2)
                Label("Hotkeys",    systemImage: "keyboard").tag(3)
                Label("Appearance", systemImage: "paintbrush").tag(4)
                Label("About",      systemImage: "info.circle").tag(5)
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
        } detail: {
            switch selection {
            case 0: GeneralTab()
            case 1: ModelTab()
            case 2: CloudTab()
            case 3: HotkeysTab()
            case 4: AppearTab()
            case 5: AboutTab()
            default: Text("Select a category")
            }
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}

// MARK: - GeneralTab

struct GeneralTab: View {
    @ObservedObject private var s = AppSettings.shared

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Enable completions", isOn: $s.isEnabled)
                sliderRow("Trigger delay", value: $s.triggerDelay, range: 0.3...1.2, step: 0.1, fmt: "%.1fs")
            }

            Section("Generation Limits") {
                sliderRow("Max tokens", value: intBinding(\.maxTokens), range: 30...120, step: 5, fmt: "%.0f")
                HStack {
                    Text("Temperature")
                    Slider(value: $s.temperature, in: 0.0...0.4, step: 0.05)
                    Text(String(format: "%.2f", s.temperature)).frame(width: 38).foregroundColor(.secondary)
                }
            }

            Section("Context Metadata") {
                Toggle("Inject current date", isOn: $s.injectDate)
                Toggle("Inject app name",     isOn: $s.injectAppName)
                LabeledContent("Custom context") {
                    TextField("Senior Backend Engineer", text: $s.customContext)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Use placeholders in System Prompt: {{app_name}}, {{date}}, {{input}}, {{custom_context}}")
                    .font(.caption2).foregroundColor(.secondary)
            }

            Section("Permissions") {
                HStack {
                    Image(systemName: AXIsProcessTrusted() ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(AXIsProcessTrusted() ? .green : .red)
                    Text(AXIsProcessTrusted() ? "Accessibility granted" : "Accessibility access required")
                    Spacer()
                    if !AXIsProcessTrusted() {
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped).padding()
    }

    private func sliderRow(_ title: String, value: Binding<Double>,
                            range: ClosedRange<Double>, step: Double, fmt: String) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range, step: step)
            Text(String(format: fmt, value.wrappedValue))
                .frame(width: 44).foregroundColor(.secondary)
        }
    }

    private func intBinding(_ kp: ReferenceWritableKeyPath<AppSettings, Int>) -> Binding<Double> {
        Binding(get: { Double(AppSettings.shared[keyPath: kp]) },
                set: { AppSettings.shared[keyPath: kp] = Int($0) })
    }
}

// MARK: - ModelTab

struct ModelTab: View {
    @ObservedObject private var s  = AppSettings.shared
    @ObservedObject private var im = InferenceManager.shared
    @State private var testOut   = ""
    @State private var isTesting = false
    @State private var scanning  = false

    var body: some View {
        Form {
            Section("Active Backend") {
                HStack {
                    Circle().fill(im.isReady ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(im.backendName)
                    Spacer()
                    if im.isGenerating { ProgressView().controlSize(.small) }
                }
                Button("Reload Backend") { Task { await im.loadModel() } }.controlSize(.small)
            }

            Section("Inference Mode") {
                Picker("Mode", selection: $s.inferenceMode) {
                    ForEach(InferenceMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                
                Text("Current mode prompt (editable below)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // === EDITABLE SYSTEM PROMPT FOR ANY MODEL/MODE ===
            Section("System Prompt — editable for any model/mode") {
                TextEditor(text: $s.systemPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 140)
                    .scrollContentBackground(.hidden)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(6)
                
                HStack(spacing: 8) {
                    Button("Apply Current Mode Default") {
                        s.systemPrompt = s.inferenceMode.systemPrompt
                    }
                    .controlSize(.small)
                    
                    Button("Reset Session") {
                        s.resetSession()
                    }
                    .controlSize(.small)
                    .foregroundColor(.red)
                    
                    Spacer()
                    
                    Button("Save as Custom") {
                        // Auto-saved via @Published
                    }
                    .controlSize(.small)
                    .foregroundColor(.secondary)
                }
                
                Text("This prompt is used by **any** backend (Ollama / Cloud / LM Studio). Changes apply immediately.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Section("Ollama") {
                LabeledContent("Host") {
                    TextField("http://localhost:11434", text: $s.ollamaHost)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                }
                if s.availableOllamaModels.isEmpty {
                    LabeledContent("Model") {
                        TextField("qwen2.5-coder:0.5b", text: $s.ollamaModel)
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                } else {
                    Picker("Model", selection: $s.ollamaModel) {
                        ForEach(s.availableOllamaModels, id: \.self) { Text($0).tag($0) }
                    }
                }
                HStack {
                    Button(scanning ? "Scanning…" : "Discover Models") {
                        scanning = true
                        Task {
                            s.availableOllamaModels = await OllamaBackend().discoverModels()
                            scanning = false
                        }
                    }.disabled(scanning).controlSize(.small)
                    if scanning { ProgressView().controlSize(.mini) }
                }
            }

            Section("Test Completion") {
                HStack {
                    Button("Run Test (current prompt)") {
                        runTest()
                    }
                    .disabled(isTesting || !im.isReady)
                    if isTesting { ProgressView().controlSize(.small).padding(.leading, 4) }
                }
                if !testOut.isEmpty {
                    Text(testOut)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.textBackgroundColor))
                        .cornerRadius(6)
                }
            }
        }
        .formStyle(.grouped).padding()
    }

    private func runTest() {
        isTesting = true
        testOut = ""
        Task {
            let r = await InferenceManager.shared.complete(prompt: "The quick brown fox", appName: "Test")
            await MainActor.run {
                testOut = r ?? "(no result)"
                isTesting = false
            }
        }
    }
}

// MARK: - CloudTab

struct CloudTab: View {
    @ObservedObject private var s = AppSettings.shared
    @State private var testing    = false
    @State private var testResult = ""

    var body: some View {
        Form {
            Section("Cloud Inference") {
                Toggle("Use cloud backend", isOn: $s.useCloudBackend)
                Text("Cloud takes priority over local backends. Requires a valid API key.")
                    .font(.caption2).foregroundColor(.secondary)
            }

            if s.useCloudBackend {
                Section("Provider") {
                    Picker("Provider", selection: $s.cloudProvider) {
                        ForEach(CloudProvider.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .onChange(of: s.cloudProvider) { _, newValue in
                        s.cloudModel = newValue.defaultModel
                    }

                    LabeledContent("API Key") {
                        SecureField("sk-…", text: $s.cloudApiKey)
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                    LabeledContent("Model") {
                        TextField(s.cloudProvider.defaultModel, text: $s.cloudModel)
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                    LabeledContent("Endpoint") {
                        Text(s.cloudProvider.baseURL).font(.caption).foregroundColor(.secondary)
                    }
                }

                Section("Test") {
                    HStack {
                        Button(testing ? "Testing…" : "Test Connection") { testCloud() }
                            .disabled(testing || s.cloudApiKey.isEmpty)
                        if testing { ProgressView().controlSize(.small) }
                    }
                    if !testResult.isEmpty {
                        Text(testResult).font(.caption)
                            .foregroundColor(testResult.hasPrefix("✓") ? .green : .red)
                    }
                }
            }
        }
        .formStyle(.grouped).padding()
    }

    private func testCloud() {
        testing = true; testResult = ""
        Task {
            let b  = CloudBackend(provider: s.cloudProvider, apiKey: s.cloudApiKey, model: s.cloudModel)
            let ok = await b.ping()
            await MainActor.run {
                testResult = ok
                    ? "✓ Connected to \(s.cloudProvider.rawValue)"
                    : "✗ Failed — check API key and model name"
                testing = false
            }
        }
    }
}

// MARK: - HotkeysTab

struct HotkeysTab: View {
    @ObservedObject private var s = AppSettings.shared

    var body: some View {
        Form {
            Section("Completion") {
                hotkeyRow("Accept suggestion",  s.acceptHotkey)
                hotkeyRow("Dismiss suggestion", s.dismissHotkey)
            }
            Section("Trigger") {
                hotkeyRow("Manual trigger", s.manualTriggerHotkey)
            }
            Section {
                Button("Reset All to Defaults") {
                    s.acceptHotkey        = .defaultAccept
                    s.dismissHotkey       = .defaultDismiss
                    s.manualTriggerHotkey = .defaultTrigger
                }.foregroundColor(.red)
            }
            Section {
                Text("Full hotkey recording requires a custom NSView component. Edit HotkeyConfig values in AppSettings to remap keys programmatically.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped).padding()
    }

    private func hotkeyRow(_ label: String, _ cfg: HotkeyConfig) -> some View {
        HStack {
            Image(systemName: "keyboard").foregroundColor(.secondary)
            Text(label)
            Spacer()
            Text(cfg.label)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(5)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}

// MARK: - Appearance

struct AppearTab: View {
    @ObservedObject private var s = AppSettings.shared

    var body: some View {
        Form {
            Section("System") {
                Toggle("Dark mode", isOn: Binding(
                    get: { s.useDarkMode },
                    set: {
                        s.useDarkMode = $0
                        NotificationCenter.default.post(name: .appearanceChanged, object: nil)
                    }
                ))
            }

            Section("Overlay Opacity") {
                HStack {
                    Text("Opacity")
                    Slider(value: $s.overlayOpacity, in: 0.2...1.0, step: 0.05)
                    Text(String(format: "%.0f%%", s.overlayOpacity * 100))
                        .frame(width: 40).foregroundColor(.secondary)
                }
            }

            Section("Preview") {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(s.useDarkMode ? Color.black : Color(.textBackgroundColor))
                        .frame(height: 90)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("func fetchUser(id: String) ")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(s.useDarkMode ? .white : .primary)
                        HStack(spacing: 6) {
                            Text("async throws -> User {")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(
                                    (s.useDarkMode ? Color.white : Color.black).opacity(s.overlayOpacity))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(s.useDarkMode
                                              ? AnyShapeStyle(Color.black.opacity(0.88))
                                              : AnyShapeStyle(Material.ultraThinMaterial))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 7)
                                                .strokeBorder(
                                                    s.useDarkMode
                                                        ? Color.white.opacity(0.1)
                                                        : Color.black.opacity(0.08),
                                                    lineWidth: 0.5)
                                        )
                                )
                            Text(s.acceptHotkey.label)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor((s.useDarkMode ? Color.white : Color.black).opacity(0.35))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.1)))
                        }
                    }.padding()
                }
            }
        }
        .formStyle(.grouped).padding()
    }
}

// MARK: - About

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "text.cursor")
                .font(.system(size: 46))
                .foregroundStyle(LinearGradient(colors: [.blue, .purple],
                    startPoint: .topLeading, endPoint: .bottomTrailing))

            VStack(spacing: 3) {
                Text("LuminaText").font(.system(size: 22, weight: .bold))
                Text("System-wide LLM Autocompletion").foregroundColor(.secondary)
                Text("Version 2.0.0").font(.caption).foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                aboutRow("cpu",            "MLX Inference",       "Qwen2.5-Coder-0.5B locally via mlx-swift")
                aboutRow("server.rack",    "Ollama + Discovery",  "Auto-discovers locally available models")
                aboutRow("cloud",          "Cloud Bridge",        "OpenAI, Anthropic, Groq, OpenRouter")
                aboutRow("wand.and.stars", "Text Transforms",     "Grammar, summarize, polish, bullets, and more")
                aboutRow("accessibility",  "System-wide",         "Works in any app via Accessibility API")
                aboutRow("keyboard",       "Configurable Hotkeys","Remap accept/dismiss to avoid OS conflicts")
            }
            .padding(.horizontal, 20)

            Spacer()

            Link("View on GitHub", destination: URL(string: "https://github.com")!)
                .foregroundColor(.accentColor).font(.caption)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func aboutRow(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(desc).font(.caption).foregroundColor(.secondary)
            }
        }
    }
}
