# Claude quota windows

Contract reviewed on 2026-10-19; CLI version and official changelog rechecked on 2026-10-20. This is contract research and synthetic validation, not a live account result.

## First-party evidence

- [Claude Help: usage credits](https://support.claude.com/en/articles/12429409-manage-usage-credits-for-paid-claude-plans) names a five-hour session limit, a weekly limit, and a separate Fable weekly limit on Max plans. This confirms the spoken name “フェイブル” as Fable, rather than Opus or Sonnet.
- [Official Agent SDK TypeScript changelog](https://github.com/anthropics/claude-agent-sdk-typescript/blob/main/CHANGELOG.md#03191) records the addition of `model_scoped` weekly windows in 0.3.191.
- [Official SDK npm package 0.3.303](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk/v/0.3.303), `sdk.d.ts`, `SDKControlGetUsageResponse`: `rate_limits.five_hour` and `seven_day` contain `utilization` and `resets_at`; optional `model_scoped[]` contains `display_name`, nullable `utilization` (0–100 used), and nullable ISO `resets_at`. Fable is the documented example label. These are used percentages, not remaining percentages.
- The type describes `model_scoped` as server model-weekly rows filtered by an allowlist. Absence can mean cached data or hidden rows; an empty array means a live endpoint listed no model-weekly windows before filtering. Missing data does not prove the account lacks a limit.
- `SDKUsageReport.rate_limits.limits[]` separately describes server rows classified by `kind` (including `weekly_scoped`), with `percent`, scope labels and reset. This is the `/usage` message shape, not TKMY's `get_usage` control response. We do not conflate the two or issue a prompt to obtain it.

## Implementation boundary

TKMY keeps its existing `get_usage` control request, `skip_behaviors: true`, identity checks, no-prompt/no-session-persistence mode, minimum reviewed CLI contract and credential ownership. No cookies, credential extraction, new endpoint, or login change is introduced.

The previous parser explicitly allowed only `five_hour` and `seven_day`, and the coordinator discarded other IDs. It therefore omitted a valid Fable `model_scoped` row even on a supported CLI. The local change accepts exactly `display_name == Fable`, validates the percentage and future reset, stores it under `claude-code-fable@<account-id>`, and retains the general weekly meter independently. Duplicate Fable rows are ambiguous and are rejected. Other model labels and old Opus/Sonnet windows are not reinterpreted as Fable. A future changed label requires a verified contract update.

Menu-bar settings are service-specific and persist across launch. Defaults select general weekly. Short-term selects the shortest actual returned non-model window below seven days; no plan-derived duration or percentage is invented. Missing selected data displays —. Selecting Fable never falls back to general weekly. A reset-time timer clears an expired current value even before the next provider refresh. Historical data is never used as a current meter.

Fable history uses its own series and purple legend; general short-term/weekly series retain blue/orange. Account attribution stays distinct. The source-compatible single `usageLimit` remains the general allowance for existing detail consumers.

## Remaining verification

Installed `/opt/homebrew/bin/claude --version` reports 2.1.76. The official changelog introduces the experimental usage method in SDK 0.3.169 and model-scoped windows in 0.3.191, and explicitly maps SDK 0.3.289 to Claude Code 2.1.289. The installed CLI predates even the usage method; the existing 2.1.289 minimum is a reviewed-contract boundary, not a claim that Fable first appeared in that version. No live quota request or authentication change was attempted. Contract fixtures establish parsing, identity separation, persistence, missing data, selection, and reset behavior; actual account availability and live multi-account switching remain unverified.

Prepared for a draft PR targeting version 1.0.14 (source build 21). Main merge, tags, publication, installed-app replacement and restart are outside the current scope. Live Fable retrieval and multi-account switching need verification with a compatible CLI and eligible account before formal release.
