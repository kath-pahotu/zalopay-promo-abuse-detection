# Reproducibility and scripts

The portfolio story is readable without running code: use the [live Power BI report](https://app.powerbi.com/view?r=eyJrIjoiZmM2NjBhZDUtMjVjYy00ZjcyLWEyMTEtMmZhMTkzZWM2Yzk0IiwidCI6IjNkZmNkMTY2LWYzZmUtNGQxNS1hNDYzLTA0NTU2YzMwNWZmMiIsImMiOjEwfQ%3D%3D), the [presentation PDF](../presentation/ZaloPay_Promotion_Abuse_Presentation.pdf), the [findings](04_insights.md), and the evidence tables/figures. The scripts are for a maintainer who needs to refresh the project.

## Script guide

| Script | What it does | Needed to understand the story? | Needed for a full refresh? |
|---|---|:---:|:---:|
| `run_all.py` | Convenience orchestrator: SQL export → validation → notebook → both Power BI workbooks | No | Helpful; it calls the steps below |
| `export_sql09_resultsets.py` | Runs the feature/export SQL and writes the 14 CSV hand-off tables | No | Yes, when refreshing from the original SQL Server |
| `verify_export.py` | Checks row counts, score logic and the transfer-loop correction before outputs reach the dashboard | No | Yes; this is a quality gate |
| `build_powerbi_workbook.py` | Builds the Excel workbook used by the main Power BI model | No | Yes for the main PBIX refresh |
| `build_python_rule_simulation_workbook.py` | Builds the workbook used by rule-decision visuals | No | Yes for those visuals |
| `export_powerbi_outputs.py` | Earlier/direct export helper retained for compatibility; the documented refresh path uses `export_sql09_resultsets.py` | No | Usually no |
| `anonymize_for_public.py` | Creates one-way anonymised portfolio data from private outputs | No | Only when republishing data safely |

## Recommended maintenance paths

### To review the portfolio

Do not run scripts. Open the live report, the browser-viewable PDF, and the evidence CSVs/figures in this repository.

### To refresh the private analysis

Run `run_all.py` with access to the original SQL Server and Python environment, then refresh the PBIX manually in Power BI Desktop. Power BI Desktop owns the final report refresh/save operation.

### To update the public portfolio safely

Publish only anonymised aggregates and sampled user-level files after validation. Do not publish raw source data, original identifiers, mapping tables, or unreviewed screenshots.

## Why validation matters

An early transfer-loop self-join counted a cross-product and created an impossible maximum of 500,057. The corrected query counts distinct counterparties; `verify_export.py` checks the maximum is below 1,000 before downstream outputs are used. This protects the credibility of the dashboard findings.
