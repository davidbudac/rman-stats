#!/bin/sh
# ============================================================================
# awr_backup_report.sh
#
# Command line wrapper for the AWR backup reports, to be run on the database
# server.  Wraps awr_backup_report_html.sql (self-contained HTML report) and
# awr_backup_overview.sql (text report), which must sit in the same directory
# as this script together with their two helpers awr_backup_catalog_connect.sql
# and awr_backup_catalog_skip.sql (symlinks to the wrapper are fine).
#
# Portable POSIX shell: written for the AIX 7.2 /bin/sh (ksh88) as well as
# Linux (bash, dash, ksh93) with only base OS tools.  No bash-isms, no GNU-only
# options (readlink -f, mktemp, timeout and grep -o are used only if present or
# not at all).  Run it as "./awr_backup_report.sh" or "sh awr_backup_report.sh".
#
# Connects with OS authentication (sqlplus -S -L / as sysdba), so no password.
# Run it as an OS user that is a member of the dba / OSDBA group (normally the
# oracle software owner).  Read-only: the SQL scripts issue SELECTs only (plus
# the optional CONNECT to the catalog); the wrapper writes nothing but the report
# files and its own temp directory.  Needs the Diagnostics Pack license.
#
# SQL*Plus is always run from a private temp directory (mode 0700, under $TMPDIR
# or /tmp) with restrict level 1 (-R 1: no HOST, !, EDIT), so no login.sql or
# pre-created file/symlink in the output directory or the caller's directory can
# be picked up; the reports are written there and moved to the output directory
# when finished.
#
# Optional RMAN recovery catalog (-c): the cross-check section (RMAN job history,
# NOT AWR) then comes from RC_RMAN_BACKUP_JOB_DETAILS in the catalog instead of
# V$RMAN_BACKUP_JOB_DETAILS in the controlfile.  Everything else still comes
# from AWR on the target.  The catalog password is taken from the environment
# variable RMAN_CATALOG_PASSWORD (for cron) or asked for on the terminal (echo
# off via stty); a wallet (-c /@alias) needs none.  It is only ever passed to
# sqlplus on stdin (never on a command line, never in a file) and never printed;
# for that it is written with a shell built-in printf (or the ksh built-in
# print), and the script stops with an error if neither is available rather than
# let an external printf show it in "ps".  Before the reports run, a separate
# sqlplus session checks the catalog: a failed login is an error (exit 1, no
# fallback); a catalog that works but does not hold this DBID or whose RC_ views
# cannot be read gives a WARNING and the reports fall back to the controlfile.
# Passwords containing a double or single quote are rejected.  The catalog check
# is run under "timeout 90" when that command exists; otherwise it has no time
# limit of its own (the OS TCP timeout applies).
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

# No "set -e" / "set -u" / pipefail: they behave differently in ksh88, dash and
# bash.  Every step that can fail is checked explicitly instead.

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

# ---- cleanup: temp directory, terminal echo ------------------------------------
tmp=""
echo_off=0
# shellcheck disable=SC2329  # invoked through the EXIT trap below
cleanup() {
  if [ "$echo_off" -eq 1 ]; then
    stty echo 2>/dev/null
    echo_off=0
  fi
  if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
  return 0
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# ---- writing a secret to a pipe without it showing up in "ps" -------------------
# Where printf is an external command (ksh88 on AIX: /usr/bin/printf) the secret
# would be on its command line.  So: shell built-in printf if there is one, else
# the ksh built-in print, else refuse.  echo is not used (it interprets
# backslashes in dash and ksh).
secret_mode=""
secret_init() {
  si_t=$(LC_ALL=C; type printf 2>&1)
  case $si_t in
    *builtin*) secret_mode='printf'; return 0 ;;
  esac
  si_t=$(LC_ALL=C; type print 2>&1)
  case $si_t in
    *builtin*) secret_mode='print'; return 0 ;;
  esac
  return 1
}
secret_line() {   # secret_line TEXT: write TEXT and a newline to stdout
  case $secret_mode in
    printf) printf '%s\n' "$1" ;;
    print)  print -r -- "$1" ;;
    *)      return 1 ;;
  esac
}

