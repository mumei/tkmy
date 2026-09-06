# Quota history storage measurement

Measured on 2026-09-07 with the production `usage_limit_samples` schema from
`SQLiteUsageStore`: its composite primary-key index, the
`(source, observed_at_ms)` history index, and the `observed_at_ms` cleanup
index. The measurement used SQLite `dbstat`, a 4 KiB page size, and 100,000
synthetic Codex samples. Samples alternate `codex` and `codex_bengalfox`, use
millisecond timestamps spaced one minute apart, 5-hour and weekly reset times,
and percentage values from 0 through 100. It does not run `VACUUM`, matching
normal production operation.

Run it again with:

```sh
rtk python3 Scripts/measure-quota-storage.py
```

The measured 100,000-row database was 13,373,440 bytes, or **133.7344 bytes
per stored sample**. `dbstat` accounted for every database page.

| SQLite object | Bytes | Bytes/sample |
| --- | ---: | ---: |
| `usage_limit_samples` table | 4,317,184 | 43.1718 |
| Composite primary-key index | 4,988,928 | 49.8893 |
| `idx_usage_limit_source_observed` | 2,375,680 | 23.7568 |
| `idx_usage_limit_observed` | 1,687,552 | 16.8755 |
| Schema page | 4,096 | 0.0410 |

The harness inserts the same 100,000 records twice with `INSERT OR IGNORE`.
The second insert added zero rows and zero database pages.

前提は24時間連続で観測する場合です。行数は
`days × 1,440 × windows × samples/min` で求めます。既存アプリの60秒タイマーは
ログに変化がない限り観測を増やしません。一方、新しい `token_count` イベントは
1分あたり1件を超えることがあるため、10件/分も併記しています。

Projected storage applies the measured 133.7344 bytes/sample to retained
distinct observations. Repeated reads of an identical observation are
deduplicated; different timestamps are retained, including busy observations
that arrive ten times per minute.

| Retention | Windows | Observations/min/window | Samples | Estimated database size |
| --- | ---: | ---: | ---: | ---: |
| 30 days | 1 | 1 | 43,200 | 5.51 MiB |
| 30 days | 3 | 1 | 129,600 | 16.53 MiB |
| 365 days | 1 | 1 | 525,600 | 67.03 MiB |
| 365 days | 3 | 1 | 1,576,800 | 201.10 MiB |
| 30 days | 1 | 10 | 432,000 | 55.10 MiB |
| 30 days | 3 | 10 | 1,296,000 | 165.29 MiB |
| 365 days | 1 | 10 | 5,256,000 | 670.35 MiB |
| 365 days | 3 | 10 | 15,768,000 | 1.96 GiB |

The application uses WAL mode. The figures above describe the checkpointed
main database; the `-wal` file can temporarily add disk use while writes have
not yet checkpointed. Deleting expired rows normally makes SQLite pages
available for reuse, so the file may remain near a previous high-water size
instead of shrinking immediately. `VACUUM` reclaims that space, but is not
needed for bounded row retention.
