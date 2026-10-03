import Foundation

/// Converts explicit spoken symbol names into the characters a person intended to type.
public enum SpokenSymbols {
    private static let word = "[\\p{L}\\p{M}\\p{N}_]"
    private static let replacements: [(phrase: String, symbol: String)] = [
        ("open square bracket", "["), ("close square bracket", "]"),
        ("open curly brace", "{"), ("close curly brace", "}"),
        ("left parenthesis", "("), ("right parenthesis", ")"),
        ("open parenthesis", "("), ("close parenthesis", ")"),
        ("left angle bracket", "<"), ("right angle bracket", ">"),
        ("less than sign", "<"), ("greater than sign", ">"),
        ("exclamation point", "!"), ("exclamation mark", "!"),
        ("quotation mark", "\""), ("double quote", "\""),
        ("vertical bar", "|"), ("pipe symbol", "|"),
        ("forward slash", "/"), ("backward slash", "\\"),
        ("back slash", "\\"), ("at sign", "@"), ("hash sign", "#"),
        ("pound sign", "#"), ("dollar sign", "$"), ("percent sign", "%"),
        ("plus sign", "+"), ("minus sign", "-"), ("equals sign", "="),
        ("question mark", "?"), ("open bracket", "["), ("close bracket", "]"),
        ("ampersand", "&"), ("asterisk", "*"), ("underscore", "_"),
        ("backslash", "\\"), ("slash", "/"), ("colon", ":"),
        ("semicolon", ";"), ("comma", ","), ("period", "."),
        ("dot", "."), ("apostrophe", "'"), ("tilde", "~"),
        ("caret", "^"), ("backtick", "`")
    ]

    private static let patterns: [(regex: NSRegularExpression, symbol: String)] = replacements.compactMap { replacement in
        let phrase = replacement.phrase.split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s+")
        let pattern = "[ \\t]*(?<!" + word + ")(?:(" + phrase + "))(?!" + word + ")(?:[.!?](?=[ \\t]*$))?[ \\t]*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        return (regex, replacement.symbol)
    }

    public static func applying(to text: String) -> String {
        var result = text
        for (regex, symbol) in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: symbol))
        }
        return result
    }

}
