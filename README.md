# TKMY

[日本語](README_ja.md) | English

**TKMY（トークン見えるやつ）** is an open-source macOS menu bar app that shows local Codex and Claude Code token usage as two independent meters. Each popover shows today's input/output totals, an estimated USD cost, and a 12-month daily heatmap.

Right-click either meter and choose **Settings…** to control the display language, launch at login, hover-to-open behavior, automatic update checks, and the visibility of the Codex and Claude Code menu items. At least one menu item always remains visible so the settings window stays reachable.

On first launch, TKMY selects a supported language from the Mac’s preferred languages. The interface can then be switched immediately between English, Japanese, German, Simplified Chinese, French, Korean, Spanish, Italian, Vietnamese, Thai, and Traditional Chinese.

The app reads local JSONL usage records. Prompt text, responses, source code, project paths, and API keys are not stored.

## Status

This repository contains an executable Swift Package implementation of the MVP. Pricing is an estimate, not a bill. Unknown model pricing is shown as unavailable instead of `$0.00`.

The bundled catalog includes GPT-6 Astra/Sol/Luna, GPT-5.6 Sol/Terra/Luna, earlier supported Codex models, and Claude Fable 5.1/5, Mythos 5.1/5, Opus 5.5/5/4.8/4.7/4.6/4.5, Sonnet 5/4.6, and Haiku 4.5. Pricing was reviewed on September 25, 2026 against the [OpenAI pricing documentation](https://developers.openai.com/api/docs/pricing) and [Claude pricing documentation](https://platform.claude.com/docs/en/about-claude/pricing). GPT-5.6 Sol uses the currently published promotional rates; Sonnet 5 uses its confirmed standard rates, with no September 1 increase. Fable 5.1, Mythos 5.1, and Opus 5.5 use their reduced cache-read rates.

**GPT-6.1 Sol status (October 5, 2026):** OpenAI documents the model as [`gpt-6.1-sol`](https://developers.openai.com/api/docs/models/gpt-6.1-sol). TKMY can display its model ID and token usage when those fields are present in Codex logs. Estimated token pricing is prepared separately in [PR #5](https://github.com/mumei/tkmy/pull/5), planned for 1.0.9; it is absent from the published 1.0.8 catalog and this Claude-quota 1.0.10 candidate until that change is integrated. Without a cost reported by the source, these versions show its cost as unavailable. A higher reasoning setting does not create a separate model ID.

Estimates use the current catalog's standard token rates, including short-context rates for OpenAI models. Long-context premiums, Fast/Priority processing, Batch/Flex discounts, regional pricing, and tool charges are not inferred from local logs. Only token categories recorded in the logs can be priced; Codex cache-write tokens are not currently reported by this parser. Historical usage without a logged cost is recalculated with the current catalog; a cost reported by the source takes precedence. Official source URLs and retrieval dates are embedded in the catalog. Models without reviewed pricing remain explicitly unpriced.

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

## Claude Code remaining allowance

TKMY reads the general subscription allowance through the installed Claude Code CLI's official Agent SDK `get_usage` control request. It uses Claude Code's existing login and sends no model prompt. Weekly allowance takes priority; if only the 5-hour window is available, the tooltip identifies it as a 5-hour limit. Model-specific limits, extra spend, and context-window percentages are separate and are not used as the general allowance.

This API is [experimental](https://github.com/anthropics/claude-agent-sdk-typescript/blob/main/CHANGELOG.md#03169). TKMY requires Claude Code **2.1.289 or later**, the oldest SDK contract reviewed for this integration, so it can request `skip_behaviors` without scanning transcripts. Earlier versions, a missing CLI/login/profile scope, API-key or third-party-provider sessions, and unavailable responses display `—`. The CLI owns authentication; TKMY does not read credentials or change Claude settings. Only percentages and reset/observation times enter the quota history.

Native installs in `~/.local/bin`, Homebrew installs, and executables on TKMY's `PATH` are detected. `TKMY_CLAUDE_EXECUTABLE` can select another CLI path when supplied to TKMY's environment. Requests are throttled to once a minute during app refreshes. A failed request can retain the original observation for at most 10 minutes, never beyond its reset; an explicitly unavailable allowance clears the cache. A reset is not assumed to restore 100% without a new observation.

To verify on another Mac with a build containing this change: check `claude --version`, confirm that `/usage` in the same Claude Code login shows a general weekly or 5-hour allowance, then choose **Refresh** on TKMY's Claude menu with **Show remaining percentage** enabled. Compare the same time window, rather than context usage or a model-specific limit. For troubleshooting, share only the two app/CLI versions, the display setting, whether `/usage` has that window, and whether TKMY shows a percentage or `—`; do not share transcripts, credential files, tokens, or raw CLI responses.

## Documentation

- [Requirements](index.html)
- [Technical design](design.html)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## License

MIT. Third-party data and dependency notices are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
