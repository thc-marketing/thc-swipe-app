-- THC follows and in-app notifications
-- Apply this migration in Supabase SQL Editor after creator_platform_schema.sql
-- and creator_post_engagement.sql.

begin;

create table if not exists public.creator_follows (
  creator_id uuid not null references public.creator_profiles(user_id) on delete cascade,
  follower_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (creator_id, follower_id),
  constraint creator_follows_no_self check (creator_id <> follower_id)
);
create index if not exists creator_follows_follower_idx
  on public.creator_follows(follower_id, created_at desc);

create table if not exists public.user_notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references auth.users(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  notification_type text not null check (notification_type in ('new_post','like','comment','follow')),
  creator_id uuid references public.creator_profiles(user_id) on delete cascade,
  post_id uuid references public.creator_posts(id) on delete cascade,
  message text not null check (char_length(message) between 1 and 240),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists user_notifications_inbox_idx
  on public.user_notifications(recipient_id, created_at desc);
create index if not exists user_notifications_unread_idx
  on public.user_notifications(recipient_id) where read_at is null;

alter table public.creator_follows enable row level security;
alter table public.user_notifications enable row level security;

drop policy if exists "Users can read follow relationships" on public.creator_follows;
create policy "Users can read follow relationships"
  on public.creator_follows for select to authenticated
  using (auth.uid() = follower_id or auth.uid() = creator_id);

drop policy if exists "Customers follow approved creators" on public.creator_follows;
create policy "Customers follow approved creators"
  on public.creator_follows for insert to authenticated
  with check (
    auth.uid() = follower_id
    and exists (
      select 1 from public.creator_profiles cp
      where cp.user_id = creator_id and cp.is_creator = true and cp.is_approved = true
    )
  );

drop policy if exists "Customers unfollow creators" on public.creator_follows;
create policy "Customers unfollow creators"
  on public.creator_follows for delete to authenticated
  using (auth.uid() = follower_id);

drop policy if exists "Users read their own notifications" on public.user_notifications;
create policy "Users read their own notifications"
  on public.user_notifications for select to authenticated
  using (auth.uid() = recipient_id);

drop policy if exists "Users mark their own notifications read" on public.user_notifications;
create policy "Users mark their own notifications read"
  on public.user_notifications for update to authenticated
  using (auth.uid() = recipient_id)
  with check (auth.uid() = recipient_id);

revoke all on public.creator_follows from anon, authenticated;
grant select, insert, delete on public.creator_follows to authenticated;
revoke all on public.user_notifications from anon, authenticated;
grant select, update on public.user_notifications to authenticated;

-- Trigger-only notification writes. Browser clients cannot create notifications.
create or replace function public.thc_notify_post_like()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_creator uuid;
begin
  select p.creator_id into v_creator
  from public.creator_posts p
  where p.id = new.post_id and p.status = 'published' and p.is_paid = false;
  if v_creator is not null and v_creator <> new.user_id then
    insert into public.user_notifications(recipient_id,actor_id,notification_type,creator_id,post_id,message)
    values(v_creator,new.user_id,'like',v_creator,new.post_id,'Someone liked your post');
  end if;
  return new;
end;
$$;

create or replace function public.thc_notify_post_comment()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_creator uuid;
begin
  select p.creator_id into v_creator
  from public.creator_posts p
  where p.id = new.post_id and p.status = 'published' and p.is_paid = false;
  if v_creator is not null and v_creator <> new.user_id then
    insert into public.user_notifications(recipient_id,actor_id,notification_type,creator_id,post_id,message)
    values(v_creator,new.user_id,'comment',v_creator,new.post_id,'Someone commented on your post');
  end if;
  return new;
end;
$$;

create or replace function public.thc_notify_new_follower()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.user_notifications(recipient_id,actor_id,notification_type,creator_id,message)
  values(new.creator_id,new.follower_id,'follow',new.creator_id,'You have a new follower');
  return new;
end;
$$;

create or replace function public.thc_notify_followers_new_post()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.status = 'published' and (tg_op = 'INSERT' or old.status is distinct from 'published') then
    insert into public.user_notifications(recipient_id,actor_id,notification_type,creator_id,post_id,message)
    select f.follower_id,new.creator_id,'new_post',new.creator_id,new.id,
      coalesce(cp.display_name,'A creator') || ' shared new content'
    from public.creator_follows f
    join public.creator_profiles cp on cp.user_id = new.creator_id
    where f.creator_id = new.creator_id
      and f.follower_id <> new.creator_id
      and cp.is_creator = true and cp.is_approved = true;
  end if;
  return new;
end;
$$;

drop trigger if exists thc_like_notification on public.creator_post_likes;
create trigger thc_like_notification after insert on public.creator_post_likes
for each row execute function public.thc_notify_post_like();

drop trigger if exists thc_comment_notification on public.creator_post_comments;
create trigger thc_comment_notification after insert on public.creator_post_comments
for each row execute function public.thc_notify_post_comment();

drop trigger if exists thc_follow_notification on public.creator_follows;
create trigger thc_follow_notification after insert on public.creator_follows
for each row execute function public.thc_notify_new_follower();

drop trigger if exists thc_new_post_notification on public.creator_posts;
create trigger thc_new_post_notification after insert or update of status on public.creator_posts
for each row execute function public.thc_notify_followers_new_post();

revoke all on function public.thc_notify_post_like() from public;
revoke all on function public.thc_notify_post_comment() from public;
revoke all on function public.thc_notify_new_follower() from public;
revoke all on function public.thc_notify_followers_new_post() from public;

commit;
