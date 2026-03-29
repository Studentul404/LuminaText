import Foundation
import Combine

enum CompletionMode {
    case autocomplete
    case transform
}

@MainActor
final class InferenceManager: ObservableObject {
    static let shared = InferenceManager()

    @Published var isReady      = false
    @Published var backendName  = "Loading…"
    @Published var isGenerating = false

    private var backend: InferenceBackend?
    private var pendingTask: Task<String?, Never>?

    private init() {}

    // MARK: - Load

    func loadModel() async {
        backendName = "Loading MLX model…"

        let mlx = MLXBackend()
        if await mlx.load() {
            backend     = mlx
            backendName = "MLX · Qwen2.5-Coder-0.5B"
            isReady     = true
            return
        }

        let ollama = OllamaBackend()
        if await ollama.ping() {
            backend     = ollama
            backendName = ollama.displayName
            isReady     = true
            return
        }

        backendName = "No backend available"
        isReady     = false
    }

    // MARK: - Complete (Mode A — Autocomplete)

    func complete(prompt: String) async -> String? {
        guard isReady, let backend else { return nil }
        pendingTask?.cancel()
        let task = Task<String?, Never> {
            guard !Task.isCancelled else { return nil }
            isGenerating = true
            defer { isGenerating = false }
            return await backend.complete(
                prompt:       prompt,
                systemPrompt: AppSettings.shared.systemPrompt,
                maxTokens:    AppSettings.shared.maxTokens,
                temperature:  AppSettings.shared.temperature
            )
        }
        pendingTask = task
        return await task.value
    }

    // MARK: - Transform (Mode B — Selection + Action)
    //
    // The full rendered prompt (system + {{input}} substitution) goes into
    // systemPrompt. user message is intentionally empty to reduce hallucinations
    // and keep the model on-task.

    func transform(selectedText: String, action: UserAction) async -> String? {
        guard isReady, let backend else { return nil }
        pendingTask?.cancel()
        let task = Task<String?, Never> {
            guard !Task.isCancelled else { return nil }
            isGenerating = true
            defer { isGenerating = false }

            let finalPrompt = AppSettings.shared.renderPrompt(
                template: action.promptTemplate,
                input:    selectedText
            )

            return await backend.complete(
                prompt:       "",           // empty user turn — all context in system prompt
                systemPrompt: finalPrompt,
                maxTokens:    AppSettings.shared.maxTokens,
                temperature:  AppSettings.shared.temperature
            )
        }
        pendingTask = task
        return await task.value
    }
}
