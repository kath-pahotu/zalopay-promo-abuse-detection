USE zalo;
GO

/* ============================================================
   09_POWERBI_EXPORT_QUERIES

   Purpose:
   - Create Power BI-ready result sets for campaign abuse analysis.
   - Export each SELECT result to CSV files in data/output/ using SSMS,
     Azure Data Studio, bcp, or scripts/export_powerbi_outputs.py.

   Privacy:
   - Private version keeps real userID values.

   Output CSV mapping:
   1. campaign_overview.csv
   2. campaign_daily_summary.csv
   3. campaign_promotion_breakdown.csv
   4. selected_campaign_merchant_distribution.csv
   5. selected_campaign_user_scored_features.csv
   6. suspicious_users_full.csv`
   7. abuse_impact_summary.csv
   8. rule_simulation_summary.csv
   9. threshold_percentile_summary.csv
   10. retention_weekly_summary.csv
   ============================================================ */

DECLARE @CampaignCode VARCHAR(50) = 'CAMP_A';

DROP TABLE IF EXISTS #selected_campaign_transactions;
DROP TABLE IF EXISTS #abuse_user_features;
DROP TABLE IF EXISTS #abuse_scored_users;

SELECT
    t.*,
    c.campaignCode,
    c.promotionName,
    c.promotion_type
INTO #selected_campaign_transactions
FROM dbo.[transaction] t
JOIN dbo.campaign_info c
    ON t.campaignID = c.campaignID
WHERE c.campaignCode = @CampaignCode;

/* Build the same user-level abuse feature table used in 08.
   REVIEW CHANGE (E5): the feature logic is no longer copy-pasted here.
   It comes from the shared view dbo.vw_abuse_user_features
   (07b_abuse_user_features_view.sql), which also carries the
   transfer-loop fix (E1). Run 07b once before running this file. */
SELECT *
INTO #abuse_user_features
FROM dbo.vw_abuse_user_features;

WITH scored_users AS (
    SELECT
        *,
        CASE WHEN immediate_discount_0_1_day >= 1000000 THEN 3
             WHEN immediate_discount_0_1_day >= 500000 AND immediate_discount_rows_0_1_day >= 10 THEN 2
             ELSE 0 END AS score_immediate_discount,
        CASE WHEN credited_campaign_discount_success_only >= 1000000 THEN 3
             WHEN credited_campaign_discount_success_only >= 500000 THEN 2
             WHEN credited_campaign_discount_success_only >= 100000 THEN 1
             ELSE 0 END AS score_credited_discount,
        CASE WHEN total_invitees >= 100 THEN 3
             WHEN total_invitees >= 20 THEN 2
             ELSE 0 END AS score_referral,
        CASE WHEN max_users_per_device >= 10 THEN 2
             WHEN max_users_per_device >= 5 THEN 1
             ELSE 0 END AS score_device,
        CASE WHEN max_users_per_ip >= 50 THEN 2
             WHEN max_users_per_ip >= 20 THEN 1
             ELSE 0 END AS score_ip,
        CASE WHEN transfer_loop_count >= 3 THEN 2
             WHEN transfer_loop_count >= 1 THEN 1
             ELSE 0 END AS score_transfer_loop
    FROM #abuse_user_features
),
final_scored_users AS (
    SELECT
        *,
        score_immediate_discount + score_credited_discount + score_referral
        + score_device + score_ip + score_transfer_loop AS suspicion_score
    FROM scored_users
)
SELECT
    *,
    CASE WHEN suspicion_score >= 7 THEN 'High risk'
         WHEN suspicion_score >= 5 THEN 'Medium risk'
         WHEN suspicion_score >= 3 THEN 'Review'
         ELSE 'Low / No action' END AS risk_tier,
    CONCAT(
        CASE WHEN immediate_discount_0_1_day >= 1000000
               OR (immediate_discount_0_1_day >= 500000 AND immediate_discount_rows_0_1_day >= 10)
             THEN CONCAT('high immediate campaign discount within 0-1 day: ', immediate_discount_0_1_day, ', ') ELSE '' END,
        CASE WHEN credited_campaign_discount_success_only >= 500000
             THEN CONCAT('high credited campaign discount: ', credited_campaign_discount_success_only, ', ')
             WHEN credited_campaign_discount_success_only >= 100000
             THEN CONCAT('elevated credited campaign discount: ', credited_campaign_discount_success_only, ', ') ELSE '' END,
        CASE WHEN total_invitees >= 20
             THEN CONCAT('high referral count: ', total_invitees, ', ') ELSE '' END,
        CASE WHEN max_users_per_device >= 5
             THEN CONCAT('shared device used by ', max_users_per_device, ' users, ') ELSE '' END,
        CASE WHEN max_users_per_ip >= 20
             THEN CONCAT('shared IP used by ', max_users_per_ip, ' users, ') ELSE '' END,
        CASE WHEN transfer_loop_count >= 1
             THEN CONCAT('reciprocal transfer loop with ', transfer_loop_count, ' partner(s), ') ELSE '' END
    ) AS reason
