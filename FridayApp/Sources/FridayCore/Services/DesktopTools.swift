import AppKit
import EventKit

public enum DesktopTools {
    public static func imageOfActiveWindow() throws -> URL {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],0) as? [[String:Any]] ?? []
        guard let row = rows.first(where:{ row in
            guard let pid=row[kCGWindowOwnerPID as String] as? Int32,let app=NSRunningApplication(processIdentifier:pid) else {return false}
            return row[kCGWindowLayer as String] as? Int == 0 && app.activationPolicy == .regular && app.bundleIdentifier != Bundle.main.bundleIdentifier
        }), let id=row[kCGWindowNumber as String] as? Int else {throw FridayError.message("No active app window.")}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        do { _ = try ProcessRunner.run("/usr/sbin/screencapture",["-x","-o","-l",String(id),url.path]);return url }
        catch {try? FileManager.default.removeItem(at:url); throw error}
    }

    public static func addReminder(_ title:String,due:Date) async throws {
        guard !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw FridayError.message("Enter a reminder title.")}
        let store=EKEventStore()
        guard try await store.requestFullAccessToReminders(), let list=store.defaultCalendarForNewReminders() else {throw FridayError.message("Allow Reminders access and configure a default list.")}
        let item=EKReminder(eventStore:store);item.calendar=list;item.title=title
        item.dueDateComponents=Calendar.current.dateComponents([.year,.month,.day,.hour,.minute],from:due)
        item.addAlarm(EKAlarm(absoluteDate:due))
        try store.save(item,commit:true)
    }

    public static func models() -> [String:[String]] {
        let url=URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent(".hermes/models_dev_cache.json")
        guard let data=try? Data(contentsOf:url),let root=(try? JSONSerialization.jsonObject(with:data)) as? [String:[String:Any]] else {return [:]}
        return root.compactMapValues { row in (row["models"] as? [String:Any]).map {Array($0.keys).sorted()} }
    }
}
