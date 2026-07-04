USE zalo;
GO

/* ============================================================
   08_ABUSE_DETECTION_RULES_FINAL_FIXED

   Purpose:
   - Final suspicious-user detection for selected campaign:
       campaignCode = ZPI_220801_115
   - This file comes AFTER:
       06_CAMPAIGN_DISCOVERY_SCAN
       07_SELECTED_CAMPAIGN_DEEP_DIVE
   - It builds user-level risk features, validates thresholds with
     percentiles, applies rule-based scoring, summarizes business
     impact, and simulates possible prevention/review rules.

   Output:
   - Full review output:
       userID, suspicion_score, risk_tier, signal metrics, reason

   For strict assessment result.xlsx:
   - Export only:
       userID, reason

   Important:
   - This is rule-based suspicious-user detection.
   - It should be interpreted as "users requiring risk review",
     not confirmed fraud labels.
   - selected_campaign_transactions filters transStatus = 1,
     so all discount features in this file are success-only credited discount.
   ============================================================ */


/* ============================================================
   A. Build selected-campaign user features

   Signals created:
   - campaign discount
   - immediate discount after account creation
   - referral count
   - shared device/IP exposure
   - transfer loop signal

   This temp table contains raw user behavior features only.
   Scoring is applied later after the percentile support check.
   ============================================================ */

DROP TABLE IF EXISTS #abuse_user_features;

WITH selected_campaign_transactions AS (
    SELECT
        t.*
    FROM dbo.[transaction] t
    JOIN dbo.campaign_info c
        ON t.campaignID = c.campaignID
    WHERE c.campaignCode = 'ZPI_220801_115'
      AND t.transStatus = 1
),

selected_campaign_users AS (
    SELECT DISTINCT
        userID
    FROM selected_campaign_transactions
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
    FROM selected_campaign_transactions
    GROUP BY
        userID
),

immediate_discount AS (
    SELECT
        sct.userID,

        SUM(
            CASE
                WHEN DATEDIFF(DAY, u.created_date, sct.reqDate) BETWEEN 0 AND 1
                THEN CAST(COALESCE(sct.discountAmount, 0) AS BIGINT)
                ELSE 0
            END
        ) AS immediate_discount_0_1_day,

        SUM(
            CASE
                WHEN COALESCE(sct.discountAmount, 0) > 0
                     AND DATEDIFF(DAY, u.created_date, sct.reqDate) BETWEEN 0 AND 1
                THEN 1 ELSE 0
            END
        ) AS immediate_discount_rows_0_1_day,

        COUNT(DISTINCT
            CASE
                WHEN COALESCE(sct.discountAmount, 0) > 0
                     AND DATEDIFF(DAY, u.created_date, sct.reqDate) BETWEEN 0 AND 1
                THEN sct.transID
            END
        ) AS distinct_immediate_discount_transactions_0_1_day,

        MIN(
            CASE
                WHEN COALESCE(sct.discountAmount, 0) > 0
                     AND DATEDIFF(DAY, u.created_date, sct.reqDate) BETWEEN 0 AND 1
                THEN sct.reqDate
            END
        ) AS first_immediate_discount_time,

        MAX(
            CASE
                WHEN COALESCE(sct.discountAmount, 0) > 0
                     AND DATEDIFF(DAY, u.created_date, sct.reqDate) BETWEEN 0 AND 1
                THEN sct.reqDate
            END
        ) AS last_immediate_discount_time

    FROM selected_campaign_transactions sct
    JOIN dbo.user_profile u
        ON sct.userID = u.userID
    GROUP BY
        sct.userID
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
    GROUP BY
        t.userID
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
    GROUP BY
        t.userID
),

successful_transfers AS (
    SELECT
        sender,
        receiver,
        amount,
        reqDate,
        transID
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
),

user_features AS (
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

    FROM selected_campaign_users scu
    LEFT JOIN campaign_discount cd
        ON scu.userID = cd.userID
    LEFT JOIN immediate_discount id
        ON scu.userID = id.userID
    LEFT JOIN referral_summary rs
        ON scu.userID = rs.userID
    LEFT JOIN user_device_signal uds
        ON scu.userID = uds.userID
    LEFT JOIN user_ip_signal uis
        ON scu.userID = uis.userID
    LEFT JOIN transfer_loop_users tlu
        ON scu.userID = tlu.userID
)

SELECT
    *
INTO #abuse_user_features
FROM user_features;


/* ============================================================
   B. Percentile-based threshold support

   Purpose:
   - Check P50/P75/P90/P95/P99 for each risk feature.
   - Explain why the thresholds used in scoring are reasonable.

   Interpretation examples from the current campaign:
   - credited discount 100K/500K/1M maps to above-normal/high/extreme users.
   - 20 invitees is around the 99th percentile.
   - 5+ users per device is above the 99th percentile.
   ============================================================ */

