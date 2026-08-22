-- =====================================================================
-- Migration 003: Core Functions
-- =====================================================================

create or replace function fn_slugify(input text)
returns text as $$
  select trim(both '-' from
    regexp_replace(
      regexp_replace(lower(trim(input)), '[^a-z0-9]+', '-', 'g'),
      '-+', '-', 'g'
    )
  );
$$ language sql immutable;

create or replace function fn_find_or_create_node_path(
  segments jsonb,
  scan_job_id uuid default null
)
returns table (leaf_node_id uuid, created_new_nodes int, item_log jsonb) as $$
declare
  seg              jsonb;
  seg_name         text;
  seg_type         text;
  seg_slug         text;
  current_parent   uuid := null;
  found_node_id    uuid;
  created_count    int := 0;
  log              jsonb := '[]'::jsonb;
begin
  for seg in select * from jsonb_array_elements(segments)
  loop
    seg_name := seg->>'name';
    seg_type := coalesce(seg->>'node_type', 'custom');
    seg_slug := fn_slugify(seg_name);

    select id into found_node_id
    from nodes
    where slug = seg_slug
      and ((current_parent is null and parent_id is null) or parent_id = current_parent)
    limit 1;

    if found_node_id is null then
      begin
        insert into nodes (parent_id, node_type, name, slug)
        values (current_parent, seg_type::node_type, seg_name, seg_slug)
        returning id into found_node_id;
      exception when invalid_text_representation then
        insert into nodes (parent_id, node_type, custom_type_label, name, slug)
        values (current_parent, 'custom', seg_type, seg_name, seg_slug)
        returning id into found_node_id;
      end;

      created_count := created_count + 1;
      log := log || jsonb_build_object('name', seg_name, 'action', 'created_node', 'node_id', found_node_id);

      if scan_job_id is not null then
        insert into scan_job_items (scan_job_id, raw_path, resolved_node_id, action, detail)
        values (scan_job_id, seg_name, found_node_id, 'created_node', 'Created new ' || seg_type || ' node: ' || seg_name);
      end if;
    else
      log := log || jsonb_build_object('name', seg_name, 'action', 'matched_existing', 'node_id', found_node_id);

      if scan_job_id is not null then
        insert into scan_job_items (scan_job_id, raw_path, resolved_node_id, action, detail)
        values (scan_job_id, seg_name, found_node_id, 'matched_existing_node', 'Matched existing node, left unedited: ' || seg_name);
      end if;
    end if;

    current_parent := found_node_id;
  end loop;

  return query select found_node_id, created_count, log;
end;
$$ language plpgsql;

comment on function fn_find_or_create_node_path is
'Walks a folder path segment by segment, reusing existing nodes and creating only what is missing. Idempotent.';

create or replace function fn_infer_resource_kind(filename text)
returns resource_kind as $$
  select case
    when lower(filename) like '%past%exam%' or lower(filename) like '%past%paper%' then 'past_paper'::resource_kind
    when lower(filename) like '%marking%scheme%' or lower(filename) like '%mark%scheme%' then 'marking_scheme'::resource_kind
    when lower(filename) like '%summary%' or lower(filename) like '%summaries%' then 'student_summary'::resource_kind
    when lower(filename) like '%flashcard%' then 'flashcards'::resource_kind
    when lower(filename) ~* '\.(ppt|pptx)$' then 'lecture_ppt'::resource_kind
    when lower(filename) ~* '\.(doc|docx)$' then 'lecture_doc'::resource_kind
    when lower(filename) ~* '\.pdf$' then 'lecture_pdf'::resource_kind
    else 'other'::resource_kind
  end;
$$ language sql immutable;

create or replace function fn_search_tree(search_query text, result_limit int default 25)
returns table (
  result_type text, id uuid, title text, node_path text, rank real
) as $$
  select 'node' as result_type, n.id, n.name as title, n.path as node_path,
         similarity(n.name, search_query) as rank
  from nodes n
  where n.name % search_query
  union all
  select 'file' as result_type, f.id, f.original_filename as title, n.path as node_path,
         ts_rank(f.extracted_text, plainto_tsquery('english', search_query)) as rank
  from files f
  join nodes n on n.id = f.node_id
  where f.extracted_text @@ plainto_tsquery('english', search_query)
    and f.is_current_version = true
    and f.status = 'active'
  order by rank desc
  limit result_limit;
$$ language sql stable;
