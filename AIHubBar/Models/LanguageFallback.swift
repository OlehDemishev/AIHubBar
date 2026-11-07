import Foundation

/// A system language the app has no translation for would fall back to the bundle's development language, Russian.
/// English is the better guess, so it is set for this launch only, before anything is localized.
enum LanguageFallback {
    /// Russian is the catalog's source language and has no `.lproj`, so it isn't in `Bundle.localizations`.
    static func needsEnglish(preferred: [String], available: [String]) -> Bool {
        func language(_ code: String) -> String { String(code.prefix { $0 != "-" && $0 != "_" }).lowercased() }
        let known = Set((available + ["ru"]).map(language))
        return !preferred.contains { known.contains(language($0)) }
    }

    static func apply(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        guard needsEnglish(preferred: Locale.preferredLanguages, available: bundle.localizations) else { return }
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleLanguages"] = ["en"]
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
}
