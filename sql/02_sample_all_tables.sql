USE zalo;
GO

/* ============================================================
   02_SAMPLE_ALL_TABLES
   Purpose:
   - View top rows from each table
   - Understand actual values
   ============================================================ */

SELECT TOP 20 *
FROM dbo.appid_info;

SELECT TOP 20 *
FROM dbo.campaign_info;

SELECT TOP 20 *
FROM dbo.referral_mapcard;

SELECT TOP 50 *
FROM dbo.[transaction];

SELECT TOP 20 *
FROM dbo.[transfer];

SELECT TOP 20 *
FROM dbo.user_profile;

