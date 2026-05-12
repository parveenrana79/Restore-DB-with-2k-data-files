--The core comparison query
--This pulls file structure from both databases and shows them side-by-side. Run on the same server where both DBs live:

SET NOCOUNT ON;

-- Pull from source DB
IF OBJECT_ID('tempdb..#Source') IS NOT NULL DROP TABLE #Source;
SELECT
    fg.name           AS filegroup_name,
    mf.name           AS logical_name,
    mf.physical_name,
    mf.[type_desc],
    mf.state_desc,
    mf.size           AS size_pages,
    mf.is_read_only
INTO #Source
FROM AA_Test_FG.sys.database_files mf
LEFT JOIN AA_Test_FG.sys.filegroups fg ON fg.data_space_id = mf.data_space_id;

-- Pull from restored DB
IF OBJECT_ID('tempdb..#Restored') IS NOT NULL DROP TABLE #Restored;
SELECT
    fg.name           AS filegroup_name,
    mf.name           AS logical_name,
    mf.physical_name,
    mf.[type_desc],
    mf.state_desc,
    mf.size           AS size_pages,
    mf.is_read_only
INTO #Restored
FROM AAFG_RESTORE_TEST.sys.database_files mf
LEFT JOIN AAFG_RESTORE_TEST.sys.filegroups fg ON fg.data_space_id = mf.data_space_id;
--Check 1: Top-line counts match?

SELECT 'Source'   AS db, COUNT(*) AS total_files,
       SUM(CASE WHEN type_desc = 'ROWS' THEN 1 ELSE 0 END) AS data_files,
       SUM(CASE WHEN type_desc = 'LOG'  THEN 1 ELSE 0 END) AS log_files,
       COUNT(DISTINCT filegroup_name) AS filegroup_count
FROM #Source
UNION ALL
SELECT 'Restored', COUNT(*),
       SUM(CASE WHEN type_desc = 'ROWS' THEN 1 ELSE 0 END),
       SUM(CASE WHEN type_desc = 'LOG'  THEN 1 ELSE 0 END),
       COUNT(DISTINCT filegroup_name)
FROM #Restored;

--Both rows must be identical except for db name. If counts differ, you missed a filegroup somewhere — stop and investigate.
--Check 2: Logical names — anything missing or extra?
-- In source but not in restored = missed during restore

