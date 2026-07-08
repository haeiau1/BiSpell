import Foundation

public enum Tokenizer {
    /// Word characters for TR/EN including Turkish letters and apostrophes inside words.
    private static let wordCharacter = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZàáâãäåæçèéêëìíîïðñòóôõöøùúûüýþÿÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞßğüşıöçĞÜŞİÖÇ'-")
    private static let nonWordCharacter = wordCharacter.inverted

    public static func tokenize(_ text: String) -> [TextToken] {
        guard !text.isEmpty else { return [] }

        var tokens: [TextToken] = []
        let ns = text as NSString
        var location = 0

        while location < ns.length {
            let rest = NSRange(location: location, length: ns.length - location)
            let letterRange = ns.rangeOfCharacter(from: wordCharacter, options: [], range: rest)
            if letterRange.location == NSNotFound { break }

            let afterStart = letterRange.location + letterRange.length
            let end: Int
            if afterStart >= ns.length {
                end = ns.length
            } else {
                let tail = NSRange(location: afterStart, length: ns.length - afterStart)
                let nonWord = ns.rangeOfCharacter(from: nonWordCharacter, options: [], range: tail)
                end = nonWord.location == NSNotFound ? ns.length : nonWord.location
            }

            var tokenRange = NSRange(location: letterRange.location, length: end - letterRange.location)
            var tokenText = ns.substring(with: tokenRange)

            // Trim leading/trailing apostrophes and hyphens
            while tokenText.hasPrefix("'") || tokenText.hasPrefix("-") {
                tokenRange.location += 1
                tokenRange.length -= 1
                guard tokenRange.length > 0 else { break }
                tokenText = ns.substring(with: tokenRange)
            }
            while tokenText.hasSuffix("'") || tokenText.hasSuffix("-") {
                tokenRange.length -= 1
                guard tokenRange.length > 0 else { break }
                tokenText = ns.substring(with: tokenRange)
            }

            if tokenRange.length > 0,
               let swiftRange = Range(tokenRange, in: text) {
                tokens.append(TextToken(text: tokenText, range: swiftRange, utf16Range: tokenRange))
            }

            location = max(end, letterRange.location + 1)
        }

        return tokens
    }

    public static func shouldSkipToken(_ text: String) -> Bool {
        if text.count < 2 { return true }
        if text.contains("@") { return true }
        if text.contains("://") { return true }
        if text.allSatisfy(\.isNumber) { return true }
        // Likely code identifier: has underscore or camel-ish mixed with digits only patterns
        if text.contains("_") { return true }
        if text.hasPrefix("http") { return true }
        // Pure hex-like or id-like
        if text.range(of: #"^[A-Za-z]+\d+[A-Za-z0-9]*$"#, options: .regularExpression) != nil,
           text.count > 12 {
            return true
        }
        return false
    }
}
