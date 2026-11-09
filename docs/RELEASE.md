# Releasing AI Hub Bar

AI Hub Bar is shared as a `.dmg` on GitHub Releases. It updates itself through [Sparkle](https://sparkle-project.org). Builds are signed with a Developer ID (team 365835Q3S6, Apple Developer Program paid 2026-11-06) and notarized by Apple.

- **What works:** a first launch without Gatekeeper's block, and updates that install themselves. Permissions given to AI Hub Bar (Terminal automation, notifications) survive updates, because every release carries the same signature.
- **Changing from the self-signed certificate:** the first Developer ID build has a new signature, so macOS asks for permissions once more. Sparkle takes it: the update's Ed25519 key is the same.

## One-time setup (done on Oleh's Mac 2026-10-30)

```bash
scripts/release-tools/make-signing-cert.sh
swift scripts/release-tools/sparkle-key.swift keygen
```

Both commands write to `~/Library/Application Support/ClaudePult-release/`. Neither writes to the login keychain, and both refuse to overwrite existing files. The folder ends up with:

| File | What it is |
|---|---|
| `developer-id.p12` + `developer-id.pass` | The Developer ID Application certificate with its private key (`developer-id.key`, `developer-id.cer`), valid until December 2027. During a release it goes into a temporary keychain that is deleted at the end. |
| `codesign.p12` + `codesign.pass` | The old self-signed “ClaudePult Release” certificate, no longer used. |
| `codesign.crt` | The certificate alone, public. |
| `sparkle-ed25519.key` | The private Ed25519 key that signs updates. Its public half is `SUPublicEDKey` in `project.yml`. |

**Back this folder up**, for example to an encrypted disk or a password manager:
- Without `sparkle-ed25519.key`, installed copies can no longer take updates.
- With a different certificate, macOS asks for permissions again.

The folder is never committed.

Developer ID setup (done 2026-11-07): the certificate was requested with `openssl` because Keychain Access opens Passwords on this macOS. Apple's intermediate `DeveloperIDG2CA.cer` has to be in the login keychain, or `codesign` fails with `errSecInternalComponent`. Notarization uses the keychain profile from `xcrun notarytool store-credentials "AIHubBar" --team-id 365835Q3S6` with an app-specific password.

## A release

```bash
scripts/release.sh 0.2.0            # build, sign, .dmg, appcast.xml into build/release/0.2.0/
scripts/release.sh 0.2.0 --publish  # the same, then the GitHub release v0.2.0 with the .dmg, appcast.xml and the overview PDFs
```

- **Before running:** the tree must be clean.
- **Build number:** it is the number of commits, so every release counts up.
- **How copies find updates:** they read `https://github.com/OlehDemishev/AIHubBar/releases/latest/download/appcast.xml`, which is the newest release's appcast. Nothing else has to be uploaded or committed.
- **Public repository needed:** people can only download the files once the repository is public.

## A new version of Sparkle

The copies on people's Macs run the old Sparkle's installer, and a broken update can't be fixed by another update. So a new Sparkle goes out as a beta first (below): update a real copy of the latest release through it and see the app restart with its permissions. After changing the version remove `build/DerivedData`, or the old module cache fails the build.

## Beta builds

Beta (canary) builds go to beta testers first: people who switched on Settings → General → **Beta builds** («Бета-версии»).

```bash
scripts/release.sh 0.4.0-beta.1 --publish   # a beta: GitHub pre-release v0.4.0-beta.1
scripts/release.sh 0.4.0 --publish          # the release, later
```

- **Who gets a beta:** only copies with “Beta builds” on. A pre-release is never GitHub's “latest”, so the normal appcast (`releases/latest/download/appcast.xml`) doesn't change.
- **The beta channel:** beta testers' copies read `https://github.com/OlehDemishev/AIHubBar/releases/download/beta/appcast.xml` instead (`Updates.betaFeedURL`). It is an asset of the release tagged `beta`, which holds no build. Every `--publish`, beta or not, replaces it with the newest release and the newest beta (`scripts/release-tools/beta-feed.py`). The first beta creates that release. Beta items carry `<sparkle:channel>beta</sparkle:channel>`; Sparkle takes them only in a beta tester's copy.
- **After the release:** a release with a higher build number than the beta reaches beta testers too, so nobody stays on an old beta.
- **Switched off:** Sparkle doesn't go back to an older version. The copy stays on the beta until the next release, which is newer.
- **Features in beta testing:** a module with `ModuleKind.isBeta` is in the Modules catalog and works only with “Beta builds” on. Today: none («Раскладка» left beta in 0.6.0). To release a module to everyone, drop its `isBeta`.
- **Version names:** `0.4.0-beta.1`, `-beta.2` …. The build number (commit count) decides what is newer, as for releases. `scripts/build-and-install.sh` skips beta tags when it names a local build.

## First launch for people

1. Download `AIHubBar-<version>.dmg` from Releases, open it and drag AI Hub Bar to Applications.
2. Open AI Hub Bar. Later updates come through Sparkle (“Updates” in Settings → General).

## Developer builds

`scripts/build-and-install.sh` installs to `~/Applications` and signs with the same Developer ID certificate, without notarization, when this Mac has the keys (`scripts/release-tools/sign-app.sh`), otherwise ad hoc. With the certificate macOS keeps the app's permissions across builds; an ad-hoc signature changes with every build, and permissions such as Accessibility (needed by «Раскладка») stop working while the switch in System Settings still shows on. Coming from an ad-hoc build: `tccutil reset Accessibility com.demishev.claudepult` once, then allow again. A release installs to `/Applications`. Don't run both at once: they share the bundle id, so there would be two ✦ in the menu bar.

Debug builds (`xcodebuild test`, `scripts/check.sh`, `scripts/export-help.sh`) have their own bundle id, `com.demishev.claudepult.debug`, and widget id `com.demishev.claudepult.debug.widget`. With the real id, reading `SMAppService.mainApp.status` in such a build moved the installed app's login item record to the build's folder, and when that folder was deleted the app didn't start at login. The Debug build also gives up `aihubbar://` (it has `aihubbar-debug://`) and doesn't open `*.claudepult` files, so macOS keeps sending them to the installed app. Its settings live in their own domain: `defaults write com.demishev.claudepult.debug …` for a Debug build, the real id for installed builds. `sfltool dumpbtm` shows the record but asks for an admin password on every call.
