USE zalo;
GO

/* ============================================================
   04_RELATIONSHIP_CHECK
   Purpose:
   - Check table relationships
   - Check unmatched campaignID/appID/userID
   ============================================================ */


-- ============================================================
-- 1. transaction ? campaign_info
-- ============================================================

SELECT 
    COUNT(*) AS transaction_rows,
    COUNT(c.campaignID) AS matched_campaign_rows,
    COUNT(*) - COUNT(c.campaignID) AS unmatched_campaign_rows
FROM dbo.[transaction] t
LEFT JOIN dbo.campaign_info c
    ON t.campaignID = c.campaignID;


-- Unmatched campaignID examples
SELECT TOP 50
    t.campaignID,
    COUNT(*) AS row_count
FROM dbo.[transaction] t
LEFT JOIN dbo.campaign_info c
    ON t.campaignID = c.campaignID
WHERE c.campaignID IS NULL
GROUP BY t.campaignID
ORDER BY row_count DESC;


-- ============================================================
-- 2. transaction ? appid_info
-- For payment transactions, appID > 0
-- ============================================================

SELECT 
    COUNT(*) AS payment_transaction_rows,
    COUNT(a.appID) AS matched_app_rows,
    COUNT(*) - COUNT(a.appID) AS unmatched_app_rows
FROM dbo.[transaction] t
LEFT JOIN dbo.appid_info a
    ON t.appID = a.appID
WHERE t.appID > 0;


-- Unmatched appID examples
SELECT TOP 50
    t.appID,
    COUNT(*) AS row_count
FROM dbo.[transaction] t
LEFT JOIN dbo.appid_info a
    ON t.appID = a.appID
WHERE t.appID > 0
  AND a.appID IS NULL
GROUP BY t.appID
ORDER BY row_count DESC;


-- ============================================================
-- 3. transaction ? user_profile
-- ============================================================

SELECT 
    COUNT(*) AS transaction_rows,
    COUNT(u.userID) AS matched_user_rows,
    COUNT(*) - COUNT(u.userID) AS unmatched_user_rows
FROM dbo.[transaction] t
LEFT JOIN dbo.user_profile u
    ON t.userID = u.userID;


-- ============================================================
-- 4. referral_mapcard inviter/referee ? user_profile
-- ============================================================

SELECT 
    COUNT(*) AS referral_rows,
    COUNT(inviter.userID) AS matched_inviter_rows,
    COUNT(referee.userID) AS matched_referee_rows,
    COUNT(*) - COUNT(inviter.userID) AS unmatched_inviter_rows,
    COUNT(*) - COUNT(referee.userID) AS unmatched_referee_rows
FROM dbo.referral_mapcard r
LEFT JOIN dbo.user_profile inviter
    ON r.userID = inviter.userID
LEFT JOIN dbo.user_profile referee
    ON r.refereeId = referee.userID;


-- ============================================================
-- 5. transfer sender/receiver ? user_profile
-- ============================================================

SELECT 
    COUNT(*) AS transfer_rows,
    COUNT(sender.userID) AS matched_sender_rows,
    COUNT(receiver.userID) AS matched_receiver_rows,
    COUNT(*) - COUNT(sender.userID) AS unmatched_sender_rows,
    COUNT(*) - COUNT(receiver.userID) AS unmatched_receiver_rows
FROM dbo.[transfer] tr
LEFT JOIN dbo.user_profile sender
    ON tr.sender = sender.userID
LEFT JOIN dbo.user_profile receiver
    ON tr.receiver = receiver.userID;