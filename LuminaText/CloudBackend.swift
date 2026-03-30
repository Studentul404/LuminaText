import Foundation

final class CloudBackend: InferenceBackend {
    let displayName: String
    private let provider: CloudProvider
    private let apiKey: String
    private let model: String
    private let baseURL: String

    init(provider: CloudProvider, apiKey: String, model: String) {
        self.provider = provider
        self.apiKey = apiKey
        self.model = model
        self.baseURL = provider.baseURL
        self.displayName = "\(provider.rawValue) · \(model)"
    }

    func ping() async -> Bool {
        return await isAvailable()
    }

    func isAvailable() async -> Bool {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = provider == .anthropic ? "/messages" : "/models"
        guard let url = URL(string: base + endpoint) else { return false }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        
        if provider == .anthropic {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                print("[LuminaText] Server responded with: \(httpResponse.statusCode)")
                return (200...299).contains(httpResponse.statusCode)
            }
        } catch {
            print("[LuminaText] Connection error: \(error.localizedDescription)")
        }
        return false
    }

    func complete(
        prompt: String,
        systemPrompt: String,
        maxTokens: Int,
        temperature: Double
    ) async -> String? {
        
        if provider == .anthropic {
            return await completeAnthropic(prompt: prompt, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
        } else {
            return await completeOpenAICompatible(prompt: prompt, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
        }
    }

    private func completeOpenAICompatible(
        prompt: String,
        systemPrompt: String,
        maxTokens: Int,
        temperature: Double
    ) async -> String? {
        
        guard let url = URL(string: "\(baseURL)/chat/completions") else { return nil }
        
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": false
        ]
        
        return await sendRequest(url: url, body: body, isAnthropic: false)
    }

    private func completeAnthropic(
        prompt: String,
        systemPrompt: String,
        maxTokens: Int,
        temperature: Double
    ) async -> String? {
        
        guard let url = URL(string: "\(baseURL)/messages") else { return nil }
        
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "system": systemPrompt,
            "messages": [["role": "user", "content": prompt]]
        ]
        
        return await sendRequest(url: url, body: body, isAnthropic: true)
    }

    private func sendRequest(url: URL, body: [String: Any], isAnthropic: Bool) async -> String? {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            if isAnthropic {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let (data, _) = try await URLSession.shared.data(for: request)
            
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if isAnthropic {
                    if let contentArray = json["content"] as? [[String: Any]],
                       let text = contentArray.first?["text"] as? String {
                        return text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    }
                } else {
                    if let choices = json["choices"] as? [[String: Any]],
                       let message = choices.first?["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        return content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    }
                }
            }
        } catch {
            print("[CloudBackend] Error: \(error)")
        }
        return nil
    }
}
