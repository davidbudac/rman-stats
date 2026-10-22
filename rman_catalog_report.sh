#!/bin/sh
# Catalog-only, read-only report. Requires SQL*Plus on PATH (Oracle 19c).
# Never run with shell tracing: connection credentials travel on stdin.
set +x
PROG=${0##*/}
cat_pw=${RMAN_CATALOG_PASSWORD:-}
unset RMAN_CATALOG_PASSWORD
usage() {
  echo "Usage: $PROG -c user@alias -b DBID [-d days] [-o directory]"
  echo '       -c /@wallet_alias is also supported; default window: 90 days.'
  echo 'One DBID is required. Password: RMAN_CATALOG_PASSWORD or terminal prompt.'
}
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
tmp='' echo_off=0
cleanup() {
  if [ "$echo_off" -eq 1 ]; then stty echo 2>/dev/null; fi
  if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
  return 0
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
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


catalog='' dbid='' days=90 outdir=.
while getopts ':c:b:d:o:h' opt; do
  case $opt in
    c) catalog=$OPTARG ;; b) dbid=$OPTARG ;; d) days=$OPTARG ;;
    o) outdir=$OPTARG ;; h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || die 'unexpected arguments'
case $dbid in ''|*[!0-9]*) die '-b requires one numeric DBID' ;; esac
[ ${#dbid} -le 10 ] && [ "$dbid" -gt 0 ] || die 'DBID must be a positive integer of at most 10 digits'
case $days in ''|*[!0-9]*) die '-d requires a positive integer' ;; esac
[ ${#days} -le 4 ] && [ "$days" -gt 0 ] && [ "$days" -le 3650 ] || die 'days must be between 1 and 3650'
case $catalog in
  /@*) cat_user=''; cat_alias=${catalog#/@} ;;
  *@*) cat_user=${catalog%%@*}; cat_alias=${catalog#*@}
       case $cat_user in ''|[!A-Za-z]*|*[!A-Za-z0-9_#\$]*) die 'invalid catalog user; use user@alias without a password' ;; esac ;;
  *) die '-c requires user@alias or /@wallet_alias' ;;
esac
case $cat_alias in ''|*[!A-Za-z0-9_.#\$:/+-]*) die 'invalid catalog alias' ;; esac
command -v sqlplus >/dev/null 2>&1 || die 'sqlplus must be on PATH'
[ -r "$SCRIPT_DIR/rman_catalog_report_html.sql" ] || die 'SQL file missing beside wrapper'
secret_init || die 'a shell with builtin printf or print is required'
if [ -n "$cat_user" ]; then
  if [ -z "$cat_pw" ]; then
    [ -t 0 ] || die 'set RMAN_CATALOG_PASSWORD or use a wallet'
    printf 'Catalog password: ' >&2
    stty -echo || die 'cannot disable terminal echo'
    echo_off=1
    IFS= read -r cat_pw
    read_rc=$?
    stty echo; echo_off=0
    printf '\n' >&2
    [ "$read_rc" -eq 0 ] || die 'password not read'
  fi
  nl='
'
  cr=$(printf '\r')
  case $cat_pw in ''|*\"*|*\'*|*"$nl"*|*"$cr"*) die 'password cannot be empty or contain quotes or line breaks' ;; esac
  cat_conn="$cat_user/\"$cat_pw\"@$cat_alias"
else
  cat_pw=''
  cat_conn="/@$cat_alias"
fi
umask 077
# Atomic mkdir also works on AIX systems without mktemp.
tmp_base=${TMPDIR:-/tmp}
case $tmp_base in /*) ;; *) die 'TMPDIR must be absolute' ;; esac
i=0
while [ "$i" -lt 20 ]; do
  candidate=$tmp_base/rmancat.$$.$i
  if mkdir "$candidate" 2>/dev/null; then tmp=$candidate; break; fi
  i=$((i + 1))
done
[ -n "$tmp" ] || die 'cannot create private working directory'
cp "$SCRIPT_DIR/rman_catalog_report_html.sql" "$tmp/report.sql" || die 'cannot copy SQL'
# Do not search caller-controlled SQLPATH/login.sql locations.
unset SQLPATH ORACLE_PATH
{
  secret_line 'set echo off verify off define off'
  secret_line 'whenever sqlerror exit failure rollback'
  secret_line 'whenever oserror exit failure rollback'
  secret_line "connect $cat_conn"
  secret_line "@report.sql $dbid $days"
  secret_line 'exit success'
} | (cd "$tmp" && sqlplus -S -L -R 1 /nolog) >"$tmp/run.log" 2>&1
rc=$?
# Never print raw SQL*Plus diagnostics: malformed connection errors can echo secrets.
[ "$rc" -eq 0 ] || die 'catalog report failed: check credentials, DBID, catalog access and Oracle version'
if grep -E 'ORA-[0-9]+|SP2-[0-9]+|TNS-[0-9]+' "$tmp/run.log" "$tmp/report.html" >/dev/null 2>&1; then
  die 'SQL*Plus reported an error; no report published'
fi
[ -s "$tmp/report.html" ] && grep -q '<!-- report-complete -->' "$tmp/report.html" || die 'incomplete report'
if [ -n "$cat_pw" ]; then
  if secret_line "$cat_pw" | awk 'NR==FNR {p=$0; next} index($0,p) {found=1} END {exit !found}' - "$tmp/report.html"; then
    die 'credential detected in output; no report published'
  fi
fi
mkdir -p "$outdir" || die 'cannot create output directory'
outdir=$(cd "$outdir" && pwd -P) || die 'invalid output directory'
# A new directory avoids overwriting an existing report or following a planted symlink.
dest=$outdir/rman_catalog_${dbid}_$(date +%Y%m%d_%H%M%S)_$$
mkdir "$dest" || die 'output destination already exists or is not writable'
mv "$tmp/report.html" "$dest/report.html" || die 'cannot publish report'
printf '%s/report.html\n' "$dest"
