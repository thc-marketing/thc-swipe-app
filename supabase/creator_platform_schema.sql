-- THC Swipe App v2: creator feed foundation
-- Apply in the Supabase SQL editor after reviewing your project policies.
-- This migration does NOT configure a payment provider or accept payments.

create extension if not exists pgcrypto;

-- Roles are controlled by trusted administrators/server-side code only.
create table if not exists public.creator_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 80),
  bio text not null default '' check (char_length(bio) <= 1000),
  avatar_url text,
  is_creator boolean not null default false,
  is_approved boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.creator_posts (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.creator_profiles(user_id) on delete cascade,
  caption text not null default '' check (char_length(caption) <= 3000),
  media_url text not null,
  media_type text not null check (media_type in ('image', 'video')),
  status text not null default 'draft' check (status in ('draft', 'published', 'removed')),
  is_paid boolean not null default false,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint free_initial_feed check (is_paid = false)
);

create index if not exists creator_posts_feed_idx
  on public.creator_posts (published_at desc)
  where status = 'published' and is_paid = false;

-- Entitlements are reserved for a later payment integration. Browser clients cannot write them.
create table if not exists public.payment_entitlements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  post_id uuid references public.creator_posts(id) on delete cascade,
  provider text not null,
  provider_event_id text not null unique,
  status text not null check (status in ('active', 'refunded', 'revoked')),
  created_at timestamptz not null default now()
);

alter table public.creator_profiles enable row level security;
alter table public.creator_posts enable row level security;
alter table public.payment_entitlements enable row level security;

-- Public creator names are visible only for approved creator accounts.
drop policy if exists "Read approved creator profiles" on public.creator_profiles;
create policy "Read approved creator profiles"
  on public.creator_profiles for select
  using (is_creator = true and is_approved = true or auth.uid() = user_id);

-- Profile provisioning, profile edits, and creator approval are managed by a trusted admin/server
-- function. No client INSERT or UPDATE policies are provided for creator_profiles.
drop policy if exists "Users update own non-role profile fields" on public.creator_profiles;

drop policy if exists "Read published free posts" on public.creator_posts;
create policy "Read published free posts"
  on public.creator_posts for select
  using (
    status = 'published' and is_paid = false
    and exists (
      select 1 from public.creator_profiles cp
      where cp.user_id = creator_id and cp.is_creator = true and cp.is_approved = true
    )
  );

drop policy if exists "Creators read own posts" on public.creator_posts;
create policy "Creators read own posts"
  on public.creator_posts for select
  using (auth.uid() = creator_id);

drop policy if exists "Approved creators insert own drafts" on public.creator_posts;
create policy "Approved creators insert own drafts"
  on public.creator_posts for insert
  with check (
    auth.uid() = creator_id
    and status = 'draft'
    and is_paid = false
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
    and exists (
      select 1 from public.creator_profiles cp
      where cp.user_id = auth.uid() and cp.is_creator = true and cp.is_approved = true
    )
  )
  with check (
    auth.uid() = creator_id
    and status = 'draft'
    and is_paid = false
    and exists (
      select 1 from public.creator_profiles cp
      where cp.user_id = auth.uid() and cp.is_creator = true and cp.is_approved = true
    )
  );

-- No client DELETE policy; moderation/removal should be performed by trusted server/admin.
-- No client policies on payment_entitlements; verified webhook/server code only.

