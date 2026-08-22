-- =====================================================================
-- Migration 002: Triggers
-- =====================================================================

create or replace function fn_set_node_path()
returns trigger as $$
declare
  parent_path text;
  parent_depth int;
begin
  if new.parent_id is null then
    new.path := new.slug;
    new.depth := 0;
  else
    select path, depth into parent_path, parent_depth
    from nodes where id = new.parent_id;

    if parent_path is null then
      raise exception 'Parent node % not found', new.parent_id;
    end if;

    new.path := parent_path || '/' || new.slug;
    new.depth := parent_depth + 1;
  end if;

  new.updated_at := now();
  return new;
end;
$$ language plpgsql;

create trigger trg_set_node_path
  before insert or update of parent_id, slug on nodes
  for each row execute function fn_set_node_path();

create or replace function fn_cascade_path_to_descendants()
returns trigger as $$
begin
  if old.path is distinct from new.path then
    with recursive descendants as (
      select id, parent_id, slug, new.path || '/' || slug as new_path, new.depth + 1 as new_depth
      from nodes where parent_id = new.id
      union all
      select n.id, n.parent_id, n.slug, d.new_path || '/' || n.slug, d.new_depth + 1
      from nodes n
      join descendants d on n.parent_id = d.id
    )
    update nodes set path = descendants.new_path, depth = descendants.new_depth, updated_at = now()
    from descendants
    where nodes.id = descendants.id;
  end if;
  return new;
end;
$$ language plpgsql;

create trigger trg_cascade_path
  after update of path on nodes
  for each row execute function fn_cascade_path_to_descendants();

create or replace function fn_version_file_on_insert()
returns trigger as $$
declare
  prior_file_id uuid;
  prior_version int;
begin
  select id, version into prior_file_id, prior_version
  from files
  where node_id = new.node_id
    and original_filename = new.original_filename
    and is_current_version = true
    and id <> new.id
  limit 1;

  if prior_file_id is not null then
    update files
    set is_current_version = false, superseded_by = new.id, updated_at = now()
    where id = prior_file_id;

    new.version := prior_version + 1;
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_version_file
  before insert on files
  for each row execute function fn_version_file_on_insert();

create or replace function fn_touch_updated_at()
returns trigger as $$
begin
  new.updated_at := now();
  return new;
end;
$$ language plpgsql;

create trigger trg_touch_files before update on files for each row execute function fn_touch_updated_at();
create trigger trg_touch_links before update on links for each row execute function fn_touch_updated_at();
