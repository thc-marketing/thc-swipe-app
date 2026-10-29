-- Secure admin review workflow for THC Creator Hub.
-- Run this migration in the Supabase SQL Editor before using creator-admin.html.

create table if not exists public.creator_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.creator_admins enable row level security;

drop policy if exists "Admins can read their own admin grant" on public.creator_admins;
create policy "Admins can read their own admin grant"
  on public.creator_admins for select
  using (auth.uid() = user_id);

-- Admins need to preview media while moderating drafts in the private creator-media bucket.
drop policy if exists "Admins read creator media for moderation" on storage.objects;
create policy "Admins read creator media for moderation"
  on storage.objects for select
  using (
    bucket_id = 'creator-media'
    and exists (
      select 1 from public.creator_admins a where a.user_id = auth.uid()
    )
  );

create or replace function public.list_pending_creator_posts()
returns table (
  post_id uuid,
  creator_id uuid,
  display_name text,
  caption text,
  media_url text,
  media_type text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.creator_admins a where a.user_id = auth.uid()
  ) then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;

  return query
  select p.id, p.creator_id, cp.display_name, p.caption, p.media_url, p.media_type, p.created_at
  from public.creator_posts p
  join public.creator_profiles cp on cp.user_id = p.creator_id
  where p.status = 'draft' and p.is_paid = false
  order by p.created_at asc;
end;
$$;

create or replace function public.review_creator_post(p_post_id uuid, p_decision text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.creator_admins a where a.user_id = auth.uid()
  ) then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;

  if p_decision not in ('publish', 'reject') then
    raise exception 'Decision must be publish or reject' using errcode = '22023';
  end if;

  update public.creator_posts
  set status = case when p_decision = 'publish' then 'published' else 'removed' end,
      published_at = case when p_decision = 'publish' then now() else null end,
      updated_at = now()
  where id = p_post_id and status = 'draft' and is_paid = false;

  if not found then
    raise exception 'Draft not found or already reviewed' using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.list_pending_creator_posts() from public, anon;
revoke all on function public.review_creator_post(uuid, text) from public, anon;
grant execute on function public.list_pending_creator_posts() to authenticated;
grant execute on function public.review_creator_post(uuid, text) to authenticated;

-- After creating your admin account in Supabase Auth, grant it access by running:
-- insert into public.creator_admins (user_id)
-- select id from auth.users where email = 'YOUR_ADMIN_EMAIL'
-- on conflict (user_id) do nothing;
