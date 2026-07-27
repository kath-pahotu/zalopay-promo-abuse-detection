import argparse
from collections import defaultdict, deque
from pathlib import Path

import pandas as pd


OUTPUT_FILES = [
    "campaign_overview.csv",
    "campaign_daily_summary.csv",
    "campaign_promotion_breakdown.csv",
    "selected_campaign_merchant_distribution.csv",
    "selected_campaign_user_scored_features.csv",
    "suspicious_users_full.csv",
    "abuse_impact_summary.csv",
    "rule_simulation_summary.csv",
    "threshold_percentile_summary.csv",
    "retention_weekly_summary.csv",
    # --- NEW: date-slicer-friendly Power BI exports ---
    "campaign_daily_risk_summary.csv",
    "campaign_user_daily_risk.csv",
    "promotion_daily_summary.csv",
    "merchant_daily_summary.csv",
]


def numeric(series):
    return pd.to_numeric(series, errors="coerce")


def week_start(series):
    return series.dt.to_period("W-SUN").dt.start_time


def safe_date_frame(frame):
    out = frame.copy()
    for column in out.columns:
        if pd.api.types.is_datetime64_any_dtype(out[column]):
            out[column] = out[column].dt.strftime("%Y-%m-%d %H:%M:%S")
            out[column] = out[column].replace("NaT", "")
    return out


def read_inputs(raw_dir):
    tx = pd.read_csv(
        raw_dir / "transaction.csv",
        usecols=[
            "transID",
            "userID",
            "appID",
            "transStatus",
            "deviceID",
            "amount",
            "reqDate",
            "userIP",
            "campaignID",
            "discountAmount",
        ],
        dtype={
            "transID": "string",
            "userID": "string",
            "deviceID": "string",
            "userIP": "string",
        },
        parse_dates=["reqDate"],
        low_memory=False,
    )
    for column in ["appID", "transStatus", "amount", "campaignID", "discountAmount"]:
        tx[column] = numeric(tx[column])
    tx["discountAmount"] = tx["discountAmount"].fillna(0)
    tx["amount"] = tx["amount"].fillna(0)

    campaign = pd.read_csv(raw_dir / "campaign_info.csv", low_memory=False)
    campaign["campaignID"] = numeric(campaign["campaignID"])

    users = pd.read_csv(
        raw_dir / "user_profile.csv",
        usecols=["userID", "created_date"],
        dtype={"userID": "string"},
        parse_dates=["created_date"],
        low_memory=False,
    )

    referrals = pd.read_csv(
        raw_dir / "referral_mapcard.csv",
        dtype={"userID": "string", "refereeId": "string"},
        parse_dates=["reqDate"],
        low_memory=False,
    )

    transfers = pd.read_csv(
        raw_dir / "transfer.csv",
        usecols=["receiver", "sender", "transStatus", "reqDate"],
        dtype={"receiver": "string", "sender": "string"},
        parse_dates=["reqDate"],
        low_memory=False,
    )
    transfers["transStatus"] = numeric(transfers["transStatus"])

    app = pd.read_csv(raw_dir / "appid_info.csv", low_memory=False)
    app["appID"] = numeric(app["appID"])
    return tx, campaign, users, referrals, transfers, app


def transfer_loop_counts(transfers):
    successful = transfers.loc[
        (transfers["transStatus"] == 1)
        & transfers["sender"].notna()
        & transfers["receiver"].notna(),
        ["sender", "receiver", "reqDate"],
    ].copy()
    if successful.empty:
        return pd.DataFrame(columns=["userID", "transfer_loop_count"])

    sender = successful["sender"].astype("string")
    receiver = successful["receiver"].astype("string")
    successful["pair_low"] = sender.where(sender <= receiver, receiver)
    successful["pair_high"] = receiver.where(sender <= receiver, sender)
    successful["direction"] = sender <= receiver
    successful = successful.sort_values(["pair_low", "pair_high", "reqDate"])

    counts = defaultdict(int)
    one_hour = pd.Timedelta(minutes=60)

    for _, group in successful.groupby(["pair_low", "pair_high"], sort=False):
        if group["direction"].nunique() < 2:
            continue
        seen = {True: deque(), False: deque()}
        for row in group.itertuples(index=False):
            direction = bool(row.direction)
            opposite = seen[not direction]
            while opposite and row.reqDate - opposite[0][0] > one_hour:
                opposite.popleft()
            match_count = len(opposite)
            if match_count:
                counts[row.sender] += match_count
                counts[row.receiver] += match_count
            seen[direction].append((row.reqDate, row.sender, row.receiver))

    return pd.DataFrame(
        {"userID": list(counts.keys()), "transfer_loop_count": list(counts.values())}
    )


