//
//  UserAction.swift
//  LuminaText
//
//  Created by Kirill on 28.03.2026.
//

// File: UserAction.swift
import Foundation

struct UserAction: Codable, Identifiable {
    var id: UUID
    var title: String
    var systemPrompt: String
    var iconName: String
    var shortcut: String?

    init(id: UUID = UUID(), title: String, systemPrompt: String, iconName: String, shortcut: String? = nil) {
        self.id = id
        self.title = title
        self.systemPrompt = systemPrompt
        self.iconName = iconName
        self.shortcut = shortcut
    }

    static let grammarFix = UserAction(
        title: "Grammar Fix",
        systemPrompt: "Fix all grammar and spelling errors. Output ONLY the corrected text.",
        iconName: "text.badge.checkmark",
        shortcut: "g"
    )

    static let defaults: [UserAction] = [
        grammarFix,
        UserAction(title: "Summarize",    systemPrompt: "Summarize concisely. Output ONLY the summary.",                          iconName: "doc.plaintext"),
        UserAction(title: "Polish",        systemPrompt: "Rewrite to be polished and professional. Output ONLY the result.",       iconName: "wand.and.stars"),
        UserAction(title: "Bullets",       systemPrompt: "Convert to a clean bullet list. Output ONLY the bullets.",              iconName: "list.bullet"),
        UserAction(title: "Add Emoji",     systemPrompt: "Enrich with relevant emoji. Output ONLY the enriched text.",            iconName: "face.smiling"),
        UserAction(title: "Professional",  systemPrompt: "Rewrite in a formal professional tone. Output ONLY the result.",        iconName: "briefcase"),
        UserAction(title: "Casual",        systemPrompt: "Rewrite in a friendly casual tone. Output ONLY the result.",            iconName: "bubble.left"),
    ]
}
