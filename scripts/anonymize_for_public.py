"""
Anonymize the pipeline outputs for the PUBLIC showcase folder.

    python scripts/anonymize_for_public.py

Reads data/output/*.csv (private) and writes anonymized copies to zalo_public/data/.
What it strips / generalizes (so the source business + individuals can't be identified):
  - campaignCode              -> "CAMP_A"
  - campaignID (73 ids)       -> "C01".."C73"
  - promotionName             -> "PROMO_01".. (keeps promotion_type: cashback/voucher)
  - appName / reportSubCat    -> "App_01" / "Sub_01"..  (keeps generic reportCat: Telco/Billing/...)
  - userID                    -> "U000001".. (only 100-row SAMPLES of user-level files are exported)
Everything analytical (amounts, dates, scores, reason text, rates) is preserved so the results still reconcile.
No mapping file is written, so the anonymization is one-way.
"""
from pathlib import Path
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "data" / "output"
OUT = ROOT / "zalo_public" / "data"                 # PUBLIC: aggregates + 100-row samples
FULL = ROOT / "data" / "output_anonymized"          # PRIVATE: full anonymized mirror (feeds the clone PBIX)
OUT.mkdir(parents=True, exist_ok=True)
FULL.mkdir(parents=True, exist_ok=True)

AGGREGATES = [
    "abuse_impact_summary.csv", "campaign_overview.csv", "campaign_daily_summary.csv",
    "campaign_daily_risk_summary.csv", "campaign_promotion_breakdown.csv",
    "promotion_daily_summary.csv", "merchant_daily_summary.csv",
    "selected_campaign_merchant_distribution.csv", "rule_simulation_summary.csv",
    "threshold_percentile_summary.csv", "retention_weekly_summary.csv",
]
USER_LEVEL = [  # full files that contain userID
    "selected_campaign_user_scored_features.csv", "suspicious_users_full.csv",
    "campaign_user_daily_risk.csv",
]
SAMPLES = {  # user-level: PUBLIC gets only a 100-row sample with synthetic ids
    "selected_campaign_user_scored_features.csv": "sample_scored_users.csv",
    "suspicious_users_full.csv": "sample_suspicious_users.csv",
}


def build_map(values, prefix, width=2):
    uniq = sorted({str(v) for v in values if pd.notna(v) and str(v) != ""})
    return {v: f"{prefix}{i + 1:0{width}d}" for i, v in enumerate(uniq)}


# --- build consistent maps from the whole dataset ---
promo, camp, app, sub = set(), set(), set(), set()
for f in ["campaign_promotion_breakdown.csv", "promotion_daily_summary.csv"]:
    d = pd.read_csv(SRC / f)
    promo |= set(d.get("promotionName", pd.Series(dtype=str)).dropna())
    camp |= {str(int(x)) for x in d.get("campaignID", pd.Series(dtype=float)).dropna()}
for f in ["merchant_daily_summary.csv", "selected_campaign_merchant_distribution.csv"]:
    d = pd.read_csv(SRC / f)
    app |= set(d.get("appName", pd.Series(dtype=str)).dropna())
    sub |= set(d.get("reportSubCat", pd.Series(dtype=str)).dropna())

PROMO = build_map(promo, "PROMO_", 2)
CAMP = build_map(camp, "C", 2)
APP = build_map(app, "App_", 2)
SUB = build_map(sub, "Sub_", 2)

# --- global userID map (consistent across all user-level files so joins still work) ---
uids = set()
for f in USER_LEVEL:
    uids |= set(pd.read_csv(SRC / f, usecols=["userID"], low_memory=False)["userID"].dropna())
USERMAP = {u: f"U{i + 1:06d}" for i, u in enumerate(sorted(uids))}


def anon(df, map_users=False):
    df = df.copy()
    if "campaignCode" in df:
        df["campaignCode"] = "CAMP_A"
    if "campaignID" in df:
        df["campaignID"] = df["campaignID"].apply(
            lambda x: CAMP.get(str(int(x)), "C00") if pd.notna(x) else x)
    if "promotionName" in df:
        df["promotionName"] = df["promotionName"].map(PROMO).fillna(df.get("promotionName"))
    if "appName" in df:
        df["appName"] = df["appName"].map(APP).fillna(df.get("appName"))
    if "reportSubCat" in df:
        df["reportSubCat"] = df["reportSubCat"].map(SUB).fillna(df.get("reportSubCat"))
    if map_users and "userID" in df:
        df["userID"] = df["userID"].map(USERMAP).fillna(df["userID"])
    return df


# 1) PUBLIC folder: aggregates (full) + user samples (100 rows, synthetic ids)
pub = []
for f in AGGREGATES:
    anon(pd.read_csv(SRC / f)).to_csv(OUT / f, index=False)
    pub.append(f)
for src, dst in SAMPLES.items():
    d = anon(pd.read_csv(SRC / src, low_memory=False).head(100), map_users=True)
    d.to_csv(OUT / dst, index=False)
    pub.append(dst + "  (100-row sample)")

# 2) PRIVATE full anonymized mirror: ALL files, full rows, consistent synthetic userIDs (feeds the clone PBIX)
full = []
for f in AGGREGATES + USER_LEVEL:
    anon(pd.read_csv(SRC / f, low_memory=False), map_users=True).to_csv(FULL / f, index=False)
    full.append(f)

# 3) PRIVATE anonymized workbook: the dashboard's real source is powerbi_outputs.xlsx — anonymize each sheet.
wb_src = SRC / "powerbi_outputs.xlsx"
if wb_src.exists():
    xls = pd.read_excel(wb_src, sheet_name=None)
    with pd.ExcelWriter(FULL / "powerbi_outputs.xlsx", engine="openpyxl") as w:
        for sheet, d in xls.items():
            anon(d, map_users=True).to_excel(w, sheet_name=sheet, index=False)
    # the py_* workbook has no identifiers — copy as-is so the clone can point at one folder
    import shutil
    py_wb = SRC / "python_rule_simulation_powerbi.xlsx"
    if py_wb.exists():
        shutil.copy(py_wb, FULL / py_wb.name)
    print(f"   + anonymized workbook: powerbi_outputs.xlsx ({len(xls)} sheets) + copied py workbook")

print(f"PUBLIC  -> {OUT}  ({len(pub)} files)")
for w in pub:
    print("   -", w)
print(f"\nPRIVATE full anonymized mirror -> {FULL}  ({len(full)} files, {len(USERMAP):,} users mapped)")
print("   (point the clone PBIX at this folder; do NOT publish it as raw CSV)")
print(f"\nMaps: {len(PROMO)} promotions, {len(CAMP)} campaign IDs, {len(APP)} apps, {len(SUB)} subcats, "
      f"{len(USERMAP):,} users. One-way (no reverse map saved).")
