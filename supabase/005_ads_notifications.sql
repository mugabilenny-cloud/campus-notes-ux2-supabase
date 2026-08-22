-- =====================================================================
-- Ads + Notifications — Schema & Matching Functions
-- =====================================================================

create table advertisers (
  id            uuid primary key default uuid_generate_v4(),
  name          text not null,
  contact_email text,
  contact_phone text,
  notes         text,
  status        text not null default 'active' check (status in ('active', 'paused', 'archived')),
  created_at    timestamptz not null default now()
);

create table ads (
  id                    uuid primary key default uuid_generate_v4(),
  advertiser_id         uuid not null references advertisers(id) on delete cascade,
  title                 text not null,
  headline              text not null,
  body                  text,
  image_url             text,
  cta_label             text,
  cta_url               text,
  target_node_id        uuid not null references nodes(id),
  include_descendants   boolean not null default true,
  starts_at             timestamptz not null default now(),
  ends_at               timestamptz,
  max_impressions       int,
  impression_count      int not null default 0,
  click_count           int not null default 0,
  status                text not null default 'draft' check (status in ('draft', 'active', 'paused', 'ended')),
  priority              int not null default 0,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create index idx_ads_target_node on ads(target_node_id);
create index idx_ads_status_dates on ads(status, starts_at, ends_at);

create table student_devices (
  id              uuid primary key default uuid_generate_v4(),
  device_token    text not null unique,
  home_node_id    uuid references nodes(id),
  push_token      text,
  last_seen_at    timestamptz not null default now(),
  created_at      timestamptz not null default now()
);

create index idx_student_devices_home_node on student_devices(home_node_id);

create table ad_impressions (
  id          uuid primary key default uuid_generate_v4(),
  ad_id       uuid not null references ads(id) on delete cascade,
  device_id   uuid not null references student_devices(id) on delete cascade,
  shown_at    timestamptz not null default now(),
  clicked     boolean not null default false,
  clicked_at  timestamptz
);

create index idx_ad_impressions_ad_id on ad_impressions(ad_id);
create index idx_ad_impressions_device_id on ad_impressions(device_id, shown_at desc);

create table notifications (
  id                    uuid primary key default uuid_generate_v4(),
  title                 text not null,
  body                  text,
  target_node_id        uuid references nodes(id),
  include_descendants   boolean not null default true,
  created_by            uuid references auth.users(id),
  expires_at            timestamptz,
  created_at            timestamptz not null default now()
);

create index idx_notifications_target_node on notifications(target_node_id);
create index idx_notifications_created_at on notifications(created_at desc);

create table notification_receipts (
  id                uuid primary key default uuid_generate_v4(),
  notification_id   uuid not null references notifications(id) on delete cascade,
  device_id         uuid not null references student_devices(id) on delete cascade,
  seen_at           timestamptz not null default now(),
  dismissed_at      timestamptz,
  unique (notification_id, device_id)
);

-- Functions
create or replace function fn_get_ads_for_device(p_device_token text, p_limit int default 3)
returns table (
  ad_id uuid, title text, headline text, body text, image_url text,
  cta_label text, cta_url text
) as $$
declare
  v_device_home_path text;
begin
  select n.path into v_device_home_path
  from student_devices d
  join nodes n on n.id = d.home_node_id
  where d.device_token = p_device_token;

  if v_device_home_path is null then
    return;
  end if;

  update student_devices set last_seen_at = now() where device_token = p_device_token;

  return query
  select a.id, a.title, a.headline, a.body, a.image_url, a.cta_label, a.cta_url
  from ads a
  join nodes target_n on target_n.id = a.target_node_id
  where a.status = 'active'
    and a.starts_at <= now()
    and (a.ends_at is null or a.ends_at > now())
    and (a.max_impressions is null or a.impression_count < a.max_impressions)
    and (
      (a.include_descendants = true and
        (v_device_home_path = target_n.path or v_device_home_path like target_n.path || '/%'))
      or
      (a.include_descendants = false and v_device_home_path = target_n.path)
    )
  order by a.priority desc, a.created_at desc
  limit p_limit;
end;
$$ language plpgsql stable;

create or replace function fn_record_ad_impression(p_ad_id uuid, p_device_token text)
returns void as $$
declare
  v_device_id uuid;
begin
  select id into v_device_id from student_devices where device_token = p_device_token;
  if v_device_id is null then
    raise exception 'Unknown device_token: %', p_device_token;
  end if;

  insert into ad_impressions (ad_id, device_id) values (p_ad_id, v_device_id);
  update ads set impression_count = impression_count + 1 where id = p_ad_id;
end;
$$ language plpgsql;

create or replace function fn_record_ad_click(p_ad_id uuid, p_device_token text)
returns void as $$
declare
  v_device_id uuid;
begin
  select id into v_device_id from student_devices where device_token = p_device_token;
  if v_device_id is null then
    raise exception 'Unknown device_token: %', p_device_token;
  end if;

  update ad_impressions
  set clicked = true, clicked_at = now()
  where ad_id = p_ad_id and device_id = v_device_id
    and id = (select id from ad_impressions where ad_id = p_ad_id and device_id = v_device_id order by shown_at desc limit 1);

  update ads set click_count = click_count + 1 where id = p_ad_id;
end;
$$ language plpgsql;

create or replace function fn_get_notifications_for_device(p_device_token text, p_limit int default 5)
returns table (
  notification_id uuid, title text, body text, created_at timestamptz
) as $$
declare
  v_device_id uuid;
  v_device_home_path text;
begin
  select d.id, n.path into v_device_id, v_device_home_path
  from student_devices d
  left join nodes n on n.id = d.home_node_id
  where d.device_token = p_device_token;

  if v_device_id is null then
    return;
  end if;

  return query
  select nt.id, nt.title, nt.body, nt.created_at
  from notifications nt
  left join nodes target_n on target_n.id = nt.target_node_id
  where (nt.expires_at is null or nt.expires_at > now())
    and not exists (
      select 1 from notification_receipts r
      where r.notification_id = nt.id and r.device_id = v_device_id
    )
    and (
      nt.target_node_id is null
      or (v_device_home_path is not null and (
        (nt.include_descendants = true and
          (v_device_home_path = target_n.path or v_device_home_path like target_n.path || '/%'))
        or
        (nt.include_descendants = false and v_device_home_path = target_n.path)
      ))
    )
  order by nt.created_at desc
  limit p_limit;
end;
$$ language plpgsql stable;

create or replace function fn_mark_notification_seen(p_notification_id uuid, p_device_token text, p_dismissed boolean default false)
returns void as $$
declare
  v_device_id uuid;
begin
  select id into v_device_id from student_devices where device_token = p_device_token;
  if v_device_id is null then
    raise exception 'Unknown device_token: %', p_device_token;
  end if;

  insert into notification_receipts (notification_id, device_id, dismissed_at)
  values (p_notification_id, v_device_id, case when p_dismissed then now() else null end)
  on conflict (notification_id, device_id)
  do update set dismissed_at = case when p_dismissed then now() else notification_receipts.dismissed_at end;
end;
$$ language plpgsql;

create or replace function fn_register_device(p_device_token text, p_home_node_id uuid default null)
returns uuid as $$
declare
  v_id uuid;
begin
  insert into student_devices (device_token, home_node_id)
  values (p_device_token, p_home_node_id)
  on conflict (device_token)
  do update set
    home_node_id = coalesce(p_home_node_id, student_devices.home_node_id),
    last_seen_at = now()
  returning id into v_id;

  return v_id;
end;
$$ language plpgsql;

-- RLS & Security Policies
alter table advertisers enable row level security;
alter table ads enable row level security;
alter table student_devices enable row level security;
alter table ad_impressions enable row level security;
alter table notifications enable row level security;
alter table notification_receipts enable row level security;

create policy "advertisers_admin_all" on advertisers for all using (fn_is_admin());
create policy "ads_admin_all" on ads for all using (fn_is_admin());
create policy "notifications_admin_all" on notifications for all using (fn_is_admin());
create policy "student_devices_admin_all" on student_devices for all using (fn_is_admin());

alter function fn_register_device(text, uuid) security definer;
alter function fn_get_ads_for_device(text, int) security definer;
alter function fn_record_ad_impression(uuid, text) security definer;
alter function fn_record_ad_click(uuid, text) security definer;
alter function fn_get_notifications_for_device(text, int) security definer;
alter function fn_mark_notification_seen(uuid, text, boolean) security definer;

create policy "ad_impressions_admin_read" on ad_impressions for select using (fn_is_admin());
create policy "notification_receipts_admin_read" on notification_receipts for select using (fn_is_admin());

grant execute on function fn_register_device(text, uuid) to anon;
grant execute on function fn_get_ads_for_device(text, int) to anon;
grant execute on function fn_record_ad_impression(uuid, text) to anon;
grant execute on function fn_record_ad_click(uuid, text) to anon;
grant execute on function fn_get_notifications_for_device(text, int) to anon;
grant execute on function fn_mark_notification_seen(uuid, text, boolean) to anon;