SELECT 'MISSING IN RESTORED' AS issue, filegroup_name, logical_name
FROM #Source
WHERE logical_name NOT IN (SELECT logical_name FROM #Restored)

UNION ALL

-- In restored but not in source = extra (shouldn't happen)
SELECT 'EXTRA IN RESTORED', filegroup_name, logical_name
FROM #Restored
WHERE logical_name NOT IN (SELECT logical_name FROM #Source);

--Expected result: zero rows. Any output here is a real problem.
--Check 3: Filegroup-to-file mapping consistency
--For each logical name, does it belong to the same filegroup in both DBs? This catches the worst-case scenario where a file got restored but assigned to the wrong filegroup:

SELECT
    s.logical_name,
    s.filegroup_name AS source_fg,
    r.filegroup_name AS restored_fg
FROM #Source s
JOIN #Restored r ON r.logical_name = s.logical_name
WHERE ISNULL(s.filegroup_name, '<NULL>') <> ISNULL(r.filegroup_name, '<NULL>');

--Expected: zero rows.
--Check 4: Multi-file filegroups — file count per filegroup matches?
--Specifically validates that your high-volume days (fg_11May2026 with 3 files, fg_23May2026 with 2) restored with the right number of files:

SELECT
    ISNULL(s.filegroup_name, r.filegroup_name) AS filegroup_name,
    s.source_file_count,
    r.restored_file_count,
    CASE
        WHEN s.source_file_count = r.restored_file_count THEN 'MATCH'
        ELSE 'MISMATCH ***'
    END AS status
FROM (
    SELECT filegroup_name, COUNT(*) AS source_file_count
    FROM #Source
    WHERE type_desc = 'ROWS'
    GROUP BY filegroup_name
) s
FULL OUTER JOIN (
    SELECT filegroup_name, COUNT(*) AS restored_file_count
    FROM #Restored
    WHERE type_desc = 'ROWS'
    GROUP BY filegroup_name
) r ON r.filegroup_name = s.filegroup_name
WHERE ISNULL(s.source_file_count, -1) <> ISNULL(r.restored_file_count, -1)
   OR s.filegroup_name IS NULL
   OR r.filegroup_name IS NULL;

--Expected: zero rows. Any mismatch = filegroup has the wrong number of files.
--For prod, also run this without the WHERE filter to get a full per-filegroup count comparison — handy for visual inspection on the high-volume days specifically:

SELECT s.filegroup_name, s.source_file_count, r.restored_file_count
FROM (SELECT filegroup_name, COUNT(*) source_file_count   FROM #Source   WHERE type_desc = 'ROWS' GROUP BY filegroup_name) s
JOIN (SELECT filegroup_name, COUNT(*) restored_file_count FROM #Restored WHERE type_desc = 'ROWS' GROUP BY filegroup_name) r
  ON r.filegroup_name = s.filegroup_name
WHERE s.source_file_count > 1   -- only multi-file FGs
ORDER BY s.filegroup_name;

--Check 5: Filegroup state — everything online?

SELECT
    filegroup_name,
    logical_name,
    state_desc
FROM #Restored
WHERE state_desc <> 'ONLINE'
ORDER BY filegroup_name;

--Expected: zero rows. Any RECOVERY_PENDING or OFFLINE files mean those filegroups didn't fully restore. (If you intentionally skipped some filegroups during piecemeal restore, those would show up here and that's fine — but for a full restore of all filegroups, nothing should appear.)
--Check 6: Physical path comparison
--This is where the comparison gets interesting since both DBs are on the same server — the restored one must have different paths (you can't have two databases pointing at the same .mdf). The check is that the relative structure matches even though the absolute paths differ:

-- Define your base paths

DECLARE @SourceBase   nvarchar(260) = 'C:\SQLDBA\AAFG_Restore\';
DECLARE @RestoredBase nvarchar(260) = 'C:\SQLDBA\AAFG_Restore_Test\';  -- whatever you used

SELECT
    s.logical_name,
    s.physical_name AS source_path,
    r.physical_name AS restored_path,
    CASE
        WHEN REPLACE(s.physical_name, @SourceBase, '') =
             REPLACE(r.physical_name, @RestoredBase, '')
        THEN 'STRUCTURE_MATCH'
        ELSE 'STRUCTURE_MISMATCH ***'
    END AS status
FROM #Source s
JOIN #Restored r ON r.logical_name = s.logical_name
WHERE REPLACE(s.physical_name, @SourceBase, '') <>
      REPLACE(r.physical_name, @RestoredBase, '');

--Expected: zero rows (meaning every file has the same path relative to its base). If you restored to the same path as source (which would mean you renamed the source DB first), use the same base for both.
--Check 7: Database is actually usable
--Three quick functional tests:

-- 7a: Database is fully online and accessible
SELECT name, state_desc, recovery_model_desc, user_access_desc
FROM sys.databases
WHERE name IN ('AA_Test_FG', 'AAFG_RESTORE_TEST');
-- Both should be ONLINE, MULTI_USER

-- 7b: Can read system catalogs in restored DB
USE AAFG_RESTORE_TEST;
SELECT COUNT(*) AS table_count FROM sys.tables;
-- Should match source DB's table count

---- 7c: Physical consistency check on each online filegroup

--DECLARE @fg sysname;
--DECLARE fg_cursor CURSOR LOCAL FAST_FORWARD FOR
--    SELECT DISTINCT fg.name
--    FROM sys.filegroups fg
--    JOIN sys.master_files mf ON mf.data_space_id = fg.data_space_id
--    WHERE mf.database_id = DB_ID() AND mf.state_desc = 'ONLINE';
--OPEN fg_cursor;
--FETCH NEXT FROM fg_cursor INTO @fg;
--WHILE @@FETCH_STATUS = 0
--BEGIN
--    PRINT 'Checking filegroup: ' + @fg;
--    DBCC CHECKFILEGROUP (@fg) WITH PHYSICAL_ONLY, NO_INFOMSGS;
--    FETCH NEXT FROM fg_cursor INTO @fg;
--END
--CLOSE fg_cursor;
--DEALLOCATE fg_cursor;

--On sample (~30 filegroups) this runs in seconds. On prod (~2,601 filegroups) it'll take noticeably longer — PHYSICAL_ONLY keeps it tolerable. If you have time and the I/O budget, drop PHYSICAL_ONLY for a full logical check, 
--but for a daily-restored DR copy PHYSICAL_ONLY is the right tradeoff.
--Optional Check 8: Row-level data spot check
--If your source DB has actual data (your sample creation script didn't populate any), pick 3-5 filegroups and compare row counts of any partitioned tables. For prod this is probably the strongest single signal that the restore worked:

-- Run in source
SELECT
    p.partition_number,
    fg.name AS filegroup_name,
    p.rows
FROM sys.partitions p
JOIN sys.allocation_units au ON au.container_id = p.partition_id
JOIN sys.filegroups fg       ON fg.data_space_id = au.data_space_id
WHERE p.object_id = OBJECT_ID('dbo.YourPartitionedTable')
ORDER BY p.partition_number;

-- Compare to the same query in restored DB
--Suggested order to run

--Run Checks 1-2 first (counts and missing files). If either fails, fix before continuing.
--Run Checks 3-5 to validate structure.
--Run Check 6 to validate physical layout.
--Run Check 7 to confirm usability.
--Optional: Check 8 if you have real data.

--For your sample DB right now (no data, ~30 filegroups), Checks 1-7 should all return zero problem rows within a couple of seconds. If they do, your restore approach is fundamentally sound and you can confidently scale to the 2,600-filegroup prod restore.


------------

SET NOCOUNT ON;

DECLARE @SourceDB   sysname = 'AA_Test_FG';
DECLARE @RestoredDB sysname = 'AAFG_RESTORE_TEST';

-- Pull source
IF OBJECT_ID('tempdb..#Source') IS NOT NULL DROP TABLE #Source;
SELECT
    fg.name           AS filegroup_name,
    mf.name           AS logical_name,
    mf.physical_name,
    mf.type_desc      AS file_type,
    mf.size * 8       AS size_kb,
    mf.state_desc
INTO #Source
FROM AA_Test_FG.sys.database_files mf
LEFT JOIN AA_Test_FG.sys.filegroups fg ON fg.data_space_id = mf.data_space_id;

-- Pull restored
IF OBJECT_ID('tempdb..#Restored') IS NOT NULL DROP TABLE #Restored;
SELECT
    fg.name           AS filegroup_name,
    mf.name           AS logical_name,
    mf.physical_name,
    mf.type_desc      AS file_type,
    mf.size * 8       AS size_kb,
    mf.state_desc
INTO #Restored
FROM AAFG_RESTORE_TEST.sys.database_files mf
LEFT JOIN AAFG_RESTORE_TEST.sys.filegroups fg ON fg.data_space_id = mf.data_space_id;

-- Side-by-side comparison with status
SELECT
    ISNULL(s.logical_name, r.logical_name)                AS logical_name,

    ISNULL(s.filegroup_name, '<missing>')                 AS source_filegroup,
    ISNULL(r.filegroup_name, '<missing>')                 AS restored_filegroup,

    ISNULL(s.file_type, '<missing>')                      AS source_file_type,
    ISNULL(r.file_type, '<missing>')                      AS restored_file_type,

    ISNULL(CAST(s.size_kb AS varchar(20)), '<missing>')   AS source_size_kb,
    ISNULL(CAST(r.size_kb AS varchar(20)), '<missing>')   AS restored_size_kb,

    ISNULL(s.physical_name, '<missing>')                  AS source_physical_path,
    ISNULL(r.physical_name, '<missing>')                  AS restored_physical_path,

    ISNULL(s.state_desc, '<missing>')                     AS source_state,
    ISNULL(r.state_desc, '<missing>')                     AS restored_state,

    CASE
        WHEN s.logical_name IS NULL
            THEN 'NOT GOOD - extra file in restored DB'
        WHEN r.logical_name IS NULL
            THEN 'NOT GOOD - missing in restored DB'
        WHEN ISNULL(s.filegroup_name, '') <> ISNULL(r.filegroup_name, '')
            THEN 'NOT GOOD - filegroup mismatch'
        WHEN s.file_type <> r.file_type
            THEN 'NOT GOOD - file type mismatch'
        WHEN r.state_desc <> 'ONLINE'
            THEN 'NOT GOOD - restored file not ONLINE (' + r.state_desc + ')'
        WHEN s.size_kb <> r.size_kb
            THEN 'WARNING - size differs (acceptable if DB grew)'
        ELSE 'GOOD'
    END AS status

FROM #Source s
FULL OUTER JOIN #Restored r
    ON r.logical_name = s.logical_name

ORDER BY
    CASE WHEN ISNULL(s.filegroup_name, r.filegroup_name) = 'PRIMARY' THEN 0 ELSE 1 END,
    ISNULL(s.filegroup_name, r.filegroup_name),
    ISNULL(s.logical_name, r.logical_name);

	-------------------------------------Quick filter to just see problems

;WITH Comparison AS (
    -- ... entire SELECT from above ...
	
-- Side-by-side comparison with status
SELECT
    ISNULL(s.logical_name, r.logical_name)                AS logical_name,

    ISNULL(s.filegroup_name, '<missing>')                 AS source_filegroup,
    ISNULL(r.filegroup_name, '<missing>')                 AS restored_filegroup,

    ISNULL(s.file_type, '<missing>')                      AS source_file_type,
    ISNULL(r.file_type, '<missing>')                      AS restored_file_type,

    ISNULL(CAST(s.size_kb AS varchar(20)), '<missing>')   AS source_size_kb,
    ISNULL(CAST(r.size_kb AS varchar(20)), '<missing>')   AS restored_size_kb,

    ISNULL(s.physical_name, '<missing>')                  AS source_physical_path,
    ISNULL(r.physical_name, '<missing>')                  AS restored_physical_path,

    ISNULL(s.state_desc, '<missing>')                     AS source_state,
    ISNULL(r.state_desc, '<missing>')                     AS restored_state,

    CASE
        WHEN s.logical_name IS NULL
            THEN 'NOT GOOD - extra file in restored DB'
        WHEN r.logical_name IS NULL
            THEN 'NOT GOOD - missing in restored DB'
        WHEN ISNULL(s.filegroup_name, '') <> ISNULL(r.filegroup_name, '')
            THEN 'NOT GOOD - filegroup mismatch'
        WHEN s.file_type <> r.file_type
            THEN 'NOT GOOD - file type mismatch'
        WHEN r.state_desc <> 'ONLINE'
            THEN 'NOT GOOD - restored file not ONLINE (' + r.state_desc + ')'
        WHEN s.size_kb <> r.size_kb
            THEN 'WARNING - size differs (acceptable if DB grew)'
        ELSE 'GOOD'
    END AS status

FROM #Source s
FULL OUTER JOIN #Restored r
    ON r.logical_name = s.logical_name

)
SELECT *
FROM Comparison
WHERE status <> 'GOOD'
ORDER BY logical_name;

--------------------------------------------------Quick summary count

;WITH Comparison AS (
    -- ... same CTE ...
	   -- ... entire SELECT from above ...
	
-- Side-by-side comparison with status
SELECT
    ISNULL(s.logical_name, r.logical_name)                AS logical_name,

    ISNULL(s.filegroup_name, '<missing>')                 AS source_filegroup,
    ISNULL(r.filegroup_name, '<missing>')                 AS restored_filegroup,

    ISNULL(s.file_type, '<missing>')                      AS source_file_type,
    ISNULL(r.file_type, '<missing>')                      AS restored_file_type,

    ISNULL(CAST(s.size_kb AS varchar(20)), '<missing>')   AS source_size_kb,
    ISNULL(CAST(r.size_kb AS varchar(20)), '<missing>')   AS restored_size_kb,

    ISNULL(s.physical_name, '<missing>')                  AS source_physical_path,
    ISNULL(r.physical_name, '<missing>')                  AS restored_physical_path,

    ISNULL(s.state_desc, '<missing>')                     AS source_state,
    ISNULL(r.state_desc, '<missing>')                     AS restored_state,

    CASE
        WHEN s.logical_name IS NULL
            THEN 'NOT GOOD - extra file in restored DB'
        WHEN r.logical_name IS NULL
            THEN 'NOT GOOD - missing in restored DB'
        WHEN ISNULL(s.filegroup_name, '') <> ISNULL(r.filegroup_name, '')
            THEN 'NOT GOOD - filegroup mismatch'
        WHEN s.file_type <> r.file_type
            THEN 'NOT GOOD - file type mismatch'
        WHEN r.state_desc <> 'ONLINE'
            THEN 'NOT GOOD - restored file not ONLINE (' + r.state_desc + ')'
        WHEN s.size_kb <> r.size_kb
            THEN 'WARNING - size differs (acceptable if DB grew)'
        ELSE 'GOOD'
    END AS status

FROM #Source s
FULL OUTER JOIN #Restored r
    ON r.logical_name = s.logical_name

)
SELECT
    SUM(CASE WHEN status = 'GOOD'           THEN 1 ELSE 0 END) AS good_count,
    SUM(CASE WHEN status LIKE 'WARNING%'    THEN 1 ELSE 0 END) AS warning_count,
    SUM(CASE WHEN status LIKE 'NOT GOOD%'   THEN 1 ELSE 0 END) AS not_good_count,
    COUNT(*)                                                   AS total_files
FROM Comparison;