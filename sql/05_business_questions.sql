USE zalo;
GO

/* ============================================================
   05_BUSINESS_QUESTIONS
   Purpose:
   - Answer assessment Part 1.2
   - Top reportCat
   - First time user crossed 100K discount
   - Weekly payment retention
   ============================================================ */


-- ============================================================
-- 1.2.1
-- Top 5 reportCat by payment transactions
-- Payment transaction condition: appID > 0
-- Success rate: successful transactions / total payment transactions
-- Assumption: transStatus = 1 means successful
-- ============================================================

SELECT TOP 5
    a.reportCat,
    COUNT(*) AS total_payment_transactions,
    COUNT(DISTINCT t.userID) AS total_users,
    SUM(CASE WHEN t.transStatus = 1 THEN 1 ELSE 0 END) AS successful_transactions,
    CAST(
        SUM(CASE WHEN t.transStatus = 1 THEN 1 ELSE 0 END) * 100.0 / COUNT(*)
        AS DECIMAL(10,2)
    ) AS success_rate_pct
FROM dbo.[transaction] t
LEFT JOIN dbo.appid_info a
    ON t.appID = a.appID
WHERE t.appID > 0
GROUP BY a.reportCat
ORDER BY total_payment_transactions DESC;


-- ============================================================
-- 1.2.2
-- First time each user earned more than 100K total discount
-- Logic: cumulative discount by user ordered by reqDate
-- ============================================================

WITH user_discount_running AS (
    SELECT 
        userID,
        transID,
        reqDate,
        discountAmount,
        SUM(CAST(COALESCE(discountAmount, 0) AS BIGINT)) OVER (
            PARTITION BY userID
            ORDER BY reqDate, transID
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS creditedDiscountEarned
    FROM dbo.[transaction]
    WHERE transStatus = 1
),
crossed_100k AS (
    SELECT 
        *,
        ROW_NUMBER() OVER (
            PARTITION BY userID
            ORDER BY reqDate, transID
        ) AS rn
    FROM user_discount_running
    WHERE creditedDiscountEarned > 100000
)
SELECT 
    userID,
    transID,
    reqDate,
    creditedDiscountEarned
FROM crossed_100k
WHERE rn = 1
ORDER BY reqDate;


-- ============================================================
-- 1.2.3
-- Weekly payment retention
-- Logic:
-- 1. Keep successful payment transactions
-- 2. Find each user's first payment week
-- 3. Check whether the user paid again in later weeks
-- ============================================================

WITH payment_events AS (
    SELECT DISTINCT
        userID,
        DATEADD(WEEK, DATEDIFF(WEEK, 0, reqDate), 0) AS payment_week
    FROM dbo.[transaction]
    WHERE appID > 0
      AND transStatus = 1
),
user_cohort AS (
    SELECT 
        userID,
        MIN(payment_week) AS cohort_week
    FROM payment_events
    GROUP BY userID
),
cohort_activity AS (
    SELECT 
        c.userID,
        c.cohort_week,
        p.payment_week,
        DATEDIFF(WEEK, c.cohort_week, p.payment_week) AS week_number
    FROM user_cohort c
    JOIN payment_events p
        ON c.userID = p.userID
),
cohort_size AS (
    SELECT 
        cohort_week,
        COUNT(DISTINCT userID) AS cohort_users
    FROM user_cohort
    GROUP BY cohort_week
)
SELECT 
    ca.cohort_week,
    ca.week_number,
    cs.cohort_users,
    COUNT(DISTINCT ca.userID) AS retained_users,
    CAST(
        COUNT(DISTINCT ca.userID) * 100.0 / cs.cohort_users
        AS DECIMAL(10,2)
    ) AS retention_rate_pct
FROM cohort_activity ca
JOIN cohort_size cs
    ON ca.cohort_week = cs.cohort_week
GROUP BY 
    ca.cohort_week,
    ca.week_number,
    cs.cohort_users
ORDER BY 
    ca.cohort_week,
    ca.week_number;

