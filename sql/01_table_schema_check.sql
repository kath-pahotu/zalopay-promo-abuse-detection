USE zalo;
GO

/* ============================================================
   01_TABLE_SCHEMA_CHECK
   Purpose:
   - Show column names
   - Show data types
   - Show nullable columns
   - Understand table grain
   ============================================================ */

SELECT 
    TABLE_NAME,
    ORDINAL_POSITION,
    COLUMN_NAME,
    DATA_TYPE,
    CHARACTER_MAXIMUM_LENGTH,
    NUMERIC_PRECISION,
    NUMERIC_SCALE,
    IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo'
ORDER BY 
    TABLE_NAME,
    ORDINAL_POSITION;