INTO #abuse_scored_users
FROM final_scored_users;

/* campaign_overview.csv */
SELECT
    campaignCode,
    COUNT(*) AS transaction_rows,
    COUNT(DISTINCT userID) AS unique_users,
    COUNT(DISTINCT campaignID) AS campaign_id_count,
    SUM(CASE WHEN appID > 0 THEN 1 ELSE 0 END) AS payment_rows,
    SUM(CASE WHEN transStatus = 1 THEN 1 ELSE 0 END) AS successful_rows,
    CAST(SUM(CASE WHEN transStatus = 1 THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(*), 0) AS DECIMAL(10,2)) AS success_rate_pct,
    SUM(CAST(COALESCE(discountAmount, 0) AS BIGINT)) AS gross_discount_all_rows,
    SUM(CASE WHEN transStatus = 1 THEN CAST(COALESCE(discountAmount, 0) AS BIGINT) ELSE 0 END) AS credited_discount_success_only,
    SUM(CASE WHEN transStatus <> 1 OR transStatus IS NULL THEN CAST(COALESCE(discountAmount, 0) AS BIGINT) ELSE 0 END) AS non_success_discount_amount,
    MIN(reqDate) AS first_seen,
    MAX(reqDate) AS last_seen
FROM #selected_campaign_transactions
GROUP BY campaignCode;

/* campaign_daily_summary.csv */
SELECT
    CAST(reqDate AS DATE) AS txn_date,
    COUNT(*) AS transaction_rows,
    COUNT(DISTINCT userID) AS unique_users,
    SUM(CASE WHEN transStatus = 1 THEN 1 ELSE 0 END) AS successful_rows,
    SUM(CAST(COALESCE(discountAmount, 0) AS BIGINT)) AS gross_discount_all_rows,
    SUM(CASE WHEN transStatus = 1 THEN CAST(COALESCE(discountAmount, 0) AS BIGINT) ELSE 0 END) AS credited_discount_success_only,
    SUM(CASE WHEN transStatus <> 1 OR transStatus IS NULL THEN CAST(COALESCE(discountAmount, 0) AS BIGINT) ELSE 0 END) AS non_success_discount_amount
FROM #selected_campaign_transactions
GROUP BY CAST(reqDate AS DATE)
ORDER BY txn_date;

/* campaign_promotion_breakdown.csv */
SELECT
    campaignID,
    promotionName,
    promotion_type,
    COUNT(*) AS transaction_rows,
    COUNT(DISTINCT userID) AS unique_users,
    SUM(CASE WHEN transStatus = 1 THEN 1 ELSE 0 END) AS successful_rows,
    SUM(CAST(COALESCE(discountAmount, 0) AS BIGINT)) AS gross_discount_all_rows,
    SUM(CASE WHEN transStatus = 1 THEN CAST(COALESCE(discountAmount, 0) AS BIGINT) ELSE 0 END) AS credited_discount_success_only,
    SUM(CASE WHEN transStatus <> 1 OR transStatus IS NULL THEN CAST(COALESCE(discountAmount, 0) AS BIGINT) ELSE 0 END) AS non_success_discount_amount
FROM #selected_campaign_transactions
GROUP BY campaignID, promotionName, promotion_type
ORDER BY credited_discount_success_only DESC;

/* selected_campaign_merchant_distribution.csv */
SELECT
    COALESCE(a.reportCat, 'Non-payment/Unknown') AS reportCat,
    COALESCE(a.reportSubCat, 'Non-payment/Unknown') AS reportSubCat,
    COALESCE(a.appName, 'Non-payment/Unknown') AS appName,
    COUNT(*) AS transaction_rows,
    COUNT(DISTINCT t.userID) AS unique_users,
    SUM(CASE WHEN t.transStatus = 1 THEN 1 ELSE 0 END) AS successful_rows,
    SUM(CAST(COALESCE(t.amount, 0) AS BIGINT)) AS total_amount,
    SUM(CASE WHEN t.transStatus = 1 THEN CAST(COALESCE(t.discountAmount, 0) AS BIGINT) ELSE 0 END) AS credited_discount_success_only
