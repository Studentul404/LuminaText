import Foundation

protocol InferenceBackend {
    var displayName: String { get }
    func ping() async -> Bool
    func complete(
        prompt: String,
        systemPrompt: String,
        maxTokens: Int,
        temperature: Double
    ) async -> String?
}
