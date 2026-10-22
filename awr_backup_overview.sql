-- ============================================================================
-- awr_backup_overview.sql
--
-- How long, and how much work, did each type of RMAN backup do over the last
-- N days?  Built from AWR (DBA_HIST_*) only, apart from the clearly labelled
-- optional cross-check in section F.
--
-- Usage (SQL*Plus, connected as SYSDBA or a user that can read DBA_HIST_*):
--
--   @awr_backup_overview.sql [days] [gap_minutes] [dbid] [inst] [scope]
--
--   days         look-back window in days                       default 60
--   gap_minutes  idle gap (minutes) that splits two runs of the
--                same backup type                               default 30
--   dbid         DBID to report on                              default: this DB
--   inst         instance number, 0 = all instances (RAC)       default 0
--   scope        RMAN = only RMAN sessions (normal use)         default RMAN
--                ALL  = NO RMAN filter, group any MODULE; only for validating
--                       the run detection / IO maths on a DB with no backups
--
--   Examples:  @awr_backup_overview.sql
--              @awr_backup_overview.sql 14 60
--              @awr_backup_overview.sql 60 30 "" 2
--   Pass "" (or omit) to take the default; omitted trailing args are fine.
--
-- Sections
--   0  AWR coverage and parameters (oldest snapshot actually available)
--   A  Summary per backup type
--   B  Run-level detail, ordered by start time
--   C  Authoritative RMAN IO per day (DBA_HIST_IOSTAT_FUNCTION) next to the
--      ASH-based estimate, so the estimate can be sanity-checked
--   D  RMAN related wait events per day (DBA_HIST_SYSTEM_EVENT)
--   F  NOT AWR: cross-check against V$RMAN_BACKUP_JOB_DETAILS
--
-- How backup types are found
--   AWR has no backup-type table.  The type comes from DBA_HIST_ACTIVE_SESS_HISTORY
--   (ASH): RMAN channel sessions set MODULE to strings such as
--   'backup full datafile: ORA_DISK_1', 'backup incr datafile: ORA_SBT_TAPE_1',
--   'backup archivelog: ORA_DISK_1', 'backup controlfile', 'backup spfile',
--   'restore ...', 'validate ...'.  backup_type is MODULE with the ': channel'
--   suffix removed, channel is that suffix.  The RMAN client session itself
--   (MODULE 'rman@host ...', PROGRAM 'rman@host (TNS V1-V3)') is reported as
--   the type 'RMAN client/catalog'.
--
-- How runs are found
--   Within one backup type, a new run starts when the gap since the previous
--   ASH sample is greater than gap_minutes (LAG plus a running SUM).
--
-- Limits - read before trusting the numbers
--   * Needs the Diagnostics Pack license (AWR/ASH).
--   * DBA_HIST_ACTIVE_SESS_HISTORY keeps 1 in 10 of the in-memory ASH samples
--     (one sample = about 10 seconds of one active session).  Everything derived
--     from it is a SAMPLED ESTIMATE: DB time = samples x 10 s, run start/end are
--     only accurate to about 10 s, and backups shorter than about 10 s may be
--     missed completely.
--   * IO volume is an estimate.  Each retained sample carries DELTA_READ_IO_BYTES
--     etc. which cover only the DELTA_TIME microseconds (about 1 s) before the
--     sample.  Each sample is scaled to the 10 s it stands for, using its own
--     rate: delta_bytes / delta_time * 10 s.  Samples with no DELTA_TIME
--     contribute 0.  Section C shows the authoritative RMAN volume for comparison.
--   * MB/s = (estimated read + write MB) / elapsed seconds of the run, i.e. an
--     average over the whole run, not a peak, and elapsed = end - start + 10 s.
--   * AWR retention may be shorter than the requested window (default 8 days
--     out of the box).  Section 0 prints the oldest snapshot that exists.
--   * Section F reads the controlfile (subject to control_file_record_keep_time),
--     not AWR.
--   * In a CDB, run from CDB$ROOT to see all containers.
--
-- The statements for A and B repeat the same WITH chain on purpose: SQL*Plus
-- cannot share a CTE between statements and this script must stay read-only
-- (no temp tables).  Keep the chains in sync when editing.
--
-- Read-only: SELECT statements only.
-- ============================================================================

