USE zalo;
GO

/* ============================================================
   07_SELECTED_CAMPAIGN_DEEP_DIVE_FIXED

   Purpose:
   - Deep dive into campaignCode = ZPI_220801_115.

   Discount metric standard:
   - gross_discount_all_rows = discountAmount from all rows.
   - credited_discount_success_only = discountAmount from transStatus = 1 only.
   - non_success_discount_amount = discountAmount from failed / non-success rows.
   - Use credited_discount_success_only as the main business promo-cost metric.
   ============================================================ */


/* ============================================================
   1. Selected campaign overview
   ============================================================ */

WITH selected_campaign_txn AS (
    SELECT
        t.*,
        c.campaignCode,
        c.promotionName,
        c.promotion_type
    FROM dbo.[transaction] t
    JOIN dbo.campaign_info c
        ON t.campaignID = c.campaignID
    WHERE c.campaignCode = 'ZPI_220801_115'
)

SELECT
    campaignCode,
    COUNT(*) AS transaction_rows,
    COUNT(DISTINCT userID) AS unique_users,
    COUNT(DISTINCT campaignID) AS campaign_id_count,

    SUM(CASE WHEN appID > 0 THEN 1 ELSE 0 END) AS payment_rows,
    SUM(CASE WHEN transStatus = 1 THEN 1 ELSE 0 END) AS successful_rows,

    CAST(
        SUM(CASE WHEN transStatus = 1 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)
        AS DECIMAL(10,2)
    ) AS success_rate_pct,

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
    ) AS non_success_discount_amount,

    MIN(reqDate) AS first_seen,
    MAX(reqDate) AS last_seen

FROM selected_campaign_txn
GROUP BY campaignCode;


/* ============================================================
   2. Promotion-level breakdown inside selected campaign
   ============================================================ */

WITH selected_campaign_txn AS (
    SELECT
        t.*,
        c.campaignCode,
        c.promotionName,
        c.promotion_type
    FROM dbo.[transaction] t
    JOIN dbo.campaign_info c
        ON t.campaignID = c.campaignID
    WHERE c.campaignCode = 'ZPI_220801_115'
)

SELECT TOP 50
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
FROM selected_campaign_txn
GROUP BY
    campaignID,
    promotionName,
    promotion_type
ORDER BY
    credited_discount_success_only DESC;


/* ============================================================
   3. Daily campaign trend
   ============================================================ */

WITH selected_campaign_txn AS (
    SELECT
        t.*,
        c.campaignCode
    FROM dbo.[transaction] t
    JOIN dbo.campaign_info c
        ON t.campaignID = c.campaignID
    WHERE c.campaignCode = 'ZPI_220801_115'
)

SELECT
    CAST(reqDate AS DATE) AS txn_date,
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
FROM selected_campaign_txn
GROUP BY
    CAST(reqDate AS DATE)
ORDER BY
    txn_date;


/* ============================================================
   4. Top users by selected-campaign discount
   Logic: success-only because this is user-level credited promo value.
   ============================================================ */

WITH selected_campaign_txn AS (
    SELECT
        t.*,
        c.campaignCode
    FROM dbo.[transaction] t
    JOIN dbo.campaign_info c
        ON t.campaignID = c.campaignID
    WHERE c.campaignCode = 'ZPI_220801_115'
      AND t.transStatus = 1
)

SELECT TOP 100
    userID,
    COUNT(*) AS successful_campaign_rows,
    COUNT(DISTINCT transID) AS distinct_successful_transactions,
    SUM(CAST(COALESCE(discountAmount, 0) AS BIGINT)) AS credited_campaign_discount_success_only,
    MIN(reqDate) AS first_campaign_time,
    MAX(reqDate) AS last_campaign_time
FROM selected_campaign_txn
GROUP BY
    userID
ORDER BY
    credited_campaign_discount_success_only DESC;


/* ============================================================
   5. New-account immediate discount behavior
   Logic: success-only because this checks immediate credited promo extraction.
   ============================================================ */

WITH selected_campaign_txn AS (
    SELECT
        t.*,
        c.campaignCode
    FROM dbo.[transaction] t
    JOIN dbo.campaign_info c
        ON t.campaignID = c.campaignID
    WHERE c.campaignCode = 'ZPI_220801_115'
      AND t.transStatus = 1
),

