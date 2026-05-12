--Option 1: Filter by restore_date range (simplest)
--If you know roughly when the restore happened, filter on the date range:
DECLARE @DBName    sysname  = 'AAFG_RESTORE_TEST';
DECLARE @StartFrom datetime = '2026-05-11 11:40';   -- before your restore started
DECLARE @EndBy     datetime = '2026-05-12 12:20';   -- after it finished

SELECT
    COUNT(*)                                                      AS restore_statements,
    MIN(rh.restore_date)                                          AS first_complete,
    MAX(rh.restore_date)                                          AS last_complete,
    DATEDIFF(MINUTE, MIN(rh.restore_date), MAX(rh.restore_date))  AS window_minutes,
    SUM(bs.backup_size) / 1024.0 / 1024.0 / 1024.0                AS total_gb
FROM msdb.dbo.restorehistory rh
JOIN msdb.dbo.backupset bs ON bs.backup_set_id = rh.backup_set_id
WHERE rh.destination_database_name = @DBName
  AND rh.restore_date BETWEEN @StartFrom AND @EndBy;
GO

--Works fine for ad-hoc analysis. Falls apart if you're scripting it for a dashboard or doing multiple restores per day.
--Option 2: Detect "runs" automatically with a time-gap heuristic
--A restore run is a cluster of RESTORE statements close together in time, separated from the next run by a big gap. This identifies runs automatically by looking for gaps larger than, say, 30 minutes:
DECLARE @DBName     sysname = 'AAFG_RESTORE_TEST';
DECLARE @GapMinutes int     = 30;   -- gap that separates one run from the next

