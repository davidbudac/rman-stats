-- ============================================================================
-- awr_backup_catalog_skip.sql
--
-- Helper for awr_backup_overview.sql and awr_backup_report_html.sql.  Not meant
-- to be run on its own.  Run through "@@&cat_script" when the catalog argument
-- is empty: does nothing, so section F / the JOBS data read the controlfile of
-- the target database.  See awr_backup_catalog_connect.sql for why this file
-- exists.
-- ============================================================================
rem no recovery catalog requested
