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
    public let similarity: Double?
    
    public init(id: Int64, scope: String, body: String, source: String, revision: String, similarity: Double? = nil) {
        self.id = id
        self.scope = scope
        self.body = body
        self.source = source
        self.revision = revision
        self.similarity = similarity
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