WITH metric_values AS (
    SELECT
        'credited_campaign_discount_success_only' AS metric_name,
        CAST(credited_campaign_discount_success_only AS FLOAT) AS metric_value
    FROM #abuse_user_features

    UNION ALL

    SELECT
        'immediate_discount_0_1_day',
        CAST(immediate_discount_0_1_day AS FLOAT)
    FROM #abuse_user_features

    UNION ALL

    SELECT
        'campaign_discount_rows',
        CAST(campaign_discount_rows AS FLOAT)
    FROM #abuse_user_features

    UNION ALL

    SELECT
        'total_invitees',
        CAST(total_invitees AS FLOAT)
    FROM #abuse_user_features

    UNION ALL

    SELECT
        'max_users_per_device',
        CAST(max_users_per_device AS FLOAT)
    FROM #abuse_user_features

    UNION ALL

    SELECT
        'max_users_per_ip',
        CAST(max_users_per_ip AS FLOAT)
    FROM #abuse_user_features

    UNION ALL

    SELECT
        'transfer_loop_count',
        CAST(transfer_loop_count AS FLOAT)
    FROM #abuse_user_features
),

percentile_calc AS (
    SELECT DISTINCT
        metric_name,

        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY metric_value)
            OVER (PARTITION BY metric_name) AS p50,

        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY metric_value)
            OVER (PARTITION BY metric_name) AS p75,

        PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY metric_value)
            OVER (PARTITION BY metric_name) AS p90,

        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY metric_value)
            OVER (PARTITION BY metric_name) AS p95,

        PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY metric_value)
            OVER (PARTITION BY metric_name) AS p99

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
GROUP BY
    mv.metric_name
ORDER BY
    mv.metric_name;


/* ============================================================
   C. Final scoring output

   Purpose:
   - Apply threshold rules to the raw user features.
   - Calculate suspicion_score.
   - Create reason text for manual review.

   Threshold rationale:
   - credited_campaign_discount_success_only:
       100K is above normal behavior, 500K is high, 1M is extreme.
   - immediate_discount_0_1_day:
       500K is near top-percentile fast reward extraction, 1M is extreme.
   - total_invitees:
       20 invitees is around the 99th percentile, 100 is extreme.
   - max_users_per_device:
       5+ users per device is above the 99th percentile.
   - max_users_per_ip:
       20+ users per IP is around the 95th percentile.
   - transfer_loop_count:
       1+ loop is a supporting signal, 3+ loops is stronger.
   ============================================================ */

DROP TABLE IF EXISTS #abuse_scored_users;

WITH scored_users AS (
    SELECT
        *,

        CASE
            WHEN immediate_discount_0_1_day >= 1000000 THEN 3
            WHEN immediate_discount_0_1_day >= 500000
                 AND immediate_discount_rows_0_1_day >= 10 THEN 2
            ELSE 0
        END AS score_immediate_discount,

        CASE
            WHEN credited_campaign_discount_success_only >= 1000000 THEN 3
            WHEN credited_campaign_discount_success_only >= 500000 THEN 2
            WHEN credited_campaign_discount_success_only >= 100000 THEN 1
            ELSE 0
        END AS score_credited_discount,

        CASE
            WHEN total_invitees >= 100 THEN 3
            WHEN total_invitees >= 20 THEN 2
            ELSE 0
        END AS score_referral,

        CASE
            WHEN max_users_per_device >= 10 THEN 2
            WHEN max_users_per_device >= 5 THEN 1
            ELSE 0
        END AS score_device,

        CASE
            WHEN max_users_per_ip >= 50 THEN 2
            WHEN max_users_per_ip >= 20 THEN 1
            ELSE 0
        END AS score_ip,

        CASE
            WHEN transfer_loop_count >= 3 THEN 2
            WHEN transfer_loop_count >= 1 THEN 1
            ELSE 0
        END AS score_transfer_loop

    FROM #abuse_user_features
),

final_scored_users AS (
    SELECT
        *,

        (
            score_immediate_discount
            + score_credited_discount
            + score_referral
            + score_device
            + score_ip
            + score_transfer_loop
        ) AS suspicion_score,

        CASE
            WHEN (
                score_immediate_discount
                + score_credited_discount
                + score_referral
                + score_device
                + score_ip
                + score_transfer_loop
            ) >= 9 THEN 'High risk'
            WHEN (
                score_immediate_discount
                + score_credited_discount
                + score_referral
                + score_device
                + score_ip
                + score_transfer_loop
            ) >= 6 THEN 'Medium risk'
            ELSE 'Review'
        END AS risk_tier

    FROM scored_users
),

