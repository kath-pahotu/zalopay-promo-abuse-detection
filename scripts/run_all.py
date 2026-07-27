"""
Run the whole DATA refresh in one command (Phases 1-3).

    python scripts/run_all.py --server "localhost\\SQLEXPRESS03"

It runs, in order, stopping if any step fails:
  1. export_sql09_resultsets.py   -> SQL (07b + 09) -> 14 CSVs
  2. verify_export.py             -> checks the 14 CSVs are consistent
  3. the notebook 01_...ipynb     -> Python rule-simulation CSVs + result.xlsx
  4. build_powerbi_workbook.py    -> powerbi_outputs.xlsx
  5. build_python_rule_simulation_workbook.py -> python_rule_simulation_powerbi.xlsx

It does NOT touch Power BI — that's a desktop app. After this finishes,
open dashboard/zalo_pay_dashboard.pbix and press Home > Refresh.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PY = sys.executable
NOTEBOOK = ROOT / "notebook" / "01_rule_simulation_storytelling.ipynb"


def step(title: str, cmd: list[str]) -> None:
    print("\n" + "=" * 70)
    print(f"STEP: {title}")
    print("=" * 70)
    print("  $ " + " ".join(str(c) for c in cmd))
    result = subprocess.run(cmd, cwd=ROOT)
    if result.returncode != 0:
        print(f"\n!! STEP FAILED: {title} (exit code {result.returncode}).")
        print("   Nothing after this ran. Fix the error above, then run again.")
        sys.exit(result.returncode)
    print(f"  OK: {title}")


def main() -> None:
    p = argparse.ArgumentParser(description="Run Phases 1-3 of the refresh in one go.")
    p.add_argument("--server", required=True, help=r'e.g. "localhost\SQLEXPRESS03"')
    p.add_argument("--database", default="zalo")
    p.add_argument("--driver", default="ODBC Driver 18 for SQL Server")
    p.add_argument("--skip-notebook", action="store_true",
                   help="skip executing the notebook (Phase 2) if you only need the SQL refresh")
    args = p.parse_args()

    # 1 + 2: SQL export, then verify
    step("1/5  Bulk-export 14 CSVs from SQL (07b + 09)",
         [PY, "scripts/export_sql09_resultsets.py",
          "--server", args.server, "--database", args.database,
          "--driver", args.driver, "--overwrite"])
    step("2/5  Verify the 14 CSVs are consistent",
         [PY, "scripts/verify_export.py"])

    # 3: execute the notebook end-to-end (headless)
    if args.skip_notebook:
        print("\n(skipping notebook per --skip-notebook)")
    else:
        step("3/5  Run the rule-simulation notebook end-to-end",
             [PY, "-m", "jupyter", "nbconvert", "--to", "notebook",
              "--execute", "--inplace",
              "--ExecutePreprocessor.timeout=1800", str(NOTEBOOK)])

    # 4 + 5: build the two Power BI workbooks
    step("4/5  Build powerbi_outputs.xlsx",
         [PY, "scripts/build_powerbi_workbook.py"])
    step("5/5  Build python_rule_simulation_powerbi.xlsx",
         [PY, "scripts/build_python_rule_simulation_workbook.py"])

    print("\n" + "=" * 70)
    print("ALL DATA STEPS DONE.")
    print("Last manual step (Power BI is a desktop app, can't be scripted here):")
    print("  1. open dashboard/zalo_pay_dashboard.pbix")
    print("  2. Home > Refresh")
    print("  3. confirm 'Total Scored Users (Summary)' = 86,170, then save the PBIX")
    print("=" * 70)


if __name__ == "__main__":
    main()
