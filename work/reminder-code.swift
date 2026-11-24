struct Reminder: Codable {
    let id: UUID
    let text: String
    let due: Date
}

struct ReminderStore {
    let file: URL
    func update<T>(_ edit: (inout [Reminder]) -> T) throws -> T {
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:folder, withIntermediateDirectories:true)
        let lock = Darwin.open(file.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw Failure.message("Could not open the reminders store.") }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw Failure.message("Could not lock the reminders store.") }
        var items = FileManager.default.fileExists(atPath:file.path) ? try JSONDecoder().decode([Reminder].self, from:Data(contentsOf:file)) : []
        let before = items.map(\.id)
        let result = edit(&items)
        if before != items.map(\.id) {
            try JSONEncoder().encode(items).write(to:file, options:.atomic)
        }
        return result
    }
    func takeDue(at now:Date) throws -> Reminder? {
        try update { items in
            guard let index = items.indices.filter({ items[$0].due <= now }).min(by:{ items[$0].due < items[$1].due }) else { return nil }
            return items.remove(at:index)
        }
    }
}
