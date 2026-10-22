<img src="assets/icon.svg" width="64" height="64" alt="">

# random oracle scripts

Created in [T3 Code](https://t3.codes).

## AWR backup reports

Three files report on RMAN / backup activity from AWR (`DBA_HIST_*`, needs the Diagnostics Pack license):

| File | What it is |
| --- | --- |
| `awr_backup_overview.sql` | Text report (SQL*Plus, writes to stdout). |
| `awr_backup_report_html.sql` | Same logic as a self-contained, offline HTML report (spools `awr_backup_report_<DB>_<yyyymmdd_hh24mi>.html`). |
| `awr_backup_report.sh` | Bash wrapper that runs either or both on the database server. |

Both SQL scripts take `[days=60] [gap_minutes=30] [dbid=current] [inst=0 (all)] [scope=RMAN|ALL]`; see their headers for details and limits.

Run the wrapper on the database server as an OS user in the `dba` group. It connects with OS authentication (`sqlplus -S -L / as sysdba`), so no password is needed. It sets the Oracle environment through `oraenv` (falling back to `/etc/oratab`) if `ORACLE_HOME` or `sqlplus` is missing, and finds the SQL files next to itself, also when called through a symlink.

```bash
./awr_backup_report.sh                          # HTML report, last 60 days, $ORACLE_SID, current dir
./awr_backup_report.sh -s cdb1 -d 14 -g 60      # SID cdb1, 14 days, 60 min gap between runs
./awr_backup_report.sh -f both -o /tmp/awrout   # HTML and text report into /tmp/awrout
./awr_backup_report.sh -a -d 14                 # scope=ALL, to validate on a DB without backups
./awr_backup_report.sh -h                       # all options
```

Options: `-s SID`, `-d days`, `-g gap_minutes`, `-b dbid`, `-i inst`, `-a` (scope=ALL), `-f html|text|both`, `-o output_dir`, `-h`. The absolute path of each generated file is printed. The wrapper exits non-zero if it finds `ORA-`/`SP2-` errors in the output or an expected file is missing.
