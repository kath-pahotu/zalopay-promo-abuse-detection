# Stage 2 — Python (pandas notebook)

**Role:** Python turns the SQL scored table into a **decision**. It simulates candidate review rules, tests
how sensitive the results are to thresholds, and — critically — **reconciles its numbers against SQL** so the
two independent implementations must agree.

## What it does

1. **Rebuilds the suspicious-user table from the raw exports** (independently of SQL's version).
2. **Simulates 7 business rules** — each a different combination of thresholds (discount, invitees, device,
   transfer loop, multi-signal) — and measures, per rule:
   - `users_flagged` (review workload),
   - `promo_cost_captured` (% of at-risk cost the rule covers),
   - `low_score_impact_pct` (an over-flagging **proxy**: share of flagged users scoring < 3).
3. **Sensitivity grid** — sweeps thresholds to show how flagged-count and cost-captured move, so the chosen
   rule isn't a lucky single point.
4. **SQL ↔ Python reconciliation** — every headline number is recomputed in pandas and checked against the
   SQL export; the reconciliation table must read `match` on every row.

## Why a notebook (not more SQL)

Rule simulation is **experimentation**: many what-if combinations, quick iteration, and side-by-side
comparison. pandas is faster to iterate than re-writing SQL per scenario, and the notebook doubles as a
**reproducible, narrated record** of how the recommendation was reached.

## The recommendation logic

The goal is the **best coverage-to-workload trade-off**, not maximum coverage:

| Rule | Users flagged | Cost captured | Over-flag proxy | Verdict |
|---|--:|--:|--:|---|
| Broad monitoring | 19,332 | 68.0% | 83.5% | monitoring only — too broad |
| **Medium balanced** | **1,994** | **23.9%** | **0.0%** | **recommended — shadow / review** |
| New-account extraction | 1,193 | 13.8% | 0.0% | candidate |
| Referral farming | 1,080 | 14.5% | 0.0% | candidate |
| Strict multi-signal | 4 | 0.05% | 0.0% | supporting only |

The **medium-balanced** rule captures a quarter of the at-risk cost while flagging only ~2% of users — the
upper-left "sweet spot" on the cost-vs-workload trade-off.

## Honesty built in

The notebook is explicit that `low_score_impact_pct` is an **internal-consistency proxy, not a measured
false-positive rate** — because the score and the rules share signals, a 0% value is expected by construction.
That caveat is carried all the way onto the dashboard.

## Outputs handed off

Rule-recommendation and sensitivity CSVs + two Power BI workbooks, all reconciled to the SQL headline numbers.

**Skills:** pandas simulation & sensitivity analysis, scenario design, reconciliation/validation testing,
honest metric framing, reproducible notebooks.