FROM #selected_campaign_transactions t
LEFT JOIN dbo.appid_info a
    ON t.appID = a.appID
GROUP BY
    COALESCE(a.reportCat, 'Non-payment/Unknown'),
    COALESCE(a.reportSubCat, 'Non-payment/Unknown'),
    COALESCE(a.appName, 'Non-payment/Unknown')
ORDER BY transaction_rows DESC;

/* selected_campaign_user_scored_features.csv */
SELECT *
FROM #abuse_scored_users
ORDER BY credited_campaign_discount_success_only DESC, userID;

/* suspicious_users_full.csv */
SELECT *
FROM #abuse_scored_users
WHERE suspicion_score >= 3
  AND reason <> ''
ORDER BY suspicion_score DESC, credited_campaign_discount_success_only DESC, userID;

/* abuse_impact_summary.csv */
SELECT
    -- E4: the honest name is total_scored_users (counts SCORED users = successful-txn, not all 90,555).
    COUNT(*) AS total_scored_users,
    COUNT(CASE WHEN suspicion_score >= 3 AND reason <> '' THEN 1 END) AS total_suspicious_users,
    CAST(COUNT(CASE WHEN suspicion_score >= 3 AND reason <> '' THEN 1 END) * 100.0 / NULLIF(COUNT(*), 0) AS DECIMAL(10,2)) AS suspicious_user_rate_pct,
    SUM(credited_campaign_discount_success_only) AS total_campaign_discount,
    SUM(CASE WHEN suspicion_score >= 3 AND reason <> '' THEN credited_campaign_discount_success_only ELSE 0 END) AS discount_used_by_suspicious_users,
    CAST(SUM(CASE WHEN suspicion_score >= 3 AND reason <> '' THEN credited_campaign_discount_success_only ELSE 0 END) * 100.0
         / NULLIF(SUM(credited_campaign_discount_success_only), 0) AS DECIMAL(10,2)) AS share_of_campaign_discount_pct
FROM #abuse_scored_users;

/* rule_simulation_summary.csv */
WITH simulated_rules AS (
    SELECT 'Block: immediate discount >= 500K within 0-1 day and discount rows >= 10' AS rule_name,
           userID, credited_campaign_discount_success_only, suspicion_score,
           CASE WHEN immediate_discount_0_1_day >= 500000 AND immediate_discount_rows_0_1_day >= 10 THEN 1 ELSE 0 END AS rule_hit
    FROM #abuse_scored_users
    UNION ALL
    SELECT 'Block: same device used by >= 10 users', userID, credited_campaign_discount_success_only, suspicion_score,
           CASE WHEN max_users_per_device >= 10 THEN 1 ELSE 0 END
    FROM #abuse_scored_users
    UNION ALL
    SELECT 'Manual review: invitees >= 20 and campaign discount >= 500K', userID, credited_campaign_discount_success_only, suspicion_score,
           CASE WHEN total_invitees >= 20 AND credited_campaign_discount_success_only >= 500000 THEN 1 ELSE 0 END
    FROM #abuse_scored_users
    UNION ALL
    SELECT 'Manual review: transfer loop exists and campaign discount >= 100K', userID, credited_campaign_discount_success_only, suspicion_score,
           CASE WHEN transfer_loop_count >= 1 AND credited_campaign_discount_success_only >= 100000 THEN 1 ELSE 0 END
    FROM #abuse_scored_users
),
rule_summary AS (
    SELECT
        rule_name,
        COUNT(DISTINCT CASE WHEN rule_hit = 1 THEN userID END) AS users_impacted,
        SUM(CASE WHEN rule_hit = 1 THEN credited_campaign_discount_success_only ELSE 0 END) AS promo_cost_at_risk_or_saved,
        COUNT(DISTINCT CASE WHEN rule_hit = 1 AND suspicion_score < 3 THEN userID END) AS low_score_users_impacted,
        CAST(COUNT(DISTINCT CASE WHEN rule_hit = 1 AND suspicion_score < 3 THEN userID END) * 100.0
             / NULLIF(COUNT(DISTINCT CASE WHEN rule_hit = 1 THEN userID END), 0) AS DECIMAL(10,2)) AS low_score_impact_pct
    FROM simulated_rules
    WHERE rule_hit = 1
    GROUP BY rule_name
)
SELECT
    rule_name,
    users_impacted,
    promo_cost_at_risk_or_saved,
    low_score_users_impacted,
    low_score_impact_pct,
    CASE
        WHEN users_impacted = 0 THEN 'No users affected'
        WHEN low_score_impact_pct >= 30 THEN 'High over-flagging risk'
        WHEN low_score_impact_pct >= 10 THEN 'Medium over-flagging risk'
        ELSE 'Lower over-flagging risk'
    END AS overflagging_risk_label
