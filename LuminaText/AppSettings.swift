import Foundation
import Combine

// MARK: - Enums

enum InferenceMode: String, CaseIterable, Identifiable, Codable {
    case auto   = "Auto"
    case coder  = "Coder"
    case prose  = "Prose"
    case fast   = "Fast"
    var id: String { rawValue }

    var systemPrompt: String {
        switch self {
        case .auto:  return AppSettings.defaultSystemPromptAuto
        case .coder: return AppSettings.defaultSystemPromptCoder
        case .prose: return AppSettings.defaultSystemPromptProse
        case .fast:  return AppSettings.defaultSystemPromptFast
        }
    }
}

enum TransformMode: String, CaseIterable, Identifiable, Codable {
    case autocomplete = "Autocomplete"
    case grammar      = "Grammar Fix"
    case summarize    = "Summarize"
    case polish       = "Polish"
    case bullets      = "Bullets"
    case emoji        = "Add Emoji"
    case professional = "Professional"
    case casual       = "Casual"
    var id: String { rawValue }

    var systemPrompt: String {
        switch self {
        case .autocomplete:  return AppSettings.shared.inferenceMode.systemPrompt
        case .grammar:       return "Fix all grammar and spelling errors. Output ONLY the corrected text."
        case .summarize:     return "Summarize concisely. Output ONLY the summary."
        case .polish:        return "Rewrite to be polished and professional. Output ONLY the result."
        case .bullets:       return "Convert to a clean bullet list. Output ONLY the bullets."
        case .emoji:         return "Enrich with relevant emoji. Output ONLY the enriched text."
        case .professional:  return "Rewrite in a formal professional tone. Output ONLY the result."
        case .casual:        return "Rewrite in a friendly casual tone. Output ONLY the result."
        }
    }
}

enum CloudProvider: String, CaseIterable, Identifiable, Codable {
    case openAI     = "OpenAI"
    case anthropic  = "Anthropic"
    case groq       = "Groq"
    case openRouter = "OpenRouter"
    case LMStudio   = "LMStudio"
    var id: String { rawValue }

    var baseURL: String {
        switch self {
        case .openAI:     return "https://api.openai.com/v1"
        case .anthropic:  return "https://api.anthropic.com/v1"
        case .groq:       return "https://api.groq.com/openai/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .LMStudio:   return "http://127.0.0.1:1234/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI:     return "gpt-4o-mini"
        case .anthropic:  return "claude-3-5-haiku-latest"
        case .groq:       return "llama-3.1-8b-instant"
        case .openRouter: return "mistralai/mistral-7b-instruct"
        case .LMStudio:   return "liquid/lfm2-1.2b"
        }
    }
}

// MARK: - HotkeyConfig

struct HotkeyConfig: Codable, Equatable {
    var keyCode:       Int
    var modifierFlags: UInt64
    var label:         String

    static let defaultAccept  = HotkeyConfig(keyCode: 48, modifierFlags: 0,      label: "⇥ Tab")
    static let defaultDismiss = HotkeyConfig(keyCode: 53, modifierFlags: 0,      label: "Esc")
    static let defaultTrigger = HotkeyConfig(keyCode: 49, modifierFlags: 262144, label: "⌃ Space")
}

// MARK: - Notifications

extension Notification.Name {
    static let suggestionAccepted  = Notification.Name("com.luminatext.suggestionAccepted")
    static let suggestionDismissed = Notification.Name("com.luminatext.suggestionDismissed")
    static let appearanceChanged   = Notification.Name("com.luminatext.appearanceChanged")
    static let sessionReset        = Notification.Name("com.luminatext.sessionReset")
}

