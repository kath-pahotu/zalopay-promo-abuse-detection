USE zalo;
GO

/* ============================================================
   06_CAMPAIGN_DISCOVERY_SCAN_FIXED

   Purpose:
   - Broad scan across all campaigns before choosing a deep-dive campaign.
   - Identify campaigns that stand out by volume, users, success-only promo cost,
     and early suspicious signals.

   Discount metric standard:
   - gross_discount_all_rows = discountAmount from all rows.
   - credited_discount_success_only = discountAmount from transStatus = 1 only.
   - non_success_discount_amount = discountAmount from failed / non-success rows.
   - Use credited_discount_success_only as the main business promo-cost metric.
   ============================================================ */


/* ============================================================
   1. Campaign overview and ranking
   ============================================================ */

WITH campaign_summary AS (
    SELECT
        c.campaignCode,
        COUNT(DISTINCT c.campaignID) AS campaign_id_count,
        COUNT(*) AS transaction_rows,
        COUNT(DISTINCT t.userID) AS unique_users,

        SUM(CASE WHEN t.appID > 0 THEN 1 ELSE 0 END) AS payment_rows,
        SUM(CASE WHEN t.transStatus = 1 THEN 1 ELSE 0 END) AS successful_rows,

        CAST(
            SUM(CASE WHEN t.transStatus = 1 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)
            AS DECIMAL(10,2)
        ) AS success_rate_pct,

        SUM(CAST(COALESCE(t.discountAmount, 0) AS BIGINT)) AS gross_discount_all_rows,

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
        ) AS non_success_discount_amount,

        MIN(t.reqDate) AS first_seen,
        MAX(t.reqDate) AS last_seen
    FROM dbo.[transaction] t
    JOIN dbo.campaign_info c
        ON t.campaignID = c.campaignID
    GROUP BY
        c.campaignCode
),

ranked_campaigns AS (
    SELECT
        *,
        RANK() OVER (ORDER BY credited_discount_success_only DESC) AS discount_rank,
        RANK() OVER (ORDER BY transaction_rows DESC) AS transaction_rank,
        RANK() OVER (ORDER BY unique_users DESC) AS user_rank
    FROM campaign_summary
)

SELECT TOP 50
    campaignCode,
    campaign_id_count,
    transaction_rows,
    unique_users,
    payment_rows,
    successful_rows,
    success_rate_pct,
    gross_discount_all_rows,
    credited_discount_success_only,
    non_success_discount_amount,
    discount_rank,
    transaction_rank,
    user_rank,
    first_seen,
    last_seen
FROM ranked_campaigns
ORDER BY
    discount_rank,
    transaction_rank,
    user_rank;


/* ============================================================
   2. Campaign-level suspicious signal scan
   ============================================================ */

WITH campaign_user_discount AS (
    SELECT
        c.campaignCode,
        t.userID,
        SUM(CAST(COALESCE(t.discountAmount, 0) AS BIGINT)) AS user_credited_campaign_discount,
        COUNT(*) AS user_successful_campaign_rows,
        COUNT(DISTINCT t.transID) AS distinct_successful_campaign_transactions
    FROM dbo.[transaction] t
    JOIN dbo.campaign_info c
        ON t.campaignID = c.campaignID
    WHERE t.transStatus = 1
    GROUP BY
        c.campaignCode,
        t.userID
),