FROM rule_summary
ORDER BY promo_cost_at_risk_or_saved DESC, users_impacted DESC;

/* threshold_percentile_summary.csv */
WITH metric_values AS (
    SELECT 'credited_campaign_discount_success_only' AS metric_name, CAST(credited_campaign_discount_success_only AS FLOAT) AS metric_value FROM #abuse_user_features
    UNION ALL SELECT 'immediate_discount_0_1_day', CAST(immediate_discount_0_1_day AS FLOAT) FROM #abuse_user_features
    UNION ALL SELECT 'campaign_discount_rows', CAST(campaign_discount_rows AS FLOAT) FROM #abuse_user_features
    UNION ALL SELECT 'total_invitees', CAST(total_invitees AS FLOAT) FROM #abuse_user_features
    UNION ALL SELECT 'max_users_per_device', CAST(max_users_per_device AS FLOAT) FROM #abuse_user_features
    UNION ALL SELECT 'max_users_per_ip', CAST(max_users_per_ip AS FLOAT) FROM #abuse_user_features
    UNION ALL SELECT 'transfer_loop_count', CAST(transfer_loop_count AS FLOAT) FROM #abuse_user_features
),
percentile_calc AS (
    SELECT DISTINCT
        metric_name,
        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY metric_value) OVER (PARTITION BY metric_name) AS p50,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY metric_value) OVER (PARTITION BY metric_name) AS p75,
        PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY metric_value) OVER (PARTITION BY metric_name) AS p90,
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY metric_value) OVER (PARTITION BY metric_name) AS p95,
        PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY metric_value) OVER (PARTITION BY metric_name) AS p99
    FROM metric_values
)
SELECT
    mv.metric_name,
    COUNT(*) AS selected_campaign_users,
    CAST(MIN(mv.metric_value) AS DECIMAL(18,2)) AS min_value,
    CAST(AVG(mv.metric_value) AS DECIMAL(18,2)) AS avg_value,
    CAST(MAX(mv.metric_value) AS DECIMAL(18,2)) AS max_value,
    CAST(MAX(pc.p50) AS DECIMAL(18,2)) AS p50,
    CAST(MAX(pc.p75) AS DECIMAL(18,2)) AS p75,
    CAST(MAX(pc.p90) AS DECIMAL(18,2)) AS p90,
    CAST(MAX(pc.p95) AS DECIMAL(18,2)) AS p95,
    CAST(MAX(pc.p99) AS DECIMAL(18,2)) AS p99
FROM metric_values mv
JOIN percentile_calc pc
    ON mv.metric_name = pc.metric_name
GROUP BY mv.metric_name
ORDER BY mv.metric_name;

/* retention_weekly_summary.csv */
WITH payment_txn AS (
    SELECT DISTINCT
        userID,
        DATEADD(WEEK, DATEDIFF(WEEK, 0, reqDate), 0) AS payment_week
    FROM dbo.[transaction]
    WHERE appID > 0
      AND transStatus = 1
),
first_payment AS (
    SELECT
        userID,
        MIN(payment_week) AS cohort_week
    FROM payment_txn
    GROUP BY userID
),
cohort_activity AS (
    SELECT
        fp.cohort_week,
        p.payment_week,
        DATEDIFF(WEEK, fp.cohort_week, p.payment_week) AS week_number,
        p.userID
    FROM payment_txn p
    JOIN first_payment fp
        ON p.userID = fp.userID
),
cohort_size AS (
    SELECT
        cohort_week,
        COUNT(DISTINCT userID) AS cohort_users
    FROM cohort_activity
    WHERE week_number = 0
    GROUP BY cohort_week
)
SELECT
    ca.cohort_week,
    ca.week_number,
    cs.cohort_users,
    COUNT(DISTINCT ca.userID) AS retained_users,
    CAST(COUNT(DISTINCT ca.userID) * 100.0 / NULLIF(cs.cohort_users, 0) AS DECIMAL(10,2)) AS retention_rate_pct
