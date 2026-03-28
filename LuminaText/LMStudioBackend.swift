import Foundation

final class LMStudioBackend: InferenceBackend {
    let displayName = "LM Studio"

    func ping() async -> Bool {
        let urlString = AppSettings.shared.lmStudioHost + "/models"
        guard let url = URL(string: urlString) else { return false }
        
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func complete(
        prompt: String,
        systemPrompt: String,
        maxTokens: Int,
        temperature: Double
    ) async -> String? {
        let urlString = AppSettings.shared.lmStudioHost + "/chat/completions"
        guard let url = URL(string: urlString) else { return nil }

        let body: [String: Any] = [
            "model": AppSettings.shared.lmStudioModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": false
        ]

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, _) = try await URLSession.shared.data(for: request)
            
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            print("[LMStudioBackend] Error: \(error)")
        }
        return nil
    }
}
