# Codex quota history

The Codex popover's **Quota history** tab shows provider-reported remaining
percentages as a table and a chart. The initial range is seven days; users can
switch to thirty days. Quota buckets and window durations have independent
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
- Parsing and storage both enforce retention. The UI loads only the latest
  thirty days, while older retained records remain in SQLite.

Backfill is gradual. There is no additional network polling, API credential
handling, or requirement to keep a Codex turn active. When local logs do not
record an observation, the app cannot reconstruct that missing value.

## Display

The chart plots confirmed runs on a fixed 0–100% scale, extending each constant
run only to its last actual confirmation. Lines are split when the quota
bucket/window or reset epoch changes, remaining allowance rises, or the next
observation is more than thirty minutes after the previous confirmation. The
one-second reset jitter does not split a confirmed epoch. Missing periods are
not filled with synthetic zero, 100%, or invented observations.

The table shows the confirmation period, remaining percentage, and reset time.
A last-confirmed label makes the age of the latest observation visible. The
7/30-day query includes runs crossing the beginning of the display range.
Model-specific allowances never join the general Codex allowance.

## Verification

Storage tests cover 365-day boundaries, expiry, reimport rejection, duplicate
observations, migration backup, out-of-order changes, reset jitter and drift,
persistence, and preservation of existing token history.
Importer tests cover work budgets, unchanged files, appends, copied logs,
partial reads, restarts, replacements, and retention. View-model tests cover
7/30-day filtering and distinct chart segments. The full popover is rendered
in every supported language.

See [SQLite capacity measurements](quota-history-storage.md) for measured
change-record and evidence sizes, assumptions, and the repeatable harness
that executes the actual Swift migration on a disposable database.
