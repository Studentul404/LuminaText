//
//  MLXBackend.swift
//  LuminaText
//
//  Created by Kirill on 28.03.2026.
//


import Foundation

final class MLXBackend: InferenceBackend {
    var displayName: String { "MLX · Qwen2.5-Coder-0.5B" }

    func ping() async -> Bool {
        // MLX ping не реалізовано у стубі (використовується тільки для fallback)
        return false
    }

    /// Метод, який викликається в InferenceManager.loadModel()
    func load() async -> Bool {
        // TODO: Тут буде реальна логіка завантаження MLX-моделі.
        // Наразі повертаємо false, щоб проєкт компілювався та переходив до Ollama.
        return false
    }

    func complete(
        prompt: String,
        systemPrompt: String,
        maxTokens: Int,
        temperature: Double
    ) async -> String? {
        // Не використовується, якщо load() повертає false
        return nil
    }
}