# ClaudePult

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

Generates `ClaudePult.xcodeproj` from `project.yml`, builds Release, installs to `~/Applications/ClaudePult.app` (replacing the old copy) and relaunches the app. Options:

- `--test` — run unit tests before building
- `--no-launch` — install without launching

The app is signed ad-hoc; no Apple Developer account is needed.

## Development

```bash
xcodegen generate
xcodebuild test -project ClaudePult.xcodeproj -scheme ClaudePult -destination 'platform=macOS,arch=arm64'
```

`ClaudePult.xcodeproj` and `ClaudePult/Info.plist` are generated from `project.yml` and are not committed — edit `project.yml` instead.

Layout:

- `ClaudePult/App` — app entry point, command-line mode
- `ClaudePult/Views` — SwiftUI views (menu panel, settings)
- `ClaudePult/Services` — system integrations (login item)
- `ClaudePultTests` — Swift Testing unit tests

## Command line

The app binary accepts headless commands (used by scripts and checks; the UI is not started):

```bash
~/Applications/ClaudePult.app/Contents/MacOS/ClaudePult --login-item status
```

| Command | Effect |
|---|---|
| `--login-item status` | print login item state (`enabled`, `disabled`, `requiresApproval`) |
| `--login-item on` | register ClaudePult as a login item |
| `--login-item off` | unregister it |
