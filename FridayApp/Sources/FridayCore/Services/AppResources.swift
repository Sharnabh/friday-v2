import Foundation

public enum AppResources {
    public static func path(_ name:String,_ ext:String) -> String {
        if let url = Bundle.main.url(forResource:name,withExtension:ext,subdirectory:"Resources")
            ?? Bundle.main.url(forResource:name,withExtension:ext) { return url.path }
        return Bundle.module.url(forResource:name,withExtension:ext,subdirectory:"Resources")?.path ?? ""
    }
}
