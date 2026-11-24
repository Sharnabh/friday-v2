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

public struct BotProfile: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var instructions: String
    
    public init(id: String, name: String, instructions: String) {
        self.id = id
        self.name = name
        self.instructions = instructions
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
        case active, editor, previous, control, remember, mailReply, calendarReply, chat
    }
    public enum Mode: String, Decodable, Sendable {
        case answer, verbatim
    }
    public let source: Source
    public let mode: Mode
    
    public init(source: Source, mode: Mode) {
        self.source = source
        self.mode = mode
    }
}
