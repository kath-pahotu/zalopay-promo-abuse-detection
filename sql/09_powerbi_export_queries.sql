USE zalo;
GO

/* ============================================================
   09_POWERBI_EXPORT_QUERIES

   Purpose:
   - Create Power BI-ready result sets for campaign abuse analysis.
   - Export each SELECT result to CSV files in data/output/ using SSMS,
     Azure Data Studio, bcp, or scripts/export_powerbi_outputs.py.

   Privacy:
   - Public version does not output real userID values.
   - User-level exports use user_key generated from a stable rank.

   Output CSV mapping:
   1. campaign_overview.csv
   2. campaign_daily_summary.csv
   3. campaign_promotion_breakdown.csv
   4. selected_campaign_merchant_distribution.csv
   5. selected_campaign_user_scored_features.csv
   6. suspicious_users_full.csv
   7. abuse_impact_summary.csv
   8. rule_simulation_summary.csv
   9. threshold_percentile_summary.csv
   10. retention_weekly_summary.csv
   ============================================================ */

DECLARE @CampaignCode VARCHAR(50) = 'ZPI_220801_115';

DROP TABLE IF EXISTS #selected_campaign_transactions;
DROP TABLE IF EXISTS #abuse_user_features;
DROP TABLE IF EXISTS #abuse_scored_users;
DROP TABLE IF EXISTS #user_export_keys;

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

/* Same logic as the private SQL; userID is used internally only. */
WITH selected_campaign_success AS (
    SELECT *
    FROM #selected_campaign_transactions
    WHERE transStatus = 1
),
selected_campaign_users AS (
    SELECT DISTINCT userID
    FROM selected_campaign_success
),
campaign_discount AS (
    SELECT
        userID,
        SUM(CAST(COALESCE(discountAmount, 0) AS BIGINT)) AS credited_campaign_discount_success_only,
        COUNT(*) AS campaign_rows,
        SUM(CASE WHEN COALESCE(discountAmount, 0) > 0 THEN 1 ELSE 0 END) AS campaign_discount_rows,
        COUNT(DISTINCT transID) AS distinct_campaign_transactions,
        MIN(reqDate) AS first_campaign_time,
        MAX(reqDate) AS last_campaign_time
    FROM selected_campaign_success
    GROUP BY userID
),
immediate_discount AS (
    SELECT
        sct.userID,
        SUM(CASE WHEN DATEDIFF(DAY, u.created_date, sct.reqDate) BETWEEN 0 AND 1
                 THEN CAST(COALESCE(sct.discountAmount, 0) AS BIGINT) ELSE 0 END) AS immediate_discount_0_1_day,
        SUM(CASE WHEN COALESCE(sct.discountAmount, 0) > 0
                  AND DATEDIFF(DAY, u.created_date, sct.reqDate) BETWEEN 0 AND 1
                 THEN 1 ELSE 0 END) AS immediate_discount_rows_0_1_day,
        COUNT(DISTINCT CASE WHEN COALESCE(sct.discountAmount, 0) > 0
                              AND DATEDIFF(DAY, u.created_date, sct.reqDate) BETWEEN 0 AND 1
                            THEN sct.transID END) AS distinct_immediate_discount_transactions_0_1_day,
        MIN(CASE WHEN COALESCE(sct.discountAmount, 0) > 0
                   AND DATEDIFF(DAY, u.created_date, sct.reqDate) BETWEEN 0 AND 1
                 THEN sct.reqDate END) AS first_immediate_discount_time,
        MAX(CASE WHEN COALESCE(sct.discountAmount, 0) > 0
                   AND DATEDIFF(DAY, u.created_date, sct.reqDate) BETWEEN 0 AND 1
                 THEN sct.reqDate END) AS last_immediate_discount_time
    FROM selected_campaign_success sct
    JOIN dbo.user_profile u
        ON sct.userID = u.userID
    GROUP BY sct.userID
),
referral_summary AS (
    SELECT
        userID,
        COUNT(DISTINCT refereeId) AS total_invitees,
        MIN(reqDate) AS first_invite_time,
        MAX(reqDate) AS last_invite_time
    FROM dbo.referral_mapcard
    GROUP BY userID
),
device_user_count AS (
    SELECT
        deviceID,
        COUNT(DISTINCT userID) AS users_per_device
    FROM dbo.[transaction]
    WHERE transStatus = 1
      AND deviceID IS NOT NULL
    GROUP BY deviceID
),
user_device_signal AS (
    SELECT
        t.userID,
        MAX(duc.users_per_device) AS max_users_per_device
    FROM dbo.[transaction] t
    JOIN device_user_count duc
        ON t.deviceID = duc.deviceID
    GROUP BY t.userID
),
ip_user_count AS (
    SELECT
        userIP,
        COUNT(DISTINCT userID) AS users_per_ip
    FROM dbo.[transaction]
    WHERE transStatus = 1
      AND userIP IS NOT NULL
    GROUP BY userIP
),
user_ip_signal AS (
    SELECT
        t.userID,
        MAX(iuc.users_per_ip) AS max_users_per_ip
    FROM dbo.[transaction] t
    JOIN ip_user_count iuc
        ON t.userIP = iuc.userIP
    GROUP BY t.userID
),
successful_transfers AS (
    SELECT sender, receiver, amount, reqDate, transID
    FROM dbo.[transfer]
    WHERE transStatus = 1
),
transfer_loop_pairs AS (
    SELECT DISTINCT
        a.sender AS user_a,
        a.receiver AS user_b,
        a.reqDate AS time_a_to_b,
        b.reqDate AS time_b_to_a,
        DATEDIFF(MINUTE, a.reqDate, b.reqDate) AS minutes_between
    FROM successful_transfers a
    JOIN successful_transfers b
        ON a.sender = b.receiver
       AND a.receiver = b.sender
       AND b.reqDate > a.reqDate
       AND DATEDIFF(MINUTE, a.reqDate, b.reqDate) BETWEEN 0 AND 60
),
transfer_loop_user_raw AS (
    SELECT user_a AS userID FROM transfer_loop_pairs
    UNION ALL
    SELECT user_b AS userID FROM transfer_loop_pairs
),
transfer_loop_users AS (
    SELECT
        userID,
        COUNT(*) AS transfer_loop_count
    FROM transfer_loop_user_raw
    GROUP BY userID
)
SELECT
    scu.userID,
    COALESCE(cd.credited_campaign_discount_success_only, 0) AS credited_campaign_discount_success_only,
    COALESCE(cd.campaign_rows, 0) AS campaign_rows,
    COALESCE(cd.campaign_discount_rows, 0) AS campaign_discount_rows,
    COALESCE(cd.distinct_campaign_transactions, 0) AS distinct_campaign_transactions,
    cd.first_campaign_time,
    cd.last_campaign_time,
    COALESCE(id.immediate_discount_0_1_day, 0) AS immediate_discount_0_1_day,
    COALESCE(id.immediate_discount_rows_0_1_day, 0) AS immediate_discount_rows_0_1_day,
    COALESCE(id.distinct_immediate_discount_transactions_0_1_day, 0) AS distinct_immediate_discount_transactions_0_1_day,
    id.first_immediate_discount_time,
    id.last_immediate_discount_time,
    COALESCE(rs.total_invitees, 0) AS total_invitees,
    rs.first_invite_time,
    rs.last_invite_time,
    COALESCE(uds.max_users_per_device, 0) AS max_users_per_device,
    COALESCE(uis.max_users_per_ip, 0) AS max_users_per_ip,
    COALESCE(tlu.transfer_loop_count, 0) AS transfer_loop_count