# ---- resolve the wrapper's real directory (follows symlinks, portable) ------
# No readlink/realpath (not on AIX): the link target is read from "ls -ld".
resolve_dir() {
  rd_src=$1
  rd_n=0
  while [ -L "$rd_src" ]; do
    rd_n=$((rd_n + 1))
    [ "$rd_n" -le 40 ] || { echo "too many levels of symbolic links: $1" >&2; return 1; }
    case $rd_src in
      */*) rd_dir=${rd_src%/*}; [ -n "$rd_dir" ] || rd_dir=/ ;;
      *)   rd_dir=. ;;
    esac
    rd_ls=$(ls -ld "$rd_src") || return 1
    # (the "->" sits in variables: a bare ">" inside ${...} trips some ksh parsers)
    rd_arrow=" -> "
    rd_pat="$rd_src$rd_arrow"
    rd_target=${rd_ls#*"$rd_pat"}
    if [ "$rd_target" = "$rd_ls" ]; then rd_target=${rd_ls#*"$rd_arrow"}; fi
    case $rd_target in
      /*) rd_src=$rd_target ;;
      *)  rd_src=$rd_dir/$rd_target ;;
    esac
  done
  case $rd_src in
    */*) rd_dir=${rd_src%/*}; [ -n "$rd_dir" ] || rd_dir=/ ;;
    *)   rd_dir=. ;;
  esac
  cd -P "$rd_dir" && pwd -P
}

self=$0
case $self in
  */*) ;;
  *) if [ -f "$self" ]; then self=./$self; else self=$(command -v "$self" 2>/dev/null) || self=$0; fi ;;
esac
SCRIPT_DIR=$(resolve_dir "$self") || die "cannot determine the directory of $0"
[ -n "$SCRIPT_DIR" ] || die "cannot determine the directory of $0"

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
is_uint() {   # non-empty, digits only
  case $1 in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}
is_pos() {    # digits only and not all zeros
  is_uint "$1" || return 1
  case $1 in
    *[!0]*) return 0 ;;
  esac
  return 1
}

