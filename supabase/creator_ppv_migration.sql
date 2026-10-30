-- THC Creator Platform: pay-per-premium-post foundation
-- Apply AFTER creator_platform_schema.sql and creator_admin_workflow.sql.
-- This migration prepares PPV data access and moderation. It does NOT process payments.
-- Payment entitlements must only be inserted/updated by a trusted verified-payment webhook.

begin;

-- Replace the original free-only constraint with explicit JPY pricing rules.
alter table public.creator_posts
  drop constraint if exists free_initial_feed;

alter table public.creator_posts
  add column if not exists price_yen integer not null default 0;

alter table public.creator_posts
  drop constraint if exists creator_posts_price_yen_check;

alter table public.creator_posts
  add constraint creator_posts_price_yen_check
  check (
    (is_paid = false and price_yen = 0)
    or
    (is_paid = true and price_yen between 100 and 1000000)
  );

create index if not exists creator_posts_premium_feed_idx
  on public.creator_posts (published_at desc)
  where status = 'published' and is_paid = true;

create index if not exists payment_entitlements_user_post_status_idx
  on public.payment_entitlements (user_id, post_id, status);

create unique index if not exists payment_entitlements_one_active_unlock_idx
  on public.payment_entitlements (user_id, post_id)
  where status = 'active';

-- Public feed preview: deliberately excludes media_url/storage path.
create or replace function public.list_creator_post_previews(
  p_limit integer default 20,
  p_offset integer default 0
)
returns table (
  post_id uuid,
  creator_id uuid,
  display_name text,
  caption text,
  media_type text,
  is_paid boolean,
  price_yen integer,
  published_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.creator_id, cp.display_name, p.caption, p.media_type,
         p.is_paid, p.price_yen, p.published_at
  from public.creator_posts p
  join public.creator_profiles cp on cp.user_id = p.creator_id
  where p.status = 'published'
    and cp.is_creator = true
    and cp.is_approved = true
  order by p.published_at desc nulls last
  limit least(greatest(coalesce(p_limit, 20), 1), 50)
  offset greatest(coalesce(p_offset, 0), 0);
$$;

revoke all on function public.list_creator_post_previews(integer, integer) from public;
grant execute on function public.list_creator_post_previews(integer, integer) to anon, authenticated;

-- A customer may inspect only their own entitlement rows. No client write policy is created.
drop policy if exists "Customers read own payment entitlements" on public.payment_entitlements;
create policy "Customers read own payment entitlements"
  on public.payment_entitlements for select
  using (auth.uid() = user_id);

-- Customers can read free published posts and premium posts only after a verified active unlock.
drop policy if exists "Read published free posts" on public.creator_posts;
create policy "Read published free or purchased posts"
  on public.creator_posts for select
  using (
    status = 'published'
    and exists (
      select 1 from public.creator_profiles cp
      where cp.user_id = creator_id and cp.is_creator = true and cp.is_approved = true
    )
    and (
      is_paid = false
      or exists (
        select 1 from public.payment_entitlements pe
        where pe.post_id = id
          and pe.user_id = auth.uid()
          and pe.status = 'active'
      )
    )
  );

-- Creators may create/update their own drafts and set their own per-post price.
-- Published posts remain immutable through the browser; admin review publishes drafts.
drop policy if exists "Approved creators insert own drafts" on public.creator_posts;
create policy "Approved creators insert own drafts"
  on public.creator_posts for insert
  with check (
    auth.uid() = creator_id
    and status = 'draft'
    and (
      (is_paid = false and price_yen = 0)
      or (is_paid = true and price_yen between 100 and 1000000)
    )
    and exists (
      select 1 from public.creator_profiles cp
      where cp.user_id = auth.uid() and cp.is_creator = true and cp.is_approved = true
    )
  );

drop policy if exists "Creators update own posts" on public.creator_posts;
create policy "Creators update own posts"
  on public.creator_posts for update
  using (
    auth.uid() = creator_id
    and status = 'draft'
    and exists (
      select 1 from public.creator_profiles cp
      where cp.user_id = auth.uid() and cp.is_creator = true and cp.is_approved = true
    )
  )
  with check (
    auth.uid() = creator_id
    and status = 'draft'
    and (
      (is_paid = false and price_yen = 0)
      or (is_paid = true and price_yen between 100 and 1000000)
    )
    and exists (
      select 1 from public.creator_profiles cp
      where cp.user_id = auth.uid() and cp.is_creator = true and cp.is_approved = true
    )
  );

-- Signed URLs for private premium media are permitted only to the owner, an admin,
-- or a customer with an active entitlement. Existing free-media policy remains intact.
drop policy if exists "Buyers read purchased premium creator media" on storage.objects;
create policy "Buyers read purchased premium creator media"
  on storage.objects for select
  using (
    bucket_id = 'creator-media'
    and exists (
      select 1
      from public.creator_posts p
      where p.media_url = storage.objects.name
        and p.status = 'published'
        and p.is_paid = true
        and exists (
          select 1 from public.payment_entitlements pe
          where pe.post_id = p.id
            and pe.user_id = auth.uid()
            and pe.status = 'active'
        )
    )
  );

-- Extend the secure admin review queue to include paid drafts and their JPY price.
drop function if exists public.list_pending_creator_posts();
create function public.list_pending_creator_posts()
returns table (
  post_id uuid,
  creator_id uuid,
  display_name text,
  caption text,
  media_url text,
  media_type text,
  is_paid boolean,
  price_yen integer,
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
  select p.id, p.creator_id, cp.display_name, p.caption, p.media_url,
         p.media_type, p.is_paid, p.price_yen, p.created_at
  from public.creator_posts p
  join public.creator_profiles cp on cp.user_id = p.creator_id
  where p.status = 'draft'
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
  where id = p_post_id
    and status = 'draft'
    and (
      (is_paid = false and price_yen = 0)
      or (is_paid = true and price_yen between 100 and 1000000)
    );

  if not found then
    raise exception 'Draft not found, invalid price, or already reviewed' using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.list_pending_creator_posts() from public, anon;
revoke all on function public.review_creator_post(uuid, text) from public, anon;
grant execute on function public.list_pending_creator_posts() to authenticated;
grant execute on function public.review_creator_post(uuid, text) to authenticated;

commit;

-- IMPORTANT:
-- 1. Keep creator-media private.
-- 2. Do not issue entitlements from browser code.
-- 3. Real checkout + signed webhook verification + entitlement writes are a separate server-side step.
-- 4. This migration alone does not make premium purchases available to customers.
