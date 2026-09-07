# Codex quota history

The Codex popover's **Quota history** tab shows provider-reported remaining
percentages as a table and a chart. The initial range is seven days; a menu
offers 1 hour, 6 hours, 12 hours, 1 day (24 hours), 7 days, and 30 days.
These are elapsed-time windows, including across daylight-saving changes.
The selected range and quota window are held by the source view model, so
automatic refreshes and history-view recreation preserve the selection.
Refreshing cached history keeps the existing view visible, including when
there are no token-usage records yet.
Quota buckets and window durations have independent
series. This is an account allowance, not a remaining token count.

History records represent changes in the reported percentage or reset window.
The first observation of each bucket is saved. Further observations with the
same value update that record's last-confirmed time, rather than adding table
rows. Both endpoints are actual JSONL timestamps: reading an old value again
never advances its confirmation time to the app's refresh time.

An observation after a gap longer than thirty minutes starts a new record even
if its value is unchanged. This distinguishes a steady value with continuing
observations from a period in which nothing was reported.

Reset timestamps may fluctuate by one second. A reset epoch admits timestamps
only while its entire minimum-to-maximum spread stays within one second;
successive one-second steps cannot drift indefinitely into the same epoch.
Percentage changes do not reset that tolerance. A larger reset change or a
transition between reported and unreported reset times starts a new epoch.
The percentage itself is compared at the provider's stored precision.

## Storage and migration

Schema 4 stores compact change records in `usage_limit_samples`, with the
first and last confirmation timestamps and an explicit reset-epoch identity.
The observations needed to reconcile out-of-order logs are packed into
`usage_limit_evidence_pages`, grouped by bucket and UTC day. These pages retain
timestamp and value evidence without allocating a full indexed history row
for each unchanged observation. They are included in capacity measurements.

Keeping that evidence matters: a late observation can reveal a changed value
inside a previously constant run. The store can reconstruct the real change
and recovery points instead of losing them or inventing their times. Duplicate
observations copied between files do not add evidence or advance confirmation
times. Same-time conflicting values retain a deterministic ordering.

Before migrating a schema-3 database, the store creates a consistent SQLite
backup beside it. If the backup fails, migration stops. The quota conversion is
transactional; token events and file cursors are preserved. Local installation
also backs up the existing app, settings, and database before replacement.

## Retention and ingestion

- Change records and packed confirmation evidence retain a rolling
  365 × 24 hours, including the cutoff. Expired evidence is deleted on refresh,
  including refreshes without logs. A run crossing the cutoff starts at its
  first remaining actual observation. Inserts independently reject expired
  and future observations, so old logs cannot resurrect deleted history.
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
- Parsing and storage both enforce retention. The UI loads the latest thirty
  days plus a thirty-minute lookback for a connected chart predecessor, while
  older retained records remain in SQLite.

Backfill is gradual. There is no additional network polling, API credential
handling, or requirement to keep a Codex turn active. When local logs do not
record an observation, the app cannot reconstruct that missing value.

## Display

The chart plots confirmed runs on a fixed 0–100% scale. Solid lines cover each
run from `observedAt` through `lastObservedAt`, and only actual endpoints
receive filled markers. Within the same source, bucket, and reset epoch, a
solid reference line connects separate actual runs or points when there is no
recovery, including gaps longer than thirty minutes. The latest observed value
may extend forward as a solid reference line to the current time, capped at a
known upcoming reset. The chart never extrapolates backward.

Storage assigns a new epoch ID after a reporting gap, even when no reset
occurred. A chart reference may bridge these different IDs across a gap longer
than thirty minutes when both reported reset times match within one second,
neither reset falls inside the gap, and remaining allowance did not recover.
Unknown or changed reset times do not qualify for this exception. The original
epoch IDs and measured-continuity segments remain unchanged.

Lines break when the quota bucket/window or reset epoch changes, or when the
remaining allowance recovers; no diagonal line joins a reset or recovery. The
one-second reset jitter does not split a confirmed epoch. These visual
references do not create observations: missing periods are not written as
synthetic zero, 100%, or other values, and they do not count toward token pace
or its rate endpoints.

