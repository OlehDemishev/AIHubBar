import Foundation
import IOKit

/// «И с закрытой крышкой» (SPEC-profiles §3, second wave). A power assertion doesn't keep a Mac awake with the lid
/// closed; only `pmset disablesleep 1` does, and that needs root. The person allows it once: a sudoers rule that lets
/// this user run exactly `pmset -a disablesleep 0|1` without a password. «Не спать» turns sleep off while a rule
/// holds and back on afterwards — only when ClaudePult was the one that turned it off.
enum LidSleep {
    static let sudoersFile = "/etc/sudoers.d/claudepult"
    static let pmset = "/usr/bin/pmset"
    /// On battery below this charge the lid hold lets go: a closed Mac in a bag should not run flat.
    static let batteryFloor = 20
    private static let ownedKey = "lidSleepDisabledByClaudePult"

    /// The rule's text; nil for a user name that can't go into sudoers safely.
    nonisolated static func rule(user: String) -> String? {
        guard !user.isEmpty, user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { return nil }
        return "\(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 0, \(pmset) -a disablesleep 1\n"
    }

    nonisolated static func wanted(holding: Bool, lidRule: Bool, installed: Bool, onPower: Bool, battery: Int?, hasLid: Bool = true) -> Bool {
        guard holding, lidRule, installed, hasLid else { return false }
        return onPower || (battery ?? 100) >= batteryFloor
    }

    enum Step: Equatable { case none, disableSleep, enableSleep }

    /// `ours`: ClaudePult turned sleep off earlier. It is remembered across launches, so a crash doesn't leave the Mac
    /// never sleeping; sleep that someone else turned off is left alone.
    nonisolated static func step(want: Bool, sleepDisabled: Bool, ours: Bool) -> Step {
        if want { return sleepDisabled ? .none : .disableSleep }
        return sleepDisabled && ours ? .enableSleep : .none
    }

    /// `pmset -g` prints «SleepDisabled  1» while sleep is off.
    nonisolated static func sleepDisabled(in pmsetOutput: String) -> Bool {
        pmsetOutput.split(separator: "\n").contains { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            return parts.count >= 2 && parts[0] == "SleepDisabled" && parts[1] == "1"
        }
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: sudoersFile) }

    /// Laptops report the lid state on the power root domain; a Mac mini, Studio or Pro has none.
    static let hasLid: Bool = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) != nil
    }()

    static var ours: Bool {
        get { UserDefaults.standard.bool(forKey: ownedKey) }
        set { UserDefaults.standard.set(newValue, forKey: ownedKey) }
    }

    static func systemSleepDisabled() async -> Bool {
        let result = try? await ProcessRunner.run(pmset, ["-g"], timeout: .seconds(10))
        return sleepDisabled(in: result?.stdoutText ?? "")
    }

    /// Through the sudoers rule; `-n` fails instead of asking for a password when the rule is gone.
    static func setSleepDisabled(_ disabled: Bool) async -> Bool {
        let result = try? await ProcessRunner.run("/usr/bin/sudo", ["-n", pmset, "-a", "disablesleep", disabled ? "1" : "0"], timeout: .seconds(10))
        return result?.exitCode == 0
    }

    /// When quitting: no time for async work.
    static func enableSleepNow() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", pmset, "-a", "disablesleep", "0"]
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
        if process.terminationStatus == 0 { ours = false }
    }

    enum AdminResult: Equatable { case done, cancelled, failed(String) }

    /// macOS asks for an administrator password in its own dialog; the rule is checked by `visudo` before it is put
    /// in place (a file name with a dot is ignored by sudo, so the check copy never counts).
    static func install() async -> AdminResult {
        guard let rule = rule(user: NSUserName()) else { return .failed(String(localized: "Имя пользователя не подходит для правила sudo")) }
        let temp = FileManager.default.temporaryDirectory.appending(path: "claudepult-sudoers-\(UUID().uuidString)")
        do { try rule.write(to: temp, atomically: true, encoding: .utf8) } catch { return .failed(error.localizedDescription) }
        defer { try? FileManager.default.removeItem(at: temp) }
        let check = "/etc/sudoers.d/.claudepult.check"
        let script = "/usr/bin/install -m 0440 -o root -g wheel '\(temp.path)' \(check) && /usr/sbin/visudo -cqf \(check) && /bin/mv -f \(check) \(sudoersFile) || { /bin/rm -f \(check); exit 1; }"
        return await runAsAdmin(script, prompt: String(localized: "ClaudePult просит разрешение не давать Mac засыпать с закрытой крышкой."))
    }

    static func uninstall() async -> AdminResult {
        await runAsAdmin("/bin/rm -f \(sudoersFile)", prompt: String(localized: "ClaudePult убирает своё разрешение для сна с закрытой крышкой."))
    }

    private static func runAsAdmin(_ shell: String, prompt: String) async -> AdminResult {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let apple = "do shell script \(quoted(shell)) with prompt \(quoted(prompt)) with administrator privileges"
        guard let result = try? await ProcessRunner.run("/usr/bin/osascript", ["-e", apple], timeout: .seconds(300)) else {
            return .failed(String(localized: "Не удалось запустить osascript"))
        }
        if result.exitCode == 0 { return .done }
        // -128: the person pressed «Отменить».
        if result.stderrText.contains("-128") { return .cancelled }
        return .failed(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