referral_summary AS (
    SELECT
        userID,
        COUNT(DISTINCT refereeId) AS total_invitees
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

device_users AS (
    SELECT DISTINCT
        t.userID
    FROM dbo.[transaction] t
    JOIN risky_devices rd
        ON t.deviceID = rd.deviceID
    WHERE t.transStatus = 1
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

ip_users AS (
    SELECT DISTINCT
        t.userID
    FROM dbo.[transaction] t
    JOIN risky_ips ri
        ON t.userIP = ri.userIP
    WHERE t.transStatus = 1
)

SELECT TOP 50
    cud.campaignCode,
    COUNT(DISTINCT cud.userID) AS unique_users,
    SUM(cud.user_credited_campaign_discount) AS credited_discount_success_only,

    SUM(CASE WHEN cud.user_credited_campaign_discount >= 100000 THEN 1 ELSE 0 END) AS users_discount_100k_plus,
    SUM(CASE WHEN cud.user_credited_campaign_discount >= 500000 THEN 1 ELSE 0 END) AS users_discount_500k_plus,
    SUM(CASE WHEN cud.user_credited_campaign_discount >= 1000000 THEN 1 ELSE 0 END) AS users_discount_1m_plus,

    CAST(
        SUM(CASE WHEN cud.user_credited_campaign_discount >= 500000 THEN 1 ELSE 0 END) * 100.0
        / COUNT(DISTINCT cud.userID)
        AS DECIMAL(10,2)
    ) AS pct_users_500k_plus,

    SUM(CASE WHEN COALESCE(rs.total_invitees, 0) >= 20 THEN 1 ELSE 0 END) AS users_high_referral_20_plus,
    SUM(CASE WHEN du.userID IS NOT NULL THEN 1 ELSE 0 END) AS users_with_shared_device_signal,
    SUM(CASE WHEN iu.userID IS NOT NULL THEN 1 ELSE 0 END) AS users_with_shared_ip_signal

FROM campaign_user_discount cud
LEFT JOIN referral_summary rs
    ON cud.userID = rs.userID
LEFT JOIN device_users du
    ON cud.userID = du.userID
LEFT JOIN ip_users iu
    ON cud.userID = iu.userID
GROUP BY
    cud.campaignCode
ORDER BY
    credited_discount_success_only DESC;


/* ============================================================
   3. Campaign priority score
   ============================================================ */

WITH campaign_user_discount AS (
    SELECT
        c.campaignCode,
        t.userID,
        SUM(CAST(COALESCE(t.discountAmount, 0) AS BIGINT)) AS user_credited_campaign_discount
    FROM dbo.[transaction] t
    JOIN dbo.campaign_info c
        ON t.campaignID = c.campaignID
    WHERE t.transStatus = 1
    GROUP BY
        c.campaignCode,
        t.userID
),

campaign_metrics AS (
    SELECT
        c.campaignCode,
        COUNT(*) AS transaction_rows,
        COUNT(DISTINCT t.userID) AS unique_users,

        SUM(CAST(COALESCE(t.discountAmount, 0) AS BIGINT)) AS gross_discount_all_rows,

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
    FROM dbo.[transaction] t
    JOIN dbo.campaign_info c
        ON t.campaignID = c.campaignID
    GROUP BY
        c.campaignCode
),

campaign_signal_metrics AS (
    SELECT
        campaignCode,
        SUM(CASE WHEN user_credited_campaign_discount >= 500000 THEN 1 ELSE 0 END) AS users_discount_500k_plus,
        SUM(CASE WHEN user_credited_campaign_discount >= 1000000 THEN 1 ELSE 0 END) AS users_discount_1m_plus
    FROM campaign_user_discount
    GROUP BY campaignCode
),

ranked AS (
    SELECT
        cm.campaignCode,
        cm.transaction_rows,
        cm.unique_users,
        cm.gross_discount_all_rows,
        cm.credited_discount_success_only,
        cm.non_success_discount_amount,
        COALESCE(csm.users_discount_500k_plus, 0) AS users_discount_500k_plus,
        COALESCE(csm.users_discount_1m_plus, 0) AS users_discount_1m_plus,

        RANK() OVER (ORDER BY cm.credited_discount_success_only DESC) AS discount_rank,
        RANK() OVER (ORDER BY cm.transaction_rows DESC) AS transaction_rank,
        RANK() OVER (ORDER BY cm.unique_users DESC) AS user_rank
    FROM campaign_metrics cm
    LEFT JOIN campaign_signal_metrics csm
        ON cm.campaignCode = csm.campaignCode
)

SELECT TOP 30
    campaignCode,
    transaction_rows,
    unique_users,
    gross_discount_all_rows,
    credited_discount_success_only,
    non_success_discount_amount,
    users_discount_500k_plus,
    users_discount_1m_plus,
    discount_rank,
    transaction_rank,
    user_rank,

    (
        CASE WHEN discount_rank <= 5 THEN 3 WHEN discount_rank <= 10 THEN 2 ELSE 0 END
        + CASE WHEN transaction_rank <= 5 THEN 3 WHEN transaction_rank <= 10 THEN 2 ELSE 0 END
        + CASE WHEN user_rank <= 5 THEN 3 WHEN user_rank <= 10 THEN 2 ELSE 0 END
        + CASE WHEN users_discount_1m_plus > 0 THEN 3 ELSE 0 END
        + CASE WHEN users_discount_500k_plus >= 10 THEN 2 ELSE 0 END
    ) AS campaign_priority_score

FROM ranked
ORDER BY
    campaign_priority_score DESC,
    credited_discount_success_only DESC;


/* ============================================================
   4. Promotion-name breakdown across campaigns
   ============================================================ */

SELECT TOP 50
    c.campaignCode,
    t.campaignID,
    c.promotionName,
    c.promotion_type,
    COUNT(*) AS transaction_rows,
    COUNT(DISTINCT t.userID) AS unique_users,
    SUM(CASE WHEN t.transStatus = 1 THEN 1 ELSE 0 END) AS successful_rows,

    SUM(CAST(COALESCE(t.discountAmount, 0) AS BIGINT)) AS gross_discount_all_rows,

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
FROM dbo.[transaction] t
JOIN dbo.campaign_info c
    ON t.campaignID = c.campaignID
GROUP BY
    c.campaignCode,
    t.campaignID,
    c.promotionName,
    c.promotion_type
ORDER BY
    credited_discount_success_only DESC;
