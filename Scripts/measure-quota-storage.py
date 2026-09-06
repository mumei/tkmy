#!/usr/bin/env python3
"""Compare schema-3 raw rows with the actual Swift change-point store.

Only a disposable database is migrated. An optional source database is opened
read-only and copied with SQLite's online backup API. No app data is modified.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import tempfile
import time
from pathlib import Path


LEGACY_SCHEMA = """
CREATE TABLE usage_limit_samples(
  source TEXT NOT NULL, limit_id TEXT NOT NULL, used_percent REAL NOT NULL,
  window_minutes INTEGER NOT NULL, resets_at_ms INTEGER NOT NULL,
  observed_at_ms INTEGER NOT NULL,
  PRIMARY KEY(source, limit_id, window_minutes, resets_at_ms, observed_at_ms, used_percent)
);
CREATE INDEX idx_usage_limit_source_observed ON usage_limit_samples(source, observed_at_ms);
CREATE INDEX idx_usage_limit_observed ON usage_limit_samples(observed_at_ms);
PRAGMA user_version = 3;
"""


def make_fixture(database: Path, count: int, confirmations: int) -> None:
    # Two independent windows, six seconds between samples in each window.
    # Each state is confirmed repeatedly; one-second reset reporting jitter is
    # input evidence, not a new reset window. All data lies inside 365 days.
    end_ms = int(time.time() * 1000) - 60_000
    start_ms = end_ms - ((count + 1) // 2) * 6_000
    if start_ms < end_ms - 364 * 86_400_000:
        raise ValueError("Too many samples for this fixture's retention interval")
    rows = []
    for index in range(count):
        sequence = index // 2
        limit_id, window = ("codex", 300) if index % 2 == 0 else ("codex_bengalfox", 10_080)
        observed = start_ms + sequence * 6_000
        reset = start_ms + (sequence * 6_000 // (window * 60_000) + 1) * window * 60_000
        reset += 1_000 if sequence % 17 == 0 else 0
        rows.append(("codex", limit_id, float((sequence // confirmations) % 101), window, reset, observed))
    with sqlite3.connect(database) as connection:
        connection.executescript(LEGACY_SCHEMA)
        connection.executemany("INSERT INTO usage_limit_samples VALUES (?, ?, ?, ?, ?, ?)", rows)


def quota_sizes(database: Path) -> dict:
    with sqlite3.connect(database) as connection:
        connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        objects = {
            name for (name,) in connection.execute(
                "SELECT name FROM sqlite_master WHERE tbl_name LIKE 'usage_limit_%'"
            )
        }
        sizes = {
            name: size for name, size in connection.execute("SELECT name,SUM(pgsize) FROM dbstat GROUP BY name")
            if name in objects
        }
        return {"allocated_quota_bytes": sum(sizes.values()), "objects": sizes,
                "rows": connection.execute("SELECT COUNT(*) FROM usage_limit_samples").fetchone()[0]}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rows", type=int, default=100_000)
    parser.add_argument("--confirmations-per-change", type=int, default=100)
    parser.add_argument("--source-database", type=Path, help="Read-only schema-3 input; a copy is migrated")
    parser.add_argument("--output-directory", type=Path, help="New directory in which to retain the fixture and report")
    args = parser.parse_args()
    if args.rows <= 0 or args.confirmations_per_change <= 0:
        parser.error("row and confirmation counts must be positive")
    temporary = tempfile.TemporaryDirectory(prefix="tkmy-quota-measure-") if args.output_directory is None else None
    directory = Path(temporary.name) if temporary else args.output_directory.resolve()
    if not temporary:
        directory.mkdir(parents=True, exist_ok=False)
    database = directory / "usage.sqlite3"
    if args.source_database:
        source = sqlite3.connect(args.source_database.resolve().as_uri() + "?mode=ro", uri=True)
        try:
            if source.execute("PRAGMA user_version").fetchone()[0] != 3:
                parser.error("source database must use schema 3")
            with sqlite3.connect(database) as destination:
                source.backup(destination)
        finally:
            source.close()
    else:
        make_fixture(database, args.rows, args.confirmations_per_change)
    before = quota_sizes(database)
    Path(str(database) + ".measurement-fixture").write_text("Disposable verification copy.\n")
    repository = Path(__file__).resolve().parent.parent
    command = [
        "rtk", "proxy", "env", "CLANG_MODULE_CACHE_PATH=/private/tmp/tkmy-clang-cache",
        "SWIFT_MODULECACHE_PATH=/private/tmp/tkmy-swift-cache", "swift", "test", "--disable-sandbox",
        "--cache-path", ".build/package-cache", "--config-path", ".build/package-config",
        "--security-path", ".build/package-security", "--filter", "quotaHistoryStorageMeasurement",
    ]
    environment = dict(os.environ, TKMY_QUOTA_VERIFY_DATABASE=str(database))
    log = directory / "swift-verification.log"
    started = time.monotonic()
    with log.open("w") as output:
        process = subprocess.run(command, cwd=repository, env=environment, stdout=output, stderr=subprocess.STDOUT)
    if process.returncode:
        raise SystemExit(f"Swift verification failed; inspect {log}\n{log.read_text()[-12000:]}")
    verification = json.loads(Path(str(database) + ".verification.json").read_text())
    after = quota_sizes(database)
    report = {
        "input_kind": "read-only copy of supplied database" if args.source_database else "synthetic",
        "confirmations_per_change": None if args.source_database else args.confirmations_per_change,
        "before": before, "after": after,
        "row_reduction_percent": round(100 * (1 - after["rows"] / before["rows"]), 3) if before["rows"] else 0,
        "allocated_quota_reduction_percent": round(100 * (1 - after["allocated_quota_bytes"] / before["allocated_quota_bytes"]), 3),
        "duplicate_replay_unchanged": verification["duplicate_replay_unchanged"],
        "swift_verification_seconds_including_build": round(time.monotonic() - started, 3),
        "measurement_scope": "SQLite quota tables and all their indexes, including packed confirmation evidence; excludes backups, token tables, reusable free pages and temporary WAL",
    }
    (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if not temporary:
        print(f"artifacts={directory}")
    if temporary:
        temporary.cleanup()


if __name__ == "__main__":
    main()
