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
   - It combines multiple suspicious signals and ranks users by score.

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
   - selected_campaign_transactions already filters transStatus = 1,
     so all discount features in this file are success-only credited discount.
   ============================================================ */


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

risky_devices AS (
    SELECT
        deviceID,
        COUNT(DISTINCT userID) AS users_per_device
    FROM dbo.[transaction]
    WHERE transStatus = 1
      AND deviceID IS NOT NULL
    GROUP BY deviceID
    HAVING COUNT(DISTINCT userID) >= 5
),

user_device_signal AS (
    SELECT
        t.userID,
        MAX(rd.users_per_device) AS max_users_per_device
    FROM dbo.[transaction] t
    JOIN risky_devices rd
        ON t.deviceID = rd.deviceID
    GROUP BY
        t.userID
),

risky_ips AS (
    SELECT
        userIP,
        COUNT(DISTINCT userID) AS users_per_ip
    FROM dbo.[transaction]
    WHERE transStatus = 1
      AND userIP IS NOT NULL
    GROUP BY userIP
    HAVING COUNT(DISTINCT userID) >= 20
),

user_ip_signal AS (
    SELECT
        t.userID,
        MAX(ri.users_per_ip) AS max_users_per_ip
    FROM dbo.[transaction] t
    JOIN risky_ips ri
        ON t.userIP = ri.userIP
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
),

scored_users AS (
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

    FROM user_features
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
                THEN CONCAT('high immediate campaign discount within 0-1 day: ', immediate_discount_0_1_day, ', ')
                ELSE ''
            END,

            CASE
                WHEN credited_campaign_discount_success_only >= 500000
                THEN CONCAT('high credited campaign discount: ', credited_campaign_discount_success_only, ', ')
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

FROM reasoned_users
WHERE suspicion_score >= 3
  AND reason <> ''
ORDER BY
    suspicion_score DESC,
    credited_campaign_discount_success_only DESC,
    immediate_discount_0_1_day DESC,
    transfer_loop_count DESC,
    userID;


/* ============================================================
   Optional strict assessment output

   If the required deliverable must contain only:
       userID | reason

   You can export only those two columns from the result above,
   or uncomment and run this SELECT by wrapping the previous logic
   into a temp table / view.
   ============================================================ */
