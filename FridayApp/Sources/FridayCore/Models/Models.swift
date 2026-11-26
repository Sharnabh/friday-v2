import Foundation

public enum FridayError: LocalizedError {
    case message(String)
    
    public var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        }
    }
}

public struct MemoryEntry: Identifiable, Sendable {
    public let id: Int64
    public let scope: String
    public let body: String
    public let source: String
    public let revision: String
    public let importance: Int
    public let createdAt: Date
    public let lastAccessedAt: Date
    public let similarity: Double?
    public let compositeScore: Double?
    
    public init(
        id: Int64,
        scope: String,
        body: String,
        source: String,
        revision: String,
        importance: Int = 5,
        createdAt: Date = Date(),
        lastAccessedAt: Date = Date(),
        similarity: Double? = nil,
        compositeScore: Double? = nil
    ) {
        self.id = id
        self.scope = scope
        self.body = body
        self.source = source
        self.revision = revision
        self.importance = importance
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.similarity = similarity
        self.compositeScore = compositeScore
    }
}

public struct GraphTriple: Identifiable, Codable, Sendable {
    public let id: Int64
    public let scope: String
    public let subject: String
    public let predicate: String
    public let object: String
    public let confidence: Double
    public let createdAt: Date

    public init(id: Int64 = 0, scope: String, subject: String, predicate: String, object: String, confidence: Double = 1.0, createdAt: Date = Date()) {
        self.id = id
        self.scope = scope
        self.subject = subject
        self.predicate = predicate
        self.object = object
        self.confidence = confidence
        self.createdAt = createdAt
    }

    public var summary: String {
        "(\(subject)) —[\(predicate)]→ (\(object))"
    }
}

public struct ExtractedFactPayload: Codable, Sendable {
    public struct FactItem: Codable, Sendable {
        public let text: String
        public let scope: String?

        public init(text: String, scope: String? = nil) {
            self.text = text
            self.scope = scope
        }

        public init(from decoder: Decoder) throws {
            if let container = try? decoder.singleValueContainer(),
               let str = try? container.decode(String.self) {
                self.text = str
                self.scope = nil
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.text = try container.decode(String.self, forKey: .text)
            self.scope = try container.decodeIfPresent(String.self, forKey: .scope)
        }

        private enum CodingKeys: String, CodingKey {
            case text, scope
        }
    }

    public struct TriplePayload: Codable, Sendable {
        public let subject: String
        public let predicate: String
        public let object: String
        public let scope: String?

        public init(subject: String, predicate: String, object: String, scope: String? = nil) {
            self.subject = subject
            self.predicate = predicate
            self.object = object
            self.scope = scope
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.subject = try container.decode(String.self, forKey: .subject)
            self.predicate = try container.decode(String.self, forKey: .predicate)
            self.object = try container.decode(String.self, forKey: .object)
            self.scope = try container.decodeIfPresent(String.self, forKey: .scope)
        }

        private enum CodingKeys: String, CodingKey {
            case subject, predicate, object, scope
        }
    }

    public let facts: [FactItem]
    public let triples: [TriplePayload]
    public let importance: Int?
    public let isDurableUserFact: Bool?

    public init(facts: [FactItem] = [], triples: [TriplePayload] = [], importance: Int? = 5, isDurableUserFact: Bool? = true) {
        self.facts = facts
        self.triples = triples
        self.importance = importance
        self.isDurableUserFact = isDurableUserFact
    }

