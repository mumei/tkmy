# TKMY

[日本語](README_ja.md) | English

**TKMY（トークン見えるやつ）** is an open-source macOS menu bar app that shows local Codex and Claude Code token usage as two independent meters. Each popover shows today's input/output totals, an estimated USD cost, and a 12-month daily heatmap.

Right-click either meter and choose **Settings…** to control the display language, launch at login, hover-to-open behavior, automatic update checks, and the visibility of the Codex and Claude Code menu items. At least one menu item always remains visible so the settings window stays reachable.

On first launch, TKMY selects a supported language from the Mac’s preferred languages. The interface can then be switched immediately between English, Japanese, German, Simplified Chinese, French, Korean, Spanish, Italian, Vietnamese, Thai, and Traditional Chinese.

The app reads local JSONL usage records. Prompt text, responses, source code, project paths, and API keys are not stored.

## Status

This repository contains an executable Swift Package implementation of the MVP. Pricing is an estimate, not a bill. Unknown model pricing is shown as unavailable instead of `$0.00`.

The bundled catalog includes GPT-6.1 Sol, GPT-6 Astra/Sol/Luna, GPT-5.6 Sol/Terra/Luna, earlier supported Codex models, and Claude Fable 5.1/5, Mythos 5.1/5, Opus 5.5/5/4.8/4.7/4.6/4.5, Sonnet 5/4.6, and Haiku 4.5. OpenAI pricing was reviewed on September 30, 2026 against the [OpenAI pricing documentation](https://developers.openai.com/api/docs/pricing) and [GPT-6.1 Sol model page](https://developers.openai.com/api/docs/models/gpt-6.1-sol); Claude pricing was last reviewed on September 25, 2026 against the [Claude pricing documentation](https://platform.claude.com/docs/en/about-claude/pricing). GPT-6.1 Sol uses Standard short-context rates, including a $0.10 cached-input rate per million tokens; reasoning effort such as `high` does not change the model ID. GPT-5.6 Sol uses the currently published promotional rates; Sonnet 5 uses its confirmed standard rates, with no September 1 increase. Fable 5.1, Mythos 5.1, and Opus 5.5 use their reduced cache-read rates.

**GPT-6.1 Sol status (October 6, 2026):** Its pricing change was merged into main in [PR #5](https://github.com/mumei/tkmy/pull/5) and is included in this 1.0.10 candidate. The published 1.0.8 catalog does not include it. TKMY can display the model ID and token usage when those fields are present in Codex logs; this candidate also estimates its cost using the bundled Standard short-context rates. A cost reported by the source still takes precedence.

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

This API is [experimental](https://github.com/anthropics/claude-agent-sdk-typescript/blob/main/CHANGELOG.md#03169). TKMY requires Claude Code **2.1.289 or later**, the oldest SDK contract reviewed for this integration, so it can request `skip_behaviors` without scanning transcripts. Earlier versions, a missing CLI/login/profile scope, API-key or third-party-provider sessions, and unavailable responses display `—`. The CLI owns authentication; TKMY does not read credentials or change Claude settings. TKMY stores percentages, reset/observation times, and an allowlist of account display fields (email, organization ID/name, and subscription type). Tokens, API keys, credential files, and raw authentication responses are never stored or logged.

Native installs in `~/.local/bin`, Homebrew installs, and executables on TKMY's `PATH` are detected. `TKMY_CLAUDE_EXECUTABLE` can select another CLI path when supplied to TKMY's environment. Quota requests are throttled to once a minute during app refreshes; identity is rechecked on every refresh, including within that interval. A failed request can retain the original observation for at most 10 minutes, never beyond its reset; an explicitly unavailable allowance clears the cache. A reset is not assumed to restore 100% without a new observation.

To verify on another Mac with a build containing this change: check `claude --version`, confirm that `/usage` in the same Claude Code login shows a general weekly or 5-hour allowance, then choose **Refresh** on TKMY's Claude menu with **Show remaining percentage** enabled. Compare the same time window, rather than context usage or a model-specific limit. For troubleshooting, share only the two app/CLI versions, the display setting, whether `/usage` has that window, and whether TKMY shows a percentage or `—`; do not share transcripts, credential files, tokens, or raw CLI responses.

## Account-separated quota history

Both Codex and Claude Code show the 5-hour and weekly remaining percentages together, with blue and orange series and a legend containing each window's last confirmed value/time. The existing six elapsed-time ranges remain available. Missing windows show `—`; resets and missing observations never imply a replenished or zero allowance. Other returned window lengths are displayed as reported.

The account picker changes only which stored history is displayed; it does not log in, log out, or switch either CLI. The current CLI account and historical accounts are labeled separately. Historical series stop at their last observation instead of extending to the present. The table identifies each row's window; the consumption pace below the graph is calculated for the labeled preferred window, never across the two series. Local token logs have no verified account attribution, so token-per-percentage estimates are unavailable for account-specific histories.

Claude identity comes from read-only `claude auth status`: `email` plus `orgId` identifies an account/organization. Missing or null organization fields are supported for personal accounts. Organization names and subscription types are display metadata and do not create new identities. Additional CLI keys are ignored; malformed identity fields fail closed. The quota provider checks identity before and after its read, and refresh caches are cleared when identity changes or cannot be verified.

Codex uses the public [app-server protocol](https://learn.chatgpt.com/docs/app-server): `account/read` with `refreshToken: false`, and `account/rateLimits/read`. It checks account identity before/after the quota response, rejects account-change notifications, and confirms identity with a fresh app-server process after acquisition. The public ChatGPT account shape exposes `email` and `planType`, but no stable workspace/account ID. Codex history therefore separates **different emails**, and cannot distinguish workspaces sharing one email. Plan names are display metadata: TKMY uses actual returned durations/percentages, never derives allowances from Plus/Pro/etc. These are **Codex allowances**, not ChatGPT chat message limits. Failed or unverifiable Codex reads clear its current quota rather than falling back to an anonymous log value.

Existing history and imported Codex session-log observations remain in **Unknown account (legacy history)**. They are never assigned to the currently logged-in account by inference. Account metadata and account-scoped history are stored locally in SQLite (schema 5); **Delete history** also removes the account metadata. The display-history retention and compressed evidence storage continue to apply independently to each account/window.

Validation uses synthetic CLI responses, temporary SQLite databases, switching-race fixtures, and offscreen macOS view rendering. It does not establish live multi-account or multi-organization behavior on every CLI version. Changes occurring and reverting entirely between identity observations cannot be detected by polling.

## Documentation

- [Requirements](index.html)
- [Technical design](design.html)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## License

MIT. Third-party data and dependency notices are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