INTO #abuse_user_features
FROM selected_campaign_users scu
LEFT JOIN campaign_discount cd ON scu.userID = cd.userID
LEFT JOIN immediate_discount id ON scu.userID = id.userID
LEFT JOIN referral_summary rs ON scu.userID = rs.userID
LEFT JOIN user_device_signal uds ON scu.userID = uds.userID
LEFT JOIN user_ip_signal uis ON scu.userID = uis.userID
LEFT JOIN transfer_loop_users tlu ON scu.userID = tlu.userID;

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
    CASE WHEN suspicion_score >= 9 THEN 'High risk'
         WHEN suspicion_score >= 6 THEN 'Medium risk'
         ELSE 'Review' END AS risk_tier,
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
             THEN CONCAT('involved in transfer loop: ', transfer_loop_count, ' loop signals, ') ELSE '' END
    ) AS reason
INTO #abuse_scored_users
FROM final_scored_users;

SELECT
    userID,
    CONCAT('user_', RIGHT('000000' + CAST(DENSE_RANK() OVER (ORDER BY userID) AS VARCHAR(6)), 6)) AS user_key
INTO #user_export_keys
FROM #abuse_scored_users;

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
SELECT
    k.user_key,
    s.suspicion_score,
    s.risk_tier,
    s.credited_campaign_discount_success_only,
    s.campaign_rows,
    s.campaign_discount_rows,
    s.distinct_campaign_transactions,
    s.immediate_discount_0_1_day,
    s.immediate_discount_rows_0_1_day,
    s.distinct_immediate_discount_transactions_0_1_day,
    s.total_invitees,
    s.max_users_per_device,
    s.max_users_per_ip,
    s.transfer_loop_count,
    s.score_immediate_discount,
    s.score_credited_discount,
    s.score_referral,
    s.score_device,
    s.score_ip,
    s.score_transfer_loop,
    s.first_campaign_time,
    s.last_campaign_time,
    s.first_immediate_discount_time,
    s.last_immediate_discount_time,
    s.first_invite_time,
    s.last_invite_time,
    s.reason
FROM #abuse_scored_users s
JOIN #user_export_keys k
    ON s.userID = k.userID
ORDER BY s.credited_campaign_discount_success_only DESC, k.user_key;

/* suspicious_users_full.csv */
SELECT
    k.user_key,
    s.suspicion_score,
    s.risk_tier,
    s.credited_campaign_discount_success_only,
    s.campaign_rows,
    s.campaign_discount_rows,
    s.distinct_campaign_transactions,
    s.immediate_discount_0_1_day,
    s.immediate_discount_rows_0_1_day,
    s.distinct_immediate_discount_transactions_0_1_day,
    s.total_invitees,
    s.max_users_per_device,
    s.max_users_per_ip,
    s.transfer_loop_count,
    s.score_immediate_discount,
    s.score_credited_discount,
    s.score_referral,
    s.score_device,
    s.score_ip,
    s.score_transfer_loop,
    s.first_campaign_time,
    s.last_campaign_time,
    s.first_immediate_discount_time,
    s.last_immediate_discount_time,
    s.first_invite_time,
    s.last_invite_time,
    s.reason
FROM #abuse_scored_users s
JOIN #user_export_keys k
    ON s.userID = k.userID
WHERE s.suspicion_score >= 3
  AND s.reason <> ''
ORDER BY s.suspicion_score DESC, s.credited_campaign_discount_success_only DESC, k.user_key;

/* abuse_impact_summary.csv */
SELECT
    COUNT(*) AS total_campaign_users,
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
