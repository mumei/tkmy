# Codex quota history

The Codex popover's **Quota history** tab shows provider-reported remaining
percentages as a table and a chart. The initial range is seven days; users can
switch to thirty days. Quota buckets and window durations have independent
series. This is an account allowance, not a remaining token count.

Observations retain their original JSONL event timestamps. A repeated refresh
does not create a new observation from an old value. Identical observations
copied between logs are deduplicated; genuinely different observation times
remain separate even when the percentage has not changed.

## Retention and ingestion

- `usage_limit_samples` retains a rolling 365 × 24 hours, including the cutoff.
  Expired samples are deleted on refresh, including refreshes without logs.
  Inserts independently reject expired and future observations, so old logs
  cannot resurrect deleted history.
- Existing token events and their file cursors keep their existing behavior.
  The explicit **delete history** operation clears both kinds of history.
- New token-count events feed quota observations into the same refresh flow.
  Older observations are imported incrementally, with a separate persistent
  `quota:` cursor for each source file. No token cursor migration is required.
- Each backfill refresh reads at most 4 MiB of JSONL content and examines at
  most sixteen candidate files, plus bounded file fingerprint reads. Files
  modified before the retention cutoff are skipped. Completed, unchanged files
  are not read again. Discovery reuses the existing token-ingestion file list.
- Partially read files continue on later refreshes. A quota-only parser caps
  unfinished lines at 1 MiB and skips oversized lines through their newline.
  Restarting inside such a line also skips its suffix.
- Parsing and storage both enforce retention. The UI loads only the latest
  thirty days, while older retained records remain in SQLite.

Backfill is gradual. There is no additional network polling, API credential
handling, or requirement to keep a Codex turn active. When local logs do not
record an observation, the app cannot reconstruct that missing value.

## Display

The chart plots observed values on a fixed 0–100% scale. Lines are split when
the quota bucket/window changes, the reported reset time changes, remaining
allowance rises, or observations are more than thirty minutes apart. Missing
periods are not filled with synthetic zero, 100%, or interpolated samples.
The table retains the observation time, remaining percentage, and the reset
time reported for that observation. Model-specific allowances never join the
general Codex allowance.

## Verification

Storage tests cover 365-day boundaries, expiry, reimport rejection, duplicate
observations, persistence, and preservation of existing token history.
Importer tests cover work budgets, unchanged files, appends, copied logs,
partial reads, restarts, replacements, and retention. View-model tests cover
7/30-day filtering and distinct chart segments. The full popover is rendered
in every supported language.

See [SQLite capacity measurements](quota-history-storage.md) for measured row
and index sizes, rate assumptions, and the repeatable synthetic-data harness.