;WITH Restores AS (
    SELECT
        rh.restore_history_id,
        rh.restore_date,
        bs.backup_size,
        LAG(rh.restore_date) OVER (ORDER BY rh.restore_date) AS prev_restore_date
    FROM msdb.dbo.restorehistory rh
    JOIN msdb.dbo.backupset bs ON bs.backup_set_id = rh.backup_set_id
    WHERE rh.destination_database_name = @DBName
),
RunBoundaries AS (
    SELECT
        restore_history_id,
        restore_date,
        backup_size,
        CASE
            WHEN prev_restore_date IS NULL
              OR DATEDIFF(MINUTE, prev_restore_date, restore_date) > @GapMinutes
            THEN 1 ELSE 0
        END AS is_run_start
    FROM Restores
),
RunNumbered AS (
    SELECT
        restore_history_id,
        restore_date,
        backup_size,
        SUM(is_run_start) OVER (ORDER BY restore_date
                                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS run_id
    FROM RunBoundaries
)
SELECT
    run_id,
    MIN(restore_date)                                          AS run_first_complete,
    MAX(restore_date)                                          AS run_last_complete,
    DATEDIFF(MINUTE, MIN(restore_date), MAX(restore_date))     AS window_minutes,
    COUNT(*)                                                   AS restore_statements,
    CAST(SUM(backup_size) / 1024.0 / 1024.0 / 1024.0 AS decimal(10,2)) AS total_gb,
    CAST(SUM(backup_size) / 1024.0 / 1024.0 / 1024.0 * 60.0 /
         NULLIF(DATEDIFF(MINUTE, MIN(restore_date), MAX(restore_date)), 0)
         AS decimal(10,2))                                     AS gb_per_hour
FROM RunNumbered
GROUP BY run_id
ORDER BY run_id DESC;
--You'll get one row per restore "run". The most recent run is at the top. Pick the run_id you care about, then drill into details with a WHERE run_id = N filter applied to the same CTE.
--This is my recommended approach for ongoing use — it's self-organizing.
--Option 3: Pre-mark each run with a session marker
--Before kicking off each restore, run a "marker" — a tiny no-op or a logging row — that gives you a known reference point. Three ways to do this:
--3a. Capture max(restore_history_id) before you start
--Cheapest, no setup:
-- BEFORE the restore run, save this number somewhere

--SELECT ISNULL(MAX(restore_history_id), 0) AS last_id_before_run
--FROM msdb.dbo.restorehistory
--WHERE destination_database_name = 'AAFG_RESTORE_TEST';

-- e.g., returns 472

---- AFTER the run, filter on it:
--SELECT ...
--FROM msdb.dbo.restorehistory rh
--JOIN msdb.dbo.backupset bs ON bs.backup_set_id = rh.backup_set_id
--WHERE rh.destination_database_name = 'AAFG_RESTORE_TEST'
--  AND rh.restore_history_id > 472;
----restore_history_id is monotonically increasing across the whole instance, so anything bigger than the marker belongs to this run.
--3b. Write to your own tracking table
--If you're going to do this regularly, create a tiny tracking table:
--USE DBA_Tools;   -- or whatever utility DB you have
GO

--CREATE TABLE dbo.RestoreRunLog (
--    run_id              int IDENTITY(1,1) PRIMARY KEY,
--    database_name       sysname        NOT NULL,
--    run_start_time      datetime2      NOT NULL DEFAULT SYSDATETIME(),
--    run_end_time        datetime2      NULL,
--    starting_history_id int            NULL,
--    ending_history_id   int            NULL,
--    notes               nvarchar(500)  NULL
--);
--GO

---- Mark the START of a run (run this BEFORE the restore)
--INSERT INTO dbo.RestoreRunLog (database_name, starting_history_id, notes)
--SELECT 'AAFG_RESTORE_TEST',
--       ISNULL(MAX(restore_history_id), 0),
--       'Daily DR refresh'
--FROM msdb.dbo.restorehistory
--WHERE destination_database_name = 'AAFG_RESTORE_TEST';

--DECLARE @RunID int = SCOPE_IDENTITY();
--SELECT @RunID AS new_run_id;   -- save this

---- Run your restore here ...

---- Mark the END of the run (run this AFTER the restore)
--UPDATE dbo.RestoreRunLog
--SET run_end_time      = SYSDATETIME(),
--    ending_history_id = (SELECT MAX(restore_history_id)
--                         FROM msdb.dbo.restorehistory
--                         WHERE destination_database_name = 'AAFG_RESTORE_TEST')
--WHERE run_id = @RunID;
----Then your reporting query joins on this:
--SELECT
--    log.run_id,
--    log.database_name,
--    log.run_start_time,
--    log.run_end_time,
--    DATEDIFF(MINUTE, log.run_start_time, log.run_end_time)        AS true_window_minutes,
--    COUNT(*)                                                      AS restore_statements,
--    CAST(SUM(bs.backup_size) / 1024.0 / 1024.0 / 1024.0 AS decimal(10,2)) AS total_gb,
--    CAST(SUM(bs.backup_size) / 1024.0 / 1024.0 / 1024.0 * 60.0 /
--         NULLIF(DATEDIFF(MINUTE, log.run_start_time, log.run_end_time), 0)
--         AS decimal(10,2))                                        AS gb_per_hour
--FROM dbo.RestoreRunLog log
--JOIN msdb.dbo.restorehistory rh
--    ON rh.destination_database_name = log.database_name
--   AND rh.restore_history_id > log.starting_history_id
--   AND rh.restore_history_id <= ISNULL(log.ending_history_id, rh.restore_history_id)
--JOIN msdb.dbo.backupset bs ON bs.backup_set_id = rh.backup_set_id
--WHERE log.run_id = @RunID   -- or whichever run you want
--GROUP BY log.run_id, log.database_name, log.run_start_time, log.run_end_time;
----This gives you the true window (real start time, not first-completion), accurate throughput, and an audit log of every DR exercise you've ever done. For something that goes in a Git repo and gets used regularly, this is the right answer.
----Option 4: Cleanup-first approach
----If you don't need any history beyond the current run, just purge before restarting:
---- Before each fresh restore, wipe history for that DB

----EXEC msdb.dbo.sp_delete_database_backuphistory @database_name = N'AAFG_RESTORE_TEST';

