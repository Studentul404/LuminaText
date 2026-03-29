import Foundation

final class OllamaBackend: InferenceBackend {
    var displayName: String { "Ollama · \(AppSettings.shared.ollamaModel)" }

    func ping() async -> Bool {
        guard let url = URL(string: "\(AppSettings.shared.ollamaHost)/api/tags") else {
            return false
        }
        
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
    
    /// Повертає список усіх локально доступних моделей Ollama
    func discoverModels() async -> [String] {
        guard let url = URL(string: "\(AppSettings.shared.ollamaHost)/api/tags") else {
            return []
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                print("[OllamaBackend] discoverModels: Invalid status code")
                return []
            }
            
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let modelsArray = json["models"] as? [[String: Any]] {
                
                let modelNames = modelsArray.compactMap { modelDict in
                    modelDict["name"] as? String
                }
                return modelNames
            }
        } catch {
            print("[OllamaBackend] discoverModels error: \(error.localizedDescription)")
        }
        
        return []
    }

    func complete(
        prompt: String,
        systemPrompt: String,
        maxTokens: Int,
        temperature: Double
    ) async -> String? {
        guard let url = URL(string: "\(AppSettings.shared.ollamaHost)/api/generate") else {
            return nil
        }

        let fullPrompt = systemPrompt.isEmpty ? prompt : "\(systemPrompt)\n\n\(prompt)"

        let body: [String: Any] = [
            "model": AppSettings.shared.ollamaModel,
            "prompt": fullPrompt,
            "stream": false,
            "options": [
                "num_predict": maxTokens,
                "temperature": temperature,
                "stop": ["\n\n", "```", "<|im_end|>", "<|end|>"]
            ]
        ]

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, _) = try await URLSession.shared.data(for: request)
            
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let responseText = json["response"] as? String {
                
                return responseText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            }
        } catch {
            print("[OllamaBackend] Error: \(error)")
        }
        return nil
    }
}
