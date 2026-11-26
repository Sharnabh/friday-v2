import Foundation

/// Task-aware multi-model router pairing OpenRouter role models with existing Hermes and ScreenInferenceRouter flows.
public enum MultiModelRouter {
    public static func classifyChatRole(botPreset: BotRolePreset, inferred: ModelRole?) -> ModelRole {
        botPreset == .auto ? (inferred ?? .fastChat) : botPreset.modelRole
    }

    /// Resolves `(provider, model)` for a role while honoring explicit per-bot/user model overrides.
    public static func effectiveProviderAndModel(
        for role: ModelRole,
        botProvider: String,
        botModel: String,
        registry: OpenRouterModelRegistry = .shared,
        hasOpenRouterKey: Bool = AssistantService.hasOpenRouterAPIKey()
    ) -> (provider: String, model: String) {
        let cleanProvider = botProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = botModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanModel.isEmpty {
            return (cleanProvider, cleanModel)
        }
        guard hasOpenRouterKey, cleanProvider.caseInsensitiveCompare("openrouter") == .orderedSame else {
            return (cleanProvider, cleanModel)
        }
        return ("openrouter", registry.primaryModel(for: role))
    }

    /// Routes a user request using Perplexity Decider when enabled (with automatic fallback to ScreenInferenceRouter).
    public static func routeQuestion(
        _ question: String,
        history: [String],
        hasPreviousCapture: Bool,
        provider: String,
        model: String,
        usePerplexityDecider: Bool,
        client: OpenRouterClient = .shared,
        registry: OpenRouterModelRegistry = .shared
    ) async throws -> ScreenRoute {
        if usePerplexityDecider {
            do {
                let state: [String: Any] = [
                    "question": question,
                    "history": history,
                    "hasPreviousCapture": hasPreviousCapture
                ]
                let routeQuestionSpec: [String: Any] = [
                    "type": "choice",
                    "instructions": "Select the best Friday assistant capability for the user's latest request.",
                    "criteria": [
                        "chat": "A conversational reply, coding question, or general knowledge answer is enough.",
                        "active": "Requires reading or explaining text on the currently visible Mac window.",
                        "visual": "Requires visually inspecting an image, chart, UI layout, or diagram on screen.",
                        "editor": "References reading or explaining a TextEdit document.",
                        "previous": "Follow-up about an already captured screen when hasPreviousCapture is true.",
                        "control": "Requests opening or controlling a Mac application, clicking, or typing.",
                        "remember": "Explicitly asks to save or remember a personal fact.",
                        "mailReply": "Asks to draft or reply to an Apple Mail email.",
                        "messageDraft": "Asks to draft a text message in Apple Messages.",
                        "generateImage": "Explicitly asks to draw, create, or generate a new image or picture."
                    ]
                ]
                let modeQuestionSpec: [String: Any] = [
                    "type": "choice",
                    "instructions": "Choose answer unless the user asked for verbatim/word-for-word reading of screen/editor text.",
                    "criteria": [
                        "answer": "Normal summarized or direct response.",
                        "verbatim": "Literal word-for-word transcript requested."
                    ]
                ]
                let (answers, _) = try await client.decide(
                    fast: true,
                    state: state,
                    questions: ["source": routeQuestionSpec, "mode": modeQuestionSpec]
                )
                if let ans = answers["source"], ans.confidence >= 0.35, let rawChoice = ans.choice {
                    guard let resolvedSource = ScreenRoute.Source(rawValue: rawChoice) else { throw FridayError.message("Unknown capability") }
                    // The full intent router resolves calendar evidence, reminder details and chat roles.
                    if [.mailReply, .calendarReply, .chat].contains(resolvedSource) {
                        throw FridayError.message("Full intent details required")
                    }
                    let modeRaw = answers["mode"]?.choice ?? "answer"
                    let mode: ScreenRoute.Mode = (resolvedSource == .active || resolvedSource == .editor)
                        ? (ScreenRoute.Mode(rawValue: modeRaw) ?? .answer)
                        : .answer
                    return ScreenRoute(source: resolvedSource, mode: mode)
                }
            } catch {
                // Fall back seamlessly to fast chat/completion router below
            }
        }

        let eff = effectiveProviderAndModel(for: .fastChat, botProvider: provider, botModel: model, registry: registry)
        return try await Task.detached(priority: .userInitiated) {
            try ScreenInferenceRouter.routeQuestion(
                question,
                history: history,
                hasPreviousCapture: hasPreviousCapture,
                provider: eff.provider,
                model: eff.model
            )
        }.value
    }
}
