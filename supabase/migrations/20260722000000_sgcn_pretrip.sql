-- 20260722000000_sgcn_pretrip.sql
--
-- Emptied on 15 Oct 2026 (v2 sprint 1). This was a one-off data fix for the original household and
-- held real figures, which do not belong in a public repository (CLAUDE.md hard rule 1). It was
-- applied to production on 22 Jul 2026; Supabase tracks migrations by version, so emptying the file
-- changes nothing there. The original lives in the owner's private Drive folder.
-- Real-household data fixes are never written as migrations again — see supabase/data-fixes/README.md.
select 1;
