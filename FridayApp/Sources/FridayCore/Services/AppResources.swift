import Foundation

public enum AppResources {
    public static var hermesPython: String? {
        let files = FileManager.default
        let installs = files.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/installs")
        let dirs = (try? files.contentsOfDirectory(at: installs, includingPropertiesForKeys: nil)) ?? []
        let facts = dirs.map { $0.appendingPathComponent("facts.json") }.sorted {
            let lhs = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let rhs = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (lhs ?? .distantPast) > (rhs ?? .distantPast)
        }
        for file in facts {
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let packages = root["packages"] as? [String: Any], let venv = packages["venv"] as? [String: Any],
                  let path = venv["environment"] as? String else { continue }
            let python = path + "/bin/python"
            if files.isExecutableFile(atPath: python) { return python }
        }
        return nil
    }

    public static var python: String { hermesPython ?? "/usr/bin/python3" }

    public static func path(_ name:String,_ ext:String) -> String {
        if let url = Bundle.main.url(forResource:name,withExtension:ext,subdirectory:"Resources")
            ?? Bundle.main.url(forResource:name,withExtension:ext) { return url.path }
        return Bundle.module.url(forResource:name,withExtension:ext,subdirectory:"Resources")?.path ?? ""
    }
}