# =========================================================
# NEW: shared helper for the two date-sliced risk exports
# Mirrors the CASE/COALESCE logic in 09_powerbi_export_queries.sql
# (daily suspicious vs non-suspicious split + user-date risk table)
# =========================================================
def add_transaction_risk_labels(transactions, scored):
    """Left-join per-user suspicion_score onto every transaction row
    (including failed ones) and derive risk_group / risk_tier_group.
    Users with no score (e.g. zero successful transactions) default to 0,
    matching COALESCE(a.suspicion_score, 0) in the SQL version.
    """
    labeled = transactions.merge(
        scored[["userID", "suspicion_score"]], on="userID", how="left"
    )
    labeled["suspicion_score"] = labeled["suspicion_score"].fillna(0)

    labeled["risk_group"] = "Non-suspicious"
    labeled.loc[labeled["suspicion_score"] >= 3, "risk_group"] = "Suspicious"

    labeled["risk_tier_group"] = "Lower-risk"
    labeled.loc[labeled["suspicion_score"] >= 3, "risk_tier_group"] = "Review"
    labeled.loc[labeled["suspicion_score"] >= 6, "risk_tier_group"] = "Medium risk"
    labeled.loc[labeled["suspicion_score"] >= 9, "risk_tier_group"] = "High risk"

    labeled["txn_date"] = labeled["reqDate"].dt.date
    return labeled


def build_campaign_daily_risk_summary(selected, scored):
    """Daily suspicious vs non-suspicious split -> campaign_daily_risk_summary.csv"""
    labeled = add_transaction_risk_labels(selected, scored)
    group_cols = ["txn_date", "risk_group", "risk_tier_group"]

    summary = (
        labeled.groupby(group_cols, dropna=False)
        .agg(
            transaction_rows=("transID", "size"),
            unique_users=("userID", "nunique"),
            successful_rows=("transStatus", lambda s: int((s == 1).sum())),
        )
        .reset_index()
    )
    credited = (
        labeled[labeled["transStatus"] == 1]
        .groupby(group_cols, dropna=False)["discountAmount"]
        .sum()
        .rename("credited_discount_success_only")
    )
    non_success = (
        labeled[labeled["transStatus"] != 1]
        .groupby(group_cols, dropna=False)["discountAmount"]
        .sum()
        .rename("non_success_discount_amount")
    )
    summary = summary.merge(credited, on=group_cols, how="left").merge(
        non_success, on=group_cols, how="left"
    )
    summary[["credited_discount_success_only", "non_success_discount_amount"]] = summary[
        ["credited_discount_success_only", "non_success_discount_amount"]
    ].fillna(0)
    return summary.sort_values(group_cols)


def build_campaign_user_daily_risk(selected, scored):
    """User-date risk table -> campaign_user_daily_risk.csv
    Grain: one row per user per date, for DISTINCTCOUNT users by any date range in Power BI.
    """
    labeled = add_transaction_risk_labels(selected, scored)
    group_cols = ["txn_date", "userID", "risk_group", "risk_tier_group"]

    summary = (
        labeled.groupby(group_cols, dropna=False)
        .agg(
            transaction_rows=("transID", "size"),
            successful_rows=("transStatus", lambda s: int((s == 1).sum())),
        )
        .reset_index()
    )
    credited = (
        labeled[labeled["transStatus"] == 1]
        .groupby(group_cols, dropna=False)["discountAmount"]
        .sum()
        .rename("credited_discount_success_only")
    )
    summary = summary.merge(credited, on=group_cols, how="left")
    summary["credited_discount_success_only"] = summary[
        "credited_discount_success_only"
    ].fillna(0)

    summary = summary[
        [
            "txn_date",
            "userID",
            "risk_group",
            "risk_tier_group",
            "credited_discount_success_only",
            "successful_rows",
            "transaction_rows",
        ]
    ]
    return summary.sort_values(["txn_date", "risk_group", "userID"])