user_discount_timing AS (
    SELECT
        sct.userID,
        u.created_date,

        MIN(sct.reqDate) AS first_campaign_transaction_time,
        DATEDIFF(DAY, u.created_date, MIN(sct.reqDate)) AS days_to_first_campaign_txn,

        SUM(CAST(COALESCE(sct.discountAmount, 0) AS BIGINT)) AS credited_campaign_discount_success_only,

        SUM(
            CASE
                WHEN DATEDIFF(DAY, u.created_date, sct.reqDate) BETWEEN 0 AND 1
                THEN CAST(COALESCE(sct.discountAmount, 0) AS BIGINT)
                ELSE 0
            END
        ) AS credited_immediate_discount_0_1_day,

        SUM(
            CASE
                WHEN COALESCE(sct.discountAmount, 0) > 0
                     AND DATEDIFF(DAY, u.created_date, sct.reqDate) BETWEEN 0 AND 1
                THEN 1 ELSE 0
            END
        ) AS immediate_discount_rows_0_1_day

    FROM selected_campaign_txn sct
    JOIN dbo.user_profile u
        ON sct.userID = u.userID
    GROUP BY
        sct.userID,
        u.created_date
)

SELECT TOP 100
    userID,
    created_date,
    first_campaign_transaction_time,
    days_to_first_campaign_txn,
    credited_campaign_discount_success_only,
    credited_immediate_discount_0_1_day,
    immediate_discount_rows_0_1_day
FROM user_discount_timing
WHERE days_to_first_campaign_txn BETWEEN 0 AND 1
ORDER BY
    credited_immediate_discount_0_1_day DESC,
    credited_campaign_discount_success_only DESC;


/* ============================================================
   6. Referral behavior of selected-campaign users
   No discount metric here. Keep as-is.
   ============================================================ */

WITH selected_campaign_users AS (
    SELECT DISTINCT
        t.userID
    FROM dbo.[transaction] t
    JOIN dbo.campaign_info c
        ON t.campaignID = c.campaignID
    WHERE c.campaignCode = 'ZPI_220801_115'
      AND t.transStatus = 1
)

SELECT TOP 100
    r.userID AS inviter_userID,
    COUNT(DISTINCT r.refereeId) AS total_invitees,
    MIN(r.reqDate) AS first_invite_time,
    MAX(r.reqDate) AS last_invite_time
FROM dbo.referral_mapcard r
JOIN selected_campaign_users scu
    ON r.userID = scu.userID
GROUP BY
    r.userID
ORDER BY
    total_invitees DESC;


/* ============================================================
   7. Shared device / IP signals among selected-campaign users
   No discount metric here. Keep as supporting signals.
   ============================================================ */

WITH selected_campaign_users AS (
    SELECT DISTINCT
        t.userID
    FROM dbo.[transaction] t
    JOIN dbo.campaign_info c
        ON t.campaignID = c.campaignID
    WHERE c.campaignCode = 'ZPI_220801_115'
      AND t.transStatus = 1
),

device_summary AS (
    SELECT
        t.deviceID,
        COUNT(DISTINCT t.userID) AS users_per_device
    FROM dbo.[transaction] t
    WHERE t.transStatus = 1
      AND t.deviceID IS NOT NULL
    GROUP BY t.deviceID
)

SELECT TOP 100
    t.deviceID,
    ds.users_per_device,
    COUNT(DISTINCT t.userID) AS selected_campaign_users_on_device
FROM dbo.[transaction] t
JOIN selected_campaign_users scu
    ON t.userID = scu.userID
JOIN device_summary ds
    ON t.deviceID = ds.deviceID
WHERE t.transStatus = 1
  AND t.deviceID IS NOT NULL
  AND ds.users_per_device >= 5
GROUP BY
    t.deviceID,
    ds.users_per_device
ORDER BY
    ds.users_per_device DESC;


WITH selected_campaign_users AS (
    SELECT DISTINCT
        t.userID
    FROM dbo.[transaction] t
    JOIN dbo.campaign_info c
        ON t.campaignID = c.campaignID
    WHERE c.campaignCode = 'ZPI_220801_115'
      AND t.transStatus = 1
),

ip_summary AS (
    SELECT
        t.userIP,
        COUNT(DISTINCT t.userID) AS users_per_ip
    FROM dbo.[transaction] t
    WHERE t.transStatus = 1
      AND t.userIP IS NOT NULL
    GROUP BY t.userIP
)

SELECT TOP 100
    t.userIP,
    ips.users_per_ip,
    COUNT(DISTINCT t.userID) AS selected_campaign_users_on_ip
FROM dbo.[transaction] t
JOIN selected_campaign_users scu
    ON t.userID = scu.userID
JOIN ip_summary ips
    ON t.userIP = ips.userIP
WHERE t.transStatus = 1
  AND t.userIP IS NOT NULL
  AND ips.users_per_ip >= 20
GROUP BY
    t.userIP,
    ips.users_per_ip
ORDER BY
    ips.users_per_ip DESC;
