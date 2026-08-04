# TKMY

[日本語](README_ja.md) | English

**TKMY（トークン見えるやつ）** is an open-source macOS menu bar app that shows local Codex and Claude Code token usage as two independent meters. Each popover shows today's input/output totals, an estimated USD cost, and a 12-month daily heatmap.

Right-click either meter and choose **Settings…** to control the display language, launch at login, hover-to-open behavior, automatic update checks, and the visibility of the Codex and Claude Code menu items. At least one menu item always remains visible so the settings window stays reachable.

On first launch, TKMY selects a supported language from the Mac’s preferred languages. The interface can then be switched immediately between English, Japanese, German, Simplified Chinese, French, Korean, Spanish, Italian, Vietnamese, Thai, and Traditional Chinese.

The app reads local JSONL usage records. Prompt text, responses, source code, project paths, and API keys are not stored.

## Status

This repository contains an executable Swift Package implementation of the MVP. Pricing is an estimate, not a bill. Unknown model pricing is shown as unavailable instead of `$0.00`.

The bundled catalog covers current publicly priced Codex model families and Claude Sonnet 4.6. Its official source URLs and retrieval date are embedded in the catalog; preview or internal model names without a published API price remain explicitly unpriced until a reviewed catalog update adds them.

## Requirements

- macOS 14 or later
- Xcode 26 or a compatible Swift 6 toolchain

## Build and test

```sh
swift test --disable-sandbox --scratch-path .build -Xcc -fmodules-cache-path=.build/ModuleCache
./Scripts/build-app.sh
open '.build/app/TKMY.app'
```

The first build resolves [Sparkle 2](https://github.com/sparkle-project/Sparkle). The generated `.app` uses an ad-hoc development signature. Official releases must use Developer ID signing, notarization, and Sparkle EdDSA signing.

The [CI workflow](https://github.com/mumei/tkmy/actions/workflows/ci.yml) can also be run manually. It tests the project, builds the release `TKMY.app`, and uploads an ad-hoc signed ZIP plus its SHA-256 checksum as a workflow artifact for 14 days.

Official releases are created manually from the [Release workflow](https://github.com/mumei/tkmy/actions/workflows/release.yml). Add `changeLog/<version>.md` before releasing; its 11-language content is validated and used as both the GitHub Release notes and embedded Sparkle release notes. After a version is entered, GitHub Actions builds and Developer ID-signs the app, notarizes it with Apple, creates and notarizes an Applications-link DMG, and publishes the DMG, ZIP, checksums, and signed `appcast.xml` to GitHub Releases. The `release` environment must contain the secrets `CERTIFICATE_P12_BASE64`, `CERTIFICATE_PASSWORD`, `NOTARY_KEY_BASE64`, and `SPARKLE_PRIVATE_KEY`, plus the variables `TKMY_FEED_URL` and `SPARKLE_PUBLIC_KEY`. The notarization Key ID, Issuer ID, and Developer ID identity can be overridden with repository variables.

## Local data sources

- Codex: `${CODEX_HOME:-~/.codex}/sessions` and `archived_sessions`
- Claude Code: `~/.claude/projects`, `~/.config/claude/projects`, and `CLAUDE_CONFIG_DIR`

The database is stored at `~/Library/Application Support/TKMY/usage.sqlite3`.

## Documentation

- [Requirements](index.html)
- [Technical design](design.html)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## License

MIT. Third-party data and dependency notices are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