def build_promotion_daily_summary(selected):
    """Promotion performance dynamic by date slicer -> promotion_daily_summary.csv"""
    daily = selected.copy()
    daily["txn_date"] = daily["reqDate"].dt.date
    group_cols = ["txn_date", "campaignID", "promotionName", "promotion_type"]

    summary = (
        daily.groupby(group_cols, dropna=False)
        .agg(
            transaction_rows=("transID", "size"),
            unique_users=("userID", "nunique"),
            successful_rows=("transStatus", lambda s: int((s == 1).sum())),
            gross_discount_all_rows=("discountAmount", "sum"),
        )
        .reset_index()
    )
    credited = (
        daily[daily["transStatus"] == 1]
        .groupby(group_cols, dropna=False)["discountAmount"]
        .sum()
        .rename("credited_discount_success_only")
    )
    non_success = (
        daily[daily["transStatus"] != 1]
        .groupby(group_cols, dropna=False)["discountAmount"]
        .sum()
        .rename("non_success_discount_amount")
    )
    summary = summary.merge(credited, on=group_cols, how="left").merge(
        non_success, on=group_cols, how="left"
    )
    summary[["credited_discount_success_only", "non_success_discount_amount"]] = summary[
        ["credited_discount_success_only", "non_success_discount_amount"]
    ].fillna(0)
    return summary.sort_values(
        ["txn_date", "credited_discount_success_only"], ascending=[True, False]
    )


def build_merchant_daily_summary(selected, app):
    """Merchant/category performance dynamic by date slicer -> merchant_daily_summary.csv"""
    daily = selected.merge(app, on="appID", how="left")
    daily[["reportCat", "reportSubCat", "appName"]] = daily[
        ["reportCat", "reportSubCat", "appName"]
    ].fillna("Non-payment/Unknown")

    daily["payment_group"] = "Payment / merchant"
    daily.loc[daily["reportCat"] == "Non-payment/Unknown", "payment_group"] = (
        "Non-payment / reward / unknown"
    )
    daily["txn_date"] = daily["reqDate"].dt.date
    group_cols = ["txn_date", "reportCat", "reportSubCat", "appName", "payment_group"]

    summary = (
        daily.groupby(group_cols, dropna=False)
        .agg(
            transaction_rows=("transID", "size"),
            unique_users=("userID", "nunique"),
            successful_rows=("transStatus", lambda s: int((s == 1).sum())),
            total_amount=("amount", "sum"),
        )
        .reset_index()
    )
    credited = (
        daily[daily["transStatus"] == 1]
        .groupby(group_cols, dropna=False)["discountAmount"]
        .sum()
        .rename("credited_discount_success_only")
    )
    non_success = (
        daily[daily["transStatus"] != 1]
        .groupby(group_cols, dropna=False)["discountAmount"]
        .sum()
        .rename("non_success_discount_amount")
    )
    summary = summary.merge(credited, on=group_cols, how="left").merge(
        non_success, on=group_cols, how="left"
    )
    summary[["credited_discount_success_only", "non_success_discount_amount"]] = summary[
        ["credited_discount_success_only", "non_success_discount_amount"]
    ].fillna(0)
    return summary.sort_values(
        ["txn_date", "credited_discount_success_only"], ascending=[True, False]
    )