The selectors, chart, compact token reference, and table header stay fixed.
Only the table rows scroll vertically. The chart has a grid and labels at
0%, 25%, 50%, 75%, and 100%, plus vertical guides at the range-specific time
ticks. Token-estimate details are available from the
information button, keeping long explanations out of the main history panel.
The elapsed-time consumption-pace display is not shown.

The table shows the confirmation period, its readable duration (for example,
35 minutes or 2 hours 15 minutes), remaining percentage, and reset time. A
single observation is explicitly labeled rather than presented as a measured
zero-minute duration. Positive durations under a minute have their own label;
longer durations use whole elapsed minutes. A last-confirmed label makes the
age of the latest observation visible.

Short ranges use time labels; the 24-hour range includes dates, and 7/30-day
ranges use dates. A run crossing the cutoff is visible. When the first visible
run connects to a real preceding observation, the chart includes that endpoint
and clips the line to the plot. It does not move the endpoint to the cutoff or
add a synthetic marker. The outside predecessor is absent from table rows.
Model-specific allowances never join the general Codex allowance.

## Observed token reference

The estimate uses the latest continuous segment in the selected range. Its
actual first and last change timestamps and percentage-point drop define the
comparison interval. A constant run's last-confirmed time is used to check
continuity, never as the timestamp of a future drop. Chart reference lines may
extend to the current clock, but the calculation does not. The time-based pace
helper remains internal; the user-facing reference is tokens per 1%.

Both rate endpoints must be actual observations inside the chosen range. A
chart boundary cannot create a rate baseline. Resets, recoveries, gaps over
thirty minutes, conflicting timestamps, reversed order, or insufficient
observations cannot supply a rate across the break. The latest segment needs
its own observed decrease; an older segment's rate is not carried forward.
The observed interval is elapsed wall-clock time, not active work time.

The token estimate uses the same endpoints and divides normalized local Codex
tokens by the observed percentage-point drop. The interval is `(start, end]`:
events at the initial observation are excluded and all events at the final
observation are included. The breakdown shows uncached input, cached input,
and output per 1%. Cached input is counted once; reasoning output is already
included in output and is not added again. Existing event-key deduplication
and cumulative-log normalization happen before this aggregation.

This is a comparison with logs on this Mac, not a fixed tokens-to-quota
conversion. Voice, other devices, and other usage absent from those logs are
not reconstructed. Only the general `codex` bucket is supported. Known Spark
events are excluded as a separate quota; an unknown or unrecognized model,
including `codex-auto-review`, makes the affected interval unavailable.
Model-specific quota IDs are not guessed from event model names. Missing
endpoints, no recorded tokens, incomplete ingestion, and arithmetic overflow
also produce an unavailable result.

No raw token history or new token-estimate table is written. The existing
ordered token-report scan also collects compact cumulative totals at quota
change timestamps. Subtracting two points gives the exact observed interval.
SQLite scan failures throw instead of returning a partial total. A namespaced scanner
checkpoint records when verifiable token coverage begins. Older imported
history did not retain malformed-line diagnostics, so token intervals starting
before that watermark remain unavailable; no full log reimport is forced.
Once two actual quota changes exist after the watermark, the token reference
can use that interval. Before then, the reference remains unavailable. The
watermark never becomes a synthetic quota observation.

The token parser remains at version 2. A negative Codex cursor version (`-2`)
records known incomplete coverage and keeps estimates unavailable on later
refreshes without repeatedly scanning an unchanged malformed file. Appends
retain that state; a successful full reparse can clear it. Claude's cursor
semantics remain unchanged. The coverage watermark is stored in the existing
cursor table and is cleared by deleting history.

## Verification

Storage tests cover 365-day boundaries, expiry, reimport rejection, duplicate
observations, migration backup, out-of-order changes, reset jitter and drift,
persistence, and preservation of existing token history.
Importer tests cover work budgets, unchanged files, appends, copied logs,
partial reads, restarts, replacements, and retention. UI tests cover all six
range boundaries, chart predecessor continuity, locale-aware axes, duration
formatting, and pace calculations. The full popover and all six quota ranges
are rendered in every supported language.
The selection regression hosts the Japanese popover and exercises 6-hour and
12-hour selections through repeated refresh states and full view recreation,
both with token records and with quota history alone.

See [SQLite capacity measurements](quota-history-storage.md) for measured
change-record and evidence sizes, assumptions, and the repeatable harness
that executes the actual Swift migration on a disposable database.
