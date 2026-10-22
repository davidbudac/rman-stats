<img src="assets/icon.svg" width="64" height="64" alt="">

# random oracle scripts

Created in [T3 Code](https://t3.codes).

## AWR backup reports

Five files report on RMAN / backup activity from AWR (`DBA_HIST_*`, needs the Diagnostics Pack license):

| File | What it is |
| --- | --- |
| `awr_backup_overview.sql` | Text report (SQL*Plus, writes to stdout). |
| `awr_backup_report_html.sql` | Same logic as a self-contained, offline HTML report (spools `awr_backup_report_<DB>_<yyyymmdd_hh24mi>.html`). |
| `awr_backup_report.sh` | Portable POSIX `sh` wrapper that runs either or both on the database server. |
| `awr_backup_catalog_connect.sql`, `awr_backup_catalog_skip.sql` | Two tiny helpers the SQL scripts call (one of them, chosen by name) to connect to the recovery catalog or to do nothing. Keep all five files in one directory. |

Both SQL scripts take `[days=60] [gap_minutes=30] [dbid=current] [inst=0 (all)] [scope=RMAN|ALL] [catalog]`; see their headers for details and limits.

Requirements: a POSIX shell (`#!/bin/sh`) and the base OS tools only (`awk`, `sed`, `grep`, `cut`, `ls`, `stty`, ...), so it runs on AIX 7.2 (ksh88 `/bin/sh`) as well as Linux. It needs no bash, `readlink`, `realpath`, `mktemp` or `timeout`; the last two are used only if present. Tested with bash 3.2/5, ksh93, dash and zsh in sh mode, on Oracle Linux 9 against a real 19c database; **not yet run on a real AIX/ksh88**, so check it there first.

Run the wrapper on the database server as an OS user in the `dba` group. It connects with OS authentication (`sqlplus -S -L / as sysdba`), so no password is needed. It sets the Oracle environment through `oraenv` (falling back to `/etc/oratab`) if `ORACLE_HOME` or `sqlplus` is missing, and finds the SQL files next to itself, also when called through a symlink. Everything is read-only: the SQL scripts issue only `SELECT`s (plus the optional `CONNECT` to the recovery catalog) and the wrapper writes nothing but the report files and its own temp directory. SQL*Plus is run from a private temp directory (mode 0700) with `-R 1` (no `HOST`/`!`), and the finished reports are moved into the output directory, so nothing planted in a shared output directory such as `/tmp` (a `login.sql`, a symlink with the report's name) can be picked up.

```bash
./awr_backup_report.sh                          # HTML report, last 60 days, $ORACLE_SID, current dir
./awr_backup_report.sh -s cdb1 -d 14 -g 60      # SID cdb1, 14 days, 60 min gap between runs
./awr_backup_report.sh -f both -o /tmp/awrout   # HTML and text report into /tmp/awrout
./awr_backup_report.sh -a -d 14                 # scope=ALL, to validate on a DB without backups
./awr_backup_report.sh -c rco@catdb             # job history from the RMAN catalog, password prompt
./awr_backup_report.sh -h                       # all options
```

Options: `-s SID`, `-d days`, `-g gap_minutes`, `-b dbid`, `-i inst`, `-a` (scope=ALL), `-c catalog`, `-f html|text|both`, `-o output_dir`, `-h`. The absolute path of each generated file is printed. The wrapper exits non-zero if it finds `ORA-`/`SP2-` errors in the output or an expected file is missing.

### Optional RMAN recovery catalog

Everything except the cross-check section (F in the text report, the "Cross-check" panel in the HTML) comes from AWR on the target. That section is labelled NOT AWR and normally reads `V$RMAN_BACKUP_JOB_DETAILS` from the controlfile, which only keeps `control_file_record_keep_time` days (default 7). With `-c` it reads `RC_RMAN_BACKUP_JOB_DETAILS` from an RMAN recovery catalog instead, filtered to the target DBID (in a CDB that is the CDB's DBID), so the job history can be much longer. The report then says "Source: RMAN recovery catalog user@tns" and shows the catalog's job count, oldest and newest job for this database in place of the `control_file_record_keep_time` row. There are no other controlfile (`V$`) reads that could come from the catalog: the rest of the scripts read `DBA_HIST_*`, plus `V$DATABASE`/`V$INSTANCE` for identity and one `V$PARAMETER` row.

```bash
./awr_backup_report.sh -c rco@catdb -f both          # asks for the password (not echoed)
RMAN_CATALOG_PASSWORD='...' ./awr_backup_report.sh -c rco@catdb    # cron
./awr_backup_report.sh -c /@catwallet                # wallet / external auth, no password
```

* `-c` takes `user@tns_alias` (an EZConnect string works too) or `/@wallet_alias`. The password comes from `RMAN_CATALOG_PASSWORD`, else a prompt with terminal echo turned off via `stty` (an error if stdin is not a terminal). It must not contain `"` or `'`.
* The password is passed to sqlplus on stdin only: never on a command line, never in a file, and never printed. It is written with a shell built-in (`printf`, or ksh's `print`); if the shell has neither, the wrapper stops with an error instead of risking it showing up in `ps`. The catalog check runs under `timeout 90` when `timeout` exists, otherwise without a limit of its own. The reports show `user@tns` or `wallet (alias)` only, and the wrapper checks its outputs for the password at the end.
* Before the reports run, the wrapper logs in to the catalog in a separate sqlplus session and checks that `RC_RMAN_BACKUP_JOB_DETAILS` is readable (catalog owner or virtual private catalog user) and that the target DBID is in `RC_DATABASE`. A failed login (wrong password, unknown alias) is an error, exit status 1, with no fallback. If the login works but the DBID is not registered or the views are not readable, it prints a WARNING and runs with the controlfile as before.
* The SQL scripts take the same connect string as the optional 6th argument, for example `@awr_backup_overview.sql 60 30 "" "" "" /@catwallet`. They read all AWR data first and CONNECT to the catalog as the last step. A failed login stops the script with exit status 1 (the HTML file is then incomplete). A password typed in that argument is visible in `ps` and must not contain `'`; prefer the wrapper or a wallet.
* The window start is computed from the target's clock before the catalog connect, and the job times are shown as the catalog stores them; the clock and time zone of the catalog database are not used.

On Oracle 19c the ASH `MODULE` of RMAN channel sessions is `backup archivelog`, `backup full datafile` and so on, without the `: ORA_DISK_1` channel suffix that older releases add. The reports handle both; without a suffix the "channels" column counts distinct sessions.
