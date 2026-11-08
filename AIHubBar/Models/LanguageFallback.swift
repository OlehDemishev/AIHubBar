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

/// The language the app runs in and the one it will have after a relaunch. They differ once the choice in Settings
/// changes, because macOS reads `AppleLanguages` at launch.
enum InterfaceLanguage {
    /// Fixed at launch (`AIHubBarApp.init` reads it first), so a later change in Settings can't alter it.
    static let running = Bundle.main.preferredLocalizations.first ?? "ru"

    /// `choice` is the language picked in Settings, empty for «Как в системе»; `system` is the system's list.
    static func afterRelaunch(choice: String, system: [String], available: [String]) -> String {
        guard choice.isEmpty else { return choice }
        guard !LanguageFallback.needsEnglish(preferred: system, available: available) else { return "en" }
        let known = available.contains("ru") ? available : available + ["ru"]
        return Bundle.preferredLocalizations(from: known, forPreferences: system).first ?? "en"
    }
}