    private enum CodingKeys: String, CodingKey {
        case facts, triples, importance
        case isDurableUserFact = "is_durable_user_fact"
        case isDurableUserFactAlt = "isDurableUserFact"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.facts = (try? container.decodeIfPresent([FactItem].self, forKey: .facts)) ?? []
        self.triples = (try? container.decodeIfPresent([TriplePayload].self, forKey: .triples)) ?? []
        self.importance = try? container.decodeIfPresent(Int.self, forKey: .importance)
        if let durable = try? container.decodeIfPresent(Bool.self, forKey: .isDurableUserFact) {
            self.isDurableUserFact = durable
        } else {
            self.isDurableUserFact = try? container.decodeIfPresent(Bool.self, forKey: .isDurableUserFactAlt)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(facts, forKey: .facts)
        try container.encode(triples, forKey: .triples)
        try container.encodeIfPresent(importance, forKey: .importance)
        try container.encodeIfPresent(isDurableUserFact, forKey: .isDurableUserFact)
    }
}

public struct ChatSessionItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let lastUpdated: Date

    public init(id: String, title: String, lastUpdated: Date = Date()) {
        self.id = id
        self.title = title
        self.lastUpdated = lastUpdated
    }
}

public struct HeyGenVoiceOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public enum HeyGenTTSCatalog {
    public static let speechEndpoint = "https://openrouter.ai/api/v1/audio/speech"
    public static let defaultModel = "heygen/heygen-voice-1-turbo:free"
    public static let availableModels: [(id: String, label: String)] = [
        ("heygen/heygen-voice-1-turbo:free", "HeyGen Voice Turbo (Free)"),
        ("heygen/heygen-voice-1-turbo", "HeyGen Voice Turbo (Low Latency)"),
        ("heygen/heygen-voice-1", "HeyGen Voice Standard")
    ]

    public static let voices: [HeyGenVoiceOption] = [
        HeyGenVoiceOption(id: "", label: "System Default (macOS)"),
        HeyGenVoiceOption(id: "nadine", label: "Nadine (HeyGen)"),
        HeyGenVoiceOption(id: "tabitha", label: "Tabitha (HeyGen)"),
        HeyGenVoiceOption(id: "noelle", label: "Noelle (HeyGen)"),
        HeyGenVoiceOption(id: "meredith", label: "Meredith (HeyGen)"),
        HeyGenVoiceOption(id: "sabrina", label: "Sabrina (HeyGen)"),
        HeyGenVoiceOption(id: "bram", label: "Bram (HeyGen)"),
        HeyGenVoiceOption(id: "gareth", label: "Gareth (HeyGen)"),
        HeyGenVoiceOption(id: "lucian", label: "Lucian (HeyGen)"),
        HeyGenVoiceOption(id: "weston", label: "Weston (HeyGen)"),
        HeyGenVoiceOption(id: "vincent", label: "Vincent (HeyGen)")
    ]
}

public enum ModelRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case orchestrator
    case fastChat
    case coding
    case vision
    case decisions
    case decisionsFast
    case embeddings
    case rerank
    case imageGen

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .orchestrator: return "Master Orchestrator"
        case .fastChat: return "Fast Chat & Routing"
        case .coding: return "Coding & Automation"
        case .vision: return "Vision & PDF/Video"
        case .decisions: return "Decision Model"
        case .decisionsFast: return "Fast Decision Router"
        case .embeddings: return "Multimodal Embeddings"
        case .rerank: return "Search Reranker"
        case .imageGen: return "Image Generation"
        }
    }

    public var requiredOutputModality: String {
        switch self {
        case .orchestrator, .fastChat, .coding, .vision: return "text"
        case .decisions, .decisionsFast: return "decisions"
        case .embeddings: return "embeddings"
        case .rerank: return "rerank"
        case .imageGen: return "image"
        }
    }
}

public enum BotRolePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case orchestrator
    case fastChat
    case coding
    case vision

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Auto (By Task)"
        case .orchestrator: return "Orchestrator (Deep)"
        case .fastChat: return "Fast Chat (Low Latency)"
        case .coding: return "Coding Specialist"
        case .vision: return "Vision & Docs"
        }
    }

    public var modelRole: ModelRole {
        switch self {
        case .auto, .orchestrator: return .orchestrator
        case .fastChat: return .fastChat
        case .coding: return .coding
        case .vision: return .vision
        }
    }
}

