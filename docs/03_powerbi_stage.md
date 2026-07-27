# Stage 3 — Power BI (5-page dashboard)

**Role:** Power BI is where the analysis becomes a **decision tool** for two audiences — a manager ("is there a
problem, how big?") and an investigator ("who, and why?").

## Page structure — the story arc

**problem → cost → who → decision → payoff**

| Page | Question | Highlights |
|---|---|---|
| 1 · Overview | Is there a problem, how big? | KPI strip, promo-cost-vs-users trend, exposure-by-risk-group area, suspicious cost-share line (peak 40.7%) |
| 2 · Promotion & Merchant Exposure | Where does the money go? | 74% concentration in one promotion; payment-vs-non-payment; merchant-category detail |
| 3 · User Risk Patterns | Who is suspicious, and why? | risk tiers, triggered-signal counts, discount-extraction scatter, referral/device signals, review list |
| 4 · Rule Decisions | Which rule do we deploy? | recommendation table (conditional-formatted), cost-vs-workload scatter, rule-specific KPIs |
| 5 · Retention Context | Did spend buy lasting users? | cohort heatmap, weighted retention curve, cohort-size dual-axis (framed as overall-payment context) |

## Data model

- ~23 real tables from the SQL/Python exports (fact tables + small summary tables), a proper **Date table**,
  and disconnected helper tables for the risk-group toggles.
- **56 DAX measures** organised into display folders (`Promotion & Merchant`, `User Risk`, `Rule Decisions`,
  `Retention`) rather than dumped in one list.
- **One metric = one value:** distinct-count measures drive user counts everywhere, so the same number never
  disagrees across pages (a trap that was deliberately engineered out).

## DAX / modelling techniques

- Distinct-count measures for user rates (avoids double-counting per-day rows).
- `DIVIDE`-based rate measures with proper `%` formatting (no pre-multiplied columns on cards).
- `SWITCH`/`SELECTEDVALUE` toggle measures for risk-group breakdowns.
- Conditional formatting via a helper colour column → green/amber/grey decision table.
- A `DateTime.LocalNow()` "last refreshed" stamp and a scope/disclaimer banner.

## Trust engineering (the part most portfolios skip)

Several **consistency bugs** were found and fixed so the dashboard doesn't "leak trust":

- a per-day `unique_users` **double-count** (110k user-days shown as users) → replaced with a distinct measure;
- a **currency series mislabelled as a percentage** → relabelled + retitled;
- a **risk tier that mixed clean and suspicious users** → split into four honest bands;
- an **over-claiming recommendation** ("blocking") → reframed to "shadow-mode / review".

## Communication touches

Navigation sidebar with active-page state, a reset-filters button, business-language titles, a scope banner
("rule-based review score, not confirmed fraud"), and a one-sentence takeaway caption on every page.

**Skills:** star-schema modelling, DAX, drill paths, conditional formatting, navigation/UX, metric-consistency
debugging, publishing.
