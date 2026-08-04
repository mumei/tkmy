# TKMY

[日本語](README_ja.md) | English

**TKMY（トークン見えるやつ）** is an open-source macOS menu bar app that shows local Codex and Claude Code token usage as two independent meters. Each popover shows today's input/output totals, an estimated USD cost, and a 12-month daily heatmap.

Right-click either meter and choose **設定…** to control launch at login, hover-to-open behavior, automatic update checks, and the visibility of the Codex and Claude Code menu items. At least one menu item always remains visible so the settings window stays reachable.

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

The first build resolves [Sparkle 2](https://github.com/sparkle-project/Sparkle). The generated `.app` is unsigned. Official releases must use Developer ID signing, notarization, and Sparkle EdDSA signing.

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