whenever sqlerror continue
set define '&' verify off echo off termout off feedback off heading on
set trimspool on trimout on tab off
set lines 250 pages 200 long 4000 numwidth 12
set serveroutput off
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
select null "1", null "2", null "3", null "4", null "5" from dual where 1 = 0;

column p_days  new_value days        noprint
column p_gap   new_value gap_minutes noprint
column p_dbid  new_value dbid        noprint
column p_inst  new_value inst        noprint
column p_scope new_value scope       noprint
select to_number(nvl('&1', '60'))                    p_days,
       to_number(nvl('&2', '30'))                    p_gap,
       to_number(nvl('&3', to_char(d.dbid)))         p_dbid,
       to_number(nvl('&4', '0'))                     p_inst,
       upper(nvl('&5', 'RMAN'))                      p_scope
  from v$database d;
column p_days  clear
column p_gap   clear
column p_dbid  clear
column p_inst  clear
column p_scope clear
column 1 clear
column 2 clear
column 3 clear
column 4 clear
column 5 clear

set termout on feedback 1

prompt
prompt ==============================================================================
prompt  AWR RMAN backup overview     days=&days  gap_minutes=&gap_minutes  dbid=&dbid  inst=&inst (0=all)  scope=&scope
prompt  All figures marked "est" are ASH-sampled estimates, see header of this script.
prompt ==============================================================================

-- ----------------------------------------------------------------------------
prompt
prompt == 0. AWR coverage ==
column db_name        format a10        heading 'DB'
column dbid           format 9999999999 heading 'DBID'
column snaps          format 999,990    heading 'SNAPS|IN WINDOW'
column oldest_snap    format a19        heading 'OLDEST SNAPSHOT|AVAILABLE'
column newest_snap    format a19        heading 'NEWEST SNAPSHOT'
column win_start      format a19        heading 'WINDOW START'
column retention      format a14        heading 'AWR RETENTION'
column coverage       format a45        heading 'COVERAGE'
select d.name                                                                  db_name,
       &dbid                                                                   dbid,
       x.snaps,
       to_char(x.oldest, 'YYYY-MM-DD HH24:MI:SS')                              oldest_snap,
       to_char(x.newest, 'YYYY-MM-DD HH24:MI:SS')                              newest_snap,
       to_char(sysdate - &days, 'YYYY-MM-DD HH24:MI:SS')                       win_start,
       extract(day from w.retention) || ' days'                               retention,
       case when x.snaps = 0
              then 'NO SNAPSHOTS IN WINDOW (check dbid / days)'
            when x.oldest > sysdate - &days + 1/24
              then 'PARTIAL: AWR holds less than the requested days'
            else 'OK: full requested window available' end                     coverage
  from (select count(*)                          snaps,
               min(s.begin_interval_time)        oldest,
               max(s.end_interval_time)          newest
          from dba_hist_snapshot s
         where s.dbid = &dbid
           and (&inst = 0 or s.instance_number = &inst)
           and s.end_interval_time >= sysdate - &days) x
  cross join v$database d
  left join dba_hist_wr_control w on w.dbid = &dbid;

