-- ============================================================================
-- awr_backup_catalog_connect.sql
--
-- Helper for awr_backup_overview.sql and awr_backup_report_html.sql.  Not meant
-- to be run on its own.  Run through "@@&cat_script" when the optional catalog
-- argument (6th) was given: connects to the RMAN recovery catalog.
--
-- Why a file: SQL*Plus does not substitute a variable in the first word of a
-- line, so a line holding only &connect_command cannot be made conditional.
-- The caller picks this file or awr_backup_catalog_skip.sql by name instead.
--
-- Variables from the caller: 6 = the connect string (holds the password, so it
-- is never printed: verify and echo are off, and it is undefined right after the
-- CONNECT), cat_label = user@tns or "wallet (tns)", which is safe to print,
-- cat_termout = ON or OFF for the CONNECT itself.  A failed login stops the
-- script (WHENEVER SQLERROR EXIT FAILURE, status 1) and with ON the ORA- error
-- is shown on the terminal.  The caller whose stdout is the report (text) uses
-- OFF so that "Connected." and glogin.sql output stay out of it; the caller
-- that writes a file (html) uses ON.  The caller's SPOOL must be off.
-- ============================================================================
set termout on
prompt Connecting to the RMAN recovery catalog &cat_label (the script stops here, exit status 1, if the login fails) ...
set termout &cat_termout verify off echo off
whenever sqlerror exit failure
connect &6
whenever sqlerror continue
undefine 6
