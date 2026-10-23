-- Invoked by rman_catalog_report.sh with validated numeric DBID and days.
-- Oracle 19c catalog database. Only RC_DATABASE and RC_RMAN_BACKUP_JOB_DETAILS.
whenever sqlerror exit failure rollback
whenever oserror exit failure rollback
set define on echo off verify off feedback off heading off pagesize 0
set linesize 32767 trimspool on tab off recsep off
set serveroutput off
variable selected_key number
variable window_start varchar2(19)
variable window_end varchar2(19)
declare
  report_end date := sysdate;
begin
  select db_key into :selected_key from rc_database where dbid = &1;
  :window_end := to_char(report_end,'YYYY-MM-DD HH24:MI:SS');
  :window_start := to_char(report_end - &2,'YYYY-MM-DD HH24:MI:SS');
end;
/
spool report.html
prompt <!doctype html><html lang="en"><head><meta charset="utf-8">
prompt <meta name="viewport" content="width=device-width,initial-scale=1"><title>RMAN catalog report</title>
prompt </head><body><main><h1>RMAN catalog report</h1>
prompt <p id="identity"></p><p>One database. Catalog history only. No AWR data.</p>
prompt <noscript>Enable JavaScript to view this offline report.</noscript>
prompt <script id="metadata" type="application/json">
select replace(json_object(
  'dbid' value to_char(dbid), 'name' value name,
  'from' value :window_start,
  'to' value :window_end
  returning varchar2(4000)), '<', '\u003c')
from rc_database where db_key = :selected_key;
prompt </script>
prompt <script id="records" type="application/x-ndjson">
select replace(json_object(
  'key' value to_char(session_key), 'type' value input_type,
  'status' value status, 'device' value output_device_type,
  'start' value to_char(start_time,'YYYY-MM-DD HH24:MI:SS'),
  'end' value to_char(end_time,'YYYY-MM-DD HH24:MI:SS'),
  'seconds' value elapsed_seconds, 'input' value input_bytes,
  'output' value output_bytes returning varchar2(4000)), '<', '\u003c')
from rc_rman_backup_job_details
where db_key = :selected_key
  and start_time >= to_date(:window_start,'YYYY-MM-DD HH24:MI:SS')
  and start_time <= to_date(:window_end,'YYYY-MM-DD HH24:MI:SS')
