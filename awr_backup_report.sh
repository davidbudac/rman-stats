#!/usr/bin/env bash
# ============================================================================
# awr_backup_report.sh
#
# Command line wrapper for the AWR backup reports, to be run on the database
# server.  Wraps awr_backup_report_html.sql (self-contained HTML report) and
# awr_backup_overview.sql (text report), which must sit in the same directory
# as this script together with their two helpers awr_backup_catalog_connect.sql
# and awr_backup_catalog_skip.sql (symlinks to the wrapper are fine).
#
# Connects with OS authentication (sqlplus -S -L / as sysdba), so no password.
# Run it as an OS user that is a member of the dba / OSDBA group (normally the
# oracle software owner).  Read-only; needs the Diagnostics Pack license.
#
# Optional RMAN recovery catalog (-c): the cross-check section (RMAN job history,
# NOT AWR) then comes from RC_RMAN_BACKUP_JOB_DETAILS in the catalog instead of
# V$RMAN_BACKUP_JOB_DETAILS in the controlfile.  Everything else still comes
# from AWR on the target.  The catalog password is taken from the environment
# variable RMAN_CATALOG_PASSWORD (for cron) or asked for on the terminal; a
# wallet (-c /@alias) needs none.  It is only ever passed to sqlplus on stdin
# (never on a command line, never in a file) and never printed.  Before the
# reports run, a separate sqlplus session checks the catalog: a failed login is
# an error (exit 1, no fallback); a catalog that works but does not hold this DBID
# or whose RC_ views cannot be read gives a WARNING and the reports fall back to
# the controlfile.  Passwords containing a double or single quote are rejected.
#
# Examples
#   ./awr_backup_report.sh                          # HTML, last 60 days, $ORACLE_SID
#   ./awr_backup_report.sh -s cdb1 -d 14 -g 60      # SID cdb1, 14 days, 60 min run gap
#   ./awr_backup_report.sh -f both -o /tmp/awrout   # HTML + text report into /tmp/awrout
#   ./awr_backup_report.sh -a -d 14                 # scope=ALL (validation, no RMAN filter)
#   ./awr_backup_report.sh -i 2                     # RAC: instance 2 only
#   ./awr_backup_report.sh -c rco@catdb             # catalog rco@catdb, password prompt
#   RMAN_CATALOG_PASSWORD=... ./awr_backup_report.sh -c rco@catdb -f both   # cron
#   ./awr_backup_report.sh -c /@catwallet           # catalog through a wallet
#
# Exit code: 0 = report(s) produced and no ORA-/SP2- errors found,
#            non-zero = usage error, environment problem, catalog login failure,
#            SQL error, or a missing output file.  Generated file paths are
#            printed on stdout.
# ============================================================================
set -euo pipefail

