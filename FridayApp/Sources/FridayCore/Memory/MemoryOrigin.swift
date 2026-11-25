import Foundation

public struct MemoryOrigin: Codable {
    public let bot:String
    public let session:String
    public let turn:Int
    public init(bot:String,session:String,turn:Int) {self.bot=bot;self.session=session;self.turn=turn}
    public var encoded:String {
        "chat:" + ((try? JSONEncoder().encode(self))?.base64EncodedString() ?? "")
    }
    public static func decode(_ source:String) -> Self? {
        guard source.hasPrefix("chat:"),let data=Data(base64Encoded:String(source.dropFirst(5))) else {return nil}
        return try? JSONDecoder().decode(Self.self,from:data)
    }
}
