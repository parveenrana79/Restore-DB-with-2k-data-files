# SQL Server Filegroup Restore Toolkit

Scripts for restoring date-partitioned SQL Server databases with hundreds or thousands of filegroups, where each filegroup represents one calendar day of data.

Built and tested for databases following the **`fg_DDMMMYYYY`** filegroup naming convention (e.g. `fg_11May2026`), with one or more `.ndf` files per filegroup stored in dedicated subfolders.

---

## When to use this

Use these scripts if your database has all of the following:

- A date-partitioned filegroup design (one filegroup per calendar day)
- A large number of filegroups — hundreds to thousands — that makes hand-written `RESTORE` statements impractical
- Some filegroups containing multiple `.ndf` files (high-volume days)
- A folder convention where each filegroup lives in its own subfolder matching the filegroup name
- A requirement to use **native T-SQL only** — no third-party modules like dbatools (common in locked-down prod environments)

If you have a normal-sized database with a handful of filegroups, you probably don't need this — a hand-written restore script will be simpler.

---

## Architecture assumed

```
C:\SQLDBA\AAFG_Restore\
├── PrimaryData\
│   └── AA_Test_FG_Primary.mdf
├── SecondaryData\
│   ├── AA_Test_FG_fg_1.ndf          ← additional files in PRIMARY filegroup
│   ├── AA_Test_FG_fg_2.ndf
│   ├── fg_11May2026\                ← one folder per filegroup
│   │   ├── AA_Test_FG_fg_11May2026.ndf
│   │   ├── AA_Test_FG_fg_11May2026_2.ndf    ← high-volume day, multiple files
│   │   └── AA_Test_FG_fg_11May2026_3.ndf
│   ├── fg_12May2026\
│   │   └── AA_Test_FG_fg_12May2026.ndf
│   └── ... (one folder per date)
└── Log\
    └── AA_Test_FG_Log.ldf
```

Key facts:

