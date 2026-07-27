"""
Verify the 14 exported Power BI CSVs are internally consistent and reflect the fixes.
Run after export_sql09_resultsets.py:

    python scripts/verify_export.py

Prints PASS/FAIL for each check. All PASS = your data is good to feed the notebook/Power BI.
"""
from pathlib import Path
import pandas as pd

OUT = Path(__file__).resolve().parents[1] / "data" / "output"
FILES = [
    "campaign_overview.csv", "campaign_daily_summary.csv", "campaign_promotion_breakdown.csv",
    "selected_campaign_merchant_distribution.csv", "selected_campaign_user_scored_features.csv",
    "suspicious_users_full.csv", "abuse_impact_summary.csv", "rule_simulation_summary.csv",
    "threshold_percentile_summary.csv", "retention_weekly_summary.csv",
    "campaign_daily_risk_summary.csv", "campaign_user_daily_risk.csv",
    "promotion_daily_summary.csv", "merchant_daily_summary.csv",
]

checks = []
def check(name, ok, detail=""):
    checks.append(ok)
    print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f"  ({detail})" if detail else ""))

# 1) all 14 files exist
missing = [f for f in FILES if not (OUT / f).exists()]
check("all 14 CSV files present", not missing, "missing: " + ", ".join(missing) if missing else "")
if missing:
    raise SystemExit("Stop: re-run the export; some files are missing.")

imp = pd.read_csv(OUT / "abuse_impact_summary.csv")
sf = pd.read_csv(OUT / "selected_campaign_user_scored_features.csv", low_memory=False)
su = pd.read_csv(OUT / "suspicious_users_full.csv", low_memory=False)
r = imp.iloc[0]

# 2) rename applied
check("abuse_impact uses total_scored_users (not total_campaign_users)",
      "total_scored_users" in imp.columns and "total_campaign_users" not in imp.columns)

# 3) row-count consistency
check("scored rows == total_scored_users",
      len(sf) == int(r["total_scored_users"]), f"{len(sf)} vs {int(r['total_scored_users'])}")
check("suspicious rows == total_suspicious_users",
      len(su) == int(r["total_suspicious_users"]), f"{len(su)} vs {int(r['total_suspicious_users'])}")

# 4) suspicious is a valid subset
check("every suspicious user exists in the scored table", su["userID"].isin(set(sf["userID"])).all())
check("every suspicious user has suspicion_score >= 3", (su["suspicion_score"] >= 3).all())

# 5) transfer-loop fix took effect (no more explosion)
mx = int(sf["transfer_loop_count"].max())
check("transfer_loop_count is sane (< 1000, i.e. not the old 500,057)", mx < 1000, f"max={mx}")

# 6) headline % recomputes from the detail
share = (sf.loc[sf["suspicion_score"] >= 3, "credited_campaign_discount_success_only"].sum()
         / sf["credited_campaign_discount_success_only"].sum() * 100)
check("share_of_campaign_discount_pct matches the detail table",
      abs(share - float(r["share_of_campaign_discount_pct"])) < 0.1,
      f"summary={r['share_of_campaign_discount_pct']}  recomputed={share:.2f}")

print("\nHeadline numbers:")
print(f"  scored users        : {int(r['total_scored_users']):,}")
print(f"  suspicious users    : {int(r['total_suspicious_users']):,}  ({r['suspicious_user_rate_pct']}%)")
print(f"  suspicious cost share: {r['share_of_campaign_discount_pct']}%")
print(f"  max transfer loops  : {mx}")

print("\n" + ("ALL CHECKS PASSED — data is good." if all(checks) else "SOME CHECKS FAILED — see above."))
