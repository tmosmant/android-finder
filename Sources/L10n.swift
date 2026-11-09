import Foundation

enum L10n {
    static var language: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale(identifier: language), arguments: arguments)
    }
}
