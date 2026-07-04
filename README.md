# ZaloPay Promo Abuse Detection - Public Portfolio

Public portfolio version of a DA/BI project analyzing promotion-abuse risk in a ZaloPay campaign dataset. This repo contains public-safe SQL, anonymized/aggregated outputs, and blurred screenshots for storytelling.

## Project Objective

Show an end-to-end analyst workflow: explore campaign data, identify suspicious promotion usage, quantify business exposure, and design practical review/prevention rules.

The project focuses on campaign `ZPI_220801_115` and answers:

- Which campaigns deserve deeper abuse investigation?
- Where did credited promotion discount concentrate?
- Which risk signals appear at user level: immediate reward extraction, referrals, shared device/IP, and transfer loops?
- How much campaign discount is attached to suspicious-review users?
- Which rules are practical for monitoring, manual review, or controlled blocking tests?

## Repository Structure

```text
data/
  output/                      public-safe/anonymized output tables
screenshots/
  public_blur/                 redacted SQL result screenshots
sql/
  00_database_overview.sql
  01_table_schema_check.sql
  02_sample_all_tables.sql
  03_data_quality_check.sql
  04_relationship_check.sql
  05_business_questions.sql
  06_campaign_discovery_scan.sql
  07_selected_campaign_deep_dive.sql
  08_abuse_detection_rules_final.sql
  09_powerbi_export_queries.sql
  SQL_Screenshot_annotated.md
scripts/
  helper scripts for public asset preparation
```

## Analysis Flow

1. Database overview and schema checks.
2. Data quality checks for duplicates, dates, missing values, and platform behavior.
3. Relationship validation across transaction, transfer, campaign, app, referral, and user tables.
4. Business questions on campaign cost, merchant categories, and retention.
5. Campaign discovery scan to choose the highest-priority campaign.
6. Selected-campaign deep dive into promotion, merchant, referral, device/IP, and transfer signals.
7. Final abuse-detection SQL with percentile threshold support, scoring, campaign impact summary, and rule simulation.
8. Power BI-ready export queries for dashboard handoff.

## Public Outputs

Public `data/output/` is designed for portfolio use and should avoid raw user IDs. User-level outputs use anonymized keys when needed.

Main handoff files:

- `selected_campaign_user_scored_features.csv`: scored user-level table with anonymized user keys
- `suspicious_users_full.csv`: anonymized suspicious-review table
- `abuse_impact_summary.csv`: campaign exposure summary
- `rule_simulation_summary.csv`: rule workload and exposure comparison
- `threshold_percentile_summary.csv`: evidence for scoring thresholds

## Important Label Limitation

The dataset has no confirmed fraud or bot labels. `suspicion_score` is a rule-based review score, not a ground-truth fraud label. For that reason, this project uses `low_score_users_impacted`, `low_score_impact_pct`, and over-flagging risk language instead of claiming confirmed error rates.

## Portfolio Story

SQL does the source-of-truth work: joins, validation, feature building, scoring, and export tables. Python extends the work with reconciliation, flexible rule simulation, sensitivity analysis, and charts. Power BI is the final communication layer for executives and business users.