-- ----------------------------------------------------------------------------
prompt
prompt == A. Summary per backup type (est, from ASH) ==
column backup_type    format a28        heading 'BACKUP TYPE'
column runs           format 99,990     heading 'RUNS'
column avg_el_min     format 999,990.0  heading 'AVG ELAP|(MIN)'
column min_el_min     format 999,990.0  heading 'MIN ELAP|(MIN)'
column max_el_min     format 999,990.0  heading 'MAX ELAP|(MIN)'
column tot_el_h       format 99,990.0   heading 'TOTAL ELAP|(HOURS)'
column avg_db_min     format 999,990.0  heading 'AVG DB TIME|(MIN)'
column tot_rd_gb      format 99,999,990.0 heading 'TOTAL READ|GB (est)'
column tot_wr_gb      format 99,999,990.0 heading 'TOTAL WRITE|GB (est)'
column avg_rd_gb      format 99,990.00  heading 'AVG READ|GB/RUN'
column avg_wr_gb      format 99,990.00  heading 'AVG WRITE|GB/RUN'
column avg_mbs        format 99,990.0   heading 'AVG MB/S|(est)'
column first_run      format a16        heading 'FIRST RUN'
column last_run       format a16        heading 'LAST RUN'

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
flagged as (
  select ash.*,
         case when lag(sample_dt) over (partition by backup_type order by sample_dt) is null
                or (sample_dt - lag(sample_dt) over (partition by backup_type order by sample_dt))
                   * 1440 > &gap_minutes
              then 1 else 0 end                                       new_run
    from ash
),
numbered as (
  select f.*,
         sum(new_run) over (partition by backup_type order by sample_dt
                            range unbounded preceding)                run_no
    from flagged f
),
runs as (
  select backup_type, run_no,
         min(sample_dt)                                               run_start,
         max(sample_dt)                                               run_end,
         round((max(sample_dt) - min(sample_dt)) * 86400) + 10               elapsed_sec,
         count(*) * 10                                                db_time_sec,
         nvl(sum(rd_b), 0)                                            rd_bytes,
         nvl(sum(wr_b), 0)                                            wr_bytes
    from numbered
   group by backup_type, run_no
)
select backup_type,
       count(*)                                                       runs,
       avg(elapsed_sec) / 60                                          avg_el_min,
       min(elapsed_sec) / 60                                          min_el_min,
       max(elapsed_sec) / 60                                          max_el_min,
       sum(elapsed_sec) / 3600                                        tot_el_h,
       avg(db_time_sec) / 60                                          avg_db_min,
       sum(rd_bytes) / power(1024, 3)                                 tot_rd_gb,
       sum(wr_bytes) / power(1024, 3)                                 tot_wr_gb,
       avg(rd_bytes) / power(1024, 3)                                 avg_rd_gb,
       avg(wr_bytes) / power(1024, 3)                                 avg_wr_gb,
       avg((rd_bytes + wr_bytes) / 1048576 / elapsed_sec)             avg_mbs,
       to_char(min(run_start), 'YYYY-MM-DD HH24:MI')                  first_run,
       to_char(max(run_start), 'YYYY-MM-DD HH24:MI')                  last_run
  from runs
 group by backup_type
 order by sum(elapsed_sec) desc, backup_type;