order by start_time, session_key;
prompt </script>
set define off
prompt <style>
prompt :root {color-scheme:light;--ink:oklch(25% .03 250);--muted:oklch(46% .03 250);--line:oklch(88% .02 250);--blue:oklch(49% .14 250);--red:oklch(46% .16 25);--space:clamp(1rem,.6rem + 2vw,2.5rem)}
prompt * {box-sizing:border-box} body {margin:0;background:oklch(97% .01 250);color:var(--ink);font:16px/1.5 system-ui,sans-serif}
prompt main {max-inline-size:1400px;margin-inline:auto;padding:var(--space)} h1 {font-size:clamp(1.8rem,1.4rem + 2vw,3rem);margin-block:.5rem} h2 {margin-block:2rem .75rem}
prompt p {color:var(--muted)} .cards {display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,12rem),1fr));gap:1rem;margin-block:1.5rem}
prompt .card,section {background:oklch(100% 0 none);border:1px solid var(--line);border-radius:.6rem;padding:1rem}.card strong {display:block;font-size:1.8rem}
prompt .controls {display:flex;flex-wrap:wrap;gap:1rem;align-items:end} label {display:grid;gap:.3rem} input,select,button {font:inherit;padding:.55rem;border:1px solid var(--muted);border-radius:.3rem;max-inline-size:100%}
prompt button {cursor:pointer;background:white;color:var(--ink)} button:active {background:var(--line)} :focus-visible {outline:3px solid var(--blue);outline-offset:3px}
prompt @media(hover:hover) and (pointer:fine) {button:hover {background:var(--line)}}
prompt .scroll {overflow:auto} table {border-collapse:collapse;inline-size:100%;font-size:.9rem} th,td {text-align:start;padding:.65rem;border-block-end:1px solid var(--line);white-space:nowrap;font-variant-numeric:tabular-nums} th {color:var(--muted)}
prompt .bad {color:var(--red);font-weight:600} .chart {display:grid;gap:.45rem} .barrow {display:grid;grid-template-columns:7rem 1fr 7rem;gap:.6rem;align-items:center;font-size:.85rem;font-variant-numeric:tabular-nums} .bar {block-size:.75rem;background:var(--blue);border-radius:2px} .charts {display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,28rem),1fr));gap:1rem} .chartbox {max-block-size:22rem;overflow:auto}
prompt small {color:var(--muted)} @media print {.controls {display:none}.scroll,.chartbox {overflow:visible;max-block-size:none} main {padding:0} body {background:white}}
prompt </style>
prompt <div class="cards" id="summary"></div>
prompt <p id="empty" hidden>No catalog job records started in this window. This does not prove that no backups ran; check catalog synchronization and retained history.</p>
prompt <div class="charts"><section><h2>Daily output</h2><p>GiB written, grouped by start date.</p><div class="chartbox"><div class="chart" id="sizes"></div></div></section><section><h2>Daily longest duration</h2><p>Minutes reported by the catalog, grouped by start date.</p><div class="chartbox"><div class="chart" id="durations"></div></div></section></div>
prompt <h2>Job records</h2>
prompt <div class="controls"><label>Search type, status or session<input id="search" type="search"></label><label>Status<select id="status"><option value="">All statuses</option></select></label><button id="reset" type="button">Reset</button></div>
prompt <p id="count" aria-live="polite"></p><div class="scroll" tabindex="0" role="region" aria-label="Job records"><table><caption>Newest records first. Sizes are GiB; duration is minutes.</caption><thead><tr><th scope="col">Session</th><th scope="col">Type</th><th scope="col">Status</th><th scope="col">Start</th><th scope="col">End</th><th scope="col">Minutes</th><th scope="col">Input GiB</th><th scope="col">Output GiB</th><th scope="col">Device</th></tr></thead><tbody id="jobs"></tbody></table></div>
prompt <p>Window uses the catalog database clock. Job timestamps appear as stored, without time-zone conversion. Records are selected by start time, including jobs still running.</p>
prompt <p>Catalog history may lag the target or be incomplete. Job status does not prove backup availability or recoverability. A failed job can still have produced backup pieces. Input type is the catalog classification, not an incremental level. Multiple records may share a session; summary counts distinguish records from sessions.</p>
prompt <small>Sources: RC_DATABASE and RC_RMAN_BACKUP_JOB_DETAILS. No target database connection, ASH samples or wait-event data.</small>
prompt </main><script>
prompt 'use strict';
prompt const $=id=>document.getElementById(id);
prompt const meta=JSON.parse($('metadata').textContent);
prompt const rows=$('records').textContent.trim().split(/\r?\n/).filter(s=>s.trim()).map(s=>JSON.parse(s));
prompt $('identity').textContent=`${meta.name} · DBID ${meta.dbid} · ${meta.from} to ${meta.to}`;
prompt const num=(v,scale=1)=>v===null?'—':(v/scale).toLocaleString(undefined,{maximumFractionDigits:2});
prompt const cards=[['Sessions',new Set(rows.map(r=>r.key)).size],['Job records',rows.length],['Completed records',rows.filter(r=>r.status==='COMPLETED').length],['Warnings / errors / failed',rows.filter(r=>/WARNING|ERROR|FAILED/.test(r.status||'')).length]];
prompt for(const [label,value] of cards){const card=document.createElement('div');card.className='card';const strong=document.createElement('strong');strong.textContent=value;card.append(strong,document.createTextNode(label));$('summary').append(card)}
prompt $('empty').hidden=rows.length!==0;
prompt for(const status of [...new Set(rows.map(r=>r.status).filter(Boolean))].sort()){const o=document.createElement('option');o.value=status;o.textContent=status;$('status').append(o)}
prompt function render(){const q=$('search').value.toLowerCase(),status=$('status').value;const filtered=rows.filter(r=>(!status||r.status===status)&&[r.key,r.type,r.status].join(' ').toLowerCase().includes(q));$('jobs').replaceChildren();for(const r of [...filtered].reverse()){const tr=document.createElement('tr');for(const [i,v] of [r.key,r.type,r.status,r.start,r.end,num(r.seconds,60),num(r.input,1073741824),num(r.output,1073741824),r.device].entries()){const td=document.createElement('td');td.textContent=v??'—';if(i===2&&/WARNING|ERROR|FAILED/.test(v||''))td.className='bad';tr.append(td)}$('jobs').append(tr)}$('count').textContent=`${filtered.length} of ${rows.length} records. Charts and summary show the full window.`}
prompt $('search').addEventListener('input',render);$('status').addEventListener('change',render);$('reset').addEventListener('click',()=>{$('search').value='';$('status').value='';render()});
prompt const daily=new Map();for(const r of rows){const day=r.start.slice(0,10),d=daily.get(day)||{output:null,seconds:null};if(r.output!==null)d.output=(d.output??0)+r.output;if(r.seconds!==null)d.seconds=Math.max(d.seconds??0,r.seconds);daily.set(day,d)}
prompt function chart(id,field,scale){const entries=[...daily.entries()];const max=Math.max(1,...entries.map(([,v])=>v[field]??0));for(const [day,v] of entries){const line=document.createElement('div');line.className='barrow';const label=document.createElement('span');label.textContent=day;const track=document.createElement('div'),bar=document.createElement('div');bar.className='bar';bar.style.inlineSize=`${Math.max(0,(v[field]??0)/max*100)}%`;track.append(bar);const value=document.createElement('span');value.textContent=num(v[field],scale);line.append(label,track,value);$(id).append(line)}}
prompt chart('sizes','output',1073741824);chart('durations','seconds',60);render();
prompt </script></body></html>
prompt <!-- report-complete -->
spool off
exit success