reasoned_users AS (
    SELECT
        userID,
        suspicion_score,
        risk_tier,

        credited_campaign_discount_success_only,
        campaign_rows,
        campaign_discount_rows,
        distinct_campaign_transactions,
        first_campaign_time,
        last_campaign_time,

        immediate_discount_0_1_day,
        immediate_discount_rows_0_1_day,
        distinct_immediate_discount_transactions_0_1_day,
        first_immediate_discount_time,
        last_immediate_discount_time,

        total_invitees,
        first_invite_time,
        last_invite_time,

        max_users_per_device,
        max_users_per_ip,
        transfer_loop_count,

        score_immediate_discount,
        score_credited_discount,
        score_referral,
        score_device,
        score_ip,
        score_transfer_loop,

        CONCAT(
            CASE
                WHEN immediate_discount_0_1_day >= 1000000
                  OR (
                      immediate_discount_0_1_day >= 500000
                      AND immediate_discount_rows_0_1_day >= 10
                  )
                THEN CONCAT('high immediate campaign discount within 0-1 day: ', immediate_discount_0_1_day, ', ')
                ELSE ''
            END,

            CASE
                WHEN credited_campaign_discount_success_only >= 500000
                THEN CONCAT('high credited campaign discount: ', credited_campaign_discount_success_only, ', ')
                WHEN credited_campaign_discount_success_only >= 100000
                THEN CONCAT('elevated credited campaign discount: ', credited_campaign_discount_success_only, ', ')
                ELSE ''
            END,

            CASE
                WHEN total_invitees >= 20
                THEN CONCAT('high referral count: ', total_invitees, ', ')
                ELSE ''
            END,

            CASE
                WHEN max_users_per_device >= 5
                THEN CONCAT('shared device used by ', max_users_per_device, ' users, ')
                ELSE ''
            END,

            CASE
                WHEN max_users_per_ip >= 20
                THEN CONCAT('shared IP used by ', max_users_per_ip, ' users, ')
                ELSE ''
            END,

            CASE
                WHEN transfer_loop_count >= 1
                THEN CONCAT('involved in transfer loop: ', transfer_loop_count, ' loop signals, ')
                ELSE ''
            END
        ) AS reason

    FROM final_scored_users
)

SELECT
    *
INTO #abuse_scored_users
FROM reasoned_users;

SELECT
    userID,
    suspicion_score,
    risk_tier,

    credited_campaign_discount_success_only,
    campaign_rows,
    campaign_discount_rows,
    distinct_campaign_transactions,

    immediate_discount_0_1_day,
    immediate_discount_rows_0_1_day,
    distinct_immediate_discount_transactions_0_1_day,

    total_invitees,
    max_users_per_device,
    max_users_per_ip,
    transfer_loop_count,

    score_immediate_discount,
    score_credited_discount,
    score_referral,
    score_device,
    score_ip,
    score_transfer_loop,

    first_campaign_time,
    last_campaign_time,
    first_immediate_discount_time,
    last_immediate_discount_time,
    first_invite_time,
    last_invite_time,

    reason
FROM #abuse_scored_users
WHERE suspicion_score >= 3
  AND reason <> ''
ORDER BY
    suspicion_score DESC,
    credited_campaign_discount_success_only DESC,
    immediate_discount_0_1_day DESC,
    transfer_loop_count DESC,
    userID;


/* ============================================================
   D. Campaign impact summary

   Purpose:
   - Summarize suspicious users and discount exposure.
   - Translate the user-level review list into business impact.
   ============================================================ */

SELECT
    COUNT(*) AS total_campaign_users,

    COUNT(CASE WHEN suspicion_score >= 3 AND reason <> '' THEN 1 END) AS total_suspicious_users,

    CAST(
        COUNT(CASE WHEN suspicion_score >= 3 AND reason <> '' THEN 1 END) * 100.0
        / NULLIF(COUNT(*), 0)
        AS DECIMAL(10,2)
    ) AS suspicious_user_rate_pct,

    SUM(credited_campaign_discount_success_only) AS total_campaign_discount,

    SUM(
        CASE
            WHEN suspicion_score >= 3 AND reason <> ''
            THEN credited_campaign_discount_success_only
            ELSE 0
        END
    ) AS discount_used_by_suspicious_users,

    CAST(
        SUM(
            CASE
                WHEN suspicion_score >= 3 AND reason <> ''
                THEN credited_campaign_discount_success_only
                ELSE 0
            END
        ) * 100.0
        / NULLIF(SUM(credited_campaign_discount_success_only), 0)
        AS DECIMAL(10,2)
    ) AS share_of_campaign_discount_pct
FROM #abuse_scored_users;

SELECT
    risk_tier,
    COUNT(*) AS users_in_tier,
    SUM(credited_campaign_discount_success_only) AS credited_discount_in_tier,
    AVG(CAST(suspicion_score AS DECIMAL(10,2))) AS avg_suspicion_score
