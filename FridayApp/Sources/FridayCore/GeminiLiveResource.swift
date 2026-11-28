import Foundation
public enum GeminiLiveResource {
    public static var url: URL? { Bundle.module.url(forResource:"gemini-live",withExtension:"js",subdirectory:"Resources") }
}