[ -n "$sid" ] || die "no SID: use -s SID or set ORACLE_SID"
case $sid in
  *[!A-Za-z0-9_#\$+-]*) die "invalid SID: '$sid'" ;;
esac
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
  case $cat_alias in
    ''|*[!A-Za-z0-9_.#\$:/+-]*)
      die "-c: invalid TNS alias or EZConnect string '$cat_alias' (allowed: letters, digits and . _ # \$ : / + -)" ;;
  esac
  if [ "$cat_wallet" -eq 0 ]; then
    case $cat_user in
      ''|[!A-Za-z]*|*[!A-Za-z0-9_#\$]*)
        die "-c: invalid catalog user '$cat_user' (expected a plain Oracle user name)" ;;
    esac
    cat_label="$cat_user@$cat_alias"
  else
    cat_label="wallet ($cat_alias)"
  fi
fi
[ -n "$outdir" ] || die "-o output_dir must not be empty"

# Take the catalog password out of the environment now, so that none of the
# child processes started from here on (oraenv, sqlplus) inherit it.
cat_pw_env=${RMAN_CATALOG_PASSWORD:-}
unset RMAN_CATALOG_PASSWORD

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
  mkdir -p "$outdir" || die "cannot create output directory: $outdir"
fi
outdir=$(cd -P "$outdir" && pwd -P) || die "cannot access output directory: $outdir"
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
  for oh_tab in /etc/oratab /var/opt/oracle/oratab; do
    [ -r "$oh_tab" ] || continue
    oh_home=$(awk -F: -v s="$1" '$1 == s && $2 != "" && $1 !~ /^#/ { print $2; exit }' "$oh_tab")
    if [ -n "$oh_home" ]; then printf '%s\n' "$oh_home"; return 0; fi
  done
  return 1
}

ORACLE_SID=$sid
export ORACLE_SID
if [ "$need_env" -eq 1 ]; then
  # oraenv may return non-zero harmlessly.  It is only sourced when it can be
  # found and read: "." of a missing file ends a POSIX shell, "|| true" or not.
  oe_file=$(command -v oraenv 2>/dev/null)
  if [ -n "$oe_file" ] && [ -r "$oe_file" ]; then
    ORAENV_ASK=NO
    export ORAENV_ASK
    # shellcheck disable=SC1090  # oraenv is found on PATH at run time
    . "$oe_file" </dev/null >/dev/null 2>&1 || true
  fi
  if [ -z "${ORACLE_HOME:-}" ] || ! command -v sqlplus >/dev/null 2>&1; then
    if home=$(oratab_home "$sid"); then
      ORACLE_HOME=$home
      PATH="$ORACLE_HOME/bin:$PATH"
      LD_LIBRARY_PATH="$ORACLE_HOME/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      LIBPATH="$ORACLE_HOME/lib${LIBPATH:+:$LIBPATH}"   # AIX
      export ORACLE_HOME PATH LD_LIBRARY_PATH LIBPATH
    fi
  fi
  # oraenv may have switched the SID (it keeps the one we exported)
  ORACLE_SID=$sid
  export ORACLE_SID
fi
command -v sqlplus >/dev/null 2>&1 \
  || die "sqlplus not found: ORACLE_HOME/PATH not set and SID '$sid' could not be resolved via oraenv or oratab (/etc/oratab)"

# ---- private work directory for sqlplus (mode 0700) -----------------------------
# SQL*Plus runs here, never in the output directory or the caller's directory, so
# that no login.sql and no pre-created file or symlink there can be picked up (it
# runs as SYSDBA).  The reports are written here and moved to the output directory
# when complete.
# mktemp is not on every AIX; mkdir without -p fails if the name exists, so a
# pre-created directory or symlink cannot be hijacked.  umask only in a subshell.
tmp_base=${TMPDIR:-/tmp}
if command -v mktemp >/dev/null 2>&1; then
  tmp=$(mktemp -d "$tmp_base/awrbr.XXXXXX" 2>/dev/null) || tmp=""
else
  tmp_i=0
  while [ "$tmp_i" -lt 20 ]; do
    tmp_try=$tmp_base/awrbr.$$.$tmp_i
    if (umask 077; mkdir "$tmp_try") 2>/dev/null; then tmp=$tmp_try; break; fi
    tmp_i=$((tmp_i + 1))
  done
fi
if [ -z "$tmp" ] || [ ! -d "$tmp" ]; then tmp=""; die "cannot create temp directory under $tmp_base"; fi

# ---- preflight: can we connect, and is the database open? ----------------------
pre=$(cd "$tmp" && printf '%s\n' \
    'set heading off feedback off pagesize 0 verify off' \
    "select 'INSTANCE_STATUS' || chr(61) || status from v\$instance;" \
    "select 'DB_ID' || chr(61) || dbid from v\$database;" \
    'exit' | sqlplus -S -L -R 1 / as sysdba 2>&1)
case $pre in
  *INSTANCE_STATUS=OPEN*) ;;
  *INSTANCE_STATUS=*) die "instance '$sid' is not OPEN (${pre##*INSTANCE_STATUS=}); AWR data needs an open database" ;;
  *) die "cannot connect to instance '$sid' as sysdba: $(printf '%s\n' "$pre" | grep -E 'ORA-|SP2-|rror' | sed -n '1p' | cut -c1-200)
    (check -s / ORACLE_SID, that the instance is running, and that this OS user is in the dba/OSDBA group)" ;;
esac

pre_dbid=$(printf '%s\n' "$pre" | sed -n 's/^DB_ID=\([0-9][0-9]*\)[[:space:]]*$/\1/p' | sed -n '1p')

