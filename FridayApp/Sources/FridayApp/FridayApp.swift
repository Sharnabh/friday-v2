import SwiftUI
import EventKit

@main
struct FridayLauncher {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--calendar-day" {
            do {
                let rows = try calendarDay(args[2])
                FileHandle.standardOutput.write(try JSONEncoder().encode(rows))
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
            return
        }
        FridayMainApp.main()
    }

    private static func calendarDay(_ day: String) throws -> [[String]] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw NSError(domain: "Friday", code: 1, userInfo: [NSLocalizedDescriptionKey: "Allow FRIDAY access to Calendar and resume the briefing."])
        }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = .current
        parser.dateFormat = "yyyy-MM-dd"
        guard let start = parser.date(from: day), parser.string(from: start) == day,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { throw CocoaError(.formatting) }
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let formatter = ISO8601DateFormatter()
        return store.events(matching: predicate).filter { $0.status != .canceled }.sorted { $0.startDate < $1.startDate }
            .map { [formatter.string(from: $0.startDate), $0.title ?? "Untitled event"] }
    }
}

struct FridayMainApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .task { state.cloudAccount.start(state) }
                .frame(minWidth: 700, minHeight: 520)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}
