import Foundation
import Combine

// MARK: - Completion Mode

enum CompletionMode {
    case autocomplete   // Mode A — triggered by typing
    case transform      // Mode B — triggered by selection + FAB action
}

// MARK: - UserAction

struct UserAction: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var prompt: String      // Instruction prompt for this action
    var sfSymbol: String    // SF Symbol name for the icon

    init(id: UUID = UUID(), title: String, prompt: String, sfSymbol: String) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.sfSymbol = sfSymbol
    }

    static let defaults: [UserAction] = [
        UserAction(
            title: "Fix Grammar",
            prompt: "Fix the grammar and spelling of the text. Output only the corrected text, no explanations.",
            sfSymbol: "textformat.abc"
        ),
        UserAction(
            title: "Make Shorter",
            prompt: "Shorten the following text while preserving its meaning. Output only the shortened text.",
            sfSymbol: "arrow.down.right.and.arrow.up.left"
        ),
        UserAction(
            title: "Make Formal",
            prompt: "Rewrite the following text in a formal, professional tone. Output only the rewritten text.",
            sfSymbol: "briefcase"
        ),
        UserAction(
            title: "Explain Code",
            prompt: "Explain what the following code does in plain English. Be concise.",
            sfSymbol: "questionmark.circle"
        ),
    ]
}

// MARK: - InferenceManager

@MainActor
final class InferenceManager: ObservableObject {
    static let shared = InferenceManager()

    @Published var isReady = false
    @Published var backendName = "Loading…"
    @Published var isGenerating = false

    private var backend: InferenceBackend?
    private var pendingTask: Task<String?, Never>?

    private init() {}

    // MARK: - Load

    func loadModel() async {
        backendName = "Loading MLX model…"

        let mlx = MLXBackend()
        if await mlx.load() {
            backend = mlx
            backendName = "MLX · Qwen2.5-Coder-0.5B"
            isReady = true
            return
        }

        let ollama = OllamaBackend()
        if await ollama.ping() {
            backend = ollama
            backendName = ollama.displayName
            isReady = true
            return
        }

        backendName = "No backend available"
        isReady = false
    }

    // MARK: - Complete (Mode A — Autocomplete)

    func complete(prompt: String) async -> String? {
        guard isReady, let backend else { return nil }
        pendingTask?.cancel()
        let task = Task<String?, Never> {
            guard !Task.isCancelled else { return nil }
            isGenerating = true
            defer { isGenerating = false }
            return await backend.complete(prompt: prompt, maxTokens: AppSettings.shared.maxTokens)
        }
        pendingTask = task
        return await task.value
    }

    // MARK: - Transform (Mode B — Selection + Action)

    func transform(selectedText: String, action: UserAction) async -> String? {
        guard isReady, let backend else { return nil }
        pendingTask?.cancel()
        let task = Task<String?, Never> {
            guard !Task.isCancelled else { return nil }
            isGenerating = true
            defer { isGenerating = false }
            let combinedPrompt = "\(action.prompt)\n\nText:\n\(selectedText)"
            return await backend.complete(prompt: combinedPrompt, maxTokens: AppSettings.shared.maxTokens)
        }
        pendingTask = task
        return await task.value
    }
}

// MARK: - AppSettings (central store)

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private static let userActionsKey = "userActions"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "isEnabled") }
    }
    @Published var maxTokens: Int {
        didSet { UserDefaults.standard.set(maxTokens, forKey: "maxTokens") }
    }
    @Published var temperature: Double {
        didSet { UserDefaults.standard.set(temperature, forKey: "temperature") }
    }
    @Published var ollamaHost: String {
        didSet { UserDefaults.standard.set(ollamaHost, forKey: "ollamaHost") }
    }
    @Published var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: "ollamaModel") }
    }
    @Published var triggerDelay: Double {
        didSet { UserDefaults.standard.set(triggerDelay, forKey: "triggerDelay") }
    }
    @Published var overlayOpacity: Double {
        didSet { UserDefaults.standard.set(overlayOpacity, forKey: "overlayOpacity") }
    }
    @Published var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt") }
    }
    @Published var acceptHotkeyCode: Int {
        didSet { UserDefaults.standard.set(acceptHotkeyCode, forKey: "acceptHotkeyCode") }
    }
    @Published var dismissHotkeyCode: Int {
        didSet { UserDefaults.standard.set(dismissHotkeyCode, forKey: "dismissHotkeyCode") }
    }

    // MARK: UserActions — persisted as JSON

    @Published var userActions: [UserAction] {
        didSet { saveUserActions() }
    }

    private func saveUserActions() {
        guard let data = try? JSONEncoder().encode(userActions) else { return }
        UserDefaults.standard.set(data, forKey: Self.userActionsKey)
    }

    private static func loadUserActions() -> [UserAction] {
        guard
            let data = UserDefaults.standard.data(forKey: userActionsKey),
            let decoded = try? JSONDecoder().decode([UserAction].self, from: data)
        else {
            return UserAction.defaults
        }
        return decoded
    }

    private init() {
        let d = UserDefaults.standard
        isEnabled         = d.object(forKey: "isEnabled")         as? Bool   ?? true
        maxTokens         = d.object(forKey: "maxTokens")         as? Int    ?? 60
        temperature       = d.object(forKey: "temperature")       as? Double ?? 0.2
        ollamaHost        = d.object(forKey: "ollamaHost")        as? String ?? "http://localhost:11434"
        ollamaModel       = d.object(forKey: "ollamaModel")       as? String ?? "qwen2.5-coder:0.5b"
        triggerDelay      = d.object(forKey: "triggerDelay")      as? Double ?? 0.4
        overlayOpacity    = d.object(forKey: "overlayOpacity")    as? Double ?? 0.55
        acceptHotkeyCode  = d.object(forKey: "acceptHotkeyCode")  as? Int    ?? 48  // Tab
        dismissHotkeyCode = d.object(forKey: "dismissHotkeyCode") as? Int    ?? 53  // Esc
        systemPrompt      = d.object(forKey: "systemPrompt")      as? String ?? """
You are a ghostwriter and expert programmer. \
Your goal is to provide the most likely continuation of the text provided by the user. \
Rules:
1. Output ONLY the completion.
2. Maintain the style, indentation, and language of the input.
3. Do not repeat the input text.
4. Stop immediately after completing the current logical thought or block.
"""
        userActions = AppSettings.loadUserActions()
    }
}