// MARK: - AppSettings

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    // MARK: UI & Experience
    @Published var isEnabled:       Bool   { didSet { ud("isEnabled",       isEnabled)       } }
    @Published var triggerDelay:    Double { didSet { ud("triggerDelay",    triggerDelay)    } }
    @Published var overlayOpacity:  Double { didSet { ud("overlayOpacity",  overlayOpacity)  } }
    @Published var useDarkMode:     Bool   { didSet { ud("useDarkMode",     useDarkMode)     } }

    // MARK: Context Injection
    @Published var injectDate:      Bool   { didSet { ud("injectDate",      injectDate)      } }
    @Published var injectAppName:   Bool   { didSet { ud("injectAppName",   injectAppName)   } }
    @Published var customContext:   String { didSet { ud("customContext",    customContext)   } }

    // MARK: Generation Parameters
    @Published var minTokens:       Int    { didSet { ud("minTokens",       minTokens)       } }
    @Published var maxTokens:       Int    { didSet { ud("maxTokens",       maxTokens)       } }
    @Published var temperature:     Double { didSet { ud("temperature",     temperature)     } }
    @Published var systemPrompt:    String { didSet { ud("systemPrompt",    systemPrompt)    } }

    // MARK: Ollama Backend
    @Published var ollamaHost:      String { didSet { ud("ollamaHost",      ollamaHost)      } }
    @Published var ollamaModel:     String { didSet { ud("ollamaModel",     ollamaModel)     } }
    @Published var availableOllamaModels: [String] = []

    // MARK: LM Studio Backend
    @Published var lmStudioHost:    String { didSet { ud("lmStudioHost",    lmStudioHost)    } }
    @Published var lmStudioModel:   String { didSet { ud("lmStudioModel",   lmStudioModel)   } }

    // MARK: Cloud Backend
    @Published var useCloudBackend: Bool   { didSet { ud("useCloudBackend", useCloudBackend) } }
    @Published var cloudApiKey:     String { didSet { ud("cloudApiKey",     cloudApiKey)     } }
    @Published var cloudModel:      String { didSet { ud("cloudModel",      cloudModel)      } }

    // MARK: User Actions Registry
    @Published var userActions: [UserAction] { didSet { saveJSON("userActions", userActions) } }

    // MARK: App Exclusions — Bundle IDs where completions are suppressed
    @Published var excludedBundleIDs: [String] {
        didSet { defaults.set(excludedBundleIDs, forKey: "excludedBundleIDs") }
    }

    @Published var excludedApps: Set<String> = [] {
    didSet {
        let array = Array(excludedApps)
        defaults.set(array, forKey: "excludedApps")
    }
}

    // MARK: Enums & Complex Objects
    @Published var inferenceMode:        InferenceMode { didSet { saveJSON("inferenceMode",        inferenceMode)        } }
    @Published var transformMode:        TransformMode { didSet { saveJSON("transformMode",        transformMode)        } }
    @Published var cloudProvider:        CloudProvider { didSet { saveJSON("cloudProvider",        cloudProvider)        } }
    @Published var acceptHotkey:         HotkeyConfig  { didSet { saveJSON("acceptHotkey",         acceptHotkey)         } }
    @Published var dismissHotkey:        HotkeyConfig  { didSet { saveJSON("dismissHotkey",        dismissHotkey)        } }
    @Published var manualTriggerHotkey:  HotkeyConfig  { didSet { saveJSON("manualTriggerHotkey",  manualTriggerHotkey)  } }

    private init() {
        let d = UserDefaults.standard

        isEnabled       = d.object(forKey: "isEnabled")       as? Bool   ?? true
        triggerDelay    = d.object(forKey: "triggerDelay")    as? Double ?? 0.6
        minTokens       = d.object(forKey: "minTokens")       as? Int    ?? 8
        maxTokens       = d.object(forKey: "maxTokens")       as? Int    ?? 60
        overlayOpacity  = d.object(forKey: "overlayOpacity")  as? Double ?? 0.75
        useDarkMode     = d.object(forKey: "useDarkMode")     as? Bool   ?? false
        injectDate      = d.object(forKey: "injectDate")      as? Bool   ?? true
        injectAppName   = d.object(forKey: "injectAppName")   as? Bool   ?? true
        customContext   = d.string(forKey:  "customContext")              ?? ""
        temperature     = d.object(forKey: "temperature")     as? Double ?? 0.15
        ollamaHost      = d.string(forKey:  "ollamaHost")                ?? "http://localhost:11434"
        ollamaModel     = d.string(forKey:  "ollamaModel")               ?? "qwen2.5-coder:0.5b"
        lmStudioHost    = d.string(forKey:  "lmStudioHost")              ?? "http://localhost:1234/v1"
        lmStudioModel   = d.string(forKey:  "lmStudioModel")             ?? "google/gemma-3-1b"
        useCloudBackend = d.bool(forKey:    "useCloudBackend")
        cloudApiKey     = d.string(forKey:  "cloudApiKey")               ?? ""
        cloudModel      = d.string(forKey:  "cloudModel")                ?? CloudProvider.openAI.defaultModel
        systemPrompt    = d.string(forKey:  "systemPrompt")              ?? AppSettings.defaultSystemPromptAuto
        excludedBundleIDs = d.stringArray(forKey: "excludedBundleIDs")   ?? []

        userActions         = AppSettings.loadJSON("userActions")         ?? UserAction.defaults
        inferenceMode       = AppSettings.loadJSON("inferenceMode")       ?? .auto
        transformMode       = AppSettings.loadJSON("transformMode")       ?? .autocomplete
        cloudProvider       = AppSettings.loadJSON("cloudProvider")       ?? .openAI
        acceptHotkey        = AppSettings.loadJSON("acceptHotkey")        ?? .defaultAccept
        dismissHotkey       = AppSettings.loadJSON("dismissHotkey")       ?? .defaultDismiss
        manualTriggerHotkey = AppSettings.loadJSON("manualTriggerHotkey") ?? .defaultTrigger
        excludedApps        = Set(d.stringArray(forKey: "excludedApps") ?? [])
    }

    // MARK: - Template Rendering

    /// Substitutes {{input}} in a promptTemplate with the selected text.
    func renderPrompt(template: String, input: String) -> String {
        if template.contains("{{input}}") {
            return template.replacingOccurrences(of: "{{input}}", with: input)
        }
        return template + "\n\n" + input
    }

    // MARK: - Exclusion helpers

    func isExcluded(bundleID: String) -> Bool {
        excludedBundleIDs.contains(bundleID)
    }

    func addExclusion(_ bundleID: String) {
        guard !excludedBundleIDs.contains(bundleID) else { return }
        excludedBundleIDs.append(bundleID)
    }

    func removeExclusion(_ bundleID: String) {
        excludedBundleIDs.removeAll { $0 == bundleID }
    }

    // MARK: - Prompts

    static let defaultSystemPromptAuto = """
You are a pure autocomplete engine.
Output ONLY the direct continuation of the input text.
Rules (STRICT):
1. NEVER output explanations, introductions, or any meta text.
2. NEVER repeat the input text.
3. Match exact style, tone, indentation and language of the input.
4. Continue from the last word/sentence. Stop at the end of a logical thought.
5. Maximum 1-2 sentences or one short code block.
"""

    static let defaultSystemPromptCoder = """
You are an expert code autocomplete engine.
Output ONLY valid code continuation.
Rules (STRICT):
1. No explanations, no comments, no markdown.
2. Match exact indentation and language.
3. Complete the current function/block only.
4. Stop after one logical statement or closing brace.
"""

    static let defaultSystemPromptProse = """
You are a literary autocomplete engine.
Output ONLY natural prose continuation.
Rules (STRICT):
1. No meta text, no summaries.
2. Match the exact tone, style and vocabulary of the input.
3. Continue the current sentence or paragraph smoothly.
4. Maximum 2 sentences.
"""

    static let defaultSystemPromptFast = """
You are an ultra-fast autocomplete engine.
Output ONLY 3-8 words that best continue the text.
Rules (STRICT):
1. No explanations ever.
2. Extremely short and direct.
3. Match style exactly.
"""

    // MARK: - Session

    func resetSession() {
        NotificationCenter.default.post(name: .sessionReset, object: nil)
    }

    func buildPrompt(base: String, appName: String?) -> String {
        var meta: [String] = []
        if injectDate {
            let f = DateFormatter(); f.dateStyle = .medium
            meta.append("Date: \(f.string(from: Date()))")
        }
        if injectAppName, let app = appName, !app.isEmpty { meta.append("App: \(app)") }
        guard !meta.isEmpty else { return base }
        return "[\(meta.joined(separator: " | "))]\n\(base)"
    }

    func resetSystemPrompt() { systemPrompt = inferenceMode.systemPrompt }

    // MARK: - Persistence helpers

    private func ud(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }

    private func saveJSON<T: Encodable>(_ key: String, _ value: T) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    static func loadJSON<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
