-- ============================================================================
-- awr_backup_report_html.sql
--
-- One self-contained, offline HTML report on RMAN / backup activity, built
-- from AWR (DBA_HIST_*) plus one clearly labelled non-AWR cross-check (controlfile,
-- or RMAN recovery catalog with the catalog argument).  This is
-- the visual companion of awr_backup_overview.sql (same logic, same caveats).
--
-- Usage (SQL*Plus, connected as SYSDBA or a user that can read DBA_HIST_*):
--
--   @awr_backup_report_html.sql [days] [gap_minutes] [dbid] [inst] [scope] [catalog]
--
--   days         look-back window in days                       default 60
--   gap_minutes  idle gap (minutes) that splits two runs of the
--                same backup type                               default 30
--   dbid         DBID to report on                              default: this DB
--   inst         instance number, 0 = all instances (RAC)       default 0
--   scope        RMAN = only RMAN sessions (normal use)         default RMAN
--                ALL  = NO RMAN filter, group any MODULE; only for validating
--                       the report on a DB that has no backups
--   catalog      optional RMAN recovery catalog connect string for the
--                cross-check panel, e.g. rco/secret@catdb or /@catwallet (wallet /
--                external auth).  Empty = read V$RMAN_BACKUP_JOB_DETAILS from the
--                controlfile.  Given = the script CONNECTs to the catalog as the
--                last DB work (all AWR data is read from the target first) and
--                reads RC_RMAN_BACKUP_JOB_DETAILS for this DBID instead.
--                The connect string must not contain a single quote.  Passing a
--                password on the command line is visible in ps; prefer a wallet
--                or let awr_backup_report.sh feed it through stdin.  The password
--                is never written to the report: only user@tns (or "wallet").
--                If the login fails the script stops (exit status 1) and the
--                report file is incomplete; if the DBID is not registered, or
--                the RC_ views cannot be read, the panel says so and stays empty.
--                Needs awr_backup_catalog_connect.sql and
--                awr_backup_catalog_skip.sql in the same directory.
--
--   Examples:  @awr_backup_report_html.sql
--              @awr_backup_report_html.sql 14 60
--              @awr_backup_report_html.sql 60 30 "" 2
--              @awr_backup_report_html.sql "" "" "" "" ALL
--              @awr_backup_report_html.sql 60 30 "" "" "" /@catwallet
--   Pass "" (or omit) to take the default; omitted trailing args are fine.
--
-- Output
--   awr_backup_report_<DBNAME>_<yyyymmdd_hh24mi>.html in the current directory.
--   No external CDN, fonts, JS or CSS: open it in any browser, offline.
--   The data is embedded as JSON (built with JSON_OBJECT), the charts are drawn
--   by a small vanilla-JS SVG renderer that is part of the file.
--
-- How backup types and runs are found (same as the text version)
--   AWR has no backup-type table.  The type is the MODULE of the sessions in
--   DBA_HIST_ACTIVE_SESS_HISTORY (ASH) with a ': channel' suffix removed, if
--   there is one.  Oracle 19c has no suffix (observed: MODULE 'backup archivelog',
--   PROGRAM 'rman@host (TNS V1-V3)'), so the channel count then comes from the
--   number of distinct sessions.  Other RMAN sessions (MODULE 'RMAN$CATALOG' or
--   'rman@host ...') are the type 'RMAN client/catalog'.  Oracle labels
--   incremental backups of every level 'backup incr datafile', level 0
--   included (observed on 19c; V$RMAN_BACKUP_JOB_DETAILS says 'DB INCR' in the
--   same way), so 'backup full datafile' only covers BACKUP DATABASE /
--   TABLESPACE / DATAFILE without the INCREMENTAL keyword.  Within a type a
--   new run starts when the gap since the previous ASH sample is greater than
--   gap_minutes; the decision is made once per sample second, so channels
--   sampled at the same instant always share a run.  A channel that switches
--   back to a type after working on
--   another one (BACKUP DATABASE PLUS ARCHIVELOG) continues a run only if that
--   run had a sample within the last 2 minutes (rejoin_minutes, defined below),
--   so the two archivelog phases around a datafile backup are two runs.  The
--   same applies when a channel of the previous run left the type shortly
--   before.
--
-- Limits - read before trusting the numbers
--   * Needs the Diagnostics Pack license (AWR/ASH).
--   * DBA_HIST_ACTIVE_SESS_HISTORY keeps 1 in 10 of the in-memory ASH samples
--     (one sample = about 10 s of one active session).  Everything derived from
--     it is a SAMPLED ESTIMATE: DB time = samples x 10 s, run start/end are
--     accurate to about 10 s, backups shorter than about 10 s may be missed.
--   * IO volume per run is an estimate: delta_bytes / delta_time * 10 s per
--     retained sample.  The authoritative figure is DBA_HIST_IOSTAT_FUNCTION,
--     function 'RMAN'; it also counts non-backup IO, so it is an UPPER BOUND.
--   * MB/s is an average over the whole run (elapsed = end - start + 10 s).
--   * AWR retention may be shorter than the requested window; the report header
--     says so (PARTIAL) when it is.
--   * The cross-check panel reads V$RMAN_BACKUP_JOB_DETAILS (controlfile, limited
--     by control_file_record_keep_time) or, with the catalog argument,
--     RC_RMAN_BACKUP_JOB_DETAILS (recovery catalog, normally a much longer
--     history).  It is NOT AWR.  The window start is taken from the target DB
--     clock before the catalog connect.
--   * In a CDB, run from CDB$ROOT to see all containers.
--   * The report embeds at most 5000 cross-check jobs.
--
-- Read-only: SELECT statements only (plus one anonymous block that only reads the
-- RC_ views, and the CONNECT to the catalog).  The ASH query chain is repeated for each
-- result set on purpose (SQL*Plus cannot share a CTE between statements and this
-- script must not create temp tables).  Keep the chains in sync when editing.
-- ============================================================================

whenever sqlerror continue
set define '&' verify off echo off termout off feedback off heading on
set trimspool on trimout on tab off
set lines 250 pages 200 long 4000 numwidth 12
set serveroutput off
-- A channel that switches back to a backup type after working on another
-- type (BACKUP ... PLUS ARCHIVELOG) continues an existing run of that type
-- only if the run had a sample within this many minutes; otherwise a new
-- run starts.  Not a positional parameter on purpose.
define rejoin_minutes = 2
ttitle off
btitle off
repheader off
repfooter off
clear columns
clear breaks
clear computes

-- Positional parameters with defaults ---------------------------------------
column 1 new_value 1 noprint
column 2 new_value 2 noprint
column 3 new_value 3 noprint
column 4 new_value 4 noprint
column 5 new_value 5 noprint
column 6 new_value 6 noprint
select null "1", null "2", null "3", null "4", null "5", null "6" from dual where 1 = 0;

column p_days  new_value days        noprint
column p_gap   new_value gap_minutes noprint
column p_dbid  new_value dbid        noprint
column p_inst  new_value inst        noprint
column p_scope new_value scope       noprint
column p_file  new_value fname       noprint
column p_win   new_value jobs_win    noprint
column p_csrc  new_value cat_src     noprint
column p_clab  new_value cat_label   noprint
column p_cscr  new_value cat_script  noprint
column p_keep  new_value cat_keep    noprint
column p_sess new_value cat_sess0   noprint
-- Cross-check source: CONTROLFILE or CATALOG.  The password in &6 is only used in
-- this statement (to derive the label user@tns or "wallet") and by the CONNECT.
select to_number(nvl('&1', '60'))                    p_days,
       to_number(nvl('&2', '30'))                    p_gap,
       to_number(nvl('&3', to_char(d.dbid)))         p_dbid,
       to_number(nvl('&4', '0'))                     p_inst,
       upper(nvl('&5', 'RMAN'))                      p_scope,
       'awr_backup_report_' || d.name || '_' || to_char(sysdate, 'yyyymmdd_hh24mi') || '.html' p_file,
       to_char(sysdate - to_number(nvl('&1', '60')), 'YYYY-MM-DD HH24:MI:SS') p_win,
       case when c.s is null then 'CONTROLFILE' else 'CATALOG' end            p_csrc,
       c.lab                                                                  p_clab,
       case when c.s is null then 'awr_backup_catalog_skip.sql'
            else 'awr_backup_catalog_connect.sql' end                         p_cscr,
       (select max(value) from v$parameter where name = 'control_file_record_keep_time') p_keep,
       to_char(sys_context('userenv', 'sessionid'))                           p_sess
  from v$database d
  cross join (select s,
                     case when s is null then ''
                          when nvl(instr(s, '/'), 0) = 1 or instr(s, '@') = 1
                            then 'wallet (' || case when instr(s, '@', -1) > 0 then substr(s, instr(s, '@', -1) + 1) else 'local' end || ')'
                          else substr(s, 1, least(nvl(nullif(instr(s, '/'), 0), 4000), nvl(nullif(instr(s, '@'), 0), 4000)) - 1)
                               || '@' || case when instr(s, '@', -1) > 0 then substr(s, instr(s, '@', -1) + 1) else 'local' end
                     end lab
                from (select cast(q'~&6~' as varchar2(4000)) s from dual)) c;
column p_win   clear
column p_csrc  clear
column p_clab  clear
column p_cscr  clear
column p_keep  clear
column p_sess clear
column p_days  clear
column p_gap   clear
column p_dbid  clear
column p_inst  clear
column p_scope clear
column p_file  clear
column 1 clear
column 2 clear
column 3 clear
column 4 clear
column 5 clear
column 6 clear

set termout on
prompt Generating &fname  (days=&days gap_minutes=&gap_minutes dbid=&dbid inst=&inst scope=&scope) ...
set termout off

