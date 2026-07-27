# Stage 1 — SQL (SQL Server / T-SQL)

**Role:** SQL is the backbone — it takes raw ZaloPay transaction data from database trust checks all the way to
a scored, per-user abuse table and the exports that feed Python and Power BI.

## Flow (files 00 → 09)

| File | Purpose | Key output |
|---|---|---|
| `00–04` | **Data trust**: row counts, keys, join validity, date ranges, success definition | joinable; `campaignID = 0` = non-campaign; success = `transStatus = 1` |
| `05` | **Business questions**: category volumes, 100K-discount crossing, weekly retention | assessment answers |
| `06` | **Campaign selection**: priority score across all campaigns | `CAMP_A` is the top-risk, top-cost campaign |
| `07` | **Deep dive**: per-user behavioural features inside the campaign | 6 raw signals per user |
| `07b` | **Single feature source** — a `VIEW` all downstream queries share | `vw_abuse_user_features` |
| `08` | **Scoring**: `suspicion_score`, `risk_tier`, `reason` | 3,671 suspicious of 86,170 scored |
| `09` | **Power BI exports**: 14 result sets | the CSVs behind the dashboard |

## Techniques demonstrated

- **CTEs & modular query design** — each feature built in a readable step, then composed.
- **Window functions** — `RANK()`, `PERCENTILE_CONT` for threshold justification (p95/p99).
- **Self-joins for graph behaviour** — detecting **reciprocal transfer loops** (A→B then B→A within 60 min).
- **Cohort logic** — first-successful-payment week for retention.
- **CASE-based rule scoring** — 6 signals → 0–2 points each → a 0–11 `suspicion_score` → risk tiers.
- **Single-source `VIEW`** — `07b` removed ~200 lines of duplicated feature logic across `08`/`09`.

## Highlight: a real bug caught and fixed

The transfer-loop signal originally used a self-join that produced a **cross-product** — counting every
timestamped row pair instead of distinct partners. One user showed **500,057 "loops."** The fix:

```sql
-- count DISTINCT reciprocal counterparties, not self-joined row pairs
transfer_loop_users AS (
    SELECT userID, COUNT(DISTINCT counterpart) AS transfer_loop_count
    FROM (SELECT user_a AS userID, user_b AS counterpart FROM transfer_loop_pairs
          UNION SELECT user_b, user_a FROM transfer_loop_pairs) e
    GROUP BY userID
)
```

Result: max dropped from **500,057 → 158**, and the downstream scores/rule simulations became trustworthy.
*This is the kind of correctness check that separates a plausible dashboard from a reliable one.*

## The scoring model

`suspicion_score` = sum of 6 signal scores. `risk_tier` bands it: **High (≥7) · Medium (5–6) · Review (3–4) ·
Low/No-action (0–2)** — deliberately aligned to the score so the dashboard's tier and score views agree.

**Skills:** T-SQL modelling, window functions, graph-style self-joins, cohort analysis, rule engineering,
data-quality debugging, single-source design.
