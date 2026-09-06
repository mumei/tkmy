# Quota history storage measurements

Schema 4 stores one history row for the first observation, a percentage/reset
change, or a restart after a gap longer than thirty minutes. Repeated equal
values update the last-confirmed time. Exact observation evidence is packed
into UTC-day pages so late logs can reconstruct changes inside an existing
run without losing information.

The measurements below include **both change rows and packed evidence, plus
all their SQLite indexes**. They compare allocated quota pages using SQLite
`dbstat` with a 4 KiB page size. Token-history tables, backup files, reusable
free pages, and temporary WAL growth are excluded. No `VACUUM` is run.

## Results

Measured on 2026-09-07 by running the actual Swift schema-3-to-4 migration and
then replaying the input in reverse order. Both replays produced identical
history records and last-confirmed timestamps.

| Input | Observations | Change rows | Old quota allocation | New quota allocation | Reduction |
| --- | ---: | ---: | ---: | ---: | ---: |
| Synthetic, 100 confirmations per percentage change | 100,000 | 1,000 | 13,336,576 B | 2,322,432 B | 82.6% |
| Read-only copy of local quota history | 1,501 | 53 | 204,800 B | 57,344 B | 72.0% |

The synthetic input has two independent Codex quota buckets, six seconds
between observations in each bucket, 5-hour/weekly reset periods, and a
one-second reset-time fluctuation every seventeenth observation. Percentages
change after every hundred confirmations and cycle through 0–100. All
observations lie within the retention window.

For the synthetic input, the new allocation consists of:

| Object | Allocated bytes |
| --- | ---: |
| Packed confirmation evidence | 2,109,440 |
| Change records | 131,072 |
| Source/time index | 40,960 |
| Last-confirmed index | 40,960 |
| **Total** | **2,322,432** |

The local-copy check independently decoded every packed evidence page and
recovered all 1,501 original observations exactly. All 833,377 existing token
event keys were retained, the token event count was unchanged, source cursors
were unchanged, and SQLite `integrity_check` returned `ok`.

These reductions depend on how often values change. A stream whose percentage
changes at every observation cannot collapse into fewer history rows and may
use more space than the old schema because it also retains ordering evidence.
The packed evidence itself still grows with distinct observations. Repeated
reads of the identical observation add neither evidence nor history rows.

## Reproduce

Run from the repository root. The script creates a disposable schema-3
database, invokes an opt-in Swift integration test, and reports the allocation
of the migrated database. It never migrates the installed app's database.

```sh
rtk proxy python3 Scripts/measure-quota-storage.py \
  --rows 100000 --confirmations-per-change 100
```

To retain the report, test log, migration backup, and verification fixture,
pass `--output-directory` with a directory that does not already exist.
To measure existing schema-3 data, pass `--source-database /path/to/usage.sqlite3`;
the script opens it read-only and migrates an online-backup copy. This option
requires schema 3 and is intended for migration verification.

## Retention and physical file size

Both change records and evidence enforce the rolling 365-day cutoff. Evidence
within the boundary UTC day is filtered by its actual timestamp; retaining a
whole day cannot reintroduce expired observations. A run crossing the cutoff
is rebuilt from its first retained confirmation. No-refresh-time observations
are synthesized.

Deletion and migration normally free SQLite pages for reuse. The main database
file can therefore remain near its previous size even when the quota tables
occupy fewer pages. WAL files and the deliberately retained migration/app
backups consume additional space. The percentages above describe active quota
storage, not an immediate reduction in the total Application Support folder.