spool &fname
set pages 0 heading off feedback off trimspool on lines 32767 termout off verify off newpage none
set define off sqlterminator off
prompt <!DOCTYPE html>
prompt <html lang="en">
prompt <head>
prompt <meta charset="utf-8">
prompt <meta name="viewport" content="width=device-width,initial-scale=1">
prompt <meta name="color-scheme" content="light dark">
prompt <title>Backup report</title>
prompt <style>
prompt :root{color-scheme:light;
prompt --bg:#eff1ee;--card:#fcfcfb;--soft:#f3f4f2;--ink:#14161a;--ink2:#4a5057;--mute:#737880;--line:#d9dcd8;--grid:#e7e9e5;
prompt --c1:#2a78d6;--c2:#eb6834;--c3:#1baf7a;--c4:#eda100;--c5:#e87ba4;--c6:#008300;--c7:#6250d6;--c8:#e34948;--other:#a3a39c;
prompt --seq-lo:#e1ecfa;--seq-hi:#184f95;--hatch:#d5d8d3;
prompt --w-cpu:#1baf7a;--w-io:#eb6834;--w-mml:#6250d6;--w-oth:#a3a39c;--read:#1baf7a;--write:#6250d6;
prompt --good:#0ca30c;--warn:#fab219;--crit:#d03b3b;
prompt --warn-bg:#fff3d1;--warn-ink:#5e4200;--crit-bg:#fde7e7;--crit-ink:#7a1b1b;--info-bg:#e6eefa;--info-ink:#1c3f73;
prompt --serif:ui-serif,"Iowan Old Style","Palatino Linotype",Palatino,Georgia,serif;
prompt --sans:ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;
prompt --mono:ui-monospace,"SF Mono",Menlo,Consolas,monospace}
prompt @media (prefers-color-scheme:dark){:root:where(:not([data-theme="light"])){color-scheme:dark;
prompt --bg:#0f1011;--card:#181817;--soft:#202020;--ink:#f0efec;--ink2:#c3c2b7;--mute:#8e8d86;--line:#2e2e2b;--grid:#272725;
prompt --c1:#3987e5;--c2:#d95926;--c3:#199e70;--c4:#c98500;--c5:#d55181;--c6:#008300;--c7:#9085e9;--c8:#e66767;--other:#85857c;
prompt --seq-lo:#1d2735;--seq-hi:#6da7ec;--hatch:#2f2f2c;
prompt --w-cpu:#199e70;--w-io:#d95926;--w-mml:#9085e9;--w-oth:#85857c;--read:#199e70;--write:#9085e9;
prompt --warn-bg:#3a2e0c;--warn-ink:#f6d27a;--crit-bg:#3d1a1a;--crit-ink:#f3a6a6;--info-bg:#18273d;--info-ink:#a9c8f2}}
prompt :root[data-theme="dark"]{color-scheme:dark;
prompt --bg:#0f1011;--card:#181817;--soft:#202020;--ink:#f0efec;--ink2:#c3c2b7;--mute:#8e8d86;--line:#2e2e2b;--grid:#272725;
prompt --c1:#3987e5;--c2:#d95926;--c3:#199e70;--c4:#c98500;--c5:#d55181;--c6:#008300;--c7:#9085e9;--c8:#e66767;--other:#85857c;
prompt --seq-lo:#1d2735;--seq-hi:#6da7ec;--hatch:#2f2f2c;
prompt --w-cpu:#199e70;--w-io:#d95926;--w-mml:#9085e9;--w-oth:#85857c;--read:#199e70;--write:#9085e9;
prompt --warn-bg:#3a2e0c;--warn-ink:#f6d27a;--crit-bg:#3d1a1a;--crit-ink:#f3a6a6;--info-bg:#18273d;--info-ink:#a9c8f2}
prompt *{box-sizing:border-box}
prompt html{background:var(--bg)}
prompt body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 var(--sans);-webkit-font-smoothing:antialiased;font-variant-numeric:tabular-nums}
prompt .wrap{max-width:1360px;margin:0 auto;padding:0 28px 48px}
prompt button{font:inherit;color:inherit}
prompt .bar{display:flex;align-items:center;justify-content:space-between;padding:18px 0 14px;border-bottom:1px solid var(--line)}
prompt .brand{display:flex;align-items:center;gap:10px;font-weight:600;letter-spacing:.01em}
prompt .brand i{display:inline-block;width:18px;height:18px;border-radius:5px;background:conic-gradient(var(--c1) 0 30%,var(--c2) 0 52%,var(--c3) 0 72%,var(--c7) 0 100%)}
prompt .bar-r{display:flex;align-items:center;gap:14px;color:var(--mute);font-size:12.5px}
prompt .btn{background:var(--card);border:1px solid var(--line);border-radius:7px;padding:5px 11px;cursor:pointer;font-size:12.5px}
prompt .btn:hover{border-color:var(--mute)}
prompt .btn:focus-visible,.lgi:focus-visible,.chip:focus-visible,th[data-sk]:focus-visible,.seg button:focus-visible{outline:2px solid var(--c1);outline-offset:2px}
prompt .hero{display:grid;grid-template-columns:minmax(260px,1fr) minmax(320px,1.6fr);gap:32px;padding:34px 0 22px}
prompt .hero h1{font:600 clamp(40px,6vw,72px)/1 var(--serif);margin:0 0 10px;letter-spacing:-.02em}
prompt .hero .lede{font:400 18px/1.35 var(--serif);color:var(--ink2);margin:0;max-width:34ch}
prompt .facts{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px 28px;margin:0;align-content:start}
prompt .facts div{border-top:1px solid var(--line);padding-top:7px;min-width:0}
prompt .facts dt{font-size:12px;color:var(--mute);margin:0 0 2px}
prompt .facts dd{margin:0;font-weight:500;overflow-wrap:anywhere}
prompt .facts dd small{display:block;font-weight:400;color:var(--ink2);font-size:12px}
prompt .ruler{grid-column:1/-1}
prompt .ruler .rl{display:flex;justify-content:space-between;font-size:12px;color:var(--mute);margin-top:5px}
prompt .ruler svg{display:block;width:100%;height:16px}
prompt .ruler .rt{font-size:12.5px;color:var(--ink2);margin-bottom:6px}
prompt .banner{display:flex;gap:12px;align-items:flex-start;border-radius:10px;padding:12px 16px;margin:0 0 14px;border:1px solid transparent}
prompt .banner svg{flex:none;margin-top:2px}
prompt .banner b{display:block}
prompt .banner.warn{background:var(--warn-bg);color:var(--warn-ink);border-color:color-mix(in srgb,var(--warn) 55%,transparent)}
prompt .banner.crit{background:var(--crit-bg);color:var(--crit-ink);border-color:color-mix(in srgb,var(--crit) 55%,transparent)}
prompt .banner.info{background:var(--info-bg);color:var(--info-ink);border-color:color-mix(in srgb,var(--c1) 40%,transparent)}
prompt .kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;margin:8px 0 12px}
prompt .kpi{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px 18px 14px;min-width:0}
prompt .kpi .n{font:600 26px/1.1 var(--serif);letter-spacing:-.01em;white-space:nowrap}
prompt .kpi .n small{font:500 13px var(--sans);color:var(--mute);margin-left:4px;letter-spacing:0}
prompt .kpi .l{font-size:13px;margin-top:6px;color:var(--ink)}
prompt .kpi .s{font-size:12px;color:var(--mute);margin-top:2px;overflow-wrap:anywhere}
prompt .last{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 18px;margin-bottom:6px}
prompt .last h3{margin:0 0 8px;font-size:13px;font-weight:600}
prompt .last ul{list-style:none;margin:0;padding:0;display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:6px 22px}
prompt .last li{display:flex;gap:8px;align-items:baseline;min-width:0;font-size:13px}
prompt .last li .nm{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1}
prompt .last li em{font-style:normal;color:var(--mute);white-space:nowrap}
prompt .dot{display:inline-block;width:9px;height:9px;border-radius:3px;flex:none;margin-right:6px}
prompt .grid{display:grid;grid-template-columns:repeat(12,minmax(0,1fr));gap:14px}
prompt .sec{grid-column:1/-1;display:flex;align-items:baseline;gap:14px;margin:30px 0 0;padding-bottom:8px;border-bottom:1px solid var(--line)}
prompt .sec h2{font:600 22px/1.2 var(--serif);margin:0;letter-spacing:-.005em}
prompt .sec p{margin:0;color:var(--mute);font-size:13px}
prompt .card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px 18px 14px;min-width:0;grid-column:span 12}
prompt .card.s6{grid-column:span 6}.card.s5{grid-column:span 5}.card.s7{grid-column:span 7}
prompt .ch{display:flex;justify-content:space-between;align-items:flex-start;gap:12px;margin-bottom:8px}
prompt .ch h3{margin:0;font-size:15px;font-weight:600}
prompt .ch p{margin:2px 0 0;font-size:12.5px;color:var(--mute);max-width:70ch}
prompt .note{font-size:12px;color:var(--mute);margin:8px 0 0}
prompt .seg{display:inline-flex;border:1px solid var(--line);border-radius:7px;overflow:hidden;flex:none}
prompt .seg button{white-space:nowrap;background:transparent;border:0;border-right:1px solid var(--line);padding:3px 10px;font-size:12px;cursor:pointer;color:var(--ink2)}
prompt .seg button:last-child{border-right:0}
prompt .seg button.on{background:var(--ink);color:var(--card)}
prompt .lg{display:flex;flex-wrap:wrap;gap:4px 14px;margin:0 0 6px}
prompt .lgi{background:none;border:0;padding:2px 0;cursor:pointer;font-size:12px;color:var(--ink2);display:inline-flex;align-items:center;gap:6px}
prompt .lgi i{display:inline-block;width:10px;height:10px;border-radius:3px}
prompt .lgi i.ln{height:3px;width:14px;border-radius:2px}
prompt .lgi.off{opacity:.38;text-decoration:line-through}
prompt .lgs{font-size:12px;color:var(--ink2);display:inline-flex;align-items:center;gap:6px}
prompt svg.chart{display:block;overflow:visible}
prompt svg text{font-family:var(--sans);fill:var(--mute);font-size:11px}
prompt svg .ax{stroke:var(--line)}
prompt svg .gl{stroke:var(--grid)}
prompt svg .lab{fill:var(--ink2)}
prompt svg [data-t]:hover{filter:brightness(1.12);stroke:var(--ink);stroke-width:1}
prompt .empty{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4px;min-height:150px;border:1px dashed var(--line);border-radius:8px;color:var(--mute);text-align:center;padding:20px;font-size:12.5px}
prompt .empty b{color:var(--ink2);font-size:13.5px}
prompt .donut{display:flex;gap:22px;align-items:center;flex-wrap:wrap}
prompt .donut ul{list-style:none;margin:0;padding:0;flex:1;min-width:200px;font-size:13px}
prompt .donut li{display:flex;gap:8px;align-items:baseline;padding:3px 0;border-bottom:1px solid var(--grid)}
prompt .donut li span.nm{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
prompt .donut li b{font-weight:600}
prompt .donut li em{font-style:normal;color:var(--mute);width:46px;text-align:right}
prompt .wp{display:grid;gap:6px}
prompt .wr{display:grid;grid-template-columns:minmax(110px,200px) 1fr 70px;gap:10px;align-items:center;font-size:12.5px}
prompt .wr .nm{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;display:flex;align-items:center;gap:6px}
prompt .wr .tr{display:flex;gap:2px;height:20px;border-radius:4px;overflow:hidden;background:var(--soft)}
prompt .wr .tr span{display:flex;align-items:center;justify-content:center;font-size:10.5px;color:#fff;min-width:0;overflow:hidden}
prompt .wr .v{text-align:right;color:var(--mute)}
prompt .sm{display:grid;grid-template-columns:repeat(auto-fill,minmax(270px,1fr));gap:18px 24px}
prompt .sm h4{margin:0 0 6px;font-size:13px;font-weight:600;display:flex;align-items:center;gap:6px}
prompt .sm h4 .t{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}.sm h4 em{white-space:nowrap;font-style:normal;font-weight:400;color:var(--mute);font-size:12px;margin-left:auto}
prompt .eb{display:grid;grid-template-columns:minmax(110px,1.5fr) 1fr 36px;gap:8px;align-items:center;font-size:12px;padding:2px 0}
prompt .eb .nm{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--ink2)}
prompt .eb .b{height:11px;background:var(--soft);border-radius:3px}
prompt .eb .b i{display:block;height:100%;border-radius:0 3px 3px 0}
prompt .eb .p{text-align:right;color:var(--mute)}
prompt .chips{display:flex;flex-wrap:wrap;gap:6px;margin:4px 0 10px;max-height:120px;overflow:auto}
prompt .chip{display:inline-flex;align-items:center;gap:6px;background:var(--card);border:1px solid var(--line);border-radius:999px;padding:3px 11px 3px 9px;font-size:12px;cursor:pointer;color:var(--ink2)}
prompt .chip.on{background:var(--ink);color:var(--card);border-color:var(--ink)}
prompt .tw{overflow:auto;max-height:620px;border:1px solid var(--line);border-radius:8px}
prompt table{border-collapse:collapse;width:100%;font-size:12.5px}
prompt th,td{padding:6px 10px;text-align:left;white-space:nowrap;border-bottom:1px solid var(--grid)}
prompt th{position:sticky;top:0;background:var(--soft);font-weight:600;color:var(--ink2);cursor:pointer;user-select:none;z-index:1}
prompt th[aria-sort="ascending"]::after{content:" \25B2";font-size:9px}
prompt th[aria-sort="descending"]::after{content:" \25BC";font-size:9px}
prompt td.n,th.n{text-align:right}
prompt td .mix{display:inline-flex;width:90px;height:10px;border-radius:3px;overflow:hidden;vertical-align:middle;background:var(--soft)}
prompt td .mix i{display:block;height:100%}
prompt tbody tr:hover td{background:var(--soft)}
prompt .more{margin-top:8px}
prompt .notawr{border:1.5px dashed color-mix(in srgb,var(--warn) 70%,var(--line))}
prompt .badge{display:inline-block;font-size:11px;font-weight:600;border-radius:5px;padding:2px 7px;background:var(--warn-bg);color:var(--warn-ink);vertical-align:middle;margin-left:8px}
prompt .stats{display:flex;flex-wrap:wrap;gap:8px 28px;margin:6px 0 12px}
prompt .stats div{min-width:110px}
prompt .stats b{display:block;font:600 20px var(--serif)}
prompt .stats span{font-size:12px;color:var(--mute)}
prompt .foot{margin-top:34px;padding-top:16px;border-top:1px solid var(--line);color:var(--ink2);font-size:12.5px;display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:10px 36px}
prompt .foot h3{font:600 15px var(--serif);margin:0 0 6px;color:var(--ink)}
prompt .foot ul{margin:0;padding-left:18px}
prompt .foot li{margin-bottom:4px}
prompt .foot code{font-family:var(--mono);font-size:11.5px;background:var(--soft);padding:1px 4px;border-radius:4px}
prompt #tip{position:fixed;z-index:50;pointer-events:none;opacity:0;background:var(--card);color:var(--ink);border:1px solid var(--line);border-radius:8px;box-shadow:0 10px 28px -10px rgba(0,0,0,.45);padding:8px 10px;font-size:12px;max-width:360px;transition:opacity .08s}
prompt #tip .tt{font-weight:600;margin-bottom:4px;overflow-wrap:anywhere}
prompt #tip .tr{display:flex;gap:7px;align-items:center;padding:1px 0}
prompt #tip .tr i{width:12px;height:3px;border-radius:2px;flex:none}
prompt #tip .tr .k{color:var(--ink2);flex:1}
prompt #tip .tr .v{font-weight:600;margin-left:12px}
prompt @media (max-width:980px){.hero{grid-template-columns:1fr}.card.s6,.card.s5,.card.s7{grid-column:span 12}.wrap{padding:0 14px 40px}.sec{flex-direction:column;gap:2px}}
prompt @media print{.btn,.seg{display:none}.card{break-inside:avoid}body{background:#fff}}
prompt @media (prefers-reduced-motion:reduce){*{transition:none!important}}
prompt </style>
prompt </head>
prompt <body>
prompt <svg width="0" height="0" style="position:absolute" aria-hidden="true"><defs>
prompt <pattern id="hatch" width="7" height="7" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><line x1="0" y1="0" x2="0" y2="7" style="stroke:var(--hatch);stroke-width:3"/></pattern>
prompt </defs></svg>
prompt <div class="wrap">
prompt <header class="bar">
prompt <div class="brand"><i></i><span>AWR backup report</span></div>
prompt <div class="bar-r"><span id="gen"></span><button class="btn" id="theme" type="button" title="Switch colour theme">Theme: auto</button></div>
prompt </header>
prompt <section class="hero" id="hero"></section>
prompt <div id="banners"></div>
prompt <section class="kpis" id="kpis"></section>
prompt <section id="last"></section>
prompt <main class="grid">
prompt <div class="sec"><h2>Timeline</h2><p>Every detected run, one lane per backup type.</p></div>
prompt <div class="card"><div class="ch"><div><h3>Backup runs on a time axis</h3><p>Each bar is one run (first to last ASH sample, plus 10 s). Hatched area is before the oldest AWR snapshot.</p></div><div id="gantt-ctl"></div></div><div id="gantt"></div></div>
prompt <div class="sec"><h2>Time and volume</h2><p>How much backup time and IO, by type. IO is an ASH estimate.</p></div>
prompt <div class="card"><div class="ch"><div><h3>Backup hours per day</h3><p>Elapsed time of runs, split at midnight, stacked by backup type. Types can run at the same time, so a day may exceed 24 h. Click a legend entry to hide a type.</p></div></div><div id="daybar"></div></div>
prompt <div class="card s6"><div class="ch"><div><h3>Share of elapsed time</h3><p>Total run elapsed time per backup type.</p></div></div><div id="donut-time"></div></div>
prompt <div class="card s6"><div class="ch"><div><h3>Share of estimated IO</h3><p>Read plus write bytes per type (ASH estimate).</p></div></div><div id="donut-io"></div></div>
prompt <div class="sec"><h2>Trends</h2><p>Is it getting slower, is it getting bigger?</p></div>
prompt <div class="card s6"><div class="ch"><div><h3>Run duration over time</h3><p>Elapsed time of each run; one line per type (largest types only).</p></div></div><div id="trend-dur"></div></div>
prompt <div class="card s6"><div class="ch"><div><h3>Throughput per run</h3><p>Estimated MB/s (read plus write) averaged over each run.</p></div></div><div id="trend-mbs"></div></div>
prompt <div class="card s6"><div class="ch"><div><h3>Duration versus volume</h3><p>One dot per run: elapsed time against estimated GB moved.</p></div><div id="scatter-ctl"></div></div><div id="scatter"></div></div>
prompt <div class="card s6"><div class="ch"><div><h3>When backups are active</h3><p>ASH samples by weekday and hour of day (database clock). Stronger colour means more activity.</p></div></div><div id="heat"></div></div>
prompt <div class="sec"><h2>Where the time goes</h2><p>ASH wait profile of the backup sessions.</p></div>
prompt <div class="card s6"><div class="ch"><div><h3>Wait profile per type</h3><p>Share of ASH samples spent on CPU, IO, media manager (MML) and other waits.</p></div></div><div id="waitmix"></div></div>
prompt <div class="card s6"><div class="ch"><div><h3>Top wait events per type</h3><p>Share of the type's ASH samples, five biggest events for the busiest types.</p></div></div><div id="topev"></div></div>
prompt <div class="sec"><h2>Authoritative RMAN IO</h2><p>From DBA_HIST_IOSTAT_FUNCTION and DBA_HIST_SYSTEM_EVENT, not from ASH sampling.</p></div>
prompt <div class="card s7"><div class="ch"><div><h3>RMAN IO per day</h3><p>Function RMAN snapshot deltas (read and write GB) with the ASH estimate overlaid.</p></div></div><div id="ioday"></div><p class="note">Upper bound: function RMAN also counts non-backup IO such as controlfile autobackups, Data Guard role changes, flashback and recovery. Intervals spanning an instance restart are dropped.</p></div>
prompt <div class="card s5"><div class="ch"><div><h3>RMAN wait events per day</h3><p>Instance-wide Backup: and RMAN events, snapshot deltas.</p></div><div id="wday-ctl"></div></div><div id="wday"></div></div>
prompt <div class="sec"><h2>Detail</h2><p>Click a column header to sort.</p></div>
prompt <div class="card"><div class="ch"><div><h3>Summary per backup type</h3><p>Estimates from ASH. MB/s is volume-weighted (total MB over total elapsed seconds).</p></div></div><div id="tbl-sum"></div></div>
prompt <div class="card"><div class="ch"><div><h3>Run detail</h3><p>Filter by type, sort by any column.</p></div></div><div class="chips" id="chips"></div><div id="tbl-runs"></div></div>
prompt <div class="sec"><h2 id="x-h2">Cross-check from the controlfile</h2><p>Not AWR. Use it as ground truth for the ASH-derived numbers above.</p></div>
prompt <div class="card notawr"><div class="ch"><div><h3><span id="x-h3">V$RMAN_BACKUP_JOB_DETAILS</span><span class="badge">NOT AWR</span></h3><p id="x-sub"></p></div></div><div id="x-note"></div><div id="x-stats"></div><div id="x-gantt"></div><div id="x-tbl"></div></div>
prompt </main>
prompt <footer class="foot" id="foot"></footer>
prompt </div>
prompt <div id="tip" role="tooltip"></div>
set define '&'
prompt <script>
prompt "use strict";
prompt const META=
select replace(json_object(
         'db'      value d.name,
         'dbid'    value &dbid,
         'inst'    value i.instance_name,
         'host'    value i.host_name,
         'ver'     value i.version_full,
         'role'    value d.database_role,
         'days'    value &days,
         'gap'     value &gap_minutes,
         'instf'   value &inst,
         'scope'   value '&scope',
         'now'     value round((sysdate - date '1970-01-01') * 86400),
         'win0'    value round((sysdate - &days - date '1970-01-01') * 86400),
         'snaps'   value x.snaps,
         'oldest'  value round((cast(x.oldest as date) - date '1970-01-01') * 86400),
         'newest'  value round((cast(x.newest as date) - date '1970-01-01') * 86400),
         'ret'     value (select max(extract(day from w.retention)) from dba_hist_wr_control w where w.dbid = &dbid),
         'snapint' value (select max(extract(day from w.snap_interval) * 1440 + extract(hour from w.snap_interval) * 60 + extract(minute from w.snap_interval)) from dba_hist_wr_control w where w.dbid = &dbid)
       ), '<', '\u003c')
  from v$database d
  cross join v$instance i
  cross join (select count(*)                   snaps,
                     min(s.begin_interval_time) oldest,
                     max(s.end_interval_time)   newest
                from dba_hist_snapshot s
               where s.dbid = &dbid
                 and (&inst = 0 or s.instance_number = &inst)
                 and s.end_interval_time >= sysdate - &days) x
/
prompt ;
prompt const RUNS=[
with snaps as (
  select dbid, instance_number, snap_id
    from dba_hist_snapshot
   where dbid = &dbid
     and (&inst = 0 or instance_number = &inst)
     and end_interval_time >= sysdate - &days
),
ash as (
  select case
           when lower(a.module) like 'rman%'
             or (lower(a.program) like 'rman%'
                 and not regexp_like(lower(a.module), '^(backup|restore|validate)'))
             then 'RMAN client/catalog'
           else lower(trim(regexp_replace(nvl(a.module, '(no module)'), ':.*$')))
         end                                                          backup_type,
         nvl(trim(regexp_substr(a.module, ':(.*)$', 1, 1, null, 1)), '-') channel,
         cast(a.sample_time as date)                                  sample_dt,
         a.instance_number, a.session_id, a.session_serial#,
         case when a.session_state = 'ON CPU'                         then 'CPU'
              when a.wait_class in ('User I/O', 'System I/O')         then 'IO'
              when a.event like 'Backup: MML%'                        then 'MML'
              else 'OTHER' end                                        cat,
         nvl(a.event, 'ON CPU')                                       ev,
         a.delta_read_io_bytes  / nullif(a.delta_time, 0) * 1e7       rd_b,
         a.delta_write_io_bytes / nullif(a.delta_time, 0) * 1e7       wr_b
    from dba_hist_active_sess_history a
    join snaps s
      on s.dbid = a.dbid and s.instance_number = a.instance_number and s.snap_id = a.snap_id
   where a.dbid = &dbid
     and a.sample_time >= sysdate - &days
     and ('&scope' = 'ALL'
          or lower(a.program) like 'rman%'
          or lower(a.module) like 'backup%'  or lower(a.module) like 'restore%'
          or lower(a.module) like 'validate%' or lower(a.module) like 'rman%')
),
phased as (
  -- Per session: type of the previous and of the next sample ('RMAN
  -- client/catalog' samples skipped).  prev_type <> backup_type means the
  -- channel just switched to this type from another one; next_type <>
  -- backup_type means it is about to leave it (end of a phase), e.g. the
  -- archivelog, datafile, archivelog phases of BACKUP DATABASE PLUS ARCHIVELOG.
  select ash.*,
         last_value(case when backup_type <> 'RMAN client/catalog' then backup_type end ignore nulls)
           over (partition by instance_number, session_id, session_serial#
                 order by sample_dt
                 rows between unbounded preceding and 1 preceding)    prev_type,
         first_value(case when backup_type <> 'RMAN client/catalog' then backup_type end ignore nulls)
           over (partition by instance_number, session_id, session_serial#
                 order by sample_dt
                 rows between 1 following and unbounded following)    next_type
    from ash
),
seconds as (
  -- One row per backup type and sample second.  ASH samples all active
  -- sessions at the same instant, so a type with several channels has
  -- several rows per second.  The run decision below is made once per
  -- second, so it cannot depend on the arbitrary order of same-second rows
  -- (per-row LAG and running SUM saw different orders and put a channel's
  -- first sample into the previous run of the type, stretching it for hours).
  -- phase_end: a session of the type left it after this sample (its next
  -- sample has another type).  all_switched: every session sampled at this
  -- second just switched to the type from another one.
  select backup_type, sample_dt,
         max(case when backup_type <> 'RMAN client/catalog'
                   and next_type is not null and next_type <> backup_type
                  then 1 else 0 end)                                  phase_end,
         min(case when backup_type <> 'RMAN client/catalog'
                   and prev_type is not null and prev_type <> backup_type
                  then 1 else 0 end)                                  all_switched
    from phased
   group by backup_type, sample_dt
),
ended as (
  -- Previous sample second of the type, and the last second before this one
  -- at which a session of the type left it.
  select s.*,
         lag(sample_dt) over (partition by backup_type order by sample_dt) prev_dt,
         max(case when phase_end = 1 then sample_dt end)
           over (partition by backup_type order by sample_dt
                 rows between unbounded preceding and 1 preceding)    last_end_dt
    from seconds s
),
flagged as (
  -- New run when the gap since the previous sample second of the type is
  -- too big.  The allowed gap shrinks from gap_minutes to rejoin_minutes
  -- when the run is probably over: every session sampled now just switched
  -- to the type from another one, or a session of this type left it shortly
  -- before the previous sample (so the previous run's channels have moved
  -- on, e.g. to the datafile phase while an idle channel kept no samples at
  -- all).  This keeps the two archivelog phases around a datafile backup as
  -- two runs.
  select e.*,
         case when prev_dt is null
                or (sample_dt - prev_dt) * 1440
                   > case when backup_type <> 'RMAN client/catalog'
                           and (   all_switched = 1
                                or (last_end_dt is not null
                                    and (prev_dt - last_end_dt) * 1440 <= &gap_minutes))
                          then least(&rejoin_minutes, &gap_minutes)
                          else &gap_minutes end
              then 1 else 0 end                                       new_run
    from ended e
),
numbered as (
  -- Run number per sample second, then back to the individual samples.
  select p.*, r.run_no
    from phased p
    join (select backup_type, sample_dt,
                 sum(new_run) over (partition by backup_type order by sample_dt
                                    rows unbounded preceding)         run_no
            from flagged) r
      on r.backup_type = p.backup_type and r.sample_dt = p.sample_dt
),
numbered2 as (
  select n.*,
         count(*) over (partition by backup_type, run_no, ev)         ev_cnt
    from numbered n
),
runs as (
  select backup_type, run_no,
         min(sample_dt)                                               run_start,
         max(sample_dt)                                               run_end,
         round((max(sample_dt) - min(sample_dt)) * 86400) + 10        elapsed_sec,
         case when backup_type = 'RMAN client/catalog'                 then 0
              when count(distinct case when channel <> '-' then channel end) > 0
                                                                       then count(distinct case when channel <> '-' then channel end)
              else count(distinct instance_number || '.' || session_id || '.' || session_serial#)
         end                                                          chans,
         count(distinct instance_number || '.' || session_id || '.' || session_serial#) sess,
         listagg(distinct to_char(instance_number), ',')
           within group (order by to_char(instance_number))           insts,
         count(*)                                                     samples,
         sum(case when cat = 'CPU'   then 1 else 0 end)               n_cpu,
         sum(case when cat = 'IO'    then 1 else 0 end)               n_io,
         sum(case when cat = 'MML'   then 1 else 0 end)               n_mml,
         sum(case when cat = 'OTHER' then 1 else 0 end)               n_oth,
         nvl(sum(rd_b), 0)                                            rd_bytes,
         nvl(sum(wr_b), 0)                                            wr_bytes,
         max(ev) keep (dense_rank last order by ev_cnt)               top_ev,
         100 * max(ev_cnt) / count(*)                                 top_ev_pct
    from numbered2
   group by backup_type, run_no
)
select replace(json_object(
         't'   value backup_type,
         's'   value round((run_start - date '1970-01-01') * 86400),
         'e'   value round((run_end   - date '1970-01-01') * 86400),
         'el'  value elapsed_sec,
         'ch'  value chans,
         'se'  value sess,
         'in'  value insts,
         'n'   value samples,
         'cpu' value n_cpu,
         'io'  value n_io,
         'mml' value n_mml,
         'oth' value n_oth,
         'rd'  value round(rd_bytes / power(1024, 3), 4),
         'wr'  value round(wr_bytes / power(1024, 3), 4),
         'ev'  value top_ev,
         'evp' value round(top_ev_pct, 1)
       ), '<', '\u003c') || ','
  from runs
 order by run_start, backup_type
/
prompt ];
prompt const EVENTS=[
with snaps as (
  select dbid, instance_number, snap_id
    from dba_hist_snapshot
   where dbid = &dbid
     and (&inst = 0 or instance_number = &inst)
     and end_interval_time >= sysdate - &days
),
ash as (
  select case
           when lower(a.module) like 'rman%'
             or (lower(a.program) like 'rman%'
                 and not regexp_like(lower(a.module), '^(backup|restore|validate)'))
             then 'RMAN client/catalog'
           else lower(trim(regexp_replace(nvl(a.module, '(no module)'), ':.*$')))
         end                                                          backup_type,
         case when a.session_state = 'ON CPU'                         then 'CPU'
              when a.wait_class in ('User I/O', 'System I/O')         then 'IO'
              when a.event like 'Backup: MML%'                        then 'MML'
              else 'OTHER' end                                        cat,
         nvl(a.event, 'ON CPU')                                       ev
    from dba_hist_active_sess_history a
    join snaps s
      on s.dbid = a.dbid and s.instance_number = a.instance_number and s.snap_id = a.snap_id
   where a.dbid = &dbid
     and a.sample_time >= sysdate - &days
     and ('&scope' = 'ALL'
          or lower(a.program) like 'rman%'
          or lower(a.module) like 'backup%'  or lower(a.module) like 'restore%'
          or lower(a.module) like 'validate%' or lower(a.module) like 'rman%')
),
agg as (
  select backup_type, cat, ev, count(*) cnt from ash group by backup_type, cat, ev
),
ranked as (
  select agg.*,
         sum(cnt) over (partition by backup_type)                     tot,
         row_number() over (partition by backup_type order by cnt desc, ev) rn
    from agg
)
select replace(json_object('t' value backup_type, 'c' value cat, 'e' value ev,
                           'n' value cnt, 'tot' value tot), '<', '\u003c') || ','
  from ranked
 where rn <= 12
 order by backup_type, rn
/
prompt ];
prompt const HEAT=[
with snaps as (
  select dbid, instance_number, snap_id
    from dba_hist_snapshot
   where dbid = &dbid
     and (&inst = 0 or instance_number = &inst)
     and end_interval_time >= sysdate - &days
)
select json_object('d' value dow, 'h' value hr, 'n' value cnt) || ','
  from (select mod(trunc(cast(a.sample_time as date)) - trunc(cast(a.sample_time as date), 'IW'), 7) dow,
               to_number(to_char(a.sample_time, 'HH24'))           hr,
               count(*)                                            cnt
          from dba_hist_active_sess_history a
          join snaps s
            on s.dbid = a.dbid and s.instance_number = a.instance_number and s.snap_id = a.snap_id
         where a.dbid = &dbid
           and a.sample_time >= sysdate - &days
           and ('&scope' = 'ALL'
                or lower(a.program) like 'rman%'
                or lower(a.module) like 'backup%'  or lower(a.module) like 'restore%'
                or lower(a.module) like 'validate%' or lower(a.module) like 'rman%')
         group by mod(trunc(cast(a.sample_time as date)) - trunc(cast(a.sample_time as date), 'IW'), 7),
                  to_number(to_char(a.sample_time, 'HH24')))
 order by dow, hr
/
prompt ];
prompt const IODAY=[
with snaps as (
  select dbid, instance_number, snap_id, begin_interval_time, startup_time
    from dba_hist_snapshot
   where dbid = &dbid
     and (&inst = 0 or instance_number = &inst)
     and end_interval_time >= sysdate - &days - 1
),
cur as (
  select s.begin_interval_time, s.startup_time, f.instance_number, f.snap_id,
         f.small_read_megabytes, f.small_write_megabytes,
         f.large_read_megabytes, f.large_write_megabytes,
         f.small_read_reqs + f.large_read_reqs                        rd_reqs,
         f.small_write_reqs + f.large_write_reqs                      wr_reqs,
         f.wait_time,
         lag(s.startup_time)           over (partition by f.instance_number, f.con_id, f.function_id order by f.snap_id) p_startup,
         lag(f.small_read_megabytes)   over (partition by f.instance_number, f.con_id, f.function_id order by f.snap_id) p_sm_rd,
         lag(f.small_write_megabytes)  over (partition by f.instance_number, f.con_id, f.function_id order by f.snap_id) p_sm_wr,
         lag(f.large_read_megabytes)   over (partition by f.instance_number, f.con_id, f.function_id order by f.snap_id) p_lg_rd,
         lag(f.large_write_megabytes)  over (partition by f.instance_number, f.con_id, f.function_id order by f.snap_id) p_lg_wr,
         lag(f.small_read_reqs + f.large_read_reqs)
                                       over (partition by f.instance_number, f.con_id, f.function_id order by f.snap_id) p_rd_reqs,
         lag(f.small_write_reqs + f.large_write_reqs)
                                       over (partition by f.instance_number, f.con_id, f.function_id order by f.snap_id) p_wr_reqs,
         lag(f.wait_time)              over (partition by f.instance_number, f.con_id, f.function_id order by f.snap_id) p_wait
    from dba_hist_iostat_function f
    join snaps s
      on s.dbid = f.dbid and s.instance_number = f.instance_number and s.snap_id = f.snap_id
   where f.dbid = &dbid
     and f.function_name = 'RMAN'
),
delta as (
  select trunc(begin_interval_time)                                   day,
         case when p_startup = startup_time
               and small_read_megabytes  >= p_sm_rd  and small_write_megabytes >= p_sm_wr
               and large_read_megabytes  >= p_lg_rd  and large_write_megabytes >= p_lg_wr
               and rd_reqs >= p_rd_reqs and wr_reqs >= p_wr_reqs and wait_time >= p_wait
              then 1 else 0 end                                       ok,
         small_read_megabytes  - p_sm_rd                              d_sm_rd,
         small_write_megabytes - p_sm_wr                              d_sm_wr,
         large_read_megabytes  - p_lg_rd                              d_lg_rd,
         large_write_megabytes - p_lg_wr                              d_lg_wr,
         rd_reqs - p_rd_reqs                                          d_rd_reqs,
         wr_reqs - p_wr_reqs                                          d_wr_reqs,
         wait_time - p_wait                                           d_wait
    from cur
   where p_startup is not null
     and begin_interval_time >= sysdate - &days
),
io_day as (
  select day,
         sum(ok)                                                      used_snaps,
         sum(1 - ok)                                                  drop_snaps,
         sum(case when ok = 1 then d_lg_rd + d_sm_rd end)             rd_mb,
         sum(case when ok = 1 then d_lg_wr + d_sm_wr end)             wr_mb,
         sum(case when ok = 1 then d_rd_reqs end)                     rd_reqs,
         sum(case when ok = 1 then d_wr_reqs end)                     wr_reqs,
         sum(case when ok = 1 then d_wait end)                        wait_ms
    from delta
   group by day
),
ash_day as (
  select trunc(cast(a.sample_time as date))                           day,
         sum(a.delta_read_io_bytes  / nullif(a.delta_time, 0) * 1e7)  rd_b,
         sum(a.delta_write_io_bytes / nullif(a.delta_time, 0) * 1e7)  wr_b
    from dba_hist_active_sess_history a
    join (select dbid, instance_number, snap_id
            from dba_hist_snapshot
           where dbid = &dbid
             and (&inst = 0 or instance_number = &inst)
             and end_interval_time >= sysdate - &days) s
      on s.dbid = a.dbid and s.instance_number = a.instance_number and s.snap_id = a.snap_id
   where a.dbid = &dbid
     and a.sample_time >= sysdate - &days
     and ('&scope' = 'ALL'
          or lower(a.program) like 'rman%'
          or lower(a.module) like 'backup%'  or lower(a.module) like 'restore%'
          or lower(a.module) like 'validate%' or lower(a.module) like 'rman%')
   group by trunc(cast(a.sample_time as date))
)
select json_object(
         'd'   value round((d.day - date '1970-01-01') * 86400),
         'us'  value i.used_snaps,
         'dr'  value i.drop_snaps,
         'rd'  value round(i.rd_mb / 1024, 4),
         'wr'  value round(i.wr_mb / 1024, 4),
         'rq'  value i.rd_reqs,
         'wq'  value i.wr_reqs,
         'ws'  value round(i.wait_ms / 1000, 2),
         'ard' value round(h.rd_b / power(1024, 3), 4),
         'awr' value round(h.wr_b / power(1024, 3), 4)) || ','
  from (select day from io_day union select day from ash_day) d
  left join io_day  i on i.day = d.day
  left join ash_day h on h.day = d.day
 order by d.day
/
prompt ];
prompt const WAITDAY=[
with snaps as (
  select dbid, instance_number, snap_id, begin_interval_time, startup_time
    from dba_hist_snapshot
   where dbid = &dbid
     and (&inst = 0 or instance_number = &inst)
     and end_interval_time >= sysdate - &days - 1
),
cur as (
  select s.begin_interval_time, s.startup_time, e.instance_number, e.event_name,
         e.total_waits, e.time_waited_micro,
         lag(s.startup_time)       over (partition by e.instance_number, e.con_id, e.event_id order by e.snap_id) p_startup,
         lag(e.total_waits)        over (partition by e.instance_number, e.con_id, e.event_id order by e.snap_id) p_waits,
         lag(e.time_waited_micro)  over (partition by e.instance_number, e.con_id, e.event_id order by e.snap_id) p_micro
    from dba_hist_system_event e
    join snaps s
      on s.dbid = e.dbid and s.instance_number = e.instance_number and s.snap_id = e.snap_id
   where e.dbid = &dbid
     and (e.event_name like 'Backup:%'
          or e.event_name like 'RMAN%'
          or e.event_name = 'RMAN backup ' || chr(38) || ' recovery I/O')
)
select replace(json_object(
         'd' value round((trunc(begin_interval_time) - date '1970-01-01') * 86400),
         'e' value event_name,
         'w' value sum(total_waits - p_waits),
         's' value round(sum(time_waited_micro - p_micro) / 1e6, 3)), '<', '\u003c') || ','
  from cur
 where p_startup = startup_time
   and total_waits >= p_waits and time_waited_micro >= p_micro
   and begin_interval_time >= sysdate - &days
 group by trunc(begin_interval_time), event_name
having sum(total_waits - p_waits) > 0
 order by trunc(begin_interval_time), event_name
/
prompt ];
prompt </script>
set define off
prompt <script>
prompt function awrMain(){
prompt var D=document,DAY=86400,TOP=7,NS='http://www.w3.org/2000/svg';
prompt function $(s,r){return (r||D).querySelector(s)}
prompt function esc(s){return String(s==null?'':s).replace(/[&<>"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]})}
prompt function num(n,d){if(n==null||isNaN(n))return '\u2013';return Number(n).toLocaleString('en-US',{minimumFractionDigits:d||0,maximumFractionDigits:d||0})}
prompt function pad(n){return n<10?'0'+n:''+n}
prompt function dt(s){var d=new Date(s*1000);return d.getUTCFullYear()+'-'+pad(d.getUTCMonth()+1)+'-'+pad(d.getUTCDate())+' '+pad(d.getUTCHours())+':'+pad(d.getUTCMinutes())}
prompt function dd(s){return dt(s).slice(0,10)}
prompt function md(s){return dt(s).slice(5,10)}
prompt function dur(sec){sec=Math.round(sec);var h=Math.floor(sec/3600),m=Math.floor(sec%3600/60),s=sec%60;
prompt  if(h>=48)return Math.floor(h/24)+'d '+(h%24)+'h';if(h>0)return h+'h '+pad(m)+'m';if(m>0)return m+'m '+pad(s)+'s';return s+'s'}
prompt function hms(sec){sec=Math.round(sec);return pad(Math.floor(sec/3600))+':'+pad(Math.floor(sec%3600/60))+':'+pad(sec%60)}
prompt function gbf(n){if(n==null||isNaN(n))return '\u2013';if(n===0)return '0';if(n>=100)return num(n,0);if(n>=10)return num(n,1);if(n>=0.1)return num(n,2);return n.toFixed(3)}
prompt function cut(s,n){s=String(s);return s.length>n?s.slice(0,n-1)+'\u2026':s}
prompt function ago(sec){if(sec<0)sec=0;if(sec<90)return 'just now';if(sec<5400)return Math.round(sec/60)+' min ago';if(sec<172800)return Math.round(sec/3600)+' h ago';return Math.round(sec/DAY)+' d ago'}
prompt function sum(a,f){var t=0;for(var i=0;i<a.length;i++)t+=f(a[i])||0;return t}
prompt function fday(s){return Math.floor(s/DAY)*DAY}
prompt
prompt // data preparation
prompt var M=META;
prompt var runs=RUNS.map(function(r,i){r.i=i;r.tot=r.rd+r.wr;r.mbs=r.tot*1024/r.el;return r});
prompt var tinfo={},tlist=[];
prompt runs.forEach(function(r){var o=tinfo[r.t];if(!o){o=tinfo[r.t]={t:r.t,runs:0,el:0,rd:0,wr:0,n:0,cpu:0,io:0,mml:0,oth:0,first:1e12,last:0,min:1e12,max:0};tlist.push(o)}
prompt  o.runs++;o.el+=r.el;o.rd+=r.rd;o.wr+=r.wr;o.n+=r.n;o.cpu+=r.cpu;o.io+=r.io;o.mml+=r.mml;o.oth+=r.oth;
prompt  if(r.s<o.first)o.first=r.s;if(r.s>o.last)o.last=r.s;if(r.el<o.min)o.min=r.el;if(r.el>o.max)o.max=r.el});
prompt tlist.sort(function(a,b){return b.el-a.el||(a.t<b.t?-1:1)});
prompt tlist.forEach(function(o,i){o.ci=i<TOP?i+1:0;o.col=i<TOP?'var(--c'+(i+1)+')':'var(--other)'});
prompt var OTH='__other',nOther=Math.max(0,tlist.length-TOP);
prompt var groups=tlist.slice(0,TOP).map(function(o){return {k:o.t,label:o.t,col:o.col}});
prompt if(nOther)groups.push({k:OTH,label:'Other ('+nOther+' type'+(nOther>1?'s':'')+')',col:'var(--other)'});
prompt function col(t){return tinfo[t]?tinfo[t].col:'var(--other)'}
prompt function gk(t){var o=tinfo[t];return o&&o.ci?t:OTH}
prompt var hasRuns=runs.length>0;
prompt var covStart=M.oldest?Math.max(M.oldest,M.win0):M.win0;
prompt var partial=M.snaps>0&&M.oldest>M.win0+3600;
prompt var dFrom=fday(covStart),dTo=fday(M.now);
prompt if(hasRuns){dFrom=Math.min(dFrom,fday(runs[0].s))}
prompt var days=[];for(var d=dFrom;d<=dTo;d+=DAY)days.push(d);
prompt var xStart=Math.min(covStart,hasRuns?runs[0].s:covStart);
prompt
prompt // tooltip
prompt var tip=$('#tip');
prompt function tt(title,rows){var h='<div class="tt">'+esc(title)+'</div>';
prompt  rows.forEach(function(r){h+='<div class="tr">'+(r[0]?'<i style="background:'+r[0]+'"></i>':'')+'<span class="k">'+esc(r[1])+'</span><span class="v">'+esc(r[2])+'</span></div>'});return h}
prompt function showTip(h,x,y){tip.innerHTML=h;tip.style.opacity=1;var w=tip.offsetWidth,hh=tip.offsetHeight,nx=x+14,ny=y+14;
prompt  if(nx+w>innerWidth-8)nx=x-w-14;if(ny+hh>innerHeight-8)ny=y-hh-14;tip.style.left=Math.max(4,nx)+'px';tip.style.top=Math.max(4,ny)+'px'}
prompt function hideTip(){tip.style.opacity=0}
prompt D.addEventListener('mousemove',function(e){var t=e.target.closest&&e.target.closest('[data-t],[data-ov]');
prompt  if(!t){hideTip();return}if(t.hasAttribute('data-t'))showTip(t.getAttribute('data-t'),e.clientX,e.clientY)});
prompt D.addEventListener('mouseleave',hideTip);
prompt
prompt // chart plumbing
prompt var CH={},HID={},ST={gantt:'all',scatter:null,wday:'s'};
prompt function chart(id,fn){CH[id]=fn}
prompt function paint(id){var el=$('#'+id);if(!el||!CH[id])return;el.__w=el.clientWidth;
prompt  try{CH[id](el)}catch(e){el.innerHTML='<div class="empty"><b>Chart error</b>'+esc(e.message)+'</div>';if(window.console)console.error(id,e)}}
prompt function paintAll(){Object.keys(CH).forEach(paint)}
prompt function W(el){return Math.max(300,Math.floor(el.clientWidth||600))}
prompt function empty(el,msg){el.innerHTML='<div class="empty"><b>No data in window</b><span>'+esc(msg||'')+'</span></div>'}
prompt function legend(id,items,line){return '<div class="lg">'+items.map(function(it){var off=HID[id]&&HID[id][it.k];
prompt  return '<button type="button" class="lgi'+(off?' off':'')+'" data-lg="'+id+'" data-k="'+esc(it.k)+'"><i class="'+(line?'ln':'')+'" style="background:'+it.col+'"></i>'+esc(cut(it.label,34))+'</button>'}).join('')+'</div>'}
prompt function hidden(id,k){return !!(HID[id]&&HID[id][k])}
prompt D.addEventListener('click',function(e){var b=e.target.closest&&e.target.closest('[data-lg]');
prompt  if(b){var id=b.getAttribute('data-lg'),k=b.getAttribute('data-k');HID[id]=HID[id]||{};HID[id][k]=!HID[id][k];paint(id);return}
prompt  b=e.target.closest&&e.target.closest('[data-seg]');
prompt  if(b){var key=b.getAttribute('data-seg');ST[key]=b.getAttribute('data-v');drawSegs();(b.getAttribute('data-ids')||'').split(',').forEach(paint)}});
prompt var SEGS=[];
prompt function seg(slot,key,opts,ids){SEGS.push({slot:slot,key:key,opts:opts,ids:ids})}
prompt function drawSegs(){SEGS.forEach(function(s){var el=$('#'+s.slot);if(!el)return;
prompt  el.innerHTML='<div class="seg">'+s.opts.map(function(o){return '<button type="button" data-seg="'+s.key+'" data-v="'+o[0]+'" data-ids="'+s.ids+'" class="'+(ST[s.key]===o[0]?'on':'')+'">'+esc(o[1])+'</button>'}).join('')+'</div>'})}
prompt
prompt // scales
prompt function niceMax(max,n){if(!(max>0))return {max:1,step:0.2,ticks:[0,0.2,0.4,0.6,0.8,1]};
prompt  var raw=max/(n||5),p=Math.pow(10,Math.floor(Math.log10(raw))),f=raw/p,s=f<=1?1:f<=2?2:f<=5?5:10,step=s*p,top=Math.ceil(max/step-1e-9)*step,t=[];
prompt  for(var v=0;v<=top+step/2;v+=step)t.push(+v.toFixed(10));return {max:top,step:step,ticks:t}}
prompt function tickf(v,step){if(step>=1)return num(v,0);var d=Math.min(4,Math.ceil(-Math.log10(step)));return num(v,d)}
prompt function logTicks(lo,hi){var t=[],a=Math.floor(Math.log10(lo)),b=Math.ceil(Math.log10(hi));for(var i=a;i<=b;i++)t.push(Math.pow(10,i));return t}
prompt function lin(d0,d1,r0,r1){return function(v){return d1===d0?r0:r0+(v-d0)*(r1-r0)/(d1-d0)}}
prompt function lg(d0,d1,r0,r1){var a=Math.log10(d0),b=Math.log10(d1);return function(v){return r0+(Math.log10(Math.max(v,d0))-a)*(r1-r0)/(b-a)}}
prompt function timeTicks(x0,x1,pw){var steps=[3600,6*3600,12*3600,DAY,2*DAY,7*DAY,14*DAY,30*DAY],target=Math.max(2,Math.floor(pw/80)),st=steps[steps.length-1];
prompt  for(var i=0;i<steps.length;i++){if((x1-x0)/steps[i]<=target){st=steps[i];break}}
prompt  var off=st>=7*DAY?4*DAY:0,t=[],v=Math.ceil((x0-off)/st)*st+off;for(;v<=x1;v+=st)t.push(v);return {step:st,ticks:t}}
prompt function tlab(v,st){return st<DAY?md(v)+' '+dt(v).slice(11,13)+'h':md(v)}
prompt function xDays(days,pw){var k=Math.max(1,Math.ceil(days.length/Math.max(1,Math.floor(pw/54))));return k}
prompt function svgO(w,h,label){return '<svg class="chart" viewBox="0 0 '+w+' '+h+'" width="'+w+'" height="'+h+'" role="img" aria-label="'+esc(label)+'">'}
prompt function yGrid(sc,ticks,step,m,w,fmt){var s='';ticks.forEach(function(v){var y=sc(v).toFixed(1);
prompt  s+='<line class="gl" x1="'+m.l+'" x2="'+(w-m.r)+'" y1="'+y+'" y2="'+y+'"/><text x="'+(m.l-8)+'" y="'+y+'" dy="0.32em" text-anchor="end">'+esc(fmt?fmt(v):tickf(v,step))+'</text>'});return s}
prompt function overlay(el,m,w,h,fn){var svg=$('svg',el),ov=$('.ov',svg);if(!ov)return;
prompt  ov.addEventListener('mousemove',function(e){var r=svg.getBoundingClientRect(),x=(e.clientX-r.left)*w/r.width;fn(x,e)});
prompt  ov.addEventListener('mouseleave',function(){hideTip();var g=$('.xh',svg);if(g)g.setAttribute('visibility','hidden')})}
prompt function pointHover(el,pts,w){var svg=$('svg',el);if(!svg||!pts.length)return;var hl=$('.hl',svg);
prompt  svg.addEventListener('mousemove',function(e){var r=svg.getBoundingClientRect(),k=w/r.width,x=(e.clientX-r.left)*k,y=(e.clientY-r.top)*k,best=null,bd=22*22;
prompt   for(var i=0;i<pts.length;i++){var dx=pts[i].x-x,dy=pts[i].y-y,q=dx*dx+dy*dy;if(q<bd){bd=q;best=pts[i]}}
prompt   if(best){hl.setAttribute('cx',best.x);hl.setAttribute('cy',best.y);hl.setAttribute('visibility','visible');hl.style.stroke=best.c;showTip(best.tip,e.clientX,e.clientY)}
prompt   else{hl.setAttribute('visibility','hidden');hideTip()}});
prompt  svg.addEventListener('mouseleave',function(){hl.setAttribute('visibility','hidden');hideTip()})}
prompt var HLC='<circle class="hl" r="7" visibility="hidden" style="fill:none;stroke-width:2.5;pointer-events:none"/>';
prompt
prompt // banners, hero, KPIs
prompt function icon(k){var p=k==='info'?'<circle cx="9" cy="9" r="7.5" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M9 8v5M9 5.2v.1" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>'
prompt  :'<path d="M9 1.8l7.6 13.4H1.4z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/><path d="M9 7v4M9 12.8v.1" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>';
prompt  return '<svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">'+p+'</svg>'}
prompt function banner(k,title,txt){return '<div class="banner '+k+'" role="status">'+icon(k)+'<div><b>'+esc(title)+'</b>'+esc(txt)+'</div></div>'}
prompt function buildTop(){
prompt  document.title='Backup report \u2013 '+M.db;
prompt  $('#gen').textContent='Generated '+dt(M.now)+' (database clock)';
prompt  var cov=M.snaps>0?dt(M.oldest)+' to '+dt(M.newest):'none';
prompt  var covDays=M.snaps>0?Math.max(0,(M.newest-Math.max(M.oldest,M.win0))/DAY):0;
prompt  var facts=[['Database',M.db,'DBID '+M.dbid+' \u00b7 '+M.role],['Instance',M.inst,M.host],['Version',M.ver,''],
prompt   ['Window',dd(M.win0)+' to '+dd(M.now),M.days+' days'],
prompt   ['Parameters','gap '+M.gap+' min \u00b7 inst '+(M.instf===0?'all':M.instf),'scope '+M.scope+(M.scope==='ALL'?' (not filtered to RMAN)':'')],
prompt   ['AWR coverage',num(covDays,1)+' of '+M.days+' days',M.snaps+' snapshots'+(M.snapint?' every '+M.snapint+' min':'')+' \u00b7 retention '+(M.ret==null?'?':M.ret+' days')]];
prompt  var h='<div><h1>'+esc(M.db)+'</h1><p class="lede">Backup activity over the last '+M.days+' days, reconstructed from AWR and ASH history.</p></div><dl class="facts">';
prompt  facts.forEach(function(f){h+='<div><dt>'+esc(f[0])+'</dt><dd>'+esc(f[1])+(f[2]?'<small>'+esc(f[2])+'</small>':'')+'</dd></div>'});
prompt  h+='</dl><div class="ruler"><div class="rt">'+esc(M.snaps>0?'AWR snapshots cover '+cov:'No AWR snapshots in the window')+'</div>'+ruler()+'<div class="rl"><span>'+esc(dd(M.win0))+'</span><span>'+esc(dd(M.now))+'</span></div></div>';
prompt  $('#hero').innerHTML=h;
prompt  var b='';
prompt  if(M.snaps===0)b+=banner('crit','No AWR snapshots in the window','Check the dbid and days parameters. Nothing below can contain data.');
prompt  else if(partial)b+=banner('warn','PARTIAL: AWR covers less than the requested window','Oldest snapshot is '+dt(M.oldest)+', so only '+num(covDays,1)+' of the requested '+M.days+' days are covered (AWR retention '+(M.ret==null?'unknown':M.ret+' days')+'). Everything in this report describes that shorter period.');
prompt  if(M.scope==='ALL')b+=banner('info','scope=ALL: validation mode','Sessions are not filtered to RMAN, so "backup types" are any ASH MODULE. Use this only to check the report on a database without backups.');
prompt  $('#banners').innerHTML=b}
prompt function ruler(){var w=1000,x0=M.win0,x1=M.now,sx=lin(x0,x1,0,w),a=M.snaps>0?sx(Math.max(M.oldest,x0)):w,z=M.snaps>0?sx(Math.min(M.newest,x1)):w;
prompt  return '<svg viewBox="0 0 '+w+' 16" preserveAspectRatio="none" role="img" aria-label="AWR coverage of the requested window"><rect x="0" y="2" width="'+w+'" height="12" rx="3" style="fill:var(--soft)"/>'
prompt  +(a>0?'<rect x="0" y="2" width="'+a+'" height="12" rx="3" style="fill:url(#hatch)"/>':'')
prompt  +(M.snaps>0?'<rect x="'+a+'" y="2" width="'+Math.max(2,z-a)+'" height="12" rx="3" style="fill:'+(partial?'var(--warn)':'var(--c3)')+'"/>':'')+'</svg>'}
prompt function kpi(n,unit,l,s){return '<div class="kpi"><div class="n">'+n+(unit?'<small>'+esc(unit)+'</small>':'')+'</div><div class="l">'+esc(l)+'</div><div class="s">'+esc(s||'')+'</div></div>'}
prompt function buildKpis(){
prompt  var tel=sum(runs,function(r){return r.el}),trd=sum(runs,function(r){return r.rd}),twr=sum(runs,function(r){return r.wr});
prompt  var iord=sum(IODAY,function(r){return r.rd}),iowr=sum(IODAY,function(r){return r.wr});
prompt  var big=null,lng=null;runs.forEach(function(r){if(!big||r.tot>big.tot)big=r;if(!lng||r.el>lng.el)lng=r});
prompt  var h='';
prompt  h+=kpi(num(runs.length),'','Backup runs',hasRuns?'across '+tlist.length+' backup type'+(tlist.length>1?'s':''):'none detected');
prompt  h+=kpi(hasRuns?num(tel/3600,1):'0','h','Total backup time','elapsed, ASH estimate');
prompt  h+=kpi(hasRuns?gbf(trd)+' / '+gbf(twr):'0','GB','Read / written (est.)','ASH estimate, per-run sum');
prompt  h+=kpi(gbf(iord+iowr),'GB','RMAN IO, authoritative','iostat: '+gbf(iord)+' read, '+gbf(iowr)+' write. Upper bound.');
prompt  h+=kpi(hasRuns&&tel>0?num((trd+twr)*1024/tel,1):'\u2013','MB/s','Average throughput','total MB over total elapsed, est.');
prompt  h+=kpi(big&&big.tot>0?gbf(big.tot):'\u2013','GB','Largest run (est.)',big&&big.tot>0?cut(big.t,26)+' \u00b7 '+dd(big.s):'no IO recorded');
prompt  h+=kpi(lng?dur(lng.el):'\u2013','','Longest run',lng?cut(lng.t,26)+' \u00b7 '+dd(lng.s):'none detected');
prompt  $('#kpis').innerHTML=h;
prompt  var l='<div class="last"><h3>Last run per backup type</h3>';
prompt  if(!hasRuns)l+='<div class="note">No runs in the window.</div>';
prompt  else{l+='<ul>';tlist.slice(0,16).forEach(function(o){l+='<li><span class="dot" style="background:'+o.col+'"></span><span class="nm" title="'+esc(o.t)+'">'+esc(o.t)+'</span><em>'+esc(ago(M.now-o.last))+'</em></li>'});
prompt   l+='</ul>'+(tlist.length>16?'<div class="note">and '+(tlist.length-16)+' more types in the summary table.</div>':'')}
prompt  $('#last').innerHTML=l+'</div>'}
prompt
prompt // Gantt
prompt function gantt(el,o){
prompt  var w=W(el),lanes=o.lanes,laneH=24,lw=Math.min(230,Math.max(110,Math.max.apply(null,lanes.map(function(l){return l.label.length}).concat([8]))*6.4+26)),
prompt   m={l:lw,r:14,t:26,b:6},pw=w-m.l-m.r,h=m.t+lanes.length*laneH+m.b,sx=lin(o.x0,o.x1,m.l,w-m.r),tk=timeTicks(o.x0,o.x1,pw),s='',li={};
prompt  lanes.forEach(function(l,i){li[l.k]=i});
prompt  s+=svgO(w,h,o.label);
prompt  lanes.forEach(function(l,i){var y=m.t+i*laneH;if(i%2===0)s+='<rect x="0" y="'+y+'" width="'+w+'" height="'+laneH+'" style="fill:var(--soft)" opacity=".6"/>';
prompt   s+='<rect x="8" y="'+(y+laneH/2-4.5)+'" width="9" height="9" rx="2.5" style="fill:'+l.col+'"/><text class="lab" x="23" y="'+(y+laneH/2)+'" dy="0.32em">'+esc(cut(l.label,Math.floor((lw-26)/6)))+'<title>'+esc(l.label)+'</title></text>'});
prompt  if(o.hatchTo&&o.hatchTo>o.x0)s+='<rect x="'+m.l+'" y="'+m.t+'" width="'+Math.max(0,sx(Math.min(o.hatchTo,o.x1))-m.l)+'" height="'+(h-m.t-m.b)+'" style="fill:url(#hatch)"/>';
prompt  tk.ticks.forEach(function(v){var x=sx(v).toFixed(1);s+='<line class="gl" x1="'+x+'" x2="'+x+'" y1="'+(m.t-4)+'" y2="'+(h-m.b)+'"/><text x="'+x+'" y="'+(m.t-10)+'" text-anchor="middle">'+esc(tlab(v,tk.step))+'</text>'});
prompt  o.items.forEach(function(it){var a=o.sOf(it),b=o.eOf(it);if(b<o.x0||a>o.x1)return;var i=li[o.laneOf(it)];if(i==null)return;
prompt   var x=Math.max(m.l,sx(a)),x2=Math.min(w-m.r,sx(b)),y=m.t+i*laneH+(laneH-14)/2;
prompt   s+='<rect x="'+x.toFixed(1)+'" y="'+y+'" width="'+Math.max(3,x2-x).toFixed(1)+'" height="14" rx="2.5" style="fill:'+o.colOf(it)+'" data-t="'+esc(o.tipOf(it))+'"/>'});
prompt  s+='</svg>';el.innerHTML=(o.legend||'')+s}
prompt function runTip(r){return tt(r.t,[[col(r.t),'Start',dt(r.s)],[null,'End',dt(r.e+10)],[null,'Elapsed',dur(r.el)],[null,'DB time (est.)',dur(r.n*10)],
prompt  [null,'Sessions / channels',r.se+' / '+r.ch],[null,'Read / write (est.)',gbf(r.rd)+' / '+gbf(r.wr)+' GB'],[null,'Throughput (est.)',num(r.mbs,1)+' MB/s'],
prompt  [null,'CPU / IO / MML / other',Math.round(100*r.cpu/r.n)+' / '+Math.round(100*r.io/r.n)+' / '+Math.round(100*r.mml/r.n)+' / '+Math.round(100*r.oth/r.n)+' %'],[null,'Top event',cut(r.ev,40)+' ('+Math.round(r.evp)+'%)']])}
prompt chart('gantt',function(el){
prompt  if(!hasRuns)return empty(el,M.scope==='RMAN'?'No RMAN sessions were found in AWR ASH history. Run with scope=ALL to preview the charts on any database.':'No ASH samples in the window.');
prompt  var span=ST.gantt==='all'?M.now-M.win0:ST.gantt*DAY,x0=Math.max(M.win0,M.now-span);
prompt  var lanes=tlist.filter(function(o){return runs.some(function(r){return r.t===o.t&&r.e+10>=x0})}).map(function(o){return {k:o.t,label:o.t,col:o.col}});
prompt  if(!lanes.length)return empty(el,'No runs in the selected range.');
prompt  gantt(el,{lanes:lanes,items:runs,x0:x0,x1:M.now,hatchTo:M.snaps>0?M.oldest:M.now,label:'Backup runs timeline',
prompt   sOf:function(r){return r.s},eOf:function(r){return r.e+10},laneOf:function(r){return r.t},colOf:function(r){return col(r.t)},tipOf:runTip})});
prompt (function(){var o=[['all','Full window']];var span=(M.now-M.win0)/DAY;[[14,'14 d'],[7,'7 d'],[2,'48 h']].forEach(function(p){if(p[0]<span)o.push([String(p[0]),p[1]])});
prompt  ST.gantt='all';seg('gantt-ctl','gantt',o,'gantt')})();
prompt
prompt // daily stacked bars
prompt chart('daybar',function(el){
prompt  if(!hasRuns)return empty(el,'No backup runs to total up.');
prompt  var by={};days.forEach(function(d){by[d]={}});
prompt  runs.forEach(function(r){var s=r.s,e=r.e+10,k=gk(r.t);while(s<e){var d0=fday(s),n=Math.min(e,d0+DAY);if(by[d0])by[d0][k]=(by[d0][k]||0)+(n-s);s=n}});
prompt  var mx=0;days.forEach(function(d){var t=0;groups.forEach(function(g){if(!hidden('daybar',g.k))t+=by[d][g.k]||0});mx=Math.max(mx,t)});
prompt  var u=mx<3600?['min',60]:['h',3600],nm=niceMax(mx/u[1],5),w=W(el),h=300,m={l:46,r:10,t:24,b:26},pw=w-m.l-m.r,ph=h-m.t-m.b,sy=lin(0,nm.max,m.t+ph,m.t),bw=pw/days.length,bar=Math.min(38,Math.max(1.5,bw-2));
prompt  var s=legend('daybar',groups)+svgO(w,h,'Backup hours per day');
prompt  s+=yGrid(sy,nm.ticks,nm.step,m,w);s+='<text x="4" y="11" style="fill:var(--mute)">'+u[0]+'</text>';
prompt  var k=xDays(days,pw);
prompt  days.forEach(function(d,i){var cx=m.l+bw*(i+0.5),y=m.t+ph,tot=0;groups.forEach(function(g){if(!hidden('daybar',g.k))tot+=by[d][g.k]||0});
prompt   groups.forEach(function(g){if(hidden('daybar',g.k))return;var v=by[d][g.k]||0;if(!v)return;var hh=v/u[1]/nm.max*ph;y-=hh;
prompt    s+='<rect x="'+(cx-bar/2).toFixed(1)+'" y="'+y.toFixed(1)+'" width="'+bar.toFixed(1)+'" height="'+Math.max(0.8,hh-1.2).toFixed(1)+'" rx="1.5" style="fill:'+g.col+'" data-t="'+esc(tt(dd(d),[[g.col,g.label,dur(v)],[null,'Day total (shown types)',dur(tot)]]))+'"/>'});
prompt   if(i%k===0)s+='<text x="'+cx.toFixed(1)+'" y="'+(h-8)+'" text-anchor="middle">'+md(d)+'</text>'});
prompt  s+='<line class="ax" x1="'+m.l+'" x2="'+(w-m.r)+'" y1="'+(m.t+ph)+'" y2="'+(m.t+ph)+'"/></svg>';el.innerHTML=s});
prompt
prompt // donuts
prompt function donut(id,valOf,fmt,unitTitle,emptyMsg){chart(id,function(el){
prompt  var vals={};groups.forEach(function(g){vals[g.k]=0});tlist.forEach(function(o){vals[gk(o.t)]+=valOf(o)});
prompt  var items=groups.filter(function(g){return vals[g.k]>0}),tot=sum(items,function(g){return vals[g.k]});
prompt  if(!hasRuns||tot<=0)return empty(el,emptyMsg);
prompt  var S=190,R=76,sw=26,C=2*Math.PI*R,acc=0,s=svgO(S,S,unitTitle);
prompt  s+='<circle cx="'+S/2+'" cy="'+S/2+'" r="'+R+'" fill="none" style="stroke:var(--soft)" stroke-width="'+sw+'"/>';
prompt  items.forEach(function(g){var f=vals[g.k]/tot,len=f*C,gap=items.length>1?Math.min(2.5,len*0.5):0;
prompt   s+='<circle cx="'+S/2+'" cy="'+S/2+'" r="'+R+'" fill="none" stroke-width="'+sw+'" style="stroke:'+g.col+'" stroke-dasharray="'+Math.max(0.1,len-gap).toFixed(2)+' '+(C-len+gap).toFixed(2)+'" stroke-dashoffset="'+(-acc).toFixed(2)+'" transform="rotate(-90 '+S/2+' '+S/2+')" data-t="'+esc(tt(g.label,[[g.col,unitTitle,fmt(vals[g.k])],[null,'Share',num(100*f,1)+' %']]))+'"/>';acc+=len});
prompt  s+='<text x="'+S/2+'" y="'+(S/2-2)+'" text-anchor="middle" style="font:600 22px var(--serif);fill:var(--ink)">'+esc(fmt(tot))+'</text><text x="'+S/2+'" y="'+(S/2+16)+'" text-anchor="middle">'+esc(unitTitle)+'</text></svg>';
prompt  var l='<ul>';items.forEach(function(g){l+='<li><span class="dot" style="background:'+g.col+'"></span><span class="nm" title="'+esc(g.label)+'">'+esc(g.label)+'</span><b>'+esc(fmt(vals[g.k]))+'</b><em>'+num(100*vals[g.k]/tot,1)+'%</em></li>'});
prompt  el.innerHTML='<div class="donut">'+s+l+'</ul></div>'})}
prompt donut('donut-time',function(o){return o.el},function(v){return v>=7200?num(v/3600,1)+' h':dur(v)},'elapsed time','No backup runs, so no time to split.');
prompt donut('donut-io',function(o){return (o.rd+o.wr)},function(v){return gbf(v)+' GB'},'estimated IO','No IO was recorded on the sampled backup sessions.');
prompt
prompt // per-run trend lines
prompt function trend(id,yOf,yTitle,unitsFn,emptyMsg){chart(id,function(el){
prompt  if(!hasRuns)return empty(el,emptyMsg);
prompt  var top=groups.filter(function(g){return g.k!==OTH}),vis=top.filter(function(g){return !hidden(id,g.k)}),pts=[],mx=0;
prompt  var rs=runs.filter(function(r){return tinfo[r.t].ci&&!hidden(id,r.t)});
prompt  rs.forEach(function(r){mx=Math.max(mx,yOf(r))});
prompt  var U=unitsFn(mx),nm=niceMax(mx/U.div,5),w=W(el),h=290,m={l:50,r:12,t:24,b:28},pw=w-m.l-m.r,ph=h-m.t-m.b,
prompt   x0=xStart,x1=M.now,sx=lin(x0,x1,m.l,w-m.r),sy=lin(0,nm.max,m.t+ph,m.t),tk=timeTicks(x0,x1,pw);
prompt  var s=legend(id,top,true)+svgO(w,h,yTitle)+yGrid(sy,nm.ticks,nm.step,m,w)+'<text x="4" y="11" style="fill:var(--mute)">'+esc(U.u)+'</text>';
prompt  tk.ticks.forEach(function(v){var x=sx(v).toFixed(1);s+='<line class="gl" x1="'+x+'" x2="'+x+'" y1="'+m.t+'" y2="'+(m.t+ph)+'"/><text x="'+x+'" y="'+(h-9)+'" text-anchor="middle">'+esc(tlab(v,tk.step))+'</text>'});
prompt  s+='<line class="ax" x1="'+m.l+'" x2="'+(w-m.r)+'" y1="'+(m.t+ph)+'" y2="'+(m.t+ph)+'"/>';
prompt  vis.forEach(function(g){var rr=rs.filter(function(r){return r.t===g.k});if(!rr.length)return;
prompt   var d=rr.map(function(r,i){return (i?'L':'M')+sx(r.s).toFixed(1)+' '+sy(yOf(r)/U.div).toFixed(1)}).join('');
prompt   s+='<path d="'+d+'" fill="none" stroke-width="2" stroke-linejoin="round" style="stroke:'+g.col+'" opacity=".9"/>';
prompt   var dots=rr.length<=300;rr.forEach(function(r){var x=sx(r.s),y=sy(yOf(r)/U.div);if(dots)s+='<circle cx="'+x.toFixed(1)+'" cy="'+y.toFixed(1)+'" r="3" style="fill:'+g.col+';stroke:var(--card)" stroke-width="1.5"/>';
prompt    pts.push({x:x,y:y,c:g.col,tip:runTip(r)})})});
prompt  s+=HLC+'</svg>';
prompt  if(nOther)s+='<p class="note">'+nOther+' smaller type'+(nOther>1?'s are':' is')+' not drawn here; see the run table.</p>';
prompt  el.innerHTML=s;pointHover(el,pts,w)})}
prompt function durUnits(mx){return mx>=7200?{u:'hours',div:3600}:mx>=120?{u:'minutes',div:60}:{u:'seconds',div:1}}
prompt trend('trend-dur',function(r){return r.el},'Elapsed',durUnits,'No backup runs, so no duration trend.');
prompt trend('trend-mbs',function(r){return r.mbs},'MB/s',function(){return {u:'MB/s',div:1}},'No backup runs, so no throughput.');
prompt
prompt // scatter
prompt seg('scatter-ctl','scatter',[['lin','Linear'],['log','Log']],'scatter');
prompt chart('scatter',function(el){
prompt  if(!hasRuns)return empty(el,'No backup runs to plot.');
prompt  var rs=runs.filter(function(r){return r.tot>0});
prompt  if(!rs.length)return empty(el,'Runs were found but none recorded IO volume, so there is nothing to plot against duration.');
prompt  if(ST.scatter==null){var mn=Math.min.apply(null,rs.map(function(r){return r.tot})),mx0=Math.max.apply(null,rs.map(function(r){return r.tot}));ST.scatter=(mx0/mn>200)?'log':'lin';drawSegs()}
prompt  var lgs=ST.scatter==='log',w=W(el),h=300,m={l:54,r:14,t:24,b:38},pw=w-m.l-m.r,ph=h-m.t-m.b;
prompt  var xe=rs.map(function(r){return r.el/60}),ye=rs.map(function(r){return r.tot}),xmax=Math.max.apply(null,xe),ymax=Math.max.apply(null,ye),xmin=Math.min.apply(null,xe),ymin=Math.min.apply(null,ye);
prompt  var sx,sy,xt,yt,nx,ny;
prompt  if(lgs){var xl=Math.pow(10,Math.floor(Math.log10(xmin))),xh=Math.pow(10,Math.ceil(Math.log10(xmax*1.01))),yl=Math.pow(10,Math.floor(Math.log10(ymin))),yh=Math.pow(10,Math.ceil(Math.log10(ymax*1.01)));
prompt   if(xl===xh)xh=xl*10;if(yl===yh)yh=yl*10;sx=lg(xl,xh,m.l,w-m.r);sy=lg(yl,yh,m.t+ph,m.t);xt=logTicks(xl,xh);yt=logTicks(yl,yh)}
prompt  else{nx=niceMax(xmax,6);ny=niceMax(ymax,5);sx=lin(0,nx.max,m.l,w-m.r);sy=lin(0,ny.max,m.t+ph,m.t);xt=nx.ticks;yt=ny.ticks}
prompt  var s=svgO(w,h,'Duration versus volume'),pts=[];
prompt  yt.forEach(function(v){var y=sy(v).toFixed(1);s+='<line class="gl" x1="'+m.l+'" x2="'+(w-m.r)+'" y1="'+y+'" y2="'+y+'"/><text x="'+(m.l-8)+'" y="'+y+'" dy="0.32em" text-anchor="end">'+esc(lgs?(v>=1?num(v,0):String(+v.toPrecision(2))):tickf(v,ny.step))+'</text>'});
prompt  xt.forEach(function(v){var x=sx(v).toFixed(1);s+='<line class="gl" x1="'+x+'" x2="'+x+'" y1="'+m.t+'" y2="'+(m.t+ph)+'"/><text x="'+x+'" y="'+(m.t+ph+15)+'" text-anchor="middle">'+esc(lgs?(v>=1?num(v,0):String(+v.toPrecision(2))):tickf(v,nx.step))+'</text>'});
prompt  s+='<text x="'+(m.l+pw/2)+'" y="'+(h-4)+'" text-anchor="middle">elapsed minutes</text><text x="4" y="11">GB (est.)</text><line class="ax" x1="'+m.l+'" x2="'+(w-m.r)+'" y1="'+(m.t+ph)+'" y2="'+(m.t+ph)+'"/>';
prompt  rs.forEach(function(r){var x=sx(r.el/60),y=sy(r.tot),c=col(r.t);s+='<circle cx="'+x.toFixed(1)+'" cy="'+y.toFixed(1)+'" r="4" style="fill:'+c+';stroke:var(--card)" stroke-width="1.5" opacity=".88"/>';pts.push({x:x,y:y,c:c,tip:runTip(r)})});
prompt  s+=HLC+'</svg>';
prompt  var hid=runs.length-rs.length;
prompt  s='<div class="lg">'+groups.map(function(g){return '<span class="lgs"><i class="dot" style="background:'+g.col+'"></i>'+esc(cut(g.label,34))+'</span>'}).join('')+'</div>'+s;
prompt  if(hid)s+='<p class="note">'+hid+' run'+(hid>1?'s':'')+' with no recorded IO volume not plotted.</p>';
prompt  el.innerHTML=s;pointHover(el,pts,w)});
prompt
prompt // heatmap
prompt chart('heat',function(el){
prompt  var tot=sum(HEAT,function(r){return r.n});if(!tot)return empty(el,'No ASH samples for the selected sessions.');
prompt  var g={},mx=0;HEAT.forEach(function(r){g[r.d+'_'+r.h]=r.n;mx=Math.max(mx,r.n)});
prompt  var w=W(el),m={l:38,r:8,t:6,b:42},pw=w-m.l-m.r,cw=pw/24,ch=Math.min(46,Math.max(20,cw*1.1)),h=m.t+7*ch+m.b,dn=['Mon','Tue','Wed','Thu','Fri','Sat','Sun'],s=svgO(w,h,'Activity heatmap');
prompt  for(var d=0;d<7;d++){s+='<text x="'+(m.l-8)+'" y="'+(m.t+d*ch+ch/2)+'" dy="0.32em" text-anchor="end">'+dn[d]+'</text>';
prompt   for(var hr=0;hr<24;hr++){var n=g[d+'_'+hr]||0,p=n?Math.round(16+84*Math.sqrt(n/mx)):0;
prompt    s+='<rect x="'+(m.l+hr*cw+1).toFixed(1)+'" y="'+(m.t+d*ch+1)+'" width="'+(cw-2).toFixed(1)+'" height="'+(ch-2)+'" rx="3" style="fill:'+(n?'color-mix(in srgb,var(--seq-hi) '+p+'%,var(--seq-lo))':'var(--soft)')+'" data-t="'+esc(tt(dn[d]+' '+pad(hr)+':00 to '+pad(hr)+':59',[[null,'ASH samples',num(n)],[null,'DB time (est.)',dur(n*10)]]))+'"/>'}}
prompt  for(var hr2=0;hr2<24;hr2+=(cw<26?3:2))s+='<text x="'+(m.l+hr2*cw+cw/2).toFixed(1)+'" y="'+(m.t+7*ch+14)+'" text-anchor="middle">'+pad(hr2)+'</text>';
prompt  var lx=m.l,ly=m.t+7*ch+24;
prompt  s+='<text x="'+lx+'" y="'+(ly+10)+'">0</text><rect x="'+(lx+14)+'" y="'+(ly+1)+'" width="120" height="10" rx="3" style="fill:url(#hg)"/><text x="'+(lx+140)+'" y="'+(ly+10)+'">'+num(mx)+' samples (sqrt scale)</text>';
prompt  s+='<defs><linearGradient id="hg"><stop offset="0" style="stop-color:color-mix(in srgb,var(--seq-hi) 8%,var(--seq-lo))"/><stop offset="1" style="stop-color:var(--seq-hi)"/></linearGradient></defs></svg>';
prompt  el.innerHTML=s});
prompt
prompt // wait profile + top events
prompt var WC=[['cpu','CPU','var(--w-cpu)'],['io','IO','var(--w-io)'],['mml','Media manager (MML)','var(--w-mml)'],['oth','Other','var(--w-oth)']];
prompt chart('waitmix',function(el){
prompt  if(!hasRuns)return empty(el,'No ASH samples to classify.');
prompt  var ts=tlist.slice().sort(function(a,b){return b.n-a.n}).slice(0,15);
prompt  var h='<div class="lg">'+WC.map(function(c){return '<span class="lgs"><i class="dot" style="background:'+c[2]+'"></i>'+c[1]+'</span>'}).join('')+'</div><div class="wp">';
prompt  ts.forEach(function(o){var seg='';WC.forEach(function(c){var v=o[c[0]],p=100*v/o.n;if(!v)return;
prompt   seg+='<span style="width:'+p+'%;background:'+c[2]+'" data-t="'+esc(tt(o.t,[[c[2],c[1],num(p,1)+' %'],[null,'Samples',num(v)+' of '+num(o.n)]]))+'">'+(p>=9?Math.round(p)+'%':'')+'</span>'});
prompt   h+='<div class="wr"><span class="nm" title="'+esc(o.t)+'"><span class="dot" style="background:'+o.col+'"></span>'+esc(o.t)+'</span><div class="tr">'+seg+'</div><span class="v">'+num(o.n*10/3600,1)+' h</span></div>'});
prompt  h+='</div><p class="note">'+(tlist.length>ts.length?'Showing the '+ts.length+' types with most ASH samples out of '+tlist.length+'. ':'')+'Right column is estimated DB time (samples x 10 s).</p>';
prompt  el.innerHTML=h});
prompt chart('topev',function(el){
prompt  if(!EVENTS.length)return empty(el,'No wait events were sampled.');
prompt  var by={};EVENTS.forEach(function(e){(by[e.t]=by[e.t]||[]).push(e)});
prompt  var ts=tlist.slice().sort(function(a,b){return b.n-a.n}).slice(0,6),h='<div class="sm">';
prompt  ts.forEach(function(o){var es=(by[o.t]||[]).slice(0,5);
prompt   h+='<div><h4><span class="dot" style="background:'+o.col+'"></span><span class="t" title="'+esc(o.t)+'">'+esc(o.t)+'</span><em>'+num(o.n)+' samples</em></h4>';
prompt   es.forEach(function(e){var p=100*e.n/e.tot;h+='<div class="eb" data-t="'+esc(tt(o.t,[[o.col,e.e,num(p,1)+' %'],[null,'Class',e.c],[null,'Samples',num(e.n)]]))+'"><span class="nm" title="'+esc(e.e)+'">'+esc(e.e)+'</span><span class="b"><i style="width:'+Math.max(1.5,p)+'%;background:'+o.col+'"></i></span><span class="p">'+Math.round(p)+'%</span></div>'});
prompt   h+='</div>'});
prompt  el.innerHTML=h+'</div>'+(tlist.length>ts.length?'<p class="note">Top '+ts.length+' of '+tlist.length+' types by ASH samples.</p>':'')});
prompt
prompt // authoritative IO per day (area)
prompt chart('ioday',function(el){
prompt  var io={};IODAY.forEach(function(r){io[r.d]=r});
prompt  var any=IODAY.some(function(r){return (r.rd||0)+(r.wr||0)+(r.ard||0)+(r.awr||0)>0});
prompt  if(!any)return empty(el,'No RMAN-function IO and no ASH IO in the window.');
prompt  var w=W(el),h=300,m={l:50,r:12,t:24,b:28},pw=w-m.l-m.r,ph=h-m.t-m.b,n=days.length,mx=0;
prompt  days.forEach(function(d){var r=io[d]||{};mx=Math.max(mx,(r.rd||0)+(r.wr||0),(r.ard||0)+(r.awr||0))});
prompt  var nm=niceMax(mx,5),sy=lin(0,nm.max,m.t+ph,m.t),sx=function(i){return n>1?m.l+i*pw/(n-1):m.l+pw/2},k=xDays(days,pw);
prompt  var s=legend('ioday',[{k:'rd',label:'Read GB (iostat)',col:'var(--read)'},{k:'wr',label:'Write GB (iostat)',col:'var(--write)'}])+'<div class="lg" style="margin-top:-2px"><span class="lgs"><i class="ln" style="display:inline-block;width:16px;border-top:2px dashed var(--ink)"></i>ASH estimate, read plus write</span></div>';
prompt  s+=svgO(w,h,'RMAN IO per day')+yGrid(sy,nm.ticks,nm.step,m,w)+'<text x="4" y="11">GB</text>';
prompt  var rdv=days.map(function(d){return hidden('ioday','rd')?0:(io[d]&&io[d].rd)||0}),wrv=days.map(function(d,i){return hidden('ioday','wr')?0:(io[d]&&io[d].wr)||0});
prompt  function area(lo,hi,c){var up=hi.map(function(v,i){return sx(i).toFixed(1)+' '+sy(lo[i]+v).toFixed(1)}),dn=hi.map(function(v,i){return sx(i).toFixed(1)+' '+sy(lo[i]).toFixed(1)}).reverse();
prompt   return '<path d="M'+up.join('L')+'L'+dn.join('L')+'Z" style="fill:'+c+'" fill-opacity=".62"/><path d="M'+up.join('L')+'" fill="none" stroke-width="2" style="stroke:'+c+'"/>'}
prompt  var z=days.map(function(){return 0});
prompt  s+=area(z,rdv,'var(--read)')+area(rdv,wrv,'var(--write)');
prompt  var ash=days.map(function(d){var r=io[d]||{};return (r.ard||0)+(r.awr||0)});
prompt  s+='<path d="M'+ash.map(function(v,i){return sx(i).toFixed(1)+' '+sy(v).toFixed(1)}).join('L')+'" fill="none" stroke-width="1.8" stroke-dasharray="5 3" style="stroke:var(--ink)"/>';
prompt  if(n<=70)ash.forEach(function(v,i){s+='<circle cx="'+sx(i).toFixed(1)+'" cy="'+sy(v).toFixed(1)+'" r="2.6" style="fill:var(--card);stroke:var(--ink)" stroke-width="1.5"/>'});
prompt  days.forEach(function(d,i){if(i%k===0)s+='<text x="'+sx(i).toFixed(1)+'" y="'+(h-9)+'" text-anchor="middle">'+md(d)+'</text>'});
prompt  s+='<line class="ax" x1="'+m.l+'" x2="'+(w-m.r)+'" y1="'+(m.t+ph)+'" y2="'+(m.t+ph)+'"/><g class="xh" visibility="hidden"><line class="ax" y1="'+m.t+'" y2="'+(m.t+ph)+'" style="stroke:var(--mute)"/></g><rect class="ov" data-ov="1" x="'+m.l+'" y="'+m.t+'" width="'+pw+'" height="'+ph+'" fill="transparent"/></svg>';
prompt  el.innerHTML=s;
prompt  overlay(el,m,w,h,function(x,e){var i=Math.max(0,Math.min(n-1,Math.round((x-m.l)/(pw/Math.max(1,n-1))))),r=io[days[i]]||{},g=$('.xh',el);
prompt   g.setAttribute('visibility','visible');$('line',g).setAttribute('x1',sx(i));$('line',g).setAttribute('x2',sx(i));
prompt   showTip(tt(dd(days[i]),[['var(--read)','Read (iostat)',gbf(r.rd||0)+' GB'],['var(--write)','Write (iostat)',gbf(r.wr||0)+' GB'],[null,'Reqs read / write',num(r.rq||0)+' / '+num(r.wq||0)],[null,'IO wait',num(r.ws||0)+' s'],
prompt    ['var(--ink)','ASH est. read / write',gbf(r.ard||0)+' / '+gbf(r.awr||0)+' GB'],[null,'Snapshots used / dropped',(r.us||0)+' / '+(r.dr||0)]]),e.clientX,e.clientY)})});
prompt
prompt // RMAN wait events per day
prompt seg('wday-ctl','wday',[['s','Time waited'],['w','Wait count']],'wday');
prompt chart('wday',function(el){
prompt  if(!WAITDAY.length)return empty(el,'No Backup: or RMAN wait events were recorded in DBA_HIST_SYSTEM_EVENT in this window.');
prompt  var key=ST.wday,tot={},by={};WAITDAY.forEach(function(r){tot[r.e]=(tot[r.e]||0)+r[key];(by[r.e]=by[r.e]||{})[r.d]=r});
prompt  var evs=Object.keys(tot).sort(function(a,b){return tot[b]-tot[a]}).slice(0,6).map(function(e,i){return {k:e,label:e,col:'var(--c'+(i+1)+')'}}),vis=evs.filter(function(g){return !hidden('wday',g.k)});
prompt  var w=W(el),h=290,m={l:50,r:12,t:24,b:28},pw=w-m.l-m.r,ph=h-m.t-m.b,n=days.length,mx=0;
prompt  vis.forEach(function(g){days.forEach(function(d){mx=Math.max(mx,(by[g.k][d]||{})[key]||0)})});
prompt  var nm=niceMax(mx,5),sy=lin(0,nm.max,m.t+ph,m.t),sx=function(i){return n>1?m.l+i*pw/(n-1):m.l+pw/2},k=xDays(days,pw);
prompt  var s=legend('wday',evs,true)+svgO(w,h,'RMAN wait events per day')+yGrid(sy,nm.ticks,nm.step,m,w)+'<text x="4" y="11">'+(key==='s'?'seconds':'waits')+'</text>';
prompt  vis.forEach(function(g){var d=days.map(function(day,i){return (i?'L':'M')+sx(i).toFixed(1)+' '+sy(((by[g.k][day]||{})[key])||0).toFixed(1)}).join('');
prompt   s+='<path d="'+d+'" fill="none" stroke-width="2" stroke-linejoin="round" style="stroke:'+g.col+'"/>'});
prompt  days.forEach(function(d,i){if(i%k===0)s+='<text x="'+sx(i).toFixed(1)+'" y="'+(h-9)+'" text-anchor="middle">'+md(d)+'</text>'});
prompt  s+='<line class="ax" x1="'+m.l+'" x2="'+(w-m.r)+'" y1="'+(m.t+ph)+'" y2="'+(m.t+ph)+'"/><g class="xh" visibility="hidden"><line class="ax" y1="'+m.t+'" y2="'+(m.t+ph)+'" style="stroke:var(--mute)"/></g><rect class="ov" data-ov="1" x="'+m.l+'" y="'+m.t+'" width="'+pw+'" height="'+ph+'" fill="transparent"/></svg>';
prompt  el.innerHTML=s;
prompt  overlay(el,m,w,h,function(x,e){var i=Math.max(0,Math.min(n-1,Math.round((x-m.l)/(pw/Math.max(1,n-1))))),g=$('.xh',el);
prompt   g.setAttribute('visibility','visible');$('line',g).setAttribute('x1',sx(i));$('line',g).setAttribute('x2',sx(i));
prompt   showTip(tt(dd(days[i]),vis.map(function(ev){var r=by[ev.k][days[i]]||{};return [ev.col,cut(ev.label,30),key==='s'?num(r.s||0,1)+' s':num(r.w||0)+' waits']})),e.clientX,e.clientY)})});
prompt
prompt // tables
prompt var TS={},FILT={};
prompt function tbl(id,o){chart(id,function(el){
prompt  var st=TS[id]=TS[id]||{k:o.defk,dir:o.defdir||1,lim:o.limit||200},rows=o.rows();
prompt  if(!rows.length){if(o.empty==='')el.innerHTML='';else empty(el,o.empty);return}
prompt  var c=o.cols[st.k]||o.cols[0];
prompt  rows=rows.slice().sort(function(a,b){var x=c.v(a),y=c.v(b);if(x==null)return 1;if(y==null)return -1;return (x<y?-1:x>y?1:0)*st.dir});
prompt  var h='<div class="tw"><table><thead><tr>'+o.cols.map(function(cc,i){return '<th tabindex="0" class="'+(cc.n?'n':'')+'" data-sk="'+i+'" aria-sort="'+(i==st.k?(st.dir>0?'ascending':'descending'):'none')+'">'+esc(cc.l)+'</th>'}).join('')+'</tr></thead><tbody>';
prompt  rows.slice(0,st.lim).forEach(function(r){h+='<tr>'+o.cols.map(function(cc){return '<td class="'+(cc.n?'n':'')+'">'+cc.h(r)+'</td>'}).join('')+'</tr>'});
prompt  h+='</tbody></table></div>';
prompt  if(rows.length>st.lim)h+='<button type="button" class="btn more" data-more="'+id+'">Show all '+num(rows.length)+' rows</button>';
prompt  else h+='<p class="note">'+num(rows.length)+' row'+(rows.length>1?'s':'')+'.</p>';
prompt  el.innerHTML=h})}
prompt function sortHdl(e){var th=e.target.closest&&e.target.closest('th[data-sk]');if(!th)return;if(e.type==='keydown'&&e.key!=='Enter'&&e.key!==' ')return;
prompt  var id=th.closest('[id^="tbl-"],[id^="x-tbl"]').id,st=TS[id],i=+th.getAttribute('data-sk');if(st.k===i)st.dir=-st.dir;else{st.k=i;st.dir=1}paint(id);e.preventDefault()}
prompt D.addEventListener('click',function(e){sortHdl(e);var b=e.target.closest&&e.target.closest('[data-more]');if(b){TS[b.getAttribute('data-more')].lim=1e9;paint(b.getAttribute('data-more'))}});
prompt D.addEventListener('keydown',sortHdl);
prompt function dotName(t){return '<span class="dot" style="background:'+col(t)+'"></span>'+esc(t)}
prompt tbl('tbl-sum',{defk:5,defdir:-1,empty:'No backup types detected in the window.',rows:function(){return tlist},cols:[
prompt  {l:'Backup type',h:function(o){return dotName(o.t)},v:function(o){return o.t}},
prompt  {l:'Runs',n:1,h:function(o){return num(o.runs)},v:function(o){return o.runs}},
prompt  {l:'Avg elapsed',n:1,h:function(o){return dur(o.el/o.runs)},v:function(o){return o.el/o.runs}},
prompt  {l:'Min elapsed',n:1,h:function(o){return dur(o.min)},v:function(o){return o.min}},
prompt  {l:'Max elapsed',n:1,h:function(o){return dur(o.max)},v:function(o){return o.max}},
prompt  {l:'Total hours',n:1,h:function(o){return num(o.el/3600,1)},v:function(o){return o.el}},
prompt  {l:'Avg DB time',n:1,h:function(o){return dur(o.n*10/o.runs)},v:function(o){return o.n/o.runs}},
prompt  {l:'Read GB (est.)',n:1,h:function(o){return gbf(o.rd)},v:function(o){return o.rd}},
prompt  {l:'Write GB (est.)',n:1,h:function(o){return gbf(o.wr)},v:function(o){return o.wr}},
prompt  {l:'MB/s (est.)',n:1,h:function(o){return num((o.rd+o.wr)*1024/o.el,1)},v:function(o){return (o.rd+o.wr)/o.el}},
prompt  {l:'First run',h:function(o){return dt(o.first)},v:function(o){return o.first}},
prompt  {l:'Last run',h:function(o){return dt(o.last)},v:function(o){return o.last}}]});
prompt function mix(r){return '<span class="mix" title="CPU '+Math.round(100*r.cpu/r.n)+'% / IO '+Math.round(100*r.io/r.n)+'% / MML '+Math.round(100*r.mml/r.n)+'% / other '+Math.round(100*r.oth/r.n)+'%">'+WC.map(function(c){return r[c[0]]?'<i style="width:'+100*r[c[0]]/r.n+'%;background:'+c[2]+'"></i>':''}).join('')+'</span>'}
prompt tbl('tbl-runs',{defk:1,defdir:1,limit:200,empty:'No runs match the selected types.',rows:function(){var f=Object.keys(FILT).filter(function(k){return FILT[k]});return f.length?runs.filter(function(r){return FILT[r.t]}):runs},cols:[
prompt  {l:'Backup type',h:function(r){return dotName(r.t)},v:function(r){return r.t}},
prompt  {l:'Start',h:function(r){return dt(r.s)},v:function(r){return r.s}},
prompt  {l:'End',h:function(r){return dt(r.e+10)},v:function(r){return r.e}},
prompt  {l:'Elapsed',n:1,h:function(r){return hms(r.el)},v:function(r){return r.el}},
prompt  {l:'Chan.',n:1,h:function(r){return r.ch},v:function(r){return r.ch}},
prompt  {l:'Sess.',n:1,h:function(r){return r.se},v:function(r){return r.se}},
prompt  {l:'Inst',n:1,h:function(r){return esc(r.in)},v:function(r){return r.in}},
prompt  {l:'DB min',n:1,h:function(r){return num(r.n*10/60,1)},v:function(r){return r.n}},
prompt  {l:'Wait mix',h:mix,v:function(r){return r.cpu/r.n}},
prompt  {l:'Read GB',n:1,h:function(r){return gbf(r.rd)},v:function(r){return r.rd}},
prompt  {l:'Write GB',n:1,h:function(r){return gbf(r.wr)},v:function(r){return r.wr}},
prompt  {l:'MB/s',n:1,h:function(r){return num(r.mbs,1)},v:function(r){return r.mbs}},
prompt  {l:'Top event',h:function(r){return esc(cut(r.ev,36))+' ('+Math.round(r.evp)+'%)'},v:function(r){return r.ev}}]});
prompt function drawChips(){var el=$('#chips');if(!hasRuns){el.innerHTML='';return}
prompt  var any=Object.keys(FILT).some(function(k){return FILT[k]});
prompt  el.innerHTML='<button type="button" class="chip'+(any?'':' on')+'" data-chip="">All types</button>'+tlist.map(function(o){return '<button type="button" class="chip'+(FILT[o.t]?' on':'')+'" data-chip="'+esc(o.t)+'"><span class="dot" style="background:'+o.col+'"></span>'+esc(cut(o.t,30))+' <span style="opacity:.7">'+o.runs+'</span></button>'}).join('')}
prompt D.addEventListener('click',function(e){var b=e.target.closest&&e.target.closest('[data-chip]');if(!b)return;var k=b.getAttribute('data-chip');
prompt  if(k==='')FILT={};else FILT[k]=!FILT[k];drawChips();paint('tbl-runs')});
prompt
prompt // cross-check: controlfile or recovery catalog
prompt var jobs=JOBS,JM=JOBMETA,isCat=JM.src==='CATALOG',srcName=isCat?'recovery catalog':'controlfile';
prompt function jcol(st){st=String(st||'').toUpperCase();return st==='COMPLETED'?'var(--good)':st.indexOf('WARN')>=0?'var(--warn)':st.indexOf('FAIL')>=0?'var(--crit)':st.indexOf('RUNNING')>=0?'var(--c1)':'var(--other)'}
prompt function jglyph(st){st=String(st||'').toUpperCase();return st==='COMPLETED'?'\u2713':st.indexOf('WARN')>=0?'!':st.indexOf('FAIL')>=0?'\u2715':'\u2022'}
prompt function buildCross(){
prompt  var keep=JM.keep==null?'unknown':JM.keep+' days',sub,note='';
prompt  $('#x-h2').textContent=isCat?'Cross-check from the RMAN recovery catalog':'Cross-check from the controlfile';
prompt  $('#x-h3').textContent=isCat?'RC_RMAN_BACKUP_JOB_DETAILS':'V$RMAN_BACKUP_JOB_DETAILS';
prompt  if(isCat){
prompt   sub='Source: RMAN recovery catalog '+(JM.label||'')+', not AWR.';
prompt   if(JM.state==='OK')sub+=' The catalog holds '+num(JM.cnt)+' job'+(JM.cnt===1?'':'s')+' for this database (DBID '+M.dbid+'), oldest '+(JM.first==null?'n/a':dt(JM.first))+', newest '+(JM.last==null?'n/a':dt(JM.last))+'. The panel below shows the last '+M.days+' days.';
prompt   else if(JM.state==='NOT_REGISTERED')note=banner('warn','DBID '+M.dbid+' is not registered in this recovery catalog','Nothing to show: '+(JM.label||'the catalog')+' has no database with this DBID in RC_DATABASE. Register the database (RMAN: REGISTER DATABASE) or check the dbid parameter.');
prompt   else if(JM.state==='NO_CONNECT')note=banner('warn','The connect to the recovery catalog did not take effect','The catalog connect string was not accepted by SQL*Plus (invalid syntax?), so no catalog data was read.');
prompt   else note=banner('warn','The recovery catalog views cannot be read','RC_DATABASE or RC_RMAN_BACKUP_JOB_DETAILS is not accessible as '+(JM.label||'this user')+' (the catalog owner or a virtual private catalog user is needed). '+(JM.err||''));
prompt  }else sub='Source is the controlfile, not AWR. control_file_record_keep_time = '+keep+(JM.keep!=null&&+JM.keep<M.days?', which is shorter than the '+M.days+'-day window, so older jobs may already be aged out.':'.');
prompt  $('#x-sub').textContent=sub;$('#x-note').innerHTML=note;
prompt  if(!jobs.length){$('#x-stats').innerHTML='';$('#x-gantt').innerHTML='';$('#x-tbl').innerHTML='';if(JM.state==='OK'||!isCat)empty($('#x-gantt'),isCat?'The recovery catalog has no jobs for this database in this window.':'V$RMAN_BACKUP_JOB_DETAILS has no jobs in this window (record keep time '+keep+').');return}
prompt  var ok=jobs.filter(function(j){return j.st==='COMPLETED'}).length,bad=jobs.filter(function(j){return String(j.st).indexOf('FAIL')>=0}).length,jh=sum(jobs,function(j){return j.el})/3600;
prompt  var st=[[num(jobs.length),'jobs'],[num(ok),'completed'],[num(jobs.length-ok-bad),'warnings or other'],[num(bad),'failed'],[num(jh,1)+' h','job elapsed time'],[gbf(sum(jobs,function(j){return j.in}))+' GB','input read'],[gbf(sum(jobs,function(j){return j.out}))+' GB','output written']];
prompt  if(hasRuns)st.push([num(sum(runs,function(r){return r.el})/3600,1)+' h','ASH-derived time (est.)']);
prompt  $('#x-stats').innerHTML='<div class="stats">'+st.map(function(x){return '<div><b>'+esc(x[0])+'</b><span>'+esc(x[1])+'</span></div>'}).join('')+'</div>'}
prompt chart('x-gantt',function(el){
prompt  if(!jobs.length){if(isCat&&JM.state!=='OK'){el.innerHTML='';return}return empty(el,'No '+srcName+' jobs in this window.')}
prompt  var ty={};jobs.forEach(function(j){ty[j.ty]=(ty[j.ty]||0)+j.el});
prompt  var lanes=Object.keys(ty).sort(function(a,b){return ty[b]-ty[a]}).map(function(k){return {k:k,label:k,col:'var(--ink2)'}}),sts={};jobs.forEach(function(j){sts[j.st]=1});
prompt  var lgd='<div class="lg">'+Object.keys(sts).map(function(k){return '<span class="lgs"><i class="dot" style="background:'+jcol(k)+'"></i>'+esc(k)+' '+jglyph(k)+'</span>'}).join('')+'</div>';
prompt  var x0=Math.min.apply(null,jobs.map(function(j){return j.s}))-3600;
prompt  gantt(el,{lanes:lanes,items:jobs,x0:Math.max(M.win0,x0),x1:M.now,hatchTo:0,legend:lgd,label:(isCat?'Recovery catalog':'Controlfile')+' job timeline',sOf:function(j){return j.s},eOf:function(j){return j.e},laneOf:function(j){return j.ty},colOf:function(j){return jcol(j.st)},
prompt   tipOf:function(j){return tt(j.ty,[[jcol(j.st),'Status',j.st+' '+jglyph(j.st)],[null,'Start',dt(j.s)],[null,'End',dt(j.e)],[null,'Elapsed',dur(j.el)],[null,'Input / output',gbf(j.in)+' / '+gbf(j.out)+' GB'],[null,'Input rate',num(j.mbs,1)+' MB/s'],[null,'Device',j.dev||'']])}})});
prompt tbl('x-tbl',{defk:2,defdir:-1,limit:100,empty:'',rows:function(){return jobs},cols:[
prompt  {l:'Input type',h:function(j){return esc(j.ty)},v:function(j){return j.ty}},
prompt  {l:'Status',h:function(j){return '<span style="color:'+jcol(j.st)+'">'+jglyph(j.st)+'</span> '+esc(j.st)},v:function(j){return j.st}},
prompt  {l:'Start',h:function(j){return dt(j.s)},v:function(j){return j.s}},
prompt  {l:'End',h:function(j){return dt(j.e)},v:function(j){return j.e}},
prompt  {l:'Elapsed',n:1,h:function(j){return hms(j.el)},v:function(j){return j.el}},
prompt  {l:'Input GB',n:1,h:function(j){return gbf(j.in)},v:function(j){return j.in}},
prompt  {l:'Output GB',n:1,h:function(j){return gbf(j.out)},v:function(j){return j.out}},
prompt  {l:'Input MB/s',n:1,h:function(j){return num(j.mbs,1)},v:function(j){return j.mbs}},
prompt  {l:'Device',h:function(j){return esc(j.dev||'')},v:function(j){return j.dev}}]});
prompt
prompt // footer
prompt function buildFoot(){
prompt  $('#foot').innerHTML='<div><h3>Method</h3><ul><li>Backup type is the ASH <code>MODULE</code> of the session without its <code>: channel</code> suffix. The RMAN client session is its own type. Oracle labels incremental backups of every level <code>backup incr datafile</code>, level 0 included, so <code>backup full datafile</code> only covers backups taken without the INCREMENTAL keyword.</li>'
prompt  +'<li>A new run starts when the gap since the previous sample of the same type exceeds '+M.gap+' minutes; the decision is made once per sample second, so channels sampled at the same instant always share a run. A channel that comes back to a type after working on another one (BACKUP DATABASE PLUS ARCHIVELOG) continues a run only if that run had a sample in the last 2 minutes; the same applies when a channel of that run left the type shortly before. Otherwise a new run starts. Elapsed is last sample minus first sample plus 10 s.</li>'
prompt  +'<li>Wait mix: ON CPU is CPU; User I/O and System I/O are IO; <code>Backup: MML</code> events are MML; everything else is other.</li>'
prompt  +'<li>Authoritative IO is the snapshot delta of <code>DBA_HIST_IOSTAT_FUNCTION</code> function RMAN. Intervals across a restart or with a negative delta are dropped.</li></ul></div>'
prompt  +'<div><h3>Read this before trusting the numbers</h3><ul><li>AWR keeps 1 in 10 ASH samples. Hours, GB and MB/s from ASH are sampled estimates; very short backups can be missed.</li>'
prompt  +'<li>Run IO is <code>delta_bytes / delta_time x 10 s</code> per retained sample, so it is rough.</li>'
prompt  +'<li>Function RMAN also counts non-backup IO (controlfile autobackups, Data Guard, flashback, recovery). Treat it as an upper bound.</li>'
prompt  +'<li>AWR coverage may be partial: retention is '+(M.ret==null?'unknown':M.ret+' days')+'. '+(isCat?'The recovery catalog panel is not AWR; the catalog usually keeps more history than the controlfile.':'The controlfile panel is not AWR and is limited by control_file_record_keep_time.')+'</li>'
prompt  +'<li>Needs the Diagnostics Pack license. In a CDB, run from CDB$ROOT to see all containers.</li></ul></div>'
prompt  +'<div><h3>About this file</h3><p>Generated by awr_backup_report_html.sql from '+esc(M.db)+' ('+esc(M.host)+') on '+dt(M.now)+', database clock. Self-contained: no network access, fonts or scripts are loaded from elsewhere. Colours follow the backup type: the '+TOP+' types with most elapsed time get a colour, the rest are grouped as Other.</p></div>'}
prompt
prompt // theme
prompt var THEMES=['auto','light','dark'],ti=0;
prompt function setTheme(t){var r=D.documentElement;if(t==='auto')r.removeAttribute('data-theme');else r.setAttribute('data-theme',t);$('#theme').textContent='Theme: '+t}
prompt (function(){var h=location.hash.replace('#','');if(h==='dark'||h==='light'){ti=THEMES.indexOf(h)}else{try{var v=localStorage.getItem('awrTheme');if(v)ti=Math.max(0,THEMES.indexOf(v))}catch(e){}}setTheme(THEMES[ti])})();
prompt $('#theme').addEventListener('click',function(){ti=(ti+1)%3;setTheme(THEMES[ti]);try{localStorage.setItem('awrTheme',THEMES[ti])}catch(e){}});
prompt
prompt // go
prompt buildTop();buildKpis();buildCross();buildFoot();drawSegs();drawChips();paintAll();
prompt var rt;window.addEventListener('resize',function(){clearTimeout(rt);rt=setTimeout(function(){Object.keys(CH).forEach(function(id){var el=$('#'+id);if(el&&el.clientWidth!==el.__w)paint(id)})},120)});
prompt }
prompt </script>
set define '&'
-- ----------------------------------------------------------------------------
-- The cross-check data is the LAST DB work.  With a catalog argument the script
-- CONNECTs to the RMAN recovery catalog here, so nothing that needs the target
-- DB may follow.  The spool is closed around the CONNECT so that nothing it prints
-- ("Connected.", glogin.sql output) can reach the report file.
spool off
define cat_termout = ON
@@&cat_script
-- A CONNECT re-runs glogin.sql, which may change SET options: set them again.
set define '&' verify off echo off termout off feedback off heading on
set trimspool on trimout on tab off
set lines 250 pages 200 long 4000 numwidth 12
set serveroutput off
ttitle off
btitle off
repheader off
repfooter off
-- State of the source: CONTROLFILE / OK / NOT_REGISTERED / NO_ACCESS: <error>.
-- Dynamic SQL, so this script never parses a view that does not exist where it runs.
variable b_state varchar2(300)
variable b_cnt   number
variable b_first number
variable b_last  number
declare
  l_reg number;
begin
  :b_state := 'OK';
  :b_cnt   := 0;
  if '&cat_src' <> 'CATALOG' then
    :b_state := 'CONTROLFILE';
    return;
  end if;
  if to_char(sys_context('userenv', 'sessionid')) = '&cat_sess0' then
    :b_state := 'NO_CONNECT';
    return;
  end if;
  begin
    execute immediate 'select count(*) from rc_database where dbid = :1' into l_reg using &dbid;
    if l_reg = 0 then
      :b_state := 'NOT_REGISTERED';
      return;
    end if;
    execute immediate 'select count(*), round((min(start_time) - date ''1970-01-01'') * 86400), '
      || 'round((max(start_time) - date ''1970-01-01'') * 86400) from rc_rman_backup_job_details '
      || 'where db_key in (select db_key from rc_database where dbid = :1)'
      into :b_cnt, :b_first, :b_last using &dbid;
  exception when others then
    :b_state := 'NO_ACCESS: ' || replace(replace(replace(substr(sqlerrm, 1, 200), chr(39), ' '), chr(38), ' '), chr(34), ' ');
  end;
end;
/
column c_state  new_value cat_state  noprint
column c_cnt    new_value cat_cnt    noprint
column c_first  new_value cat_first  noprint
column c_last   new_value cat_last   noprint
column c_src    new_value jobs_src   noprint
select :b_state c_state, nvl(:b_cnt, 0) c_cnt, nvl(to_char(:b_first), 'null') c_first, nvl(to_char(:b_last), 'null') c_last,
       case when :b_state = 'CONTROLFILE'
              then 'v$rman_backup_job_details'
            when :b_state = 'OK'
              then '(select * from rc_rman_backup_job_details where db_key in (select db_key from rc_database where dbid = &dbid))'
            else '(select to_char(null) input_type, to_char(null) status, sysdate start_time, sysdate end_time, 0 elapsed_seconds, '
                 || '0 input_bytes, 0 output_bytes, 0 input_bytes_per_sec, to_char(null) output_device_type from dual where 1 = 0)'
       end c_src
  from dual
/
column c_state  clear
column c_cnt    clear
column c_first  clear
column c_last   clear
column c_src    clear
spool &fname append
set pages 0 heading off feedback off trimspool on lines 32767 termout off verify off newpage none
set define '&' sqlterminator off
prompt <script>
prompt const JOBS=[
select replace(json_object(
         'ty'  value input_type,
         'st'  value status,
         's'   value round((start_time - date '1970-01-01') * 86400),
         'e'   value round((end_time   - date '1970-01-01') * 86400),
         'el'  value elapsed_seconds,
         'in'  value round(input_bytes  / power(1024, 3), 4),
         'out' value round(output_bytes / power(1024, 3), 4),
         'mbs' value round(input_bytes_per_sec / 1048576, 2),
         'dev' value output_device_type), '<', '\u003c') || ','
  from (select * from &jobs_src
         where start_time >= to_date('&jobs_win', 'YYYY-MM-DD HH24:MI:SS')
         order by start_time desc)
 where rownum <= 5000
 order by start_time
/
prompt ];
prompt const JOBMETA=
select replace(json_object(
         'src'   value '&cat_src',
         'label' value '&cat_label',
         'state' value case when '&cat_state' like 'NO^_ACCESS%' escape '^' then 'NO_ACCESS' else '&cat_state' end,
         'err'   value case when '&cat_state' like 'NO^_ACCESS: %' escape '^' then substr('&cat_state', 12) end,
         'cnt'   value &cat_cnt,
         'first' value &cat_first,
         'last'  value &cat_last,
         'keep'  value nullif('&cat_keep', '')), '<', '\u003c')
  from dual
/
prompt ;
prompt awrMain();
prompt </script>
prompt </body>
prompt </html>
spool off
set define '&' sqlterminator ';' termout on feedback 6 verify on heading on pages 14 lines 80
prompt
prompt Report written: &fname
clear columns