def build_outputs(raw_dir, campaign_code, privacy):
    tx, campaign, users, referrals, transfers, app = read_inputs(raw_dir)

    selected = tx.merge(
        campaign[["campaignID", "campaignCode", "promotionName", "promotion_type"]],
        on="campaignID",
        how="inner",
    )
    selected = selected[selected["campaignCode"] == campaign_code].copy()
    selected_success = selected[selected["transStatus"] == 1].copy()

    overview = pd.DataFrame(
        [
            {
                "campaignCode": campaign_code,
                "transaction_rows": len(selected),
                "unique_users": selected["userID"].nunique(),
                "campaign_id_count": selected["campaignID"].nunique(),
                "payment_rows": int((selected["appID"] > 0).sum()),
                "successful_rows": int((selected["transStatus"] == 1).sum()),
                "success_rate_pct": round(
                    (selected["transStatus"] == 1).sum() * 100 / max(len(selected), 1), 2
                ),
                "gross_discount_all_rows": int(selected["discountAmount"].sum()),
                "credited_discount_success_only": int(
                    selected.loc[selected["transStatus"] == 1, "discountAmount"].sum()
                ),
                "non_success_discount_amount": int(
                    selected.loc[selected["transStatus"] != 1, "discountAmount"].sum()
                ),
                "first_seen": selected["reqDate"].min(),
                "last_seen": selected["reqDate"].max(),
            }
        ]
    )

    daily = (
        selected.assign(txn_date=selected["reqDate"].dt.date)
        .groupby("txn_date", dropna=False)
        .agg(
            transaction_rows=("transID", "size"),
            unique_users=("userID", "nunique"),
            successful_rows=("transStatus", lambda s: int((s == 1).sum())),
            gross_discount_all_rows=("discountAmount", "sum"),
        )
        .reset_index()
    )
    credited_daily = (
        selected[selected["transStatus"] == 1]
        .assign(txn_date=lambda d: d["reqDate"].dt.date)
        .groupby("txn_date")["discountAmount"]
        .sum()
        .rename("credited_discount_success_only")
    )
    non_success_daily = (
        selected[selected["transStatus"] != 1]
        .assign(txn_date=lambda d: d["reqDate"].dt.date)
        .groupby("txn_date")["discountAmount"]
        .sum()
        .rename("non_success_discount_amount")
    )
    daily = daily.merge(credited_daily, on="txn_date", how="left").merge(
        non_success_daily, on="txn_date", how="left"
    )
    daily[["credited_discount_success_only", "non_success_discount_amount"]] = daily[
        ["credited_discount_success_only", "non_success_discount_amount"]
    ].fillna(0)

    promo = (
        selected.groupby(["campaignID", "promotionName", "promotion_type"], dropna=False)
        .agg(
            transaction_rows=("transID", "size"),
            unique_users=("userID", "nunique"),
            successful_rows=("transStatus", lambda s: int((s == 1).sum())),
            gross_discount_all_rows=("discountAmount", "sum"),
        )
        .reset_index()
    )
    promo_credited = (
        selected[selected["transStatus"] == 1]
        .groupby(["campaignID", "promotionName", "promotion_type"], dropna=False)[
            "discountAmount"
        ]
        .sum()
        .rename("credited_discount_success_only")
    )
    promo_non_success = (
        selected[selected["transStatus"] != 1]
        .groupby(["campaignID", "promotionName", "promotion_type"], dropna=False)[
            "discountAmount"
        ]
        .sum()
        .rename("non_success_discount_amount")
    )
    promo = promo.merge(
        promo_credited, on=["campaignID", "promotionName", "promotion_type"], how="left"
    ).merge(
        promo_non_success,
        on=["campaignID", "promotionName", "promotion_type"],
        how="left",
    )
    promo[["credited_discount_success_only", "non_success_discount_amount"]] = promo[
        ["credited_discount_success_only", "non_success_discount_amount"]
    ].fillna(0)
    promo = promo.sort_values("credited_discount_success_only", ascending=False)

    merchant_base = selected.merge(app, on="appID", how="left")
    merchant_base[["reportCat", "reportSubCat", "appName"]] = merchant_base[
        ["reportCat", "reportSubCat", "appName"]
    ].fillna("Non-payment/Unknown")
    merchant = (
        merchant_base.groupby(["reportCat", "reportSubCat", "appName"], dropna=False)
        .agg(
            transaction_rows=("transID", "size"),
            unique_users=("userID", "nunique"),
            successful_rows=("transStatus", lambda s: int((s == 1).sum())),
            total_amount=("amount", "sum"),
        )
        .reset_index()
    )
    merchant_credited = (
        merchant_base[merchant_base["transStatus"] == 1]
        .groupby(["reportCat", "reportSubCat", "appName"], dropna=False)[
            "discountAmount"
        ]
        .sum()
        .rename("credited_discount_success_only")
    )
    merchant = merchant.merge(
        merchant_credited, on=["reportCat", "reportSubCat", "appName"], how="left"
    ).fillna({"credited_discount_success_only": 0})
    merchant = merchant.sort_values("transaction_rows", ascending=False)

    campaign_discount = (
        selected_success.groupby("userID")
        .agg(
            credited_campaign_discount_success_only=("discountAmount", "sum"),
            campaign_rows=("transID", "size"),
            campaign_discount_rows=("discountAmount", lambda s: int((s > 0).sum())),
            distinct_campaign_transactions=("transID", "nunique"),
            first_campaign_time=("reqDate", "min"),
            last_campaign_time=("reqDate", "max"),
        )
        .reset_index()
    )

    immediate_base = selected_success.merge(users, on="userID", how="inner")
    immediate_base["days_to_txn"] = (
        immediate_base["reqDate"].dt.normalize()
        - immediate_base["created_date"].dt.normalize()
    ).dt.days
    immediate_base["is_immediate"] = immediate_base["days_to_txn"].between(0, 1)
    immediate_base["immediate_discount_value"] = immediate_base["discountAmount"].where(
        immediate_base["is_immediate"], 0
    )
    immediate_base["immediate_discount_row"] = (
        immediate_base["is_immediate"] & (immediate_base["discountAmount"] > 0)
    ).astype(int)
    immediate_summary = (
        immediate_base.groupby("userID")
        .agg(
            immediate_discount_0_1_day=("immediate_discount_value", "sum"),
            immediate_discount_rows_0_1_day=("immediate_discount_row", "sum"),
            distinct_immediate_discount_transactions_0_1_day=(
                "transID",
                lambda s: s[
                    immediate_base.loc[s.index, "is_immediate"]
                    & (immediate_base.loc[s.index, "discountAmount"] > 0)
                ].nunique(),
            ),
            first_immediate_discount_time=(
                "reqDate",
                lambda s: s[
                    immediate_base.loc[s.index, "is_immediate"]
                    & (immediate_base.loc[s.index, "discountAmount"] > 0)
                ].min(),
            ),
            last_immediate_discount_time=(
                "reqDate",
                lambda s: s[
                    immediate_base.loc[s.index, "is_immediate"]
                    & (immediate_base.loc[s.index, "discountAmount"] > 0)
                ].max(),
            ),
        )
        .reset_index()
    )

    referral_summary = (
        referrals.groupby("userID")
        .agg(
            total_invitees=("refereeId", "nunique"),
            first_invite_time=("reqDate", "min"),
            last_invite_time=("reqDate", "max"),
        )
        .reset_index()
    )

    tx_success = tx[tx["transStatus"] == 1].copy()
    device_counts = (
        tx_success[tx_success["deviceID"].notna()]
        .groupby("deviceID")["userID"]
        .nunique()
        .rename("users_per_device")
        .reset_index()
    )
    user_device = (
        tx[tx["deviceID"].notna()][["userID", "deviceID"]]
        .merge(device_counts, on="deviceID", how="inner")
        .groupby("userID")["users_per_device"]
        .max()
        .rename("max_users_per_device")
        .reset_index()
    )

    ip_counts = (
        tx_success[tx_success["userIP"].notna()]
        .groupby("userIP")["userID"]
        .nunique()
        .rename("users_per_ip")
        .reset_index()
    )
    user_ip = (
        tx[tx["userIP"].notna()][["userID", "userIP"]]
        .merge(ip_counts, on="userIP", how="inner")
        .groupby("userID")["users_per_ip"]
        .max()
        .rename("max_users_per_ip")
        .reset_index()
    )

    loops = transfer_loop_counts(transfers)

    features = (
        pd.DataFrame({"userID": selected_success["userID"].drop_duplicates()})
        .merge(campaign_discount, on="userID", how="left")
        .merge(immediate_summary, on="userID", how="left")
        .merge(referral_summary, on="userID", how="left")
        .merge(user_device, on="userID", how="left")
        .merge(user_ip, on="userID", how="left")
        .merge(loops, on="userID", how="left")
    )
    numeric_fill = [
        "credited_campaign_discount_success_only",
        "campaign_rows",
        "campaign_discount_rows",
        "distinct_campaign_transactions",
        "immediate_discount_0_1_day",
        "immediate_discount_rows_0_1_day",
        "distinct_immediate_discount_transactions_0_1_day",
        "total_invitees",
        "max_users_per_device",
        "max_users_per_ip",
        "transfer_loop_count",
    ]
    features[numeric_fill] = features[numeric_fill].fillna(0)

    scored = features.copy()
    scored["score_immediate_discount"] = 0
    scored.loc[scored["immediate_discount_0_1_day"] >= 1_000_000, "score_immediate_discount"] = 3
    scored.loc[
        (scored["immediate_discount_0_1_day"].between(500_000, 999_999))
        & (scored["immediate_discount_rows_0_1_day"] >= 10),
        "score_immediate_discount",
    ] = 2

    scored["score_credited_discount"] = 0
    scored.loc[scored["credited_campaign_discount_success_only"] >= 100_000, "score_credited_discount"] = 1
    scored.loc[scored["credited_campaign_discount_success_only"] >= 500_000, "score_credited_discount"] = 2
    scored.loc[scored["credited_campaign_discount_success_only"] >= 1_000_000, "score_credited_discount"] = 3

    scored["score_referral"] = 0
    scored.loc[scored["total_invitees"] >= 20, "score_referral"] = 2
    scored.loc[scored["total_invitees"] >= 100, "score_referral"] = 3

    scored["score_device"] = 0
    scored.loc[scored["max_users_per_device"] >= 5, "score_device"] = 1
    scored.loc[scored["max_users_per_device"] >= 10, "score_device"] = 2

    scored["score_ip"] = 0
    scored.loc[scored["max_users_per_ip"] >= 20, "score_ip"] = 1
    scored.loc[scored["max_users_per_ip"] >= 50, "score_ip"] = 2

    scored["score_transfer_loop"] = 0
    scored.loc[scored["transfer_loop_count"] >= 1, "score_transfer_loop"] = 1
    scored.loc[scored["transfer_loop_count"] >= 3, "score_transfer_loop"] = 2

    score_columns = [
        "score_immediate_discount",
        "score_credited_discount",
        "score_referral",
        "score_device",
        "score_ip",
        "score_transfer_loop",
    ]
    scored["suspicion_score"] = scored[score_columns].sum(axis=1)
    scored["risk_tier"] = "Review"
    scored.loc[scored["suspicion_score"] >= 6, "risk_tier"] = "Medium risk"
    scored.loc[scored["suspicion_score"] >= 9, "risk_tier"] = "High risk"

    reasons = []
    for row in scored.itertuples(index=False):
        parts = []
        if row.immediate_discount_0_1_day >= 1_000_000:
            parts.append(
                f"high immediate campaign discount within 0-1 day: {int(row.immediate_discount_0_1_day)}"
            )
        if row.credited_campaign_discount_success_only >= 500_000:
            parts.append(
                f"high credited campaign discount: {int(row.credited_campaign_discount_success_only)}"
            )
        if row.total_invitees >= 20:
            parts.append(f"high referral count: {int(row.total_invitees)}")
        if row.max_users_per_device >= 5:
            parts.append(f"shared device used by {int(row.max_users_per_device)} users")
        if row.max_users_per_ip >= 20:
            parts.append(f"shared IP used by {int(row.max_users_per_ip)} users")
        if row.transfer_loop_count >= 1:
            parts.append(f"involved in transfer loop: {int(row.transfer_loop_count)} loop signals")
        reasons.append(", ".join(parts) + (", " if parts else ""))
    scored["reason"] = reasons

    ordered_columns = [
        "userID",
        "suspicion_score",
        "risk_tier",
        "credited_campaign_discount_success_only",
        "campaign_rows",
        "campaign_discount_rows",
        "distinct_campaign_transactions",
        "immediate_discount_0_1_day",
        "immediate_discount_rows_0_1_day",
        "distinct_immediate_discount_transactions_0_1_day",
        "total_invitees",
        "max_users_per_device",
        "max_users_per_ip",
        "transfer_loop_count",
        "score_immediate_discount",
        "score_credited_discount",
        "score_referral",
        "score_device",
        "score_ip",
        "score_transfer_loop",
        "first_campaign_time",
        "last_campaign_time",
        "first_immediate_discount_time",
        "last_immediate_discount_time",
        "first_invite_time",
        "last_invite_time",
        "reason",
    ]
    user_features = scored[ordered_columns].sort_values(
        ["credited_campaign_discount_success_only", "userID"], ascending=[False, True]
    )
    suspicious = user_features[
        (user_features["suspicion_score"] >= 3) & (user_features["reason"] != "")
    ].sort_values(
        ["suspicion_score", "credited_campaign_discount_success_only", "userID"],
        ascending=[False, False, True],
    )

    if privacy == "public":
        mapping = {
            user_id: f"user_{i:06d}"
            for i, user_id in enumerate(sorted(scored["userID"].dropna().unique()), start=1)
        }
        user_features = user_features.copy()
        suspicious = suspicious.copy()
        user_features.insert(0, "user_key", user_features["userID"].map(mapping))
        suspicious.insert(0, "user_key", suspicious["userID"].map(mapping))
        user_features = user_features.drop(columns=["userID"])
        suspicious = suspicious.drop(columns=["userID"])

    impact = pd.DataFrame(
        [
            {
                "total_scored_users": len(scored),
                "total_suspicious_users": len(suspicious),
                "suspicious_user_rate_pct": round(len(suspicious) * 100 / max(len(scored), 1), 2),
                "total_campaign_discount": int(
                    scored["credited_campaign_discount_success_only"].sum()
                ),
                "discount_used_by_suspicious_users": int(
                    scored.loc[
                        (scored["suspicion_score"] >= 3) & (scored["reason"] != ""),
                        "credited_campaign_discount_success_only",
                    ].sum()
                ),
                "share_of_campaign_discount_pct": round(
                    scored.loc[
                        (scored["suspicion_score"] >= 3) & (scored["reason"] != ""),
                        "credited_campaign_discount_success_only",
                    ].sum()
                    * 100
                    / max(scored["credited_campaign_discount_success_only"].sum(), 1),
                    2,
                ),
            }
        ]
    )

    rules = [
        (
            "Block: immediate discount >= 500K within 0-1 day and discount rows >= 10",
            (scored["immediate_discount_0_1_day"] >= 500_000)
            & (scored["immediate_discount_rows_0_1_day"] >= 10),
        ),
        ("Block: same device used by >= 10 users", scored["max_users_per_device"] >= 10),
        (
            "Manual review: invitees >= 20 and campaign discount >= 500K",
            (scored["total_invitees"] >= 20)
            & (scored["credited_campaign_discount_success_only"] >= 500_000),
        ),
        (
            "Manual review: transfer loop exists and campaign discount >= 100K",
            (scored["transfer_loop_count"] >= 1)
            & (scored["credited_campaign_discount_success_only"] >= 100_000),
        ),
    ]
    rule_rows = []
    for rule_name, mask in rules:
        hit = scored[mask]
        if hit.empty:
            continue
        low_score_users = hit[hit["suspicion_score"] < 3]
        low_score_impact_pct = round(len(low_score_users) * 100 / max(len(hit), 1), 2)
        if low_score_impact_pct >= 30:
            label = "High over-flagging risk"
        elif low_score_impact_pct >= 10:
            label = "Medium over-flagging risk"
        else:
            label = "Lower over-flagging risk"
        rule_rows.append(
            {
                "rule_name": rule_name,
                "users_impacted": hit["userID"].nunique(),
                "promo_cost_at_risk_or_saved": int(
                    hit["credited_campaign_discount_success_only"].sum()
                ),
                "low_score_users_impacted": low_score_users["userID"].nunique(),
                "low_score_impact_pct": low_score_impact_pct,
                "overflagging_risk_label": label,
            }
        )
    rule_summary = pd.DataFrame(rule_rows).sort_values(
        ["promo_cost_at_risk_or_saved", "users_impacted"], ascending=[False, False]
    )

    metric_names = [
        "credited_campaign_discount_success_only",
        "immediate_discount_0_1_day",
        "campaign_discount_rows",
        "total_invitees",
        "max_users_per_device",
        "max_users_per_ip",
        "transfer_loop_count",
    ]
    percentile_rows = []
    for metric in metric_names:
        values = features[metric].astype(float)
        percentile_rows.append(
            {
                "metric_name": metric,
                "selected_campaign_users": len(values),
                "min_value": round(values.min(), 2),
                "avg_value": round(values.mean(), 2),
                "max_value": round(values.max(), 2),
                "p50": round(values.quantile(0.50), 2),
                "p75": round(values.quantile(0.75), 2),
                "p90": round(values.quantile(0.90), 2),
                "p95": round(values.quantile(0.95), 2),
                "p99": round(values.quantile(0.99), 2),
            }
        )
    percentile = pd.DataFrame(percentile_rows).sort_values("metric_name")

    payment = tx[(tx["appID"] > 0) & (tx["transStatus"] == 1)][["userID", "reqDate"]].copy()
    payment["payment_week"] = week_start(payment["reqDate"])
    payment = payment[["userID", "payment_week"]].drop_duplicates()
    first_payment = payment.groupby("userID")["payment_week"].min().rename("cohort_week")
    retention_base = payment.merge(first_payment, on="userID", how="inner")
    retention_base["week_number"] = (
        (retention_base["payment_week"] - retention_base["cohort_week"]).dt.days // 7
    )
    cohort_size = (
        retention_base[retention_base["week_number"] == 0]
        .groupby("cohort_week")["userID"]
        .nunique()
        .rename("cohort_users")
    )
    retention = (
        retention_base.groupby(["cohort_week", "week_number"])["userID"]
        .nunique()
        .rename("retained_users")
        .reset_index()
        .merge(cohort_size, on="cohort_week", how="left")
    )
    retention["retention_rate_pct"] = (
        retention["retained_users"] * 100 / retention["cohort_users"]
    ).round(2)
    retention = retention[
        ["cohort_week", "week_number", "cohort_users", "retained_users", "retention_rate_pct"]
    ].sort_values(["cohort_week", "week_number"])

    # --- NEW: the 4 additional date-slicer-friendly exports ---
    campaign_daily_risk_summary = build_campaign_daily_risk_summary(selected, scored)
    campaign_user_daily_risk = build_campaign_user_daily_risk(selected, scored)
    promotion_daily_summary = build_promotion_daily_summary(selected)
    merchant_daily_summary = build_merchant_daily_summary(selected, app)

    return {
        "campaign_overview.csv": overview,
        "campaign_daily_summary.csv": daily,
        "campaign_promotion_breakdown.csv": promo,
        "selected_campaign_merchant_distribution.csv": merchant,
        "selected_campaign_user_scored_features.csv": user_features,
        "suspicious_users_full.csv": suspicious,
        "abuse_impact_summary.csv": impact,
        "rule_simulation_summary.csv": rule_summary,
        "threshold_percentile_summary.csv": percentile,
        "retention_weekly_summary.csv": retention,
        # --- NEW ---
        "campaign_daily_risk_summary.csv": campaign_daily_risk_summary,
        "campaign_user_daily_risk.csv": campaign_user_daily_risk,
        "promotion_daily_summary.csv": promotion_daily_summary,
        "merchant_daily_summary.csv": merchant_daily_summary,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--campaign-code", default="ZPI_220801_115")
    parser.add_argument("--privacy", choices=["private", "public"], default="private")
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    source_root = (args.source_root or repo_root).resolve()
    raw_dir = source_root / "data" / "raw"
    output_dir = repo_root / "data" / "output"
    output_dir.mkdir(parents=True, exist_ok=True)

    outputs = build_outputs(raw_dir, args.campaign_code, args.privacy)
    for filename in OUTPUT_FILES:
        frame = safe_date_frame(outputs[filename])
        frame.to_csv(output_dir / filename, index=False, encoding="utf-8-sig")
        print(f"Wrote {output_dir / filename} ({len(frame):,} rows)")


if __name__ == "__main__":
    main()
