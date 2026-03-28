// File: InferenceManager.swift
import Foundation
import Combine
import AppKit

// MARK: - InferenceBackend Protocol

protocol InferenceBackend {
    var displayName: String { get }
    func ping() async -> Bool
    func complete(prompt: String, systemPrompt: String, maxTokens: Int, temperature: Double) async -> String?
}

// MARK: - InferenceManager

@MainActor
final class InferenceManager: ObservableObject {
    static let shared = InferenceManager()

    @Published var isReady = false
    @Published var backendName = "Loading..."
    @Published var isGenerating = false

    private(set) var activeBackend: InferenceBackend?

    private var lastPromptHash: Int = 0
    private var lastGenerationTime: Date = .distantPast

    private init() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleSessionReset),
                                               name: .sessionReset, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleSessionReset() {
        lastPromptHash = 0
        lastGenerationTime = .distantPast
    }

    // MARK: - Public API

    func complete(prompt: String, appName: String) async -> String? {
        let s = AppSettings.shared
        var finalSystemPrompt = s.systemPrompt

        if s.injectAppName {
            finalSystemPrompt = finalSystemPrompt.replacingOccurrences(of: "{{app_name}}", with: appName)
        } else {
            finalSystemPrompt = finalSystemPrompt.replacingOccurrences(of: "{{app_name}}", with: "Unknown App")
        }

        if s.injectDate {
            let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
            finalSystemPrompt = finalSystemPrompt.replacingOccurrences(of: "{{date}}", with: dateStr)
        } else {
            finalSystemPrompt = finalSystemPrompt.replacingOccurrences(of: "{{date}}", with: "")
        }

        finalSystemPrompt = finalSystemPrompt.replacingOccurrences(of: "{{input}}", with: prompt)

        if !s.customContext.isEmpty {
            finalSystemPrompt = finalSystemPrompt.replacingOccurrences(of: "{{custom_context}}", with: s.customContext)
        } else {
            finalSystemPrompt = finalSystemPrompt.replacingOccurrences(of: "{{custom_context}}", with: "")
        }

        return await generateResponse(prompt: prompt, systemPrompt: finalSystemPrompt)
    }

    func transform(text: String, mode: TransformMode) async -> String? {
        let system = mode.systemPrompt
        return await generateResponse(prompt: text, systemPrompt: system)
    }

    /// Runs a UserAction against the selected text, resolving all $Variables first.
    func run(action: UserAction, selectedText: String, appName: String) async -> String? {
        let resolved = resolveTemplate(action.systemPrompt, selectedText: selectedText, appName: appName)
        return await generateResponse(prompt: selectedText, systemPrompt: resolved)
    }

    // MARK: - Template Engine
    // Supported variables: $AppName, $CurrentDate, $Clipboard, $SelectedText

    func resolveTemplate(_ template: String, selectedText: String, appName: String) -> String {
        var result = template

        result = result.replacingOccurrences(of: "$AppName", with: appName)

        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
        result = result.replacingOccurrences(of: "$CurrentDate", with: dateStr)

        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        result = result.replacingOccurrences(of: "$Clipboard", with: clipboard)

        result = result.replacingOccurrences(of: "$SelectedText", with: selectedText)

        return result
    }

    // MARK: - Core Inference

    func generateResponse(prompt: String, systemPrompt: String) async -> String? {
        guard let backend = activeBackend else { return nil }

        let currentHash = prompt.hashValue
        if currentHash == lastPromptHash && Date().timeIntervalSince(lastGenerationTime) < 0.8 {
            return nil
        }

        isGenerating = true
        defer {
            isGenerating = false
            lastPromptHash = currentHash
            lastGenerationTime = Date()
        }

        return await backend.complete(
            prompt: prompt,
            systemPrompt: systemPrompt,
            maxTokens: AppSettings.shared.maxTokens,
            temperature: AppSettings.shared.temperature
        )
    }

    // MARK: - Backend Lifecycle

    func loadModel() async {
        isReady = false
        backendName = "Initializing..."
        activeBackend = nil

        let s = AppSettings.shared

        if s.useCloudBackend && !s.cloudApiKey.isEmpty {
            let cloud = CloudBackend(provider: s.cloudProvider, apiKey: s.cloudApiKey, model: s.cloudModel)
            if await cloud.ping() { setup(backend: cloud); return }
        }

        let mlx = MLXBackend()
        if await mlx.load() { setup(backend: mlx); return }

        let ollama = OllamaBackend()
        if await ollama.ping() { setup(backend: ollama); return }

        backendName = "No Backend Available"
    }

    private func setup(backend: InferenceBackend) {
        self.activeBackend = backend
        self.backendName = backend.displayName
        self.isReady = true
    }
}

// MARK: - MLX Backend (stub)

final class MLXBackend: InferenceBackend {
    let displayName = "MLX · Local"
    func load() async -> Bool { return false }
    func ping() async -> Bool { return false }
    func complete(prompt: String, systemPrompt: String, maxTokens: Int, temperature: Double) async -> String? { nil }
}
