# SQL — ZaloPay Campaign Abuse Detection

This folder holds the SQL analysis for campaign `ZPI_220801_115`, run in order `00 → 09`.

> **Note:** for the narrative walkthrough of what each query establishes, see the per-stage case study
> in **[`../docs/01_sql_stage.md`](../docs/01_sql_stage.md)**.

## Flow

```text
00_database_overview.sql        Confirm DB + table scale
01_table_schema_check.sql       Columns, types, nullability (data dictionary)
02_sample_all_tables.sql        What each table means in real rows
03_data_quality_check.sql       Row counts, duplicate keys, dates, nulls, status, early signal scouting
04_relationship_check.sql       Joins are reliable; campaignID 0 = non-campaign
05_business_questions.sql       Category volume · first 100K cumulative discount · weekly retention
06_campaign_discovery_scan.sql  Priority-score all campaigns -> select ZPI_220801_115
07_selected_campaign_deep_dive.sql  Per-user signals inside the selected campaign
07b_abuse_user_features_view.sql    Create dbo.vw_abuse_user_features (shared feature build; run once before 08/09)
08_abuse_detection_rules_final.sql  Percentile support -> scoring -> impact -> rule simulation
09_powerbi_export_queries.sql   Build the Power BI / handoff CSVs
```

## Key conventions
- **Success = `transStatus = 1`.** All credited-discount figures are success-only.
- **`campaignID = 0`** is non-campaign activity and is excluded from campaign analysis.
- **`transID` is not unique** — use `COUNT(DISTINCT transID)` for transaction counts.
- **Scored population = 86,170** users with ≥1 *successful* campaign transaction (the campaign has
  90,555 unique users in total, including non-successful).
- The `suspicion_score` is a **rule-based review score, not a confirmed fraud label.**

## Known follow-ups
See [`../review/01_project_flow_review.md`](../review/01_project_flow_review.md) for the full review.
The most important open item is the **transfer-loop count explosion** (feature `transfer_loop_count`
reaches 500,057 due to a self-join cross-product) — fix in both `08` and `09` before trusting the
transfer-loop signal.