FROM cohort_activity ca
JOIN cohort_size cs
    ON ca.cohort_week = cs.cohort_week
GROUP BY ca.cohort_week, ca.week_number, cs.cohort_users
ORDER BY ca.cohort_week, ca.week_number;




/* =========================================================
   Power BI export: daily suspicious vs non-suspicious split
   ========================================================= */

SELECT
    CAST(t.reqDate AS DATE) AS txn_date,

    CASE
        WHEN COALESCE(a.suspicion_score, 0) >= 3
            THEN 'Suspicious'
        ELSE 'Non-suspicious'
    END AS risk_group,

    CASE
        WHEN COALESCE(a.suspicion_score, 0) >= 9
            THEN 'High risk'
        WHEN COALESCE(a.suspicion_score, 0) >= 6
            THEN 'Medium risk'
        WHEN COALESCE(a.suspicion_score, 0) >= 3
            THEN 'Review'
        ELSE 'Lower-risk'
    END AS risk_tier_group,

    COUNT(*) AS transaction_rows,
    COUNT(DISTINCT t.userID) AS unique_users,

    SUM(CASE WHEN t.transStatus = 1 THEN 1 ELSE 0 END) AS successful_rows,

    SUM(
        CASE
            WHEN t.transStatus = 1
                THEN CAST(COALESCE(t.discountAmount, 0) AS BIGINT)
            ELSE 0
        END
    ) AS credited_discount_success_only,

    SUM(
        CASE
            WHEN t.transStatus <> 1 OR t.transStatus IS NULL
                THEN CAST(COALESCE(t.discountAmount, 0) AS BIGINT)
            ELSE 0
        END
    ) AS non_success_discount_amount

FROM #selected_campaign_transactions t
LEFT JOIN #abuse_scored_users a
    ON t.userID = a.userID

GROUP BY
    CAST(t.reqDate AS DATE),
    CASE
        WHEN COALESCE(a.suspicion_score, 0) >= 3
            THEN 'Suspicious'
        ELSE 'Non-suspicious'
    END,
    CASE
        WHEN COALESCE(a.suspicion_score, 0) >= 9
            THEN 'High risk'
        WHEN COALESCE(a.suspicion_score, 0) >= 6
            THEN 'Medium risk'
        WHEN COALESCE(a.suspicion_score, 0) >= 3
            THEN 'Review'
        ELSE 'Lower-risk'
    END

ORDER BY
    txn_date,
    risk_group,
    risk_tier_group;



/* =========================================================
   Power BI export: user-date risk table
   Purpose: allow dynamic DISTINCTCOUNT users by date range
   ========================================================= */

SELECT
    CAST(t.reqDate AS DATE) AS txn_date,
    t.userID,

    CASE
        WHEN COALESCE(a.suspicion_score, 0) >= 3
            THEN 'Suspicious'
        ELSE 'Non-suspicious'
    END AS risk_group,

    CASE
        WHEN COALESCE(a.suspicion_score, 0) >= 9
            THEN 'High risk'
        WHEN COALESCE(a.suspicion_score, 0) >= 6
            THEN 'Medium risk'
        WHEN COALESCE(a.suspicion_score, 0) >= 3
            THEN 'Review'
        ELSE 'Lower-risk'
    END AS risk_tier_group,

    SUM(
        CASE
            WHEN t.transStatus = 1
                THEN CAST(COALESCE(t.discountAmount, 0) AS BIGINT)
            ELSE 0
        END
    ) AS credited_discount_success_only,

    SUM(CASE WHEN t.transStatus = 1 THEN 1 ELSE 0 END) AS successful_rows,

    COUNT(*) AS transaction_rows

FROM #selected_campaign_transactions t
LEFT JOIN #abuse_scored_users a
    ON t.userID = a.userID

GROUP BY
    CAST(t.reqDate AS DATE),
    t.userID,
    CASE
        WHEN COALESCE(a.suspicion_score, 0) >= 3
            THEN 'Suspicious'
        ELSE 'Non-suspicious'
    END,
    CASE
        WHEN COALESCE(a.suspicion_score, 0) >= 9
            THEN 'High risk'
        WHEN COALESCE(a.suspicion_score, 0) >= 6
            THEN 'Medium risk'
        WHEN COALESCE(a.suspicion_score, 0) >= 3
            THEN 'Review'
        ELSE 'Lower-risk'
    END

