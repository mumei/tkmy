#!/usr/bin/env python3
"""Measure the quota-history SQLite schema used by SQLiteUsageStore.

This creates a disposable, synthetic 100,000-row database. It intentionally
uses the production quota table and every production index, but never opens an
application database.
"""

from __future__ import annotations

import argparse
import os
import sqlite3
import tempfile
from pathlib import Path


SCHEMA = """
CREATE TABLE usage_limit_samples(
  source TEXT NOT NULL,
  limit_id TEXT NOT NULL,
  used_percent REAL NOT NULL,
  window_minutes INTEGER NOT NULL,
  resets_at_ms INTEGER NOT NULL,
  observed_at_ms INTEGER NOT NULL,
  PRIMARY KEY(source, limit_id, window_minutes, resets_at_ms, observed_at_ms, used_percent)
);
CREATE INDEX idx_usage_limit_source_observed
  ON usage_limit_samples(source, observed_at_ms);
CREATE INDEX idx_usage_limit_observed
  ON usage_limit_samples(observed_at_ms);
"""


def make_rows(count: int) -> list[tuple[str, str, float, int, int, int]]:
    # Minute-spaced observations, two real Codex-style limit identifiers, and
    # 5-hour / weekly reset windows. Millisecond storage is exercised directly.
    start_ms = 1_735_689_600_000
    rows = []
    for index in range(count):
        observed_at_ms = start_ms + index * 60_000
        if index % 2:
            limit_id, window_minutes = "codex_bengalfox", 10_080
            resets_at_ms = start_ms + ((index // 10_080) + 1) * 10_080 * 60_000
        else:
            limit_id, window_minutes = "codex", 300
            resets_at_ms = start_ms + ((index // 300) + 1) * 300 * 60_000
        rows.append(("codex", limit_id, float(index % 101), window_minutes, resets_at_ms, observed_at_ms))
    return rows


def dbstat_sizes(connection: sqlite3.Connection) -> dict[str, int]:
    return dict(connection.execute("SELECT name, SUM(pgsize) FROM dbstat GROUP BY name"))


def format_bytes(value: float) -> str:
    return f"{value:,.0f} B ({value / 1024:.1f} KiB, {value / 1024 / 1024:.2f} MiB)"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rows", type=int, default=100_000)
    parser.add_argument("--database", type=Path, help="Optional output database path; defaults to a temporary file.")
    args = parser.parse_args()
    if args.rows <= 0:
        parser.error("--rows must be positive")
    temporary = args.database is None
    if args.database and args.database.exists():
        parser.error("--database must name a new file; refusing to touch an existing database")
    if temporary:
        descriptor, raw_path = tempfile.mkstemp(prefix="quota-storage-", suffix=".sqlite3")
        os.close(descriptor)
        database = Path(raw_path)
    else:
        database = args.database
    if temporary:
        os.unlink(database)

    connection = sqlite3.connect(database)
    try:
        connection.execute("PRAGMA journal_mode = DELETE")
        connection.execute("PRAGMA page_size = 4096")
        connection.executescript(SCHEMA)
        rows = make_rows(args.rows)
        connection.executemany(
            """INSERT OR IGNORE INTO usage_limit_samples(
                source, limit_id, used_percent, window_minutes, resets_at_ms, observed_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?)""",
            rows,
        )
        connection.commit()

        before_count = connection.execute("SELECT COUNT(*) FROM usage_limit_samples").fetchone()[0]
        before_pages = connection.execute("PRAGMA page_count").fetchone()[0]
        connection.executemany(
            """INSERT OR IGNORE INTO usage_limit_samples(
                source, limit_id, used_percent, window_minutes, resets_at_ms, observed_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?)""",
            rows,
        )
        connection.commit()
        after_count = connection.execute("SELECT COUNT(*) FROM usage_limit_samples").fetchone()[0]
        after_pages = connection.execute("PRAGMA page_count").fetchone()[0]

        page_size = connection.execute("PRAGMA page_size").fetchone()[0]
        sizes = dbstat_sizes(connection)
        file_bytes = database.stat().st_size
        print(f"database={database}")
        print(f"rows={before_count:,}; page_size={page_size:,}; file_bytes={file_bytes:,}; page_bytes={after_pages * page_size:,}")
        print(f"duplicate_insert_rows_added={after_count - before_count}; duplicate_insert_pages_added={after_pages - before_pages}")
        for name in sorted(sizes):
            bytes_used = sizes[name]
            print(f"{name}: {bytes_used:,} bytes; {bytes_used / before_count:.4f} bytes/row")
        accounted = sum(sizes.values())
        print(f"dbstat_accounted={accounted:,}; unaccounted_schema_or_free_pages={file_bytes - accounted:,}")
    finally:
        connection.close()
        if temporary:
            database.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