PROG=${0##*/}

usage() {
  cat <<EOF
Usage: $PROG [-s SID] [-d days] [-g gap_minutes] [-b dbid] [-i inst]
              [-a] [-c catalog] [-f html|text|both] [-o output_dir] [-h]

Run the AWR backup reports on the database server via sqlplus / as sysdba
(OS authentication; run as a member of the dba / OSDBA group).

  -s SID        ORACLE_SID of the instance (default: \$ORACLE_SID; required)
  -d days       look-back window in days                    (default 60)
  -g minutes    idle gap that splits two runs of a backup type (default 30)
  -b dbid       DBID to report on                           (default: this DB)
  -i inst       instance number, 0 = all instances (RAC)    (default 0)
  -a            scope=ALL: no RMAN filter, group any MODULE (validation mode
                for a DB without backups; default scope is RMAN)
  -c catalog    read the RMAN job history (cross-check section, not AWR) from
                this RMAN recovery catalog instead of the controlfile; form
                user@tns_alias or /@wallet_alias.  Password: env
                RMAN_CATALOG_PASSWORD, else asked on the terminal (a wallet needs
                none).  Login failure = error; DBID not registered or RC_ views
                not readable = warning and fallback to the controlfile.
  -f format     html, text or both                          (default html)
  -o dir        output directory, created if missing        (default .)
  -h            show this help

Output: awr_backup_report_<DB>_<yyyymmdd_hh24mi>.html and/or
        awr_backup_overview_<SID>_<yyyymmdd_hh24mi>.txt in the output directory.
EOF
}

die() { printf '%s: ERROR: %s\n' "$PROG" "$*" >&2; exit 1; }
info() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# ---- resolve the wrapper's real directory (follows symlinks, portable) ------
resolve_dir() {
  local src=$1 dir target
  while [ -L "$src" ]; do
    dir=$(cd -P "$(dirname "$src")" && pwd)
    target=$(readlink "$src")
    case $target in
      /*) src=$target ;;
      *)  src=$dir/$target ;;
    esac
  done
  cd -P "$(dirname "$src")" && pwd
}
SCRIPT_DIR=$(resolve_dir "${BASH_SOURCE[0]}")

# ---- options ----------------------------------------------------------------
sid=${ORACLE_SID:-}
sid_from_opt=0
days="" gap="" dbid="" inst=""
scope=""
catalog=""
fmt=html
outdir=.

while getopts ':s:d:g:b:i:ac:f:o:h' opt; do
  case $opt in
    s) sid=$OPTARG; sid_from_opt=1 ;;
    d) days=$OPTARG ;;
    g) gap=$OPTARG ;;
    b) dbid=$OPTARG ;;
    i) inst=$OPTARG ;;
    a) scope=ALL ;;
    c) catalog=$OPTARG ;;
    f) fmt=$OPTARG ;;
    o) outdir=$OPTARG ;;
    h) usage; exit 0 ;;
    :) die "option -$OPTARG requires an argument (use -h for usage)" ;;
    \?) die "unknown option: -$OPTARG (use -h for usage)" ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || { die "unexpected argument: $1 (use -h for usage)"; }

# ---- validation ---------------------------------------------------------------
is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }
is_pos()  { is_uint "$1" && [ "$((10#$1))" -gt 0 ]; }

[ -n "$sid" ] || die "no SID: use -s SID or set ORACLE_SID"
[[ $sid =~ ^[A-Za-z0-9_#$+-]+$ ]] || die "invalid SID: '$sid'"
if [ -n "$days" ]; then is_pos "$days" || die "-d days must be a positive integer, got '$days'"; fi
if [ -n "$gap" ];  then is_pos "$gap"  || die "-g gap_minutes must be a positive integer, got '$gap'"; fi
if [ -n "$dbid" ]; then is_pos "$dbid" || die "-b dbid must be a positive integer, got '$dbid'"; fi
if [ -n "$inst" ]; then is_uint "$inst" || die "-i inst must be a non-negative integer (0 = all), got '$inst'"; fi
case $fmt in
  html|text|both) ;;
  *) die "-f must be html, text or both, got '$fmt'" ;;
esac

# -c catalog: user@tns_alias or /@wallet_alias (no password here)
cat_user="" cat_alias="" cat_wallet=0 cat_label=""
if [ -n "$catalog" ]; then
  case $catalog in
    /@*) cat_wallet=1; cat_alias=${catalog#/@} ;;
    *@*) cat_user=${catalog%%@*}; cat_alias=${catalog#*@} ;;
    *)   die "-c must be user@tns_alias or /@wallet_alias, got '$catalog'" ;;
  esac
  if [ "$cat_wallet" -eq 0 ]; then
    case $cat_user in
      */*) die "-c takes user@tns_alias without a password; set RMAN_CATALOG_PASSWORD or answer the prompt" ;;
    esac
  fi
  [[ $cat_alias =~ ^[A-Za-z0-9_.#$:/+-]+$ ]] \
    || die "-c: invalid TNS alias or EZConnect string '$cat_alias' (allowed: letters, digits and . _ # \$ : / + -)"
  if [ "$cat_wallet" -eq 0 ]; then
    [[ $cat_user =~ ^[A-Za-z][A-Za-z0-9_#$]*$ ]] \
      || die "-c: invalid catalog user '$cat_user' (expected a plain Oracle user name)"
    cat_label="$cat_user@$cat_alias"
  else
    cat_label="wallet ($cat_alias)"
  fi
fi
[ -n "$outdir" ] || die "-o output_dir must not be empty"

html_sql=$SCRIPT_DIR/awr_backup_report_html.sql
text_sql=$SCRIPT_DIR/awr_backup_overview.sql
if [ "$fmt" != text ]; then [ -r "$html_sql" ] || die "cannot read $html_sql"; fi
if [ "$fmt" != html ]; then [ -r "$text_sql" ] || die "cannot read $text_sql"; fi
for f in awr_backup_catalog_connect.sql awr_backup_catalog_skip.sql; do
  [ -r "$SCRIPT_DIR/$f" ] || die "cannot read $SCRIPT_DIR/$f (helper of the SQL scripts, keep it next to them)"
done
case $SCRIPT_DIR in
  *[\"\ ]*) die "script directory must not contain spaces or quotes: $SCRIPT_DIR" ;;
esac

# ---- output directory ---------------------------------------------------------
if [ ! -d "$outdir" ]; then
  mkdir -p -- "$outdir" || die "cannot create output directory: $outdir"
fi
outdir=$(cd -P -- "$outdir" && pwd) || die "cannot access output directory: $outdir"
[ -w "$outdir" ] || die "output directory is not writable: $outdir"
case $outdir in
  *[\"\ ]*) die "output directory must not contain spaces or quotes: $outdir" ;;
esac

# ---- Oracle environment ---------------------------------------------------------
# Re-source the environment when ORACLE_HOME is unset, sqlplus is not on PATH,
# or -s names a different SID than the one the current environment was set for.
need_env=0
[ -n "${ORACLE_HOME:-}" ] || need_env=1
command -v sqlplus >/dev/null 2>&1 || need_env=1
if [ "$sid_from_opt" -eq 1 ] && [ "${ORACLE_SID:-}" != "$sid" ]; then need_env=1; fi

oratab_home() {   # print ORACLE_HOME for SID $1 from oratab, fail if not found
  local tab home
  for tab in /etc/oratab /var/opt/oracle/oratab; do
    [ -r "$tab" ] || continue
    home=$(awk -F: -v s="$1" '$1 == s && $2 != "" && $1 !~ /^#/ { print $2; exit }' "$tab")
    if [ -n "$home" ]; then printf '%s\n' "$home"; return 0; fi
  done
  return 1
}

export ORACLE_SID="$sid"
if [ "$need_env" -eq 1 ]; then
  # oraenv is not written for set -u, and may return non-zero harmlessly
  if command -v oraenv >/dev/null 2>&1; then
    set +u
    export ORAENV_ASK=NO
    # shellcheck disable=SC1091
    . oraenv </dev/null >/dev/null 2>&1 || true
    set -u
  fi
  if [ -z "${ORACLE_HOME:-}" ] || ! command -v sqlplus >/dev/null 2>&1; then
    if home=$(oratab_home "$sid"); then
      export ORACLE_HOME=$home
      export PATH="$ORACLE_HOME/bin:$PATH"
      export LD_LIBRARY_PATH="$ORACLE_HOME/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
  fi
  # oraenv may have switched the SID (it keeps the one we exported)
  export ORACLE_SID="$sid"
fi
command -v sqlplus >/dev/null 2>&1 \
  || die "sqlplus not found: ORACLE_HOME/PATH not set and SID '$sid' could not be resolved via oraenv or oratab (/etc/oratab)"

# ---- preflight: can we connect, and is the database open? ----------------------
pre=$( ( cd -- "$outdir" && sqlplus -S -L / as sysdba <<'EOF'
set heading off feedback off pagesize 0 verify off
select 'INSTANCE_STATUS' || chr(61) || status from v$instance;
select 'DB_ID' || chr(61) || dbid from v$database;
exit
EOF
) 2>&1 || true )
case $pre in
  *INSTANCE_STATUS=OPEN*) ;;
  *INSTANCE_STATUS=*) die "instance '$sid' is not OPEN (${pre##*INSTANCE_STATUS=}); AWR data needs an open database" ;;
  *) die "cannot connect to instance '$sid' as sysdba: $(printf '%s' "$pre" | grep -E 'ORA-|SP2-|rror' | head -n 1 | cut -c1-200)
    (check -s / ORACLE_SID, that the instance is running, and that this OS user is in the dba/OSDBA group)" ;;
esac

pre_dbid=$(printf '%s\n' "$pre" | sed -n 's/^DB_ID=\([0-9][0-9]*\)[[:space:]]*$/\1/p' | head -n 1)

# ---- optional recovery catalog: password and pre-flight --------------------------
# The password only ever lives in shell variables and travels on pipes (printf is a
# builtin, so it never shows up in a command line).  No file, no argv.
cat_pw="" cat_conn="" cat_arg6=""
scrub() {   # scrub TEXT: hide the catalog password in text before it is printed
  local t=$1
  if [ -n "$cat_pw" ]; then t=${t//"$cat_pw"/***}; fi
  printf '%s' "$t"
}
if [ -n "$catalog" ]; then
  if [ "$cat_wallet" -eq 1 ]; then
    cat_conn="/@$cat_alias"
    cat_arg6="\"/@$cat_alias\""
  else
    if [ -n "${RMAN_CATALOG_PASSWORD:-}" ]; then
      cat_pw=$RMAN_CATALOG_PASSWORD
    elif [ -t 0 ]; then
      IFS= read -r -s -p "Password for RMAN catalog $cat_label: " cat_pw || die "no password read"
      printf '\n' >&2
    else
      die "no catalog password: set RMAN_CATALOG_PASSWORD, or run on a terminal to be prompted (or use a wallet: -c /@alias)"
    fi
    # the variable must not leak into child processes
    unset RMAN_CATALOG_PASSWORD
    [ -n "$cat_pw" ] || die "the catalog password is empty"
    case $cat_pw in
      *\"*|*\'*) die "the catalog password must not contain a double or single quote" ;;
    esac
    case $cat_pw in
      *$'\n'*|*$'\r'*) die "the catalog password must not contain a line break" ;;
    esac
    cat_conn="$cat_user/\"$cat_pw\"@$cat_alias"
    # as a SQL*Plus script argument: wrapped in quotes, inner quotes doubled
    cat_arg6="\"$cat_user/\"\"$cat_pw\"\"@$cat_alias\""
  fi

  cat_dbid=${dbid:-$pre_dbid}
  [ -n "$cat_dbid" ] || die "cannot determine the DBID of '$sid' for the catalog check"
  info "checking RMAN recovery catalog $cat_label for DBID $cat_dbid ..."
  tmo=""
  if command -v timeout >/dev/null 2>&1; then tmo="timeout 90"; fi
  # shellcheck disable=SC2086  # $tmo is deliberately word-split ("timeout 90" or empty)
  cat_out=$(printf '%s\n' \
      'set define off heading off feedback off pagesize 0 verify off echo off termout on' \
      'whenever sqlerror exit failure' \
      "connect $cat_conn" \
      'whenever sqlerror continue' \
      "select 'CAT_LOGIN' || chr(61) || user from dual;" \
      "select 'CAT_REGISTERED' || chr(61) || count(*) from rc_database where dbid = $cat_dbid;" \
      "select 'CAT_JOBVIEW' || chr(61) || count(*) from rc_rman_backup_job_details where rownum = 1;" \
      'exit' | $tmo sqlplus -S /nolog 2>&1 || true)
  case $cat_out in
    *CAT_LOGIN=*) ;;
    *) die "cannot log in to the RMAN recovery catalog $cat_label: $(scrub "$(printf '%s' "$cat_out" | grep -E 'ORA-|SP2-|TNS-' | head -n 1 | cut -c1-200)")
    (a login failure is not retried against the controlfile: fix user, password or alias)" ;;
  esac
  cat_warn=""
  case $cat_out in
    *CAT_REGISTERED=*)
      if printf '%s\n' "$cat_out" | grep -q '^CAT_REGISTERED=0[[:space:]]*$'; then
        cat_warn="DBID $cat_dbid is not registered in the recovery catalog $cat_label"
      elif ! printf '%s\n' "$cat_out" | grep -q '^CAT_JOBVIEW='; then
        cat_warn="RC_RMAN_BACKUP_JOB_DETAILS is not accessible as $cat_label"
      fi ;;
    *) cat_warn="RC_DATABASE is not accessible as $cat_label (needs the catalog owner or a virtual private catalog user)" ;;
  esac
  if [ -n "$cat_warn" ]; then
    printf '%s: WARNING: %s; falling back to the controlfile (%s) for the cross-check section\n' "$PROG" "$cat_warn" "V\$RMAN_BACKUP_JOB_DETAILS" >&2
    catalog="" cat_arg6="" cat_label=""
  else
    info "recovery catalog $cat_label OK: DBID $cat_dbid is registered"
  fi
fi

# ---- run helpers ----------------------------------------------------------------
tmp=$(mktemp -d "${TMPDIR:-/tmp}/${PROG}.XXXXXX") || die "cannot create temp directory"
trap 'rm -rf -- "$tmp"' EXIT

# SQL*Plus positional args; "" = take the SQL script default
args=$(printf '%s %s %s %s %s %s' "${days:-\"\"}" "${gap:-\"\"}" "${dbid:-\"\"}" "${inst:-\"\"}" "${scope:-\"\"}" "${cat_arg6:-\"\"}")

errors=0

# scan_errors FILE LABEL: warn about lines starting with ORA-nnnnn / SP2-nnnn
scan_errors() {
  local file=$1 label=$2 hits
  hits=$(grep -E '^[[:space:]]*(ORA|SP2)-[0-9]+' -- "$file" | cut -c1-300 | head -n 20 || true)
  if [ -n "$hits" ]; then
    {
      printf '%s: WARNING: ORA-/SP2- errors found in %s:\n' "$PROG" "$label"
      printf '%s\n' "$hits" | sed 's/^/    /'
    } >&2
    errors=1
    case $hits in
      *ORA-01034*|*ORA-12162*|*ORA-12547*|*ORA-27101*|*ORA-01031*|*ORA-01017*)
        info "hint: check that -s '$sid' is a running instance on this host, that ORACLE_HOME matches it, and that this OS user is in the dba/OSDBA group" ;;
    esac
  fi
}

run_sqlplus() {   # run_sqlplus SCRIPT -> stdout/stderr of sqlplus; returns its rc
  # the script line goes in on stdin (it holds the catalog password, if any)
  ( cd -- "$outdir" && printf '%s\n' "@$1 $args" 'exit' | sqlplus -S -L / as sysdba )
}

stamp=$(date +%Y%m%d_%H%M)
produced=()

info "SID=$sid  days=${days:-60}  gap=${gap:-30}  dbid=${dbid:-current}  inst=${inst:-0}  scope=${scope:-RMAN}  format=$fmt  job source=${cat_label:+recovery catalog }${cat_label:-controlfile}"
[ "$scope" != ALL ] || info "scope=ALL: validation mode, no RMAN filter"

# ---- HTML -------------------------------------------------------------------------
if [ "$fmt" != text ]; then
  log=$tmp/html.log
  rc=0
  run_sqlplus "$html_sql" >"$log" 2>&1 || rc=$?
  scan_errors "$log" "sqlplus output (html report)"
  [ "$rc" -eq 0 ] || { info "sqlplus exited with status $rc (html report)"; errors=1; }
  name=$(sed -n 's/^Report written:[[:space:]]*//p' "$log" | tail -n 1)
  if [ -n "$name" ] && [ -s "$outdir/$name" ]; then
    scan_errors "$outdir/$name" "$name"
    produced+=("$outdir/$name")
  else
    info "ERROR: HTML report was not produced (no 'Report written' line or file missing/empty)"
    errors=1
    sed -n '1,20p' "$log" | cut -c1-300 | sed 's/^/    /' >&2
  fi
fi

# ---- text -------------------------------------------------------------------------
if [ "$fmt" != html ]; then
  txt=$outdir/awr_backup_overview_${sid}_${stamp}.txt
  rc=0
  run_sqlplus "$text_sql" >"$txt" 2>&1 || rc=$?
  scan_errors "$txt" "$(basename "$txt")"
  [ "$rc" -eq 0 ] || { info "sqlplus exited with status $rc (text report)"; errors=1; }
  if [ -s "$txt" ]; then
    produced+=("$txt")
  else
    info "ERROR: text report was not produced (file missing/empty)"
    errors=1
  fi
fi

# ---- safety net: the catalog password must not be in any output --------------------
if [ -n "$cat_pw" ]; then
  for f in "${produced[@]+"${produced[@]}"}" "$tmp"/*.log; do
    [ -f "$f" ] || continue
    if grep -qF -f <(printf '%s\n' "$cat_pw") -- "$f" 2>/dev/null; then
      info "ERROR: the catalog password was found in $(basename -- "$f"); removing it"
      rm -f -- "$f"
      produced=()
      errors=1
    fi
  done
fi

# ---- result -----------------------------------------------------------------------
for f in "${produced[@]+"${produced[@]}"}"; do
  printf '%s\n' "$f"
done

if [ "$errors" -ne 0 ]; then
  info "finished with errors"
  exit 1
fi
