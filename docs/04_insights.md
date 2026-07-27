# Insights & Recommendation

The narrative a stakeholder should walk away with — in plain business terms.

## 1. The promotion worked, but its budget is concentrated

Campaign `CAMP_A` drove **254,309 transactions** from **90,555 users** at a **76% success rate**,
spending **7.0bn ₫** in credited promo cost. But that spend is **not evenly distributed**: a single promotion
(`PROMO_45`) accounts for **74%** of the credited cost. Budget risk is concentrated in a few promotions and a
few merchant categories — so monitoring effort should be too.

## 2. A small group of users absorbs a large share of the budget

Of **86,170 scored users**, **3,671 (4.26%)** score as suspicious on the 6-signal model — and they hold
**26.94% of the credited promo cost (≈1.89bn ₫)**. On the single highest day, suspicious users accounted for
**40.7% of that day's promo cost.** So ~4 in 100 users are tied to ~1 in 4 promo dong.

> **The one-liner for a slide:** *"4.26% of users → 26.94% of promo cost."*

## 3. Suspicion is multi-signal, not one behaviour

Abuse isn't a single tell. Among the 3,671 suspicious users, **99.9% trigger at least two signals**, and
higher-risk users combine more: medium-risk users average ~3 signals, high-risk ~5. The strongest signals are
**high credited discount, reciprocal transfer loops, and shared IPs.** This is why the model *scores* users
across signals rather than banning on any single behaviour.

## 4. The right action is prioritized review, not automated blocking

Seven rules were simulated. The **medium-balanced rule** is the recommendation:

- flags **1,994 users** → only a **2.3% review workload**,
- captures **23.9%** of the at-risk promo cost,
- **0%** low-score proxy impact.

**But the honest framing matters:** because the score and the rules use the same signals, "0% low-score
impact" is an *internal-consistency proxy, not a proven false-positive rate*. Without confirmed fraud labels,
the safe recommendation is **shadow mode / high-priority manual review**, escalating to blocking only after
outcome validation.

## 5. Retention is context, not proof

At the overall-payment level, **Week-1 retention is ~24%** and **Week-4 ~20%** across 79,592 cohort users.
This is shown as **context** — the current data measures overall payment retention, not campaign-attributed
retention by risk group, so it *cannot* yet prove "the promo bought only one-time extractors." That's flagged
honestly and listed as future work.

## Recommendation summary

| Do now | Why |
|---|---|
| Put the **medium-balanced rule** into **shadow mode / manual review** | best coverage-to-workload trade-off |
| Prioritise the **dominant promotion (`PROMO_45`) & top merchant categories** for monitoring | 74% of budget risk sits there |
| Keep the **"review score, not fraud" disclaimer** on every stakeholder view | avoids over-action on unlabeled data |
| Build **campaign-scoped retention by risk group** next | to test whether abuse users retain worse |

## What I'd do next (roadmap)

Network/ring detection across referral + device + transfer graphs · velocity features (first-hour burst
timing) · a second-opinion anomaly model (Isolation Forest) to cross-check the rule score · a what-if
threshold simulator · and a formal validation plan once manual labels exist.
