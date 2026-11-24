import Foundation
import EventKit

public final class ReminderService {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func update<T>(_ edit: (inout [Reminder]) -> T) throws -> T {
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lock = Darwin.open(file.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw FridayError.message("Could not open the reminders store.") }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw FridayError.message("Could not lock the reminders store.") }
        var items = FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode([Reminder].self, from: Data(contentsOf: file)) : []
        let before = items
        let result = edit(&items)
        if before != items {
            try JSONEncoder().encode(items).write(to: file, options: .atomic)
        }
        return result
    }

    public func takeDue(at now: Date) throws -> Reminder? {
        try update { items in
            guard let index = items.indices.filter({ items[$0].due <= now }).min(by: { items[$0].due < items[$1].due }) else { return nil }
            let fired = items[index]
            if let frequency = fired.frequency {
                let calendar = Calendar.current
                let anchor = fired.firstDue ?? fired.due
                var pattern = calendar.dateComponents([.hour, .minute, .second], from: anchor)
                if frequency == .weekly { pattern.weekday = calendar.component(.weekday, from: anchor) }
                if let next = calendar.nextDate(after: now, matching: pattern, matchingPolicy: .nextTimePreservingSmallerComponents) {
                    items[index].firstDue = anchor
                    items[index].due = next
                    return fired
                }
            }
            return items.remove(at: index)
        }
    }

    public func list() throws -> [Reminder] {
        try update { $0.sorted { $0.due < $1.due } }
    }
}

public final class ActivityService {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public func append(_ entry: ActivityEntry) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(entry).write(to: file, options: .atomic)
    }

    public func recent() throws -> [ActivityEntry] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "json" }.map {
            try JSONDecoder().decode(ActivityEntry.self, from: Data(contentsOf: $0))
        }.sorted { $0.date > $1.date }
    }
}

public final class MailCalendarService {
    public static func mailOperation(_ arguments: [String], helperScriptPath: String) throws -> [String: String] {
        let raw = try ProcessRunner.run("/usr/bin/osascript", ["-l", "JavaScript", helperScriptPath] + arguments)
        let result = try JSONDecoder().decode([String: String].self, from: Data(raw.utf8))
        if let error = result["error"] { throw FridayError.message("Apple Mail: " + error) }
        return result
    }

    public static func upcomingCalendarConflicts() throws -> [String: Any] {
        let store = EKEventStore(), ready = DispatchSemaphore(value: 0)
        if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            store.requestFullAccessToEvents { _, _ in ready.signal() }
            ready.wait()
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw FridayError.message("Allow FRIDAY full Calendar access in Privacy & Security to check availability.")
        }
        let start = Date(), end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
        let format = ISO8601DateFormatter()
        format.timeZone = .current
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let busy = store.events(matching: predicate).filter { $0.availability != .free && $0.status != .canceled }
        return [
            "from": format.string(from: start),
            "until": format.string(from: end),
            "timeZone": TimeZone.current.identifier,
            "busy": busy.map { [format.string(from: $0.startDate), format.string(from: $0.endDate)] }
        ]
    }
}
