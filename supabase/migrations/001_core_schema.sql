-- =====================================================================
-- KIU Notes Repository — Core Schema
-- Migration 001: Tree, Files, Links, Scan Jobs
-- =====================================================================

create extension if not exists "uuid-ossp";
create extension if not exists pg_trgm;

create type node_type as enum (
  'university', 'faculty', 'department', 'course', 'year',
  'semester', 'course_unit', 'lecture_notes', 'custom'
);

create type resource_kind as enum (
  'lecture_pdf', 'lecture_doc', 'lecture_ppt', 'past_paper',
  'marking_scheme', 'student_summary', 'flashcards', 'youtube_link', 'other'
);

create type scan_status as enum ('pending', 'running', 'completed', 'completed_with_errors', 'failed');
create type scan_item_action as enum ('created_node', 'matched_existing_node', 'file_ingested', 'link_ingested', 'skipped_unrecognized', 'error');

create table nodes (
  id            uuid primary key default uuid_generate_v4(),
  parent_id     uuid references nodes(id) on delete cascade,
  node_type     node_type not null,
  custom_type_label text,
  name          text not null,
  slug          text not null,
  sort_order    int not null default 0,
  path          text not null,
  depth         int not null default 0,
  metadata      jsonb not null default '{}',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint unique_slug_per_parent unique (parent_id, slug)
);

create unique index unique_root_slug on nodes (slug) where parent_id is null;
create index idx_nodes_parent_id on nodes(parent_id);
create index idx_nodes_path on nodes using gin (path gin_trgm_ops);
create index idx_nodes_path_btree on nodes(path);
create index idx_nodes_node_type on nodes(node_type);
create index idx_nodes_metadata on nodes using gin (metadata);
comment on table nodes is 'Self-referencing tree. Any node may have children at any depth.';
comment on column nodes.path is 'Materialized slug path, trigger-maintained. Do not write directly.';

create table files (
  id                uuid primary key default uuid_generate_v4(),
  node_id           uuid not null references nodes(id) on delete cascade,
  original_filename text not null,
  storage_path      text not null unique,
  storage_bucket    text not null default 'notes-repo-files',
  mime_type         text not null,
  file_extension    text not null,
  size_bytes        bigint not null,
  resource_kind     resource_kind not null default 'other',
  academic_year     text,
  version           int not null default 1,
  is_current_version boolean not null default true,
  superseded_by     uuid references files(id),
  uploaded_by       uuid references auth.users(id),
  scan_job_id       uuid,
  status            text not null default 'active' check (status in ('active', 'flagged', 'archived')),
  flag_reason       text,
  extracted_text    tsvector,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index idx_files_node_id on files(node_id);
create index idx_files_status on files(status);
create index idx_files_extracted_text on files using gin (extracted_text);
create index idx_files_current_version on files(node_id, is_current_version) where is_current_version = true;
comment on table files is 'Uploaded PDF/DOC/XLS files, attached to a leaf node. Versioned by filename+node.';

create table links (
  id            uuid primary key default uuid_generate_v4(),
  node_id       uuid not null references nodes(id) on delete cascade,
  url           text not null,
  title         text,
  link_type     text not null default 'youtube' check (link_type in ('youtube', 'external', 'other')),
  description   text,
  added_by      uuid references auth.users(id),
  scan_job_id   uuid,
  status        text not null default 'active' check (status in ('active', 'flagged', 'archived')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index idx_links_node_id on links(node_id);
create index idx_links_status on links(status);
comment on table links is 'External links (YouTube etc.) attached to a leaf node.';

create table scan_jobs (
  id                uuid primary key default uuid_generate_v4(),
  triggered_by      uuid references auth.users(id) not null,
  source_type       text not null default 'upload' check (source_type in ('upload', 'storage_folder', 'external_drive')),
  source_reference  text,
  status            scan_status not null default 'pending',
  total_items       int not null default 0,
  items_ingested    int not null default 0,
  items_skipped     int not null default 0,
  items_errored     int not null default 0,
  started_at        timestamptz,
  completed_at      timestamptz,
  created_at        timestamptz not null default now(),
  error_summary     text
);

alter table files add constraint fk_files_scan_job foreign key (scan_job_id) references scan_jobs(id);
alter table links add constraint fk_links_scan_job foreign key (scan_job_id) references scan_jobs(id);
comment on table scan_jobs is 'One row per admin-triggered folder scan.';

create table scan_job_items (
  id                uuid primary key default uuid_generate_v4(),
  scan_job_id       uuid not null references scan_jobs(id) on delete cascade,
  raw_path          text not null,
  resolved_node_id  uuid references nodes(id),
  resolved_file_id  uuid references files(id),
  resolved_link_id  uuid references links(id),
  action            scan_item_action not null,
  detail            text,
  created_at        timestamptz not null default now()
);

create index idx_scan_job_items_job_id on scan_job_items(scan_job_id);
comment on table scan_job_items is 'Per-item audit trail for a scan job.';
