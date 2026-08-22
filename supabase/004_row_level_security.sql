-- =====================================================================
-- Migration 004: Row Level Security
-- =====================================================================

alter table nodes enable row level security;
alter table files enable row level security;
alter table links enable row level security;
alter table scan_jobs enable row level security;
alter table scan_job_items enable row level security;

create or replace function fn_is_admin()
returns boolean as $$
  select coalesce(
    (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin',
    false
  );
$$ language sql stable;

create policy "nodes_public_read" on nodes for select using (true);
create policy "nodes_admin_insert" on nodes for insert with check (fn_is_admin());
create policy "nodes_admin_update" on nodes for update using (fn_is_admin());
create policy "nodes_admin_delete" on nodes for delete using (fn_is_admin());

create policy "files_public_read_active" on files for select
  using (status = 'active' or fn_is_admin());
create policy "files_admin_insert" on files for insert with check (fn_is_admin());
create policy "files_admin_update" on files for update using (fn_is_admin());
create policy "files_admin_delete" on files for delete using (fn_is_admin());

create policy "links_public_read_active" on links for select
  using (status = 'active' or fn_is_admin());
create policy "links_admin_insert" on links for insert with check (fn_is_admin());
create policy "links_admin_update" on links for update using (fn_is_admin());
create policy "links_admin_delete" on links for delete using (fn_is_admin());

create policy "scan_jobs_admin_all" on scan_jobs for all using (fn_is_admin());
create policy "scan_job_items_admin_all" on scan_job_items for all using (fn_is_admin());

create policy "storage_public_read" on storage.objects for select
  using (bucket_id = 'notes-repo-files');
create policy "storage_admin_write" on storage.objects for insert
  with check (bucket_id = 'notes-repo-files' and fn_is_admin());
create policy "storage_admin_delete" on storage.objects for delete
  using (bucket_id = 'notes-repo-files' and fn_is_admin());
