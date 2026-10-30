-- THC: secure purchase-intent records (no payment processing)
-- Apply after creator_ppv_migration.sql in Supabase SQL Editor.

begin;

create table if not exists public.creator_purchase_intents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  post_id uuid not null references public.creator_posts(id) on delete cascade,
  price_yen integer not null check (price_yen between 100 and 1000000),
  status text not null default 'pending' check (status in ('pending', 'paid', 'cancelled', 'expired')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists creator_purchase_intents_user_created_idx
  on public.creator_purchase_intents (user_id, created_at desc);

create unique index if not exists creator_purchase_intents_one_pending_per_post_idx
  on public.creator_purchase_intents (user_id, post_id)
  where status = 'pending';

alter table public.creator_purchase_intents enable row level security;

drop policy if exists "Customers read own purchase intents" on public.creator_purchase_intents;
create policy "Customers read own purchase intents"
  on public.creator_purchase_intents
  for select to authenticated
  using (auth.uid() = user_id);

revoke all on public.creator_purchase_intents from public, anon, authenticated;
grant select on public.creator_purchase_intents to authenticated;

create or replace function public.create_creator_purchase_intent(p_post_id uuid)
returns table (intent_id uuid, price_yen integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_price integer;
  v_intent_id uuid;
begin
  if v_user_id is null then
    raise exception 'Sign in required' using errcode = '28000';
  end if;

  select p.price_yen into v_price
  from public.creator_posts p
  join public.creator_profiles cp on cp.user_id = p.creator_id
  where p.id = p_post_id
    and p.status = 'published'
    and p.is_paid = true
    and cp.is_creator = true
    and cp.is_approved = true;

  if v_price is null then
    raise exception 'Premium post not found or unavailable' using errcode = 'P0002';
  end if;

  insert into public.creator_purchase_intents (user_id, post_id, price_yen, status)
  values (v_user_id, p_post_id, v_price, 'pending')
  on conflict (user_id, post_id) where status = 'pending'
  do update set updated_at = now()
  returning id into v_intent_id;

  return query select v_intent_id, v_price;
end;
$$;

revoke all on function public.create_creator_purchase_intent(uuid) from public, anon;
grant execute on function public.create_creator_purchase_intent(uuid) to authenticated;

commit;

-- This records purchase intent only. It does not charge, mark paid, or grant media access.
-- Only a future verified payment webhook may transition status to paid and create entitlements.