-- ----------------------------------------------------------------------------
prompt
prompt == B. Run detail ordered by start time (est, from ASH) ==
column run_start      format a16        heading 'START'
column run_end        format a16        heading 'END'
column elapsed        format a9         heading 'ELAPSED|HH:MI:SS'
column chans          format 990        heading 'CHAN|NELS'
column sess           format 9,990      heading 'SESS|IONS'
column insts          format a5         heading 'INST'
column db_min         format 99,990.0   heading 'DB TIME|(MIN)'
column cpu_pct        format 990        heading 'CPU|%'
column io_pct         format 990        heading 'IO|WAIT %'
column mml_pct        format 990        heading 'MML|WAIT %'
column oth_pct        format 990        heading 'OTHER|WAIT %'
column rd_gb          format 9,999,990.00 heading 'READ GB|(est)'
column wr_gb          format 9,999,990.00 heading 'WRITE GB|(est)'
column mbs            format 99,990.0   heading 'MB/S|(est)'
column top_event      format a44        heading 'TOP EVENT (% OF SAMPLES)'

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
flagged as (
  select ash.*,
         case when lag(sample_dt) over (partition by backup_type order by sample_dt) is null
                or (sample_dt - lag(sample_dt) over (partition by backup_type order by sample_dt))
                   * 1440 > &gap_minutes
              then 1 else 0 end                                       new_run
    from ash
),
numbered as (
  select f.*,
         sum(new_run) over (partition by backup_type order by sample_dt
                            range unbounded preceding)                run_no
    from flagged f
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
         round((max(sample_dt) - min(sample_dt)) * 86400) + 10               elapsed_sec,
         count(distinct case when channel <> '-' then channel end)    chans,
         count(distinct instance_number || '.' || session_id || '.' || session_serial#) sess,
         listagg(distinct to_char(instance_number), ',')
           within group (order by to_char(instance_number))           insts,
         count(*)                                                     samples,
         count(*) * 10                                                db_time_sec,
         100 * sum(case when cat = 'CPU'   then 1 else 0 end) / count(*) cpu_pct,
         100 * sum(case when cat = 'IO'    then 1 else 0 end) / count(*) io_pct,
         100 * sum(case when cat = 'MML'   then 1 else 0 end) / count(*) mml_pct,
         100 * sum(case when cat = 'OTHER' then 1 else 0 end) / count(*) oth_pct,
         nvl(sum(rd_b), 0)                                            rd_bytes,
         nvl(sum(wr_b), 0)                                            wr_bytes,
         max(ev) keep (dense_rank last order by ev_cnt)               top_ev,
         100 * max(ev_cnt) / count(*)                                 top_ev_pct
    from numbered2
   group by backup_type, run_no
)
select backup_type,
       to_char(run_start, 'YYYY-MM-DD HH24:MI')                       run_start,
       to_char(run_end,   'YYYY-MM-DD HH24:MI')                       run_end,
       lpad(trunc(elapsed_sec / 3600), 2, '0') || ':' ||
         lpad(mod(trunc(elapsed_sec / 60), 60), 2, '0') || ':' ||
         lpad(mod(trunc(elapsed_sec), 60), 2, '0')                    elapsed,
       chans, sess, insts,
       db_time_sec / 60                                               db_min,
       cpu_pct, io_pct, mml_pct, oth_pct,
       rd_bytes / power(1024, 3)                                      rd_gb,
       wr_bytes / power(1024, 3)                                      wr_gb,
       (rd_bytes + wr_bytes) / 1048576 / elapsed_sec                  mbs,
       substr(top_ev, 1, 36) || ' (' || round(top_ev_pct) || '%)'     top_event
  from runs
 order by run_start, backup_type;

-- ----------------------------------------------------------------------------
prompt
prompt == C. Authoritative RMAN IO per day: DBA_HIST_IOSTAT_FUNCTION, function RMAN
prompt      Snapshot deltas of cumulative counters.  Intervals spanning an instance
prompt      restart (startup_time changed) or with a negative delta are discarded.
prompt      Not split by backup type.  ASH columns = estimate from section A/B logic.
prompt      Function RMAN also counts non-backup IO (controlfile autobackups, Data Guard
prompt      role changes / reinstate, flashback, recovery), so treat it as an upper bound.
column day            format a10        heading 'DAY'
column used_snaps     format 9,990      heading 'SNAPS|USED'
column drop_snaps     format 9,990      heading 'SNAPS|DROPPED'
column lg_rd_gb       format 99,990.00  heading 'LARGE|READ GB'
column sm_rd_gb       format 99,990.00  heading 'SMALL|READ GB'
column lg_wr_gb       format 99,990.00  heading 'LARGE|WRITE GB'
column sm_wr_gb       format 99,990.00  heading 'SMALL|WRITE GB'
column rd_reqs        format 999,999,990 heading 'READ REQS'
column wr_reqs        format 999,999,990 heading 'WRITE REQS'
column wait_s         format 9,999,990  heading 'IO WAIT|SECONDS'
column ash_rd_gb      format 99,990.00  heading 'ASH est|READ GB'
column ash_wr_gb      format 99,990.00  heading 'ASH est|WRITE GB'

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
         sum(case when ok = 1 then d_lg_rd end)                       lg_rd_mb,
         sum(case when ok = 1 then d_sm_rd end)                       sm_rd_mb,
         sum(case when ok = 1 then d_lg_wr end)                       lg_wr_mb,
         sum(case when ok = 1 then d_sm_wr end)                       sm_wr_mb,
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
select to_char(d.day, 'YYYY-MM-DD')                                   day,
       i.used_snaps, i.drop_snaps,
       i.lg_rd_mb / 1024                                              lg_rd_gb,
       i.sm_rd_mb / 1024                                              sm_rd_gb,
       i.lg_wr_mb / 1024                                              lg_wr_gb,
       i.sm_wr_mb / 1024                                              sm_wr_gb,
       i.rd_reqs, i.wr_reqs,
       i.wait_ms / 1000                                               wait_s,
       h.rd_b / power(1024, 3)                                        ash_rd_gb,
       h.wr_b / power(1024, 3)                                        ash_wr_gb
  from (select day from io_day union select day from ash_day) d
  left join io_day  i on i.day = d.day
  left join ash_day h on h.day = d.day
 order by d.day;

-- ----------------------------------------------------------------------------
prompt
prompt == D. RMAN related wait events per day: DBA_HIST_SYSTEM_EVENT ==
prompt      Instance-wide (not only RMAN sessions), snapshot deltas, restarts discarded.
column event_name     format a40        heading 'EVENT'
column d_waits        format 999,999,999,990 heading 'WAITS'
column d_time_s       format 9,999,990.0 heading 'TIME WAITED|(SECONDS)'
column avg_ms         format 99,990.00  heading 'AVG|MS/WAIT'

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
select to_char(trunc(begin_interval_time), 'YYYY-MM-DD')              day,
       event_name,
       sum(total_waits - p_waits)                                     d_waits,
       sum(time_waited_micro - p_micro) / 1e6                         d_time_s,
       sum(time_waited_micro - p_micro) / 1000
         / nullif(sum(total_waits - p_waits), 0)                      avg_ms
  from cur
 where p_startup = startup_time
   and total_waits >= p_waits and time_waited_micro >= p_micro
   and begin_interval_time >= sysdate - &days
 group by trunc(begin_interval_time), event_name
having sum(total_waits - p_waits) > 0
 order by trunc(begin_interval_time), event_name;

-- ----------------------------------------------------------------------------
prompt
prompt == F. CROSS-CHECK, NOT AWR: V$RMAN_BACKUP_JOB_DETAILS ==
prompt      Source is the controlfile (limited by control_file_record_keep_time),
prompt      not AWR.  Ground truth to compare with sections A and B.
column input_type     format a16        heading 'INPUT TYPE'
column status         format a24        heading 'STATUS'
column jobs           format 99,990     heading 'JOBS'
column start_time     format a16        heading 'START'
column end_time       format a16        heading 'END'
column elapsed_hms    format a9         heading 'ELAPSED|HH:MI:SS'
column in_gb          format 9,999,990.00 heading 'INPUT GB'
column out_gb         format 9,999,990.00 heading 'OUTPUT GB'
column in_mbs         format 99,990.0   heading 'INPUT|MB/S'
column keep_time      format a8         heading 'KEEP DAYS'
select 'control_file_record_keep_time (days)' name, value keep_time
  from v$parameter where name = 'control_file_record_keep_time';

prompt
prompt F1. Summary per input type and status
select input_type, status,
       count(*)                                                       jobs,
       avg(elapsed_seconds) / 60                                      avg_el_min,
       max(elapsed_seconds) / 60                                      max_el_min,
       sum(elapsed_seconds) / 3600                                    tot_el_h,
       sum(input_bytes)  / power(1024, 3)                             in_gb,
       sum(output_bytes) / power(1024, 3)                             out_gb
  from v$rman_backup_job_details
 where start_time >= sysdate - &days
 group by input_type, status
 order by input_type, status;

prompt
prompt F2. Job detail
select input_type, status,
       to_char(start_time, 'YYYY-MM-DD HH24:MI')                      start_time,
       to_char(end_time,   'YYYY-MM-DD HH24:MI')                      end_time,
       lpad(trunc(elapsed_seconds / 3600), 2, '0') || ':' ||
         lpad(mod(trunc(elapsed_seconds / 60), 60), 2, '0') || ':' ||
         lpad(mod(trunc(elapsed_seconds), 60), 2, '0')                elapsed_hms,
       input_bytes  / power(1024, 3)                                  in_gb,
       output_bytes / power(1024, 3)                                  out_gb,
       input_bytes_per_sec / 1048576                                  in_mbs
  from v$rman_backup_job_details
 where start_time >= sysdate - &days
 order by start_time;

prompt
prompt == end of awr_backup_overview ==
clear columns
set feedback 6 verify on
