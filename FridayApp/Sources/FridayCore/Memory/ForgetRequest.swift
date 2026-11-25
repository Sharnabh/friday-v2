import Foundation

public enum ForgetRequest {
    public static func topic(in message: String) -> String? {
        let pattern = #"^(?:please\s+)?(?:forget\s+(?:(?:that\s+(?:i\s+(?:am\s+(?:a\s+)?)?|my\s+)|my\s+|about\s+))?|delete\s+memory\s+about\s+|remove\s+from\s+memory\s+)(.+)$"#
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of:pattern,options:[.regularExpression,.caseInsensitive]) else {return nil}
        return String(text[range]).replacingOccurrences(of:pattern,with:"$1",options:[.regularExpression,.caseInsensitive])
    }
}