# ---- optional recovery catalog: password and pre-flight --------------------------
# The password only ever lives in shell variables and travels on pipes, written by
# a built-in (see secret_line), so it is never in a command line.  No file, no argv.
cat_pw="" cat_conn="" cat_arg6=""
scrub() {   # scrub TEXT: hide the catalog password in a line of text before it is printed
  if [ -z "$cat_pw" ]; then printf '%s' "$1"; return 0; fi
  { secret_line "$cat_pw"; secret_line "$1"; } | awk '
    NR == 1 { pw = $0; next }
    { line = $0; out = ""
      while ((i = index(line, pw)) > 0) { out = out substr(line, 1, i - 1) "***"; line = substr(line, i + length(pw)) }
      printf "%s", out line }'
}
if [ -n "$catalog" ]; then
  if [ "$cat_wallet" -eq 1 ]; then
    cat_conn="/@$cat_alias"
    cat_arg6="\"/@$cat_alias\""
  else
    secret_init || die "cannot handle the catalog password safely: this shell has neither a built-in printf nor a built-in print, so it could appear in a process listing; run under ksh93/bash/dash or use a wallet (-c /@alias)"
    if [ -n "$cat_pw_env" ]; then
      cat_pw=$cat_pw_env
    elif [ -t 0 ]; then
      printf 'Password for RMAN catalog %s: ' "$cat_label" >&2
      stty -echo || die "cannot turn off terminal echo for the password prompt"
      echo_off=1
      IFS= read -r cat_pw
      read_rc=$?
      stty echo 2>/dev/null
      echo_off=0
      printf '\n' >&2
      [ "$read_rc" -eq 0 ] || die "no password read"
    else
      die "no catalog password: set RMAN_CATALOG_PASSWORD, or run on a terminal to be prompted (or use a wallet: -c /@alias)"
    fi
    cat_pw_env=""
    [ -n "$cat_pw" ] || die "the catalog password is empty"
    case $cat_pw in
      *\"*|*\'*) die "the catalog password must not contain a double or single quote" ;;
    esac
    nl='
'
    cr=$(printf '\r')
    case $cat_pw in
      *"$nl"*|*"$cr"*) die "the catalog password must not contain a line break" ;;
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
  # the connect line holds the password: written with secret_line, not printf
  # shellcheck disable=SC2086  # $tmo is deliberately word-split ("timeout 90" or empty)
  cat_out=$( {
      printf '%s\n' \
        'set define off heading off feedback off pagesize 0 verify off echo off termout on' \
        'whenever sqlerror exit failure'
      if [ -n "$cat_pw" ]; then secret_line "connect $cat_conn"; else printf '%s\n' "connect $cat_conn"; fi
      printf '%s\n' \
        'whenever sqlerror continue' \
        "select 'CAT_LOGIN' || chr(61) || user from dual;" \
        "select 'CAT_REGISTERED' || chr(61) || count(*) from rc_database where dbid = $cat_dbid;" \
        "select 'CAT_JOBVIEW' || chr(61) || count(*) from rc_rman_backup_job_details where rownum = 1;" \
        'exit'
    } | (cd "$tmp" && $tmo sqlplus -S -R 1 /nolog) 2>&1 )
  case $cat_out in
    *CAT_LOGIN=*) ;;
    *) die "cannot log in to the RMAN recovery catalog $cat_label: $(scrub "$(printf '%s\n' "$cat_out" | grep -E 'ORA-|SP2-|TNS-' | sed -n '1p' | cut -c1-200)")
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

# SQL*Plus positional args; "" = take the SQL script default
dq='""'
args="${days:-$dq} ${gap:-$dq} ${dbid:-$dq} ${inst:-$dq} ${scope:-$dq} ${cat_arg6:-$dq}"

errors=0

# scan_errors FILE LABEL: warn about lines starting with ORA-nnnnn / SP2-nnnn
scan_errors() {
  se_hits=$(grep -E '^[[:space:]]*(ORA|SP2)-[0-9]+' "$2" 2>/dev/null | cut -c1-300 | sed '20q')
  if [ -n "$se_hits" ]; then
    {
      printf '%s: WARNING: ORA-/SP2- errors found in %s:\n' "$PROG" "$1"
      printf '%s\n' "$se_hits" | sed 's/^/    /'
    } >&2
    errors=1
    case $se_hits in
      *ORA-01034*|*ORA-12162*|*ORA-12547*|*ORA-27101*|*ORA-01031*|*ORA-01017*)
        info "hint: check that -s '$sid' is a running instance on this host, that ORACLE_HOME matches it, and that this OS user is in the dba/OSDBA group" ;;
    esac
  fi
}

