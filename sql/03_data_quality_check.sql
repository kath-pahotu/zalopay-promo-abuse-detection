USE zalo;
GO

/* ============================================================
   03_DATA_QUALITY_CHECK
   Purpose:
   - Check row counts
   - Check duplicate IDs
   - Check missing important fields
   - Check date ranges
   ============================================================ */


-- ============================================================
-- 1. Row counts
-- ============================================================

SELECT 'appid_info' AS table_name, COUNT(*) AS row_count FROM dbo.appid_info
UNION ALL
SELECT 'campaign_info', COUNT(*) FROM dbo.campaign_info
UNION ALL
SELECT 'referral_mapcard', COUNT(*) FROM dbo.referral_mapcard
UNION ALL
SELECT 'transaction', COUNT(*) FROM dbo.[transaction]
UNION ALL
SELECT 'transfer', COUNT(*) FROM dbo.[transfer]
UNION ALL
SELECT 'user_profile', COUNT(*) FROM dbo.user_profile;


-- ============================================================
-- 2. Duplicate check: transaction ID
-- ============================================================

SELECT 
    COUNT(*) AS total_rows,
    COUNT(DISTINCT transID) AS distinct_transID,
    COUNT(*) - COUNT(DISTINCT transID) AS duplicate_transID_rows
FROM dbo.[transaction];


-- View duplicated transID examples
SELECT TOP 50
    transID,
    COUNT(*) AS row_count
FROM dbo.[transaction]
GROUP BY transID
HAVING COUNT(*) > 1
ORDER BY row_count DESC;


-- ============================================================
-- 3. Duplicate check: appID and campaignID master tables
-- ============================================================

SELECT 
    COUNT(*) AS total_rows,
    COUNT(DISTINCT appID) AS distinct_appID,
    COUNT(*) - COUNT(DISTINCT appID) AS duplicate_appID_rows
FROM dbo.appid_info;


SELECT 
    COUNT(*) AS total_rows,
    COUNT(DISTINCT campaignID) AS distinct_campaignID,
    COUNT(*) - COUNT(DISTINCT campaignID) AS duplicate_campaignID_rows
FROM dbo.campaign_info;


-- ============================================================
-- 4. Basic date ranges
-- Change reqDate column name if your actual column is different.
-- ============================================================

SELECT 
    'transaction' AS table_name,
    MIN(reqDate) AS min_date,
    MAX(reqDate) AS max_date
FROM dbo.[transaction];

SELECT 
    'transfer' AS table_name,
    MIN(reqDate) AS min_date,
    MAX(reqDate) AS max_date
FROM dbo.[transfer];

SELECT 
    'referral_mapcard' AS table_name,
    MIN(reqDate) AS min_date,
    MAX(reqDate) AS max_date
FROM dbo.referral_mapcard;

SELECT 
    'user_profile' AS table_name,
    MIN(created_date) AS min_created_date,
    MAX(created_date) AS max_created_date
FROM dbo.user_profile;


-- ============================================================
-- 5. Missing-value check for important transaction fields
-- If a column name errors, check 01_table_schema_check.sql
-- and adjust the column name.
-- ============================================================

SELECT 
    COUNT(*) AS total_rows,

    SUM(CASE WHEN userID IS NULL THEN 1 ELSE 0 END) AS missing_userID,
    SUM(CASE WHEN transID IS NULL THEN 1 ELSE 0 END) AS missing_transID,
    SUM(CASE WHEN campaignID IS NULL THEN 1 ELSE 0 END) AS missing_campaignID,
    SUM(CASE WHEN appID IS NULL THEN 1 ELSE 0 END) AS missing_appID,
    SUM(CASE WHEN deviceID IS NULL THEN 1 ELSE 0 END) AS missing_deviceID,
    SUM(CASE WHEN userIP IS NULL THEN 1 ELSE 0 END) AS missing_userIP
FROM dbo.[transaction];


-- ============================================================
-- 6. Transaction status distribution
-- ============================================================

SELECT 
    transStatus,
    COUNT(*) AS row_count,
    CAST(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER () AS DECIMAL(10,2)) AS pct
FROM dbo.[transaction]
GROUP BY transStatus
ORDER BY row_count DESC;


-- ============================================================
-- 7. Campaign code distribution
-- ============================================================

SELECT TOP 20
    c.campaignCode,
    COUNT(*) AS transaction_rows,
    COUNT(DISTINCT t.userID) AS unique_users,

    -- Gross discount shown in source rows, including failed / non-success rows.
    SUM(CAST(COALESCE(t.discountAmount, 0) AS BIGINT)) AS gross_discount_all_rows,

    -- Main promo-cost metric: discount from successful rows only.
    SUM(
        CASE
            WHEN t.transStatus = 1
            THEN CAST(COALESCE(t.discountAmount, 0) AS BIGINT)
            ELSE 0
        END
    ) AS credited_discount_success_only,

    -- Diagnostic field: discount amount attached to failed / non-success rows.
    SUM(
        CASE
            WHEN t.transStatus <> 1 OR t.transStatus IS NULL
            THEN CAST(COALESCE(t.discountAmount, 0) AS BIGINT)
            ELSE 0
        END
    ) AS non_success_discount_amount
FROM dbo.[transaction] t
LEFT JOIN dbo.campaign_info c
    ON t.campaignID = c.campaignID
GROUP BY c.campaignCode
ORDER BY transaction_rows DESC;