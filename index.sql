-- === Fresh schema for "Oăng Oăng w cún cáo" ===
-- Uses Supabase (Postgres + RLS). Run this in Supabase SQL editor.

-- 1) Profiles
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text,
  display_name text,
  avatar_url text,
  created_at timestamp with time zone default now()
);
alter table public.profiles enable row level security;
create policy "profiles are readable by everyone" on public.profiles for select using (true);
create policy "users upsert own profile" on public.profiles for insert with check (auth.uid() = id);
create policy "users update own profile" on public.profiles for update using (auth.uid() = id);

-- 2) Admins
create table if not exists public.admins (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  note text
);
alter table public.admins enable row level security;
create policy "admins readable to authenticated" on public.admins for select to authenticated using (true);
create policy "only admins manage admins" on public.admins for all using (exists(select 1 from public.admins a where a.user_id = auth.uid())) with check (exists(select 1 from public.admins a where a.user_id = auth.uid()));

-- Helper: check admin
create or replace function public.is_admin(uid uuid)
returns boolean language sql stable as $$
  select exists(select 1 from public.admins a where a.user_id = uid);
$$;

-- 3) Threads (per chap)
create table if not exists public.threads (
  id bigint generated always as identity primary key,
  type text not null check (type in ('chap','page')),
  key text not null unique,
  created_at timestamp with time zone default now()
);
alter table public.threads enable row level security;
create policy "threads readable by all" on public.threads for select using (true);
create policy "any auth can create thread" on public.threads for insert to authenticated with check (true);

-- 4) Comments
create table if not exists public.comments (
  id bigint generated always as identity primary key,
  thread_id bigint not null references public.threads(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  parent_id bigint references public.comments(id) on delete cascade,
  content text not null,
  is_hidden boolean not null default false,
  created_at timestamp with time zone default now(),
  updated_at timestamp with time zone
);
alter table public.comments enable row level security;
-- read: everyone sees non-hidden; owner/admin see own/any
create policy "read comments" on public.comments for select using (
  not is_hidden or user_id = auth.uid() or public.is_admin(auth.uid())
);
-- create
create policy "add comments" on public.comments for insert to authenticated with check (true);
-- update own or admin
create policy "edit own or admin" on public.comments for update using (user_id = auth.uid() or public.is_admin(auth.uid()));
-- delete own or admin
create policy "delete own or admin" on public.comments for delete using (user_id = auth.uid() or public.is_admin(auth.uid()));

-- 5) Reactions (emoji per comment)
create table if not exists public.reactions (
  comment_id bigint not null references public.comments(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  emoji text not null,
  created_at timestamp with time zone default now(),
  primary key (comment_id, user_id, emoji)
);
alter table public.reactions enable row level security;
create policy "reactions readable by all" on public.reactions for select using (true);
create policy "upsert own reactions" on public.reactions for insert to authenticated with check (true);
create policy "delete own reactions" on public.reactions for delete using (user_id = auth.uid());

-- 6) Likes (heart per thread/chap)
create table if not exists public.likes (
  thread_id bigint not null references public.threads(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamp with time zone default now(),
  primary key (thread_id, user_id)
);
alter table public.likes enable row level security;
create policy "likes readable by all" on public.likes for select using (true);
create policy "like auth" on public.likes for insert to authenticated with check (true);
create policy "unlike own" on public.likes for delete using (user_id = auth.uid());

-- 7) Notifications
create table if not exists public.notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  type text not null check (type in ('reply','new_comment')),
  payload jsonb,
  created_at timestamp with time zone default now(),
  read_at timestamp with time zone
);
alter table public.notifications enable row level security;
create policy "read own notifications" on public.notifications for select using (user_id = auth.uid());
create policy "mark own notifications" on public.notifications for update using (user_id = auth.uid());
-- allow inserts from app/trigger
create policy "allow insert notifications" on public.notifications for insert to authenticated with check (true);

-- 8) Triggers: when a comment is inserted -> notify parent owner (reply) and admins (new_comment on root)
create or replace function public.notify_on_comment()
returns trigger language plpgsql security definer as $$
declare
  parent_user uuid;
  admin_id uuid;
begin
  -- reply notification
  if new.parent_id is not null then
    select user_id into parent_user from public.comments where id = new.parent_id;
    if parent_user is not null and parent_user <> new.user_id then
      insert into public.notifications(user_id, type, payload)
      values (parent_user, 'reply', jsonb_build_object('comment_id', new.id, 'thread_id', new.thread_id, 'message', 'Ai đó đã trả lời bình luận của bạn'));
    end if;
  else
    -- root comment -> notify admins
    for admin_id in select user_id from public.admins loop
      if admin_id is not null and admin_id <> new.user_id then
        insert into public.notifications(user_id, type, payload)
        values (admin_id, 'new_comment', jsonb_build_object('comment_id', new.id, 'thread_id', new.thread_id, 'message', 'Có bình luận mới'));
      end if;
    end loop;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_notify_on_comment on public.comments;
create trigger trg_notify_on_comment after insert on public.comments
for each row execute function public.notify_on_comment();

-- 9) Realtime publication
alter publication supabase_realtime add table public.threads;
alter publication supabase_realtime add table public.comments;
alter publication supabase_realtime add table public.reactions;
alter publication supabase_realtime add table public.likes;
alter publication supabase_realtime add table public.notifications;

-- 10) Seed: make yourself admin after first login
--   replace '00000000-0000-0000-0000-000000000000' with your auth.user id
-- insert into public.admins(user_id, note) values ('00000000-0000-0000-0000-000000000000', 'site owner');