ORDER BY
    txn_date,
    risk_group,
    userID;


/* =========================================================
   Power BI export: promotion_daily_summary.csv
   Purpose: make promotion performance dynamic by date slicer
   ========================================================= */

SELECT
    CAST(reqDate AS DATE) AS txn_date,
    campaignID,
    promotionName,
    promotion_type,

    COUNT(*) AS transaction_rows,
    COUNT(DISTINCT userID) AS unique_users,

    SUM(CASE WHEN transStatus = 1 THEN 1 ELSE 0 END) AS successful_rows,

    SUM(CAST(COALESCE(discountAmount, 0) AS BIGINT)) AS gross_discount_all_rows,

    SUM(
        CASE
            WHEN transStatus = 1
                THEN CAST(COALESCE(discountAmount, 0) AS BIGINT)
            ELSE 0
        END
    ) AS credited_discount_success_only,

    SUM(
        CASE
            WHEN transStatus <> 1 OR transStatus IS NULL
                THEN CAST(COALESCE(discountAmount, 0) AS BIGINT)
            ELSE 0
        END
    ) AS non_success_discount_amount

FROM #selected_campaign_transactions
GROUP BY
    CAST(reqDate AS DATE),
    campaignID,
    promotionName,
    promotion_type

ORDER BY
    txn_date,
    credited_discount_success_only DESC;



/* =========================================================
   Power BI export: merchant_daily_summary.csv
   Purpose: make merchant/category performance dynamic by date slicer
   ========================================================= */

SELECT
    CAST(t.reqDate AS DATE) AS txn_date,

    COALESCE(a.reportCat, 'Non-payment/Unknown') AS reportCat,
    COALESCE(a.reportSubCat, 'Non-payment/Unknown') AS reportSubCat,
    COALESCE(a.appName, 'Non-payment/Unknown') AS appName,

    CASE
        WHEN COALESCE(a.reportCat, 'Non-payment/Unknown') = 'Non-payment/Unknown'
            THEN 'Non-payment / reward / unknown'
        ELSE 'Payment / merchant'
    END AS payment_group,

    COUNT(*) AS transaction_rows,
    COUNT(DISTINCT t.userID) AS unique_users,

    SUM(CASE WHEN t.transStatus = 1 THEN 1 ELSE 0 END) AS successful_rows,

    SUM(CAST(COALESCE(t.amount, 0) AS BIGINT)) AS total_amount,

    SUM(
        CASE
            WHEN t.transStatus = 1
                THEN CAST(COALESCE(t.discountAmount, 0) AS BIGINT)
            ELSE 0
        END
    ) AS credited_discount_success_only,

    SUM(
        CASE
            WHEN t.transStatus <> 1 OR t.transStatus IS NULL
                THEN CAST(COALESCE(t.discountAmount, 0) AS BIGINT)
            ELSE 0
        END
    ) AS non_success_discount_amount

FROM #selected_campaign_transactions t
LEFT JOIN dbo.appid_info a
    ON t.appID = a.appID

GROUP BY
    CAST(t.reqDate AS DATE),
    COALESCE(a.reportCat, 'Non-payment/Unknown'),
    COALESCE(a.reportSubCat, 'Non-payment/Unknown'),
    COALESCE(a.appName, 'Non-payment/Unknown'),
    CASE
        WHEN COALESCE(a.reportCat, 'Non-payment/Unknown') = 'Non-payment/Unknown'
            THEN 'Non-payment / reward / unknown'
        ELSE 'Payment / merchant'
    END

ORDER BY
    txn_date,
    credited_discount_success_only DESC;



/* ============================================================
   Diagnostic-only queries (commented out).
   These were used during development to inspect the temp table and
   schema. They return EXTRA result sets, which breaks the bulk
   exporter (scripts/export_sql09_resultsets.py expects exactly 14).
   Keep them commented so 09 returns the 14 Power BI result sets only.
   Un-comment temporarily if you want to inspect them by hand.

   select *
   from #selected_campaign_transactions;

   SELECT c.name AS column_name
   FROM tempdb.sys.columns c
   WHERE c.object_id = OBJECT_ID('tempdb..#selected_campaign_transactions')
   ORDER BY c.column_id;

   SELECT COLUMN_NAME, DATA_TYPE
   FROM INFORMATION_SCHEMA.COLUMNS
   WHERE TABLE_NAME = 'campaign_info'
     AND COLUMN_NAME = 'promotionName';
   ============================================================ */