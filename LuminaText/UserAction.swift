import Foundation

struct UserAction: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var title: String
    var iconName: String
    var shortcut: String?
    /// Supports {{input}} placeholder. If absent, entire string is treated as instruction and input is appended.
    var promptTemplate: String

    init(id: UUID = UUID(), title: String, promptTemplate: String, iconName: String, shortcut: String? = nil) {
        self.id             = id
        self.title          = title
        self.promptTemplate = promptTemplate
        self.iconName       = iconName
        self.shortcut       = shortcut
    }

    // Legacy init for callers that pass systemPrompt — maps to promptTemplate
    init(id: UUID = UUID(), title: String, systemPrompt: String, iconName: String, shortcut: String? = nil) {
        self.init(id: id, title: title, promptTemplate: systemPrompt, iconName: iconName, shortcut: shortcut)
    }

    // Renders the final system-prompt string by substituting {{input}} with selectedText.
    func rendered(input: String) -> String {
        if promptTemplate.contains("{{input}}") {
            return promptTemplate.replacingOccurrences(of: "{{input}}", with: input)
        }
        // No placeholder — append input as trailing context
        return promptTemplate + "\n\n" + input
    }

    static func == (lhs: UserAction, rhs: UserAction) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: - YAML

    func toYAML() -> String {
        let escapedTitle    = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedIcon     = iconName.replacingOccurrences(of: "\"", with: "\\\"")
        let indentedPrompt  = promptTemplate
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    " + $0 }
            .joined(separator: "\n")
        var yaml = """
        - id: "\(id.uuidString)"
          title: "\(escapedTitle)"
          icon: "\(escapedIcon)"
          prompt: |
        \(indentedPrompt)
        """
        if let s = shortcut { yaml += "\n  shortcut: \"\(s)\"" }
        return yaml
    }

    /// Minimal line-based YAML parser — no external dependencies.
    /// Supports the format produced by toYAML(). For full YAML use Yams.
    static func fromYAML(_ yaml: String) -> [UserAction] {
        var results: [UserAction] = []
        let lines = yaml.components(separatedBy: .newlines)
        var i = 0

        while i < lines.count {
            let line = lines[i]
            // New action block starts with "- id:"
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("- id:") {
                var idStr = ""
                var title = ""
                var icon  = "sparkles"
                var shortcut: String? = nil
                var promptLines: [String] = []
                var inPromptBlock = false

                idStr = yamlValue(from: line)
                i += 1

                while i < lines.count {
                    let inner = lines[i]
                    let trimmed = inner.trimmingCharacters(in: .whitespaces)

                    // Next top-level item — stop
                    if trimmed.hasPrefix("- id:") { break }

                    if inPromptBlock {
                        // Block scalar ends when indent drops back to 2 spaces or less
                        if inner.hasPrefix("    ") || inner.hasPrefix("\t   ") {
                            promptLines.append(String(inner.dropFirst(4)))
                        } else if trimmed.isEmpty {
                            promptLines.append("")
                        } else {
                            inPromptBlock = false
                            // Parse this line normally (fall through below)
                            if trimmed.hasPrefix("shortcut:") { shortcut = yamlValue(from: inner) }
                            i += 1; continue
                        }
                        i += 1; continue
                    }

                    if trimmed.hasPrefix("title:")    { title = yamlValue(from: inner) }
                    else if trimmed.hasPrefix("icon:") { icon  = yamlValue(from: inner) }
                    else if trimmed.hasPrefix("shortcut:") { shortcut = yamlValue(from: inner) }
                    else if trimmed.hasPrefix("prompt:") { inPromptBlock = true }
                    i += 1
                }

                let prompt = promptLines
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .newlines)

                if !title.isEmpty, !prompt.isEmpty {
                    let uuid = UUID(uuidString: idStr) ?? UUID()
                    results.append(UserAction(id: uuid, title: title,
                                              promptTemplate: prompt, iconName: icon,
                                              shortcut: shortcut))
                }
            } else {
                i += 1
            }
        }
        return results
    }

    private static func yamlValue(from line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        let raw = String(line[line.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        // Strip surrounding quotes
        if (raw.hasPrefix("\"") && raw.hasSuffix("\"")) ||
           (raw.hasPrefix("'")  && raw.hasSuffix("'")) {
            return String(raw.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
        }
        return raw
    }

    // MARK: - Defaults

    static let defaults: [UserAction] = [
        UserAction(title: "Grammar Fix",
                   promptTemplate: "Fix all grammar and spelling errors. Output ONLY the corrected text.\n\n{{input}}",
                   iconName: "text.badge.checkmark", shortcut: "g"),
        UserAction(title: "Summarize",
                   promptTemplate: "Summarize concisely. Output ONLY the summary.\n\n{{input}}",
                   iconName: "doc.plaintext"),
        UserAction(title: "Polish",
                   promptTemplate: "Rewrite to be polished and professional. Output ONLY the result.\n\n{{input}}",
                   iconName: "wand.and.stars"),
        UserAction(title: "Bullets",
                   promptTemplate: "Convert to a clean bullet list. Output ONLY the bullets.\n\n{{input}}",
                   iconName: "list.bullet"),
        UserAction(title: "Add Emoji",
                   promptTemplate: "Enrich with relevant emoji. Output ONLY the enriched text.\n\n{{input}}",
                   iconName: "face.smiling"),
        UserAction(title: "Professional",
                   promptTemplate: "Rewrite in a formal professional tone. Output ONLY the result.\n\n{{input}}",
                   iconName: "briefcase"),
        UserAction(title: "Casual",
                   promptTemplate: "Rewrite in a friendly casual tone. Output ONLY the result.\n\n{{input}}",
                   iconName: "bubble.left"),
    ]
}
