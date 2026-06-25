USE zalo;
GO

/* ============================================================
   00_DATABASE_OVERVIEW
   Purpose:
   - Check current database
   - Check all tables
   - Check row counts
   - Check table size
   ============================================================ */

-- 1. Confirm current database
SELECT 
    DB_NAME() AS current_database,
    @@SERVERNAME AS server_name,
    GETDATE() AS checked_at;


-- 2. List all user tables
SELECT 
    s.name AS schema_name,
    t.name AS table_name,
    t.create_date,
    t.modify_date
FROM sys.tables t
JOIN sys.schemas s
    ON t.schema_id = s.schema_id
ORDER BY t.name;


-- 3. Row count for each table
SELECT 
    s.name AS schema_name,
    t.name AS table_name,
    SUM(p.rows) AS row_count
FROM sys.tables t
JOIN sys.schemas s
    ON t.schema_id = s.schema_id
JOIN sys.partitions p
    ON t.object_id = p.object_id
WHERE p.index_id IN (0, 1)
GROUP BY 
    s.name,
    t.name
ORDER BY row_count DESC;


-- 4. Table size overview
SELECT 
    t.name AS table_name,
    SUM(p.rows) AS row_count,
    CAST(SUM(a.total_pages) * 8.0 / 1024 AS DECIMAL(18,2)) AS total_size_mb,
    CAST(SUM(a.used_pages) * 8.0 / 1024 AS DECIMAL(18,2)) AS used_size_mb
FROM sys.tables t
JOIN sys.indexes i
    ON t.object_id = i.object_id
JOIN sys.partitions p
    ON i.object_id = p.object_id 
   AND i.index_id = p.index_id
JOIN sys.allocation_units a
    ON p.partition_id = a.container_id
GROUP BY t.name
ORDER BY total_size_mb DESC;