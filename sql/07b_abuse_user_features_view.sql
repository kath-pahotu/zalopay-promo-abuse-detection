USE zalo;
GO

/* ============================================================
   07b_ABUSE_USER_FEATURES_VIEW  (single source of truth)

   Purpose:
   - Build the user-level abuse feature table for campaign
     ZPI_220801_115 in ONE place, so 08 (scoring) and 09
     (Power BI export) both consume the same definition and
     cannot drift apart.

   Run order:
       00 ... 07  ->  07b (this file, creates the view)
                  ->  08_abuse_detection_rules_final.sql
                  ->  09_powerbi_export_queries.sql

   Notes:
   - All discount features are success-only (transStatus = 1).
   - REVIEW FIX (E1): transfer_loop_count is now the number of
     DISTINCT reciprocal counterparties a user loops with, not
     the raw count of self-joined transfer rows. The old logic
     produced a cross-product (max 500,057) because heavy
     reciprocal partners transfer hundreds of times; the top
     pair alone generated up to 866 x 363 joined rows. Counting
     distinct partners makes the feature bounded and meaningful:
       transfer_loop_count = 0  -> no reciprocal loop
       transfer_loop_count = 1  -> loops with 1 partner
       transfer_loop_count >= 3 -> loops with 3+ partners
   ============================================================ */

CREATE OR ALTER VIEW dbo.vw_abuse_user_features AS
WITH selected_campaign_transactions AS (
    SELECT t.*
    FROM dbo.[transaction] t
    JOIN dbo.campaign_info c
        ON t.campaignID = c.campaignID
    WHERE c.campaignCode = 'ZPI_220801_115'
      AND t.transStatus = 1
),
selected_campaign_users AS (
    SELECT DISTINCT userID
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
    FROM selected_campaign_transactions sct
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
    SELECT deviceID, COUNT(DISTINCT userID) AS users_per_device
    FROM dbo.[transaction]
    WHERE transStatus = 1 AND deviceID IS NOT NULL
    GROUP BY deviceID
),
user_device_signal AS (
    SELECT t.userID, MAX(duc.users_per_device) AS max_users_per_device
    FROM dbo.[transaction] t
    JOIN device_user_count duc ON t.deviceID = duc.deviceID
    GROUP BY t.userID
),
ip_user_count AS (
    SELECT userIP, COUNT(DISTINCT userID) AS users_per_ip
    FROM dbo.[transaction]
    WHERE transStatus = 1 AND userIP IS NOT NULL
    GROUP BY userIP
),
user_ip_signal AS (
    SELECT t.userID, MAX(iuc.users_per_ip) AS max_users_per_ip
    FROM dbo.[transaction] t
    JOIN ip_user_count iuc ON t.userIP = iuc.userIP
    GROUP BY t.userID
),
successful_transfers AS (
    SELECT sender, receiver, amount, reqDate, transID
    FROM dbo.[transfer]
    WHERE transStatus = 1
),
/* FIX (E1): reduce each reciprocal pair to ONE distinct ordered pair
   BEFORE counting, so a pair that transfers back and forth many times
   is a single loop relationship, not hundreds of self-joined rows. */
transfer_loop_pairs AS (
    SELECT DISTINCT
        a.sender   AS user_a,
        a.receiver AS user_b
    FROM successful_transfers a
    JOIN successful_transfers b
        ON a.sender   = b.receiver
       AND a.receiver = b.sender
       AND b.reqDate > a.reqDate
       AND DATEDIFF(MINUTE, a.reqDate, b.reqDate) BETWEEN 0 AND 60
),
transfer_loop_users AS (
    SELECT userID, COUNT(DISTINCT counterpart) AS transfer_loop_count
    FROM (
        SELECT user_a AS userID, user_b AS counterpart FROM transfer_loop_pairs
        UNION
        SELECT user_b AS userID, user_a AS counterpart FROM transfer_loop_pairs
    ) loop_edges
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
FROM selected_campaign_users scu
LEFT JOIN campaign_discount cd    ON scu.userID = cd.userID
LEFT JOIN immediate_discount id   ON scu.userID = id.userID
LEFT JOIN referral_summary rs     ON scu.userID = rs.userID
LEFT JOIN user_device_signal uds  ON scu.userID = uds.userID
LEFT JOIN user_ip_signal uis      ON scu.userID = uis.userID
LEFT JOIN transfer_loop_users tlu ON scu.userID = tlu.userID;
GO
