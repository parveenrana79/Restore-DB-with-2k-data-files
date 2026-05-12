USE master;
GO

-- Drop if exists (so you can rerun)
IF OBJECT_ID('tempdb..#FileList') IS NOT NULL DROP TABLE #FileList;

CREATE TABLE #FileList (
    LogicalName              nvarchar(128),
    PhysicalName             nvarchar(260),
    [Type]                   char(1),
    FileGroupName            nvarchar(128),
    [Size]                   numeric(20,0),
    [MaxSize]                numeric(20,0),
    FileID                   bigint,
    CreateLSN                numeric(25,0),
    DropLSN                  numeric(25,0),
    UniqueID                 uniqueidentifier,
    ReadOnlyLSN              numeric(25,0),
    ReadWriteLSN             numeric(25,0),
    BackupSizeInBytes        bigint,
    SourceBlockSize          int,
    FileGroupID              int,
    LogGroupGUID             uniqueidentifier,
    DifferentialBaseLSN      numeric(25,0),
    DifferentialBaseGUID     uniqueidentifier,
    IsReadOnly               bit,
    IsPresent                bit,
    TDEThumbprint            varbinary(32),
    SnapshotURL              nvarchar(360)
);

INSERT INTO #FileList
EXEC ('RESTORE FILELISTONLY FROM DISK = ''C:\SQLDBA\AAFG_Restore\Backup\AA_Test_FG_full_new.bak''');

SELECT * FROM #FileList --ORDER BY FileGroupName, LogicalName;

SELECT COUNT(DISTINCT FileGroupName) AS total_filegroups
FROM #FileList
WHERE [Type] = 'D' --AND FileGroupName IS NOT NULL;

SELECT FileGroupName, COUNT(*) AS file_count
FROM #FileList
WHERE [Type] = 'D'
  AND FileGroupName <> 'PRIMARY'
GROUP BY FileGroupName
ORDER BY FileGroupName;

SELECT FileGroupName, COUNT(*) AS file_count
FROM #FileList
WHERE [Type] = 'D' AND FileGroupName <> 'PRIMARY'
GROUP BY FileGroupName
HAVING COUNT(*) > 1
ORDER BY file_count DESC, FileGroupName;
--select * from sys.filegroups

SELECT LogicalName, PhysicalName, [Type]
FROM #FileList
WHERE FileGroupName = 'PRIMARY' OR [Type] = 'L'
ORDER BY [Type], LogicalName;

SELECT
    COUNT(DISTINCT FileGroupName) AS total_filegroups,
    COUNT(*)                      AS total_data_files,
    SUM(CASE WHEN FileGroupName = 'PRIMARY' THEN 1 ELSE 0 END) AS primary_files,
    SUM(CASE WHEN FileGroupName <> 'PRIMARY' THEN 1 ELSE 0 END) AS secondary_data_files
FROM #FileList
WHERE [Type] = 'D';

--SELECT DISTINCT
--    'IF NOT EXIST "C:\SQLDBA\AAFG_RESTORE_TEST\' + FileGroupName + '" ' +
--    'MKDIR "C:\SQLDBA\AAFG_RESTORE_TEST\' + FileGroupName + '"' AS mkdir_cmd
--FROM #FileList
--WHERE [Type] = 'D' --AND FileGroupName <> 'PRIMARY'
--ORDER BY mkdir_cmd;

SELECT DISTINCT PhysicalName
FROM #FileList
WHERE [Type] = 'D' --AND FileGroupName <> 'PRIMARY'

-- Assumes #FileList already populated from RESTORE FILELISTONLY

