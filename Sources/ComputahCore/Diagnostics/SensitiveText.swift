import Foundation

public enum SensitiveText {
    private static let patterns = [
        #"(?im)\b[A-Z0-9_]*(?:API_KEY|ACCESS_TOKEN|AUTH_TOKEN|SECRET|PASSWORD)[A-Z0-9_]*\s*=\s*(?:\"[^\"\r\n]*\"|'[^'\r\n]*'|[^\s;]+)"#,
        #"\b(?:sk-[A-Za-z0-9_-]{12,}|apikey_[A-Za-z0-9_-]{12,})"#
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Detect protected spans before tokenizing or slicing the original source.
    static func protectedRanges(in source: String) -> [NSRange] {
        let range = NSRange(source.startIndex..., in: source)
        return patterns.flatMap { $0.matches(in: source, range: range).map(\.range) }
    }

    static func redact(_ source: String, range: NSRange) -> String {
        let result = NSMutableString(string: (source as NSString).substring(with: range))
        let intersections = protectedRanges(in: source).map { NSIntersectionRange($0, range) }
            .filter { $0.length > 0 }.sorted { $0.location < $1.location }
        // Merge overlaps so replacement offsets always refer to the original text.
        var spans: [NSRange] = []
        for span in intersections {
            if let last = spans.last, NSMaxRange(last) >= span.location {
                spans[spans.count - 1] = NSUnionRange(last, span)
            } else { spans.append(span) }
        }
        for span in spans.reversed() {
            result.replaceCharacters(in: NSRange(location: span.location - range.location, length: span.length),
                                     with: "[REDACTED CREDENTIAL]")
        }
        return result as String
    }

    public static func redact(_ source: String) -> String {
        guard source.contains("=") || source.contains("sk-") || source.contains("apikey_") else { return source }
        var text = source
        for pattern in patterns {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[REDACTED CREDENTIAL]")
        }
        return text
    }

    public static func json(_ value: Any) -> Any {
        if let text = value as? String { return redact(text) }
        if let values = value as? [Any] { return values.map(json) }
        if let values = value as? [String: Any] { return values.mapValues(json) }
        return value
    }

    public static func encodedJSON(_ data: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: json(JSONSerialization.jsonObject(with: data)), options: [.prettyPrinted, .sortedKeys])
    }
}
