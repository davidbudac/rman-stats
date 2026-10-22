#!/usr/bin/env bash
# ============================================================================
# awr_backup_report.sh
#
# Command line wrapper for the AWR backup reports, to be run on the database
# server.  Wraps awr_backup_report_html.sql (self-contained HTML report) and
# awr_backup_overview.sql (text report), which must sit in the same directory
# as this script (symlinks to the wrapper are fine).
#
# Connects with OS authentication (sqlplus -S -L / as sysdba), so no password.
# Run it as an OS user that is a member of the dba / OSDBA group (normally the
# oracle software owner).  Read-only; needs the Diagnostics Pack license.
#
# Examples
#   ./awr_backup_report.sh                          # HTML, last 60 days, $ORACLE_SID
#   ./awr_backup_report.sh -s cdb1 -d 14 -g 60      # SID cdb1, 14 days, 60 min run gap
#   ./awr_backup_report.sh -f both -o /tmp/awrout   # HTML + text report into /tmp/awrout
#   ./awr_backup_report.sh -a -d 14                 # scope=ALL (validation, no RMAN filter)
#   ./awr_backup_report.sh -i 2                     # RAC: instance 2 only
#
# Exit code: 0 = report(s) produced and no ORA-/SP2- errors found,
#            non-zero = usage error, environment problem, SQL error, or a
#            missing output file.  Generated file paths are printed on stdout.
# ============================================================================
set -euo pipefail

PROG=${0##*/}

usage() {
  cat <<EOF
Usage: $PROG [-s SID] [-d days] [-g gap_minutes] [-b dbid] [-i inst]
              [-a] [-f html|text|both] [-o output_dir] [-h]

Run the AWR backup reports on the database server via sqlplus / as sysdba
(OS authentication; run as a member of the dba / OSDBA group).

  -s SID        ORACLE_SID of the instance (default: \$ORACLE_SID; required)
  -d days       look-back window in days                    (default 60)
  -g minutes    idle gap that splits two runs of a backup type (default 30)
  -b dbid       DBID to report on                           (default: this DB)
  -i inst       instance number, 0 = all instances (RAC)    (default 0)
  -a            scope=ALL: no RMAN filter, group any MODULE (validation mode
                for a DB without backups; default scope is RMAN)
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
fmt=html
outdir=.

while getopts ':s:d:g:b:i:af:o:h' opt; do
  case $opt in
    s) sid=$OPTARG; sid_from_opt=1 ;;
    d) days=$OPTARG ;;
    g) gap=$OPTARG ;;
    b) dbid=$OPTARG ;;
    i) inst=$OPTARG ;;
    a) scope=ALL ;;
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
[ -n "$outdir" ] || die "-o output_dir must not be empty"

html_sql=$SCRIPT_DIR/awr_backup_report_html.sql
text_sql=$SCRIPT_DIR/awr_backup_overview.sql
if [ "$fmt" != text ]; then [ -r "$html_sql" ] || die "cannot read $html_sql"; fi
if [ "$fmt" != html ]; then [ -r "$text_sql" ] || die "cannot read $text_sql"; fi
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
exit
EOF
) 2>&1 || true )
case $pre in
  *INSTANCE_STATUS=OPEN*) ;;
  *INSTANCE_STATUS=*) die "instance '$sid' is not OPEN (${pre##*INSTANCE_STATUS=}); AWR data needs an open database" ;;
  *) die "cannot connect to instance '$sid' as sysdba: $(printf '%s' "$pre" | grep -E 'ORA-|SP2-|rror' | head -n 1 | cut -c1-200)
    (check -s / ORACLE_SID, that the instance is running, and that this OS user is in the dba/OSDBA group)" ;;
esac

# ---- run helpers ----------------------------------------------------------------
tmp=$(mktemp -d "${TMPDIR:-/tmp}/${PROG}.XXXXXX") || die "cannot create temp directory"
trap 'rm -rf -- "$tmp"' EXIT

# SQL*Plus positional args; "" = take the SQL script default
args=$(printf '%s %s %s %s %s' "${days:-\"\"}" "${gap:-\"\"}" "${dbid:-\"\"}" "${inst:-\"\"}" "${scope:-\"\"}")

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
  ( cd -- "$outdir" && sqlplus -S -L / as sysdba <<EOF
@$1 $args
exit
EOF
  )
}

stamp=$(date +%Y%m%d_%H%M)
produced=()

info "SID=$sid  days=${days:-60}  gap=${gap:-30}  dbid=${dbid:-current}  inst=${inst:-0}  scope=${scope:-RMAN}  format=$fmt"
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

# ---- result -----------------------------------------------------------------------
for f in "${produced[@]+"${produced[@]}"}"; do
  printf '%s\n' "$f"
done

if [ "$errors" -ne 0 ]; then
  info "finished with errors"
  exit 1
fi