--;WITH FolderHierarchy AS (
--    -- Anchor: strip filename, get the immediate parent folder of each file
--    SELECT DISTINCT
--        LEFT(PhysicalName, LEN(PhysicalName) - CHARINDEX('\', REVERSE(PhysicalName))) AS folder_path
--    FROM #FileList
--    WHERE PhysicalName LIKE '%\%'

--    UNION ALL

--    -- Recursive: take each folder and emit its parent
--    SELECT LEFT(folder_path, LEN(folder_path) - CHARINDEX('\', REVERSE(folder_path)))
--    FROM FolderHierarchy
--    WHERE CHARINDEX('\', folder_path) > 0
--      AND LEN(folder_path) > 3       -- stop before bare drive (e.g., 'C:\')
--)
--SELECT DISTINCT folder_path,
--       LEN(folder_path) - LEN(REPLACE(folder_path, '\', '')) AS depth
--FROM FolderHierarchy
--WHERE folder_path <> ''
--ORDER BY depth, folder_path
--OPTION (MAXRECURSION 10);


-- Assumes #FileList already populated from RESTORE FILELISTONLY

SET NOCOUNT ON;

DECLARE @SourceBase nvarchar(260) = 'C:\SQLDBA\AAFG_Restore';
DECLARE @TargetBase nvarchar(260) = 'C:\SQLDBA\AAFG_RESTORE_TEST';  -- change if redirecting

-- Capture distinct folder paths into a working table
IF OBJECT_ID('tempdb..#Folders') IS NOT NULL DROP TABLE #Folders;

;WITH FolderHierarchy AS (
    SELECT DISTINCT
        LEFT(PhysicalName, LEN(PhysicalName) - CHARINDEX('\', REVERSE(PhysicalName))) AS folder_path
    FROM #FileList
    WHERE PhysicalName LIKE '%\%'

    UNION ALL

    SELECT LEFT(folder_path, LEN(folder_path) - CHARINDEX('\', REVERSE(folder_path)))
    FROM FolderHierarchy
    WHERE CHARINDEX('\', folder_path) > 0
      AND LEN(folder_path) > 3
)
SELECT DISTINCT
    REPLACE(folder_path, @SourceBase, @TargetBase) AS target_folder,
    LEN(folder_path) - LEN(REPLACE(folder_path, '\', '')) AS depth
INTO #Folders
FROM FolderHierarchy
WHERE folder_path <> ''
OPTION (MAXRECURSION 10);

-- DRY RUN: just PRINT what would happen
DECLARE @path nvarchar(260);
DECLARE @counter int = 0;

DECLARE folder_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT target_folder
    FROM #Folders
    ORDER BY depth, target_folder;

OPEN folder_cursor;
FETCH NEXT FROM folder_cursor INTO @path;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @counter = @counter + 1;
    PRINT 'WOULD CREATE: ' + @path;
    FETCH NEXT FROM folder_cursor INTO @path;
END

CLOSE folder_cursor;
DEALLOCATE folder_cursor;

PRINT '';
PRINT '---';
PRINT 'Total folders that would be created: ' + CAST(@counter AS varchar(10));

--restore filelistonly from disk  ='C:\SQLDBA\AAFG_Restore\Backup\AA_Test_FG_full.bak'

-------------------------------------

-- Assumes #Folders table from Step 2a is still populated.
-- If you're in a new session, re-run the CTE block above to repopulate it.
GO

SET NOCOUNT ON;

DECLARE @path nvarchar(260);
DECLARE @created int = 0;
DECLARE @failed  int = 0;
DECLARE @err_msg nvarchar(4000);

DECLARE folder_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT target_folder
    FROM #Folders
    ORDER BY depth, target_folder;

OPEN folder_cursor;
FETCH NEXT FROM folder_cursor INTO @path;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC master.dbo.xp_create_subdir @path;
        SET @created = @created + 1;
        -- Comment out the next line for prod to reduce output noise
        PRINT 'CREATED: ' + @path;
    END TRY
    BEGIN CATCH
        SET @failed = @failed + 1;
        SET @err_msg = ERROR_MESSAGE();
        PRINT 'FAILED:  ' + @path + '  --> ' + @err_msg;
    END CATCH

    FETCH NEXT FROM folder_cursor INTO @path;
END

CLOSE folder_cursor;
DEALLOCATE folder_cursor;

PRINT '';
PRINT '---';
PRINT 'Folders processed successfully: ' + CAST(@created AS varchar(10));
PRINT 'Folders failed:                 ' + CAST(@failed AS varchar(10));


------------------------

DECLARE @DBName       sysname       = 'AAFG_RESTORE_TEST';
DECLARE @BackupFile   nvarchar(260) = 'C:\SQLDBA\AAFG_Restore\Backup\AA_Test_FG_full_new.bak';
DECLARE @SourceBase nvarchar(260) = 'C:\SQLDBA\AAFG_Restore';
DECLARE @TargetBase nvarchar(260) = 'C:\SQLDBA\AAFG_RESTORE_TEST';  -- change if redirecting


;WITH FileTargets AS (
    SELECT
        FileGroupName,
        LogicalName,
        [Type],
        REPLACE(PhysicalName, @SourceBase, @TargetBase) AS target_path
    FROM #FileList
)
SELECT
    CASE WHEN FileGroupName = 'PRIMARY' THEN 0 ELSE 1 END AS exec_order,
    'RESTORE DATABASE [' + @DBName + '] FILEGROUP = ''' + FileGroupName + ''' '
    + 'FROM DISK = ''' + @BackupFile + ''' '
    + 'WITH '
    + CASE WHEN FileGroupName = 'PRIMARY' THEN 'PARTIAL, ' ELSE '' END
    + 'NORECOVERY, '
    + STRING_AGG('MOVE ''' + LogicalName + ''' TO ''' + target_path + '''', ', ')
    + CASE
        WHEN FileGroupName = 'PRIMARY'
        THEN ', ' + (
            SELECT 'MOVE ''' + LogicalName + ''' TO ''' + target_path + ''''
            FROM FileTargets
            WHERE [Type] = 'L'
        )
        ELSE ''
      END
    + ';' AS restore_stmt
FROM FileTargets
WHERE [Type] = 'D'
GROUP BY FileGroupName
ORDER BY exec_order, FileGroupName;