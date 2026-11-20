import Foundation

/// The installer's texts in the Mac's language (one of PXPlay's twelve), English otherwise.
enum Texts {
    static let supported = ["en", "de", "es", "fr", "he", "it", "ja", "ko", "pt", "ru", "zh_CN", "zh_TW"]

    static let language: String = {
        if let forced = ProcessInfo.processInfo.environment["MIRAGE_LANGUAGE"], supported.contains(forced) { return forced }
        for preferred in Locale.preferredLanguages {
            let tag = preferred.lowercased()
            var candidate = String(tag.split(separator: "-").first ?? "")
            if candidate == "zh" {
                let traditional = tag.contains("hant") || tag.contains("-tw") || tag.contains("-hk") || tag.contains("-mo")
                candidate = traditional ? "zh_TW" : "zh_CN"
            } else if candidate == "iw" {
                candidate = "he"
            }
            if supported.contains(candidate) { return candidate }
        }
        return "en"
    }()

    static var rightToLeft: Bool { language == "he" }

    private static let table: [String: [String: String]] = {
        guard let url = Bundle.main.url(forResource: "strings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let all = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else { return [:] }
        return all
    }()

    static func get(_ key: String, _ arguments: String...) -> String {
        var text = table[key]?[language] ?? table[key]?["en"] ?? key
        for (index, argument) in arguments.enumerated() {
            text = text.replacingOccurrences(of: "{\(index)}", with: argument)
        }
        return text
    }
}

func L(_ key: String, _ arguments: String...) -> String {
    var text = Texts.get(key)
    for (index, argument) in arguments.enumerated() {
        text = text.replacingOccurrences(of: "{\(index)}", with: argument)
    }
    return text
}