run_sqlplus() {   # run_sqlplus SCRIPT -> stdout/stderr of sqlplus; returns its rc
  # the script line goes in on stdin (it holds the catalog password, if any);
  # sqlplus is the last command of the pipeline, so its status is the result;
  # it runs in the private work directory, so the HTML spool lands there
  (
    cd "$tmp" || exit 1
    {
      if [ -n "$cat_pw" ]; then secret_line "@$1 $args"; else printf '%s\n' "@$1 $args"; fi
      printf '%s\n' 'exit'
    } | sqlplus -S -L -R 1 / as sysdba
  )
}

publish() {   # publish SRC DEST: move a finished report from the work directory to the output directory
  # mv replaces the directory entry, it never writes through a symlink; still refuse
  # to replace anything that is not a plain file (symlink, directory, device).
  if [ -L "$2" ] || { [ -e "$2" ] && [ ! -f "$2" ]; }; then
    info "ERROR: refusing to replace $2: it exists and is not a regular file"
    return 1
  fi
  mv -f "$1" "$2" || { info "ERROR: cannot move ${1##*/} to $2"; return 1; }
  return 0
}

stamp=$(date +%Y%m%d_%H%M)
set --    # from here on the positional parameters hold the list of produced files

info "SID=$sid  days=${days:-60}  gap=${gap:-30}  dbid=${dbid:-current}  inst=${inst:-0}  scope=${scope:-RMAN}  format=$fmt  job source=${cat_label:+recovery catalog }${cat_label:-controlfile}"
[ "$scope" != ALL ] || info "scope=ALL: validation mode, no RMAN filter"

# ---- HTML -------------------------------------------------------------------------
if [ "$fmt" != text ]; then
  log=$tmp/html.log
  rc=0
  run_sqlplus "$html_sql" >"$log" 2>&1 || rc=$?
  scan_errors "sqlplus output (html report)" "$log"
  [ "$rc" -eq 0 ] || { info "sqlplus exited with status $rc (html report)"; errors=1; }
  name=$(sed -n 's/^Report written:[[:space:]]*//p' "$log" | sed -n '$p')
  case $name in ''|*/*|.*) name="" ;; esac
  if [ -n "$name" ] && [ -s "$tmp/$name" ]; then
    scan_errors "$name" "$tmp/$name"
    if publish "$tmp/$name" "$outdir/$name"; then set -- "$@" "$outdir/$name"; else errors=1; fi
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
  run_sqlplus "$text_sql" >"$tmp/text.out" 2>&1 || rc=$?
  scan_errors "${txt##*/}" "$tmp/text.out"
  [ "$rc" -eq 0 ] || { info "sqlplus exited with status $rc (text report)"; errors=1; }
  if [ -s "$tmp/text.out" ]; then
    if publish "$tmp/text.out" "$txt"; then set -- "$@" "$txt"; else errors=1; fi
  else
    info "ERROR: text report was not produced (file missing/empty)"
    errors=1
  fi
fi

# ---- safety net: the catalog password must not be in any output --------------------
# The password goes to awk on stdin ("-"), the file to search is its other operand.
if [ -n "$cat_pw" ]; then
  for f in "$@" "$tmp"/*; do
    [ -f "$f" ] || continue
    if secret_line "$cat_pw" | awk 'NR == FNR { pw = $0; next } index($0, pw) { found = 1; exit } END { exit !found }' - "$f" 2>/dev/null; then
      info "ERROR: the catalog password was found in ${f##*/}; removing it"
      rm -f "$f"
      set --
      errors=1
    fi
  done
fi

# ---- result -----------------------------------------------------------------------
for f in "$@"; do
  printf '%s\n' "$f"
done

if [ "$errors" -ne 0 ]; then
  info "finished with errors"
  exit 1
fi
exit 0
