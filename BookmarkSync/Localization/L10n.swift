import Foundation

/// Runtime strings use the same native localization tables as SwiftUI literals.
/// Keep persisted names and activity tokens in English; translate only for display.
enum L10n {
    static func text(_ key: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }

    static func profileSetName(_ name: String) -> String {
        let prefix = "Set "
        if name.hasPrefix(prefix) {
            let number = String(name.dropFirst(prefix.count))
            if !number.isEmpty && number.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return format("Set %@", number)
            }
        }
        // These are application-generated fallbacks, never browser profile names.
        if name == "Set" || name == "Other Set" { return text(name) }
        return name
    }

    static func activityTitle(_ title: String) -> String {
        for prefix in ["Add: ", "Update: ", "Delete: "] where title.hasPrefix(prefix) {
            return format(prefix + "%@", String(title.dropFirst(prefix.count)))
        }
        return title == "Reorder" ? text(title) : title
    }
}
