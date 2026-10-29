# ClaudeBar

Native macOS menu bar app (no Dock icon): a control panel for the projects in `~/Projects` and for Claude Code sessions. Full specification: [docs/SPEC.md](docs/SPEC.md). Progress: [docs/STATUS.md](docs/STATUS.md). Design decisions: [DECISIONS.md](DECISIONS.md).

Current stage: **1 — skeleton**. The menu bar icon opens an empty panel with «Настройки…» and «Выход»; the Settings window has the «Запускать при входе в систему» toggle.

## Requirements

- macOS 14 or newer (developed on macOS 27, Apple Silicon)
- Xcode with Swift 6 (developed with Xcode 27.1)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build and install

```bash
scripts/build-and-install.sh
```

Generates `ClaudeBar.xcodeproj` from `project.yml`, builds Release, installs to `~/Applications/ClaudeBar.app` (replacing the old copy) and relaunches the app. Options:

- `--test` — run unit tests before building
- `--no-launch` — install without launching

The app is signed ad-hoc; no Apple Developer account is needed.

## Development

```bash
xcodegen generate
xcodebuild test -project ClaudeBar.xcodeproj -scheme ClaudeBar -destination 'platform=macOS,arch=arm64'
```

`ClaudeBar.xcodeproj` and `ClaudeBar/Info.plist` are generated from `project.yml` and are not committed — edit `project.yml` instead.

Layout:

- `ClaudeBar/App` — app entry point, command-line mode
- `ClaudeBar/Views` — SwiftUI views (menu panel, settings)
- `ClaudeBar/Services` — system integrations (login item)
- `ClaudeBarTests` — Swift Testing unit tests

## Command line

The app binary accepts headless commands (used by scripts and checks; the UI is not started):

```bash
~/Applications/ClaudeBar.app/Contents/MacOS/ClaudeBar --login-item status
```

| Command | Effect |
|---|---|
| `--login-item status` | print login item state (`enabled`, `disabled`, `requiresApproval`) |
| `--login-item on` | register ClaudeBar as a login item |
| `--login-item off` | unregister it |