- The **PRIMARY** filegroup may contain multiple files (the `.mdf` plus additional `.ndf` files in `SecondaryData\`)
- Each **named filegroup** (`fg_DDMMMYYYY`) lives in its own subfolder
- **High-volume days** have multiple `.ndf` files in one filegroup, named with `_2`, `_3` suffixes

---

## What's in this repo

| Script | Purpose |
|---|---|
| `01_capture_filelist.sql` | Reads `RESTORE FILELISTONLY` from the backup file into a temp table |
| `02_analyze_structure.sql` | Pre-flight queries — counts filegroups, identifies multi-file days, surfaces anomalies |
| `03_create_folders_dryrun.sql` | PRINT-only dry run showing all folders that would be created |
| `04_create_folders_execute.sql` | Creates folders via `xp_create_subdir` with per-folder error handling |
| `05_generate_restore_script.sql` | Generates one `RESTORE FILEGROUP` statement per filegroup |
| `06_compare_source_vs_restored.sql` | Side-by-side comparison of source and restored DB structure with GOOD/NOT GOOD status |

---

## Quick start

### 1. Capture the backup's file list

```sql
-- Edit the backup file path at the top of the script
:r 01_capture_filelist.sql
```

This populates `#FileList` from `RESTORE FILELISTONLY`. Everything downstream uses this temp table, so keep the session open.

### 2. Run the pre-flight analysis

```sql
:r 02_analyze_structure.sql
```

Verify the numbers match expectations before continuing:

- Total filegroup count (should be ~number of dates + 1 for PRIMARY)
- Total data file count
- Multi-file filegroups (high-volume days)
- PRIMARY filegroup contents
- Path depth distribution (should be 2 distinct depths only)

### 3. Dry-run the folder creation

```sql
:r 03_create_folders_dryrun.sql
```

Read every `WOULD CREATE` line. Confirm the total count is reasonable and that there are no surprise paths.

### 4. Create the folders

```sql
:r 04_create_folders_execute.sql
```

`xp_create_subdir` is idempotent, so safe to rerun. Watch for `FAILED:` lines in the output — almost always an NTFS permission issue on the SQL Server service account.

### 5. Generate the restore script

```sql
:r 05_generate_restore_script.sql
```

Run via `sqlcmd` with `-y 0` to avoid truncating long lines:

```cmd
sqlcmd -S YourServer -E -d master -i 05_generate_restore_script.sql ^
       -o C:\Temp\AA_Test_FG_Restore.sql -h -1 -W -y 0
```

**Spot-check 3 statements before running:**

- PRIMARY → should have `PARTIAL, NORECOVERY` + multiple `MOVE` clauses including the log
- A single-file filegroup → one `MOVE` clause
- A multi-file filegroup (e.g. `fg_11May2026`) → comma-separated `MOVE` clauses, all in one `RESTORE` statement

### 6. Run the restore

Run the generated `.sql` file on the target server. PRIMARY must complete first; subsequent filegroups can run in parallel batches if you wrap them in PowerShell with `ForEach-Object -Parallel`.

### 7. Verify with side-by-side comparison

```sql
:r 06_compare_source_vs_restored.sql
```

Every row should show `GOOD` in the status column. Filter to `WHERE status <> 'GOOD'` to surface only problems.

---

## Configuration

Each script has variables at the top to edit. Common ones:

```sql
DECLARE @DBName       sysname       = 'AA_Test_FG';
DECLARE @BackupFile   nvarchar(260) = 'C:\SQLDBA\AAFG_Restore\Backup\AA_Test_FG_full.bak';
DECLARE @SourceBase   nvarchar(260) = 'C:\SQLDBA\AAFG_Restore';
DECLARE @TargetBase   nvarchar(260) = 'C:\SQLDBA\AAFG_Restore';   -- change to redirect
```

To restore to a different drive or server path, change `@TargetBase`. All folder creation and `MOVE` clauses will use the new base.

---

## Prerequisites

- SQL Server 2017 or later (uses `STRING_AGG`). For 2014/2016 see the `FOR XML PATH` variant in the comments of `05_generate_restore_script.sql`.
- `sysadmin` or equivalent permission on the target instance (needed for `xp_create_subdir` and `RESTORE`).
- NTFS write permission for the SQL Server service account on the target base folder.
- **Instant File Initialization** enabled (Perform Volume Maintenance Tasks for the SQL Server service account). At thousands-of-files scale this is the difference between hours and days.
- The `.bak` file accessible to the SQL Server service account.

---

## Performance notes

For a database with ~2,600 filegroups:

- **Pre-create folders before restore.** `RESTORE` fails immediately if the target folder doesn't exist.
- **Run PRIMARY restore sequentially first.** All other filegroups can be restored in parallel after PRIMARY completes (DB in `NORECOVERY` state allows concurrent `RESTORE FILEGROUP` against different filegroups).
- **Tune `MAXTRANSFERSIZE = 4194304` and `BUFFERCOUNT = 50`** on `RESTORE` statements. Defaults are poor for many small backups.
- **Pre-size the log file.** With a long log chain across thousands of filegroups, the `.ldf` can grow significantly during piecemeal restore.
- **Parallelism beyond ~6-8 threads** rarely helps — disk I/O becomes the bottleneck.

---

## Limitations

- Designed for SQL Server **Enterprise Edition** (online piecemeal restore). Works on Standard Edition but the database is offline until the final `WITH RECOVERY`.
- Assumes a single `.bak` file containing all filegroups. For per-filegroup backup files, the generator needs adjustment to look up backup paths per filegroup.
- Does not handle the **log restore chain** for point-in-time recovery — full-backup-only restores are covered.
- Path-parsing uses backslash separators; Windows-only.

---

## Troubleshooting

**`RESTORE FILELISTONLY` returns a different column count than expected**
Schema varies by SQL Server version. Edit `01_capture_filelist.sql` to drop trailing columns (`SnapshotURL`, `TDEThumbprint`) until the column count matches.

**`xp_create_subdir` fails with permission error**
The SQL Server **service account** (not your login) needs NTFS write permission on the target base folder. Grant via Windows Explorer → Properties → Security.

**Generated `RESTORE` statements are truncated mid-line**
You ran `sqlcmd` without `-y 0`. Re-run with `-y 0 -h -1 -W` to preserve long lines.

**Filegroups stuck in `RECOVERY_PENDING` after restore**
Either the filegroup wasn't restored (intentional? check the script output) or the final `WITH RECOVERY` wasn't issued on the last statement.

**`DBCC CHECKDB` complains about offline filegroups**
Use `DBCC CHECKFILEGROUP` per online filegroup instead. Loop included in `06_compare_source_vs_restored.sql`.

---

## Testing

Always run the full sequence on a non-prod target with a small sample database **before** running on prod. The included `AA_Test_FG` sample DB (30 filegroups, ~34 files) takes under a minute end-to-end and exercises every code path including multi-file filegroups.

---

## Contributing

PRs welcome for:

- SQL Server 2014/2016 compatibility (replace `STRING_AGG` with `FOR XML PATH`)
- Per-filegroup-backup-file variant
- Log restore chain generator for point-in-time recovery
- Linux path support

---

## License

MIT
