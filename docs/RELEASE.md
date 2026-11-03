# Releasing AI Hub Bar without an Apple Developer account

AI Hub Bar is shared as a `.dmg` on GitHub Releases. It updates itself through [Sparkle](https://sparkle-project.org). There is no Apple Developer ID, so the build is signed with a self-signed certificate.

- **What works:** updates install themselves. Permissions given to AI Hub Bar (Terminal automation, notifications) survive updates, because every release carries the same signature.
- **What it costs:** macOS cannot vouch for the app, so the first launch needs one extra step (see “First launch” below).
- **Developer ID later:** buying it means adding notarization to `scripts/release.sh`; everything else stays.

## One-time setup (done on Oleh's Mac 2026-10-30)

```bash
scripts/release-tools/make-signing-cert.sh
swift scripts/release-tools/sparkle-key.swift keygen
```

Both commands write to `~/Library/Application Support/ClaudePult-release/`. Neither writes to the login keychain, and both refuse to overwrite existing files. The folder ends up with:

| File | What it is |
|---|---|
| `codesign.p12` + `codesign.pass` | The “ClaudePult Release” code signing certificate and its password. During a release it goes into a temporary keychain that is deleted at the end. |
| `codesign.crt` | The certificate alone, public. |
| `sparkle-ed25519.key` | The private Ed25519 key that signs updates. Its public half is `SUPublicEDKey` in `project.yml`. |

**Back this folder up**, for example to an encrypted disk or a password manager:
- Without `sparkle-ed25519.key`, installed copies can no longer take updates.
- With a different certificate, macOS asks for permissions again.

The folder is never committed.

## A release

```bash
scripts/release.sh 0.2.0            # build, sign, .dmg, appcast.xml into build/release/0.2.0/
scripts/release.sh 0.2.0 --publish  # the same, then the GitHub release v0.2.0 with the .dmg, appcast.xml and the overview PDFs
```

- **Before running:** the tree must be clean.
- **Build number:** it is the number of commits, so every release counts up.
- **How copies find updates:** they read `https://github.com/OlehDemishev/AIHubBar/releases/latest/download/appcast.xml`, which is the newest release's appcast. Nothing else has to be uploaded or committed.
- **Public repository needed:** people can only download the files once the repository is public.

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
- **Features in beta testing:** a module with `ModuleKind.isBeta` is in the Modules catalog and works only with “Beta builds” on. Today: «Раскладка» (docs/specs/SPEC-layout.md). To release it to everyone, drop it from `isBeta`.
- **Version names:** `0.4.0-beta.1`, `-beta.2` …. The build number (commit count) decides what is newer, as for releases. `scripts/build-and-install.sh` skips beta tags when it names a local build.

## First launch for people

1. Download `AIHubBar-<version>.dmg` from Releases, open it and drag AI Hub Bar to Applications.
2. Open AI Hub Bar. macOS says it can't check the app; close that message.
3. Open System Settings → Privacy & Security, scroll to “AI Hub Bar was blocked…” and press “Open Anyway”. Confirm with your password.
4. AI Hub Bar opens from then on. Later updates come through Sparkle (“Updates” in Settings → General) without these steps.

## Developer builds

`scripts/build-and-install.sh` installs to `~/Applications` and signs with the same «ClaudePult Release» certificate when this Mac has the keys (`scripts/release-tools/sign-app.sh`), otherwise ad hoc. With the certificate macOS keeps the app's permissions across builds; an ad-hoc signature changes with every build, and permissions such as Accessibility (needed by «Раскладка») stop working while the switch in System Settings still shows on. Coming from an ad-hoc build: `tccutil reset Accessibility com.demishev.claudepult` once, then allow again. A release installs to `/Applications`. Don't run both at once: they share the bundle id, so there would be two ✦ in the menu bar.
