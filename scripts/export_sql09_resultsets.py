"""
Bulk-export the 14 Power BI CSVs by running the corrected SQL directly.

What it does (no manual "Save Results As" for 14 grids):
  1. connects to your SQL Server "zalo" database
  2. runs sql/07b_abuse_user_features_view.sql   (creates/updates the shared view)
  3. runs sql/09_powerbi_export_queries.sql       (returns the 14 result sets)
  4. checks it got exactly 14 result sets with the expected columns
  5. writes them to data/output/ with the exact filenames the workbook script needs

Run (from the repo root), replacing the server name with yours from SSMS:
    python scripts/export_sql09_resultsets.py --server ".\\SQLEXPRESS" --database "zalo" --overwrite

If anything about the result count/columns is wrong, it STOPS and writes nothing.
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

import pandas as pd
import pyodbc


# result order MUST match the SELECT order in 09_powerbi_export_queries.sql
RESULT_MAPPING = [
    ("campaign_overview.csv", {"campaignCode"}),
    ("campaign_daily_summary.csv", {"txn_date"}),
    ("campaign_promotion_breakdown.csv", {"campaignID", "promotionName"}),
    ("selected_campaign_merchant_distribution.csv", {"reportCat"}),
    ("selected_campaign_user_scored_features.csv", {"userID", "suspicion_score", "risk_tier"}),
    ("suspicious_users_full.csv", {"userID", "suspicion_score", "risk_tier"}),
    ("abuse_impact_summary.csv", {"total_scored_users"}),
    ("rule_simulation_summary.csv", {"rule_name"}),
    ("threshold_percentile_summary.csv", {"metric_name"}),
    ("retention_weekly_summary.csv", {"cohort_week", "week_number"}),
    ("campaign_daily_risk_summary.csv", {"txn_date", "risk_group"}),
    ("campaign_user_daily_risk.csv", {"txn_date", "userID", "risk_group"}),
    ("promotion_daily_summary.csv", {"txn_date", "campaignID"}),
    ("merchant_daily_summary.csv", {"txn_date", "reportCat"}),
]


def split_sql_batches(sql_text: str) -> list[str]:
    """Split an SSMS SQL file on lines that contain only GO."""
    return [
        b.strip()
        for b in re.split(r"^\s*GO\s*$", sql_text, flags=re.IGNORECASE | re.MULTILINE)
        if b.strip()
    ]


def is_use_batch(batch: str) -> bool:
    return bool(re.fullmatch(r"USE\s+(?:\[[^\]]+\]|[A-Za-z0-9_]+)\s*;?", batch.strip(), re.IGNORECASE))


def discard_all_results(cursor: pyodbc.Cursor) -> None:
    while True:
        if cursor.description is not None:
            cursor.fetchall()
        if not cursor.nextset():
            break


def collect_all_results(cursor: pyodbc.Cursor) -> list[pd.DataFrame]:
    results = []
    while True:
        if cursor.description is not None:
            cols = [c[0] for c in cursor.description]
            results.append(pd.DataFrame.from_records(cursor.fetchall(), columns=cols))
        if not cursor.nextset():
            break
    return results


def run_without_export(cursor: pyodbc.Cursor, sql_path: Path) -> None:
    for batch in split_sql_batches(sql_path.read_text(encoding="utf-8-sig")):
        if is_use_batch(batch):
            continue
        cursor.execute(batch)
        discard_all_results(cursor)


def run_and_collect(cursor: pyodbc.Cursor, sql_path: Path) -> list[pd.DataFrame]:
    results = []
    for batch in split_sql_batches(sql_path.read_text(encoding="utf-8-sig")):
        if is_use_batch(batch):
            continue
        cursor.execute(batch)
        results.extend(collect_all_results(cursor))
    return results


def validate_results(results: list[pd.DataFrame]) -> None:
    if len(results) != len(RESULT_MAPPING):
        raise RuntimeError(
            f"Expected {len(RESULT_MAPPING)} result sets from SQL 09 but got {len(results)}. "
            "Nothing was written. (Check that the diagnostic queries at the end of 09 are still "
            "commented out.)"
        )
    for i, ((filename, required), frame) in enumerate(zip(RESULT_MAPPING, results), start=1):
        missing = required - set(frame.columns)
        if missing:
            raise RuntimeError(
                f"Result #{i} does not look like {filename}. Missing columns: {sorted(missing)}. "
                f"Got columns: {list(frame.columns)}. Nothing was written."
            )


def main() -> None:
    p = argparse.ArgumentParser(description="Run 07b + 09 and export the 14 Power BI CSVs.")
    p.add_argument("--server", required=True, help=r'e.g. ".\SQLEXPRESS" or "localhost"')
    p.add_argument("--database", default="zalo")
    p.add_argument("--driver", default="ODBC Driver 18 for SQL Server")
    p.add_argument("--overwrite", action="store_true", help="allow replacing existing CSVs")
    args = p.parse_args()

    root = Path(__file__).resolve().parents[1]
    sql_07b = root / "sql" / "07b_abuse_user_features_view.sql"
    sql_09 = root / "sql" / "09_powerbi_export_queries.sql"
    out_dir = root / "data" / "output"
    out_dir.mkdir(parents=True, exist_ok=True)

    existing = [out_dir / f for f, _ in RESULT_MAPPING if (out_dir / f).exists()]
    if existing and not args.overwrite:
        raise FileExistsError(
            f"{len(existing)} output CSVs already exist. Back them up, then rerun with --overwrite."
        )

    conn_str = (
        f"DRIVER={{{args.driver}}};SERVER={args.server};DATABASE={args.database};"
        "Trusted_Connection=yes;Encrypt=yes;TrustServerCertificate=yes;"
    )
    print(f"Connecting to {args.server} / {args.database} ...")
    with pyodbc.connect(conn_str, autocommit=True) as conn:
        cur = conn.cursor()
        cur.execute("SET NOCOUNT ON")
        discard_all_results(cur)
        print(f"Running {sql_07b.name} ...")
        run_without_export(cur, sql_07b)
        print(f"Running {sql_09.name} ...")
        results = run_and_collect(cur, sql_09)

    validate_results(results)  # writes nothing unless all 14 pass

    for (filename, _), frame in zip(RESULT_MAPPING, results):
        frame.to_csv(out_dir / filename, index=False, encoding="utf-8-sig")
        print(f"  wrote {filename}: {len(frame):,} rows")
    print(f"Done. {len(results)} CSV files written to {out_dir}")


if __name__ == "__main__":
    main()