public enum MemoryEmbeddingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case localOnly
    case multimodalRAG
    case cloudAll

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .localOnly: return "Local Only (0 Quota)"
        case .multimodalRAG: return "Cloud Docs / RAG Only"
        case .cloudAll: return "Cloud Hybrid (All Memories)"
        }
    }
}

public struct OpenRouterModelDescriptor: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let contextLength: Int
    public let inputModalities: [String]
    public let outputModalities: [String]
    public let supportedParameters: [String]
    public let isFree: Bool

    public init(
        id: String,
        name: String,
        contextLength: Int,
        inputModalities: [String],
        outputModalities: [String],
        supportedParameters: [String] = [],
        isFree: Bool
    ) {
        self.id = id
        self.name = name
        self.contextLength = contextLength
        self.inputModalities = inputModalities
        self.outputModalities = outputModalities
        self.supportedParameters = supportedParameters
        self.isFree = isFree
    }
}

public struct BotProfile: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var instructions: String
    public var voice: String
    public var role: BotRolePreset

    public init(id: String, name: String, instructions: String, voice: String = "", role: BotRolePreset = .auto) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.voice = voice
        self.role = role
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.instructions = try container.decode(String.self, forKey: .instructions)
        self.voice = (try? container.decodeIfPresent(String.self, forKey: .voice)) ?? ""
        self.role = (try? container.decodeIfPresent(BotRolePreset.self, forKey: .role)) ?? .auto
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, instructions, voice, role
    }
}

public struct MentionableBot: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let role: String

    public init(id: String, name: String, role: String) {
        self.id = id
        self.name = name
        self.role = role
    }
}

public struct BotGroup: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var members: [String]
    
    public init(id: String, name: String, members: [String]) {
        self.id = id
        self.name = name
        self.members = members
    }
}

public enum Frequency: String, Codable, CaseIterable, Sendable {
    case daily = "Daily"
    case weekly = "Weekly"
}

public struct Reminder: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public var due: Date
    public var frequency: Frequency?
    public var firstDue: Date?
    public var readsTextEdit: Bool?
    
    public init(id: UUID = UUID(), text: String, due: Date, frequency: Frequency? = nil, firstDue: Date? = nil, readsTextEdit: Bool? = nil) {
        self.id = id
        self.text = text
        self.due = due
        self.frequency = frequency
        self.firstDue = firstDue
        self.readsTextEdit = readsTextEdit
    }
}

public struct ActivityEntry: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public let date: Date
    public let scheduled: Date
    public let action: String
    public let subject: String
    public let error: String?
    
    public init(id: UUID = UUID(), date: Date, scheduled: Date, action: String, subject: String, error: String? = nil) {
        self.id = id
        self.date = date
        self.scheduled = scheduled
        self.action = action
        self.subject = subject
        self.error = error
    }
}

public struct MacPlan: Decodable, Sendable {
    public struct Step: Decodable, Sendable {
        public let action: String
        public let value: String
        
        public init(action: String, value: String) {
            self.action = action
            self.value = value
        }
    }
    
    public let app: String
    public let steps: [Step]
    public let expected: String
    
    public init(app: String, steps: [Step], expected: String) {
        self.app = app
        self.steps = steps
        self.expected = expected
    }
}

public struct ScreenRoute: Decodable, Sendable {
    public enum Source: String, Decodable, Sendable {
        case active, visual, editor, previous, control, remember, mailReply, calendarReply, messageDraft, generateImage, chat
    }
    public enum Mode: String, Decodable, Sendable {
        case answer, verbatim
    }
    public struct FollowUp: Decodable, Sendable {
        public let title: String
        public let due: String?
    }

    public let chatRole: String?
    public let followUp: FollowUp?
    public let source: Source
    public let mode: Mode
    
    public init(source: Source, mode: Mode) {
        self.chatRole = nil
        self.followUp = nil
        self.source = source
        self.mode = mode
    }
}
