import Foundation
import Combine

// MARK: - Completion Mode

enum CompletionMode {
    case autocomplete   // Mode A — triggered by typing
    case transform      // Mode B — triggered by selection + FAB action
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
            
            return await backend.complete(
                prompt: prompt,
                systemPrompt: AppSettings.shared.systemPrompt,
                maxTokens: AppSettings.shared.maxTokens,
                temperature: AppSettings.shared.temperature
            )
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
            
            // Використовуємо systemPrompt з нової структури UserAction
            return await backend.complete(
                prompt: selectedText,
                systemPrompt: action.systemPrompt,
                maxTokens: AppSettings.shared.maxTokens,
                temperature: AppSettings.shared.temperature
            )
        }
        pendingTask = task
        return await task.value
    }
}
