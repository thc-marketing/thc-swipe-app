-- THC customer engagement: likes and comments on free published posts only.
begin;

create table if not exists public.creator_post_likes (
  post_id uuid not null references public.creator_posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table if not exists public.creator_post_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.creator_posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);

create index if not exists creator_post_comments_feed_idx
  on public.creator_post_comments(post_id, created_at desc);

alter table public.creator_post_likes enable row level security;
alter table public.creator_post_comments enable row level security;

drop policy if exists "Customers read likes on free posts" on public.creator_post_likes;
create policy "Customers read likes on free posts"
  on public.creator_post_likes for select to anon, authenticated
  using (exists (
    select 1 from public.creator_posts p
    where p.id = post_id and p.status = 'published' and p.is_paid = false
  ));

drop policy if exists "Customers like free posts as themselves" on public.creator_post_likes;
create policy "Customers like free posts as themselves"
  on public.creator_post_likes for insert to authenticated
  with check (
    auth.uid() = user_id and exists (
      select 1 from public.creator_posts p
      join public.creator_profiles cp on cp.user_id = p.creator_id
      where p.id = post_id and p.status = 'published' and p.is_paid = false
        and cp.is_creator = true and cp.is_approved = true
    )
  );

drop policy if exists "Customers remove their own likes" on public.creator_post_likes;
create policy "Customers remove their own likes"
  on public.creator_post_likes for delete to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Public read comments on free posts" on public.creator_post_comments;
create policy "Public read comments on free posts"
  on public.creator_post_comments for select to anon, authenticated
  using (exists (
    select 1 from public.creator_posts p
    where p.id = post_id and p.status = 'published' and p.is_paid = false
  ));

drop policy if exists "Signed-in customers comment on free posts" on public.creator_post_comments;
create policy "Signed-in customers comment on free posts"
  on public.creator_post_comments for insert to authenticated
  with check (
    auth.uid() = user_id
    and char_length(trim(body)) between 1 and 1000
    and exists (
      select 1 from public.creator_posts p
      join public.creator_profiles cp on cp.user_id = p.creator_id
      where p.id = post_id and p.status = 'published' and p.is_paid = false
        and cp.is_creator = true and cp.is_approved = true
    )
  );

drop policy if exists "Customers delete their own comments" on public.creator_post_comments;
create policy "Customers delete their own comments"
  on public.creator_post_comments for delete to authenticated
  using (auth.uid() = user_id);

create or replace function public.get_free_post_engagement(p_post_id uuid)
returns table (like_count bigint, comment_count bigint, liked_by_me boolean)
language sql stable security definer set search_path = ''
as $$
  select
    (select count(*) from public.creator_post_likes l where l.post_id = p.id),
    (select count(*) from public.creator_post_comments c where c.post_id = p.id),
    exists(select 1 from public.creator_post_likes l where l.post_id = p.id and l.user_id = auth.uid())
  from public.creator_posts p
  join public.creator_profiles cp on cp.user_id = p.creator_id
  where p.id = p_post_id and p.status = 'published' and p.is_paid = false
    and cp.is_creator = true and cp.is_approved = true;
$$;

create or replace function public.list_free_post_comments(p_post_id uuid, p_limit integer default 20)
returns table (comment_id uuid, body text, created_at timestamptz)
language sql stable security definer set search_path = ''
as $$
  select c.id, c.body, c.created_at
  from public.creator_post_comments c
  join public.creator_posts p on p.id = c.post_id
  join public.creator_profiles cp on cp.user_id = p.creator_id
  where c.post_id = p_post_id and p.status = 'published' and p.is_paid = false
    and cp.is_creator = true and cp.is_approved = true
  order by c.created_at desc
  limit least(greatest(coalesce(p_limit,20),1),50);
$$;

revoke all on function public.get_free_post_engagement(uuid) from public;
revoke all on function public.list_free_post_comments(uuid,integer) from public;
grant execute on function public.get_free_post_engagement(uuid) to anon, authenticated;
grant execute on function public.list_free_post_comments(uuid,integer) to anon, authenticated;
grant select on public.creator_post_likes, public.creator_post_comments to anon, authenticated;
grant insert, delete on public.creator_post_likes to authenticated;
grant select, insert, delete on public.creator_post_comments to authenticated;

commit;