FROM #abuse_scored_users
WHERE suspicion_score >= 3
  AND reason <> ''
GROUP BY
    risk_tier
ORDER BY
    CASE risk_tier
        WHEN 'High risk' THEN 1
        WHEN 'Medium risk' THEN 2
        ELSE 3
    END;


/* ============================================================
   E. Rule simulation

   Purpose:
   - Test what happens if the business applies possible prevention
     or manual-review rules.
   - Estimate rule coverage, promo cost at risk, and a rough
     over-flagging proxy.

   Note:
   - promo_cost_at_risk_or_saved is not guaranteed real savings.
     It means credited campaign discount attached to users hit by the rule.
   - low_score_users_impacted counts rule-hit users with suspicion_score < 3. This is not a confirmed count of incorrectly flagged users.
   ============================================================ */

WITH simulated_rules AS (
    SELECT
        'Block: immediate discount >= 500K within 0-1 day and discount rows >= 10' AS rule_name,
        userID,
        credited_campaign_discount_success_only,
        suspicion_score,
        CASE
            WHEN immediate_discount_0_1_day >= 500000
             AND immediate_discount_rows_0_1_day >= 10
            THEN 1 ELSE 0
        END AS rule_hit
    FROM #abuse_scored_users

    UNION ALL

    SELECT
        'Block: same device used by >= 10 users',
        userID,
        credited_campaign_discount_success_only,
        suspicion_score,
        CASE
            WHEN max_users_per_device >= 10
            THEN 1 ELSE 0
        END AS rule_hit
    FROM #abuse_scored_users

    UNION ALL

    SELECT
        'Manual review: invitees >= 20 and campaign discount >= 500K',
        userID,
        credited_campaign_discount_success_only,
        suspicion_score,
        CASE
            WHEN total_invitees >= 20
             AND credited_campaign_discount_success_only >= 500000
            THEN 1 ELSE 0
        END AS rule_hit
    FROM #abuse_scored_users

    UNION ALL

    SELECT
        'Manual review: transfer loop exists and campaign discount >= 100K',
        userID,
        credited_campaign_discount_success_only,
        suspicion_score,
        CASE
            WHEN transfer_loop_count >= 1
             AND credited_campaign_discount_success_only >= 100000
            THEN 1 ELSE 0
        END AS rule_hit
    FROM #abuse_scored_users
)

SELECT
    rule_name,

    COUNT(DISTINCT CASE WHEN rule_hit = 1 THEN userID END) AS users_impacted,

    SUM(
        CASE
            WHEN rule_hit = 1
            THEN credited_campaign_discount_success_only
            ELSE 0
        END
    ) AS promo_cost_at_risk_or_saved,

    COUNT(DISTINCT
        CASE
            WHEN rule_hit = 1
             AND suspicion_score < 3
            THEN userID
        END
    ) AS low_score_users_impacted,

    CAST(
        COUNT(DISTINCT
            CASE
                WHEN rule_hit = 1
                 AND suspicion_score < 3
                THEN userID
            END
        ) * 100.0
        / NULLIF(COUNT(DISTINCT CASE WHEN rule_hit = 1 THEN userID END), 0)
        AS DECIMAL(10,2)
    ) AS low_score_impact_pct,

    CASE
        WHEN COUNT(DISTINCT CASE WHEN rule_hit = 1 THEN userID END) = 0
        THEN 'No users affected'

        WHEN
            COUNT(DISTINCT
                CASE
                    WHEN rule_hit = 1
                     AND suspicion_score < 3
                    THEN userID
                END
            ) * 100.0
            / NULLIF(COUNT(DISTINCT CASE WHEN rule_hit = 1 THEN userID END), 0)
            >= 30
        THEN 'High over-flagging risk'

        WHEN
            COUNT(DISTINCT
                CASE
                    WHEN rule_hit = 1
                     AND suspicion_score < 3
                    THEN userID
                END
            ) * 100.0
            / NULLIF(COUNT(DISTINCT CASE WHEN rule_hit = 1 THEN userID END), 0)
            >= 10
        THEN 'Medium over-flagging risk'

        ELSE 'Lower over-flagging risk'
    END AS overflagging_risk_label

FROM simulated_rules
WHERE rule_hit = 1
GROUP BY
    rule_name
ORDER BY
    promo_cost_at_risk_or_saved DESC,
    users_impacted DESC;


/* ============================================================
   Optional strict assessment output

   If the required deliverable must contain only:
       userID | reason

   Export only these two columns from #abuse_scored_users:

   SELECT
       userID,
       reason
   FROM #abuse_scored_users
   WHERE suspicion_score >= 3
     AND reason <> ''
   ORDER BY
       suspicion_score DESC,
       credited_campaign_discount_success_only DESC;
   ============================================================ */
