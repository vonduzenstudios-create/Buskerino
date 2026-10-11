-- Buskerino database setup for Supabase.
-- Paste this whole file into Supabase > SQL Editor and press Run.
-- Safe to run again: it drops and recreates Buskerino's own tables and functions.
--
-- BEFORE RUNNING: change the email on the last line to the one you log in with
-- on the performer page.

-- ---------- Clean slate ----------
drop table if exists votes, show_state, songs, performers cascade;

-- ---------- Tables ----------
create table songs (
  id         text primary key,
  title      text not null,
  sort_order int  not null,
  active     boolean not null default true,   -- false = hidden from the audience
  played     boolean not null default false,
  video      text                              -- looping gameplay video URL (step 2)
);

-- One row holding the live show state. Every change bumps `version`,
-- which is what screens listen to for live updates.
create table show_state (
  id        int primary key default 1 check (id = 1),
  frozen_id text references songs(id) on delete set null,
  version   bigint not null default 0
);
insert into show_state default values;

-- One row per thumb. A phone (anonymous login) gets at most 3, one per song.
create table votes (
  song_id    text not null references songs(id) on delete cascade,
  voter      uuid not null,
  created_at timestamptz not null default now(),
  primary key (song_id, voter)
);

-- Emails allowed to use the performer controls.
create table performers (email text primary key);

-- Nobody touches tables directly; reads of songs/state are public, everything
-- else goes through the functions below.
alter table songs      enable row level security;
alter table show_state enable row level security;
alter table votes      enable row level security;
alter table performers enable row level security;
create policy "public read" on songs      for select using (true);
create policy "public read" on show_state for select using (true);

-- Live updates: screens subscribe to changes on show_state.
do $$ begin
  alter publication supabase_realtime add table show_state;
exception when duplicate_object then null; end $$;

-- ---------- Helpers ----------
create or replace function bump() returns void
language sql security definer set search_path = public as $$
  update show_state set version = version + 1 where id = 1;
$$;

create or replace function is_performer() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false
     and exists (select 1 from performers where lower(email) = lower(auth.jwt() ->> 'email'));
$$;

create or replace function require_performer() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_performer() then raise exception 'Only the performer can do that.'; end if;
end $$;

-- Songs on the audience list, ranked: frozen first, then thumbs, then starting order.
create or replace function ranked_songs()
returns table (id text, title text, votes int, video text)
language sql stable security definer set search_path = public as $$
  select s.id, s.title, count(v.voter)::int as votes, s.video
  from songs s
  left join votes v on v.song_id = s.id
  cross join show_state st
  where s.active and not s.played
  group by s.id, st.frozen_id
  order by (s.id = st.frozen_id) desc nulls last, count(v.voter) desc, s.sort_order;
$$;

-- ---------- Public ----------
create or replace function get_board() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'frozenId', (select frozen_id from show_state where id = 1),
    'votesPerDevice', 3,
    'songs', coalesce((select json_agg(r) from ranked_songs() r), '[]'::json)
  );
$$;

create or replace function my_votes() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(song_id), '[]'::json) from votes where voter = auth.uid();
$$;

create or replace function cast_vote(p_song text) returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not signed in.'; end if;
  perform pg_advisory_xact_lock(hashtext(uid::text));
  if not exists (select 1 from songs where id = p_song and active and not played) then
    raise exception 'That song is not on the list.';
  end if;
  if (select frozen_id from show_state where id = 1) = p_song then
    raise exception 'That song is locked in and coming up now.';
  end if;
  if exists (select 1 from votes where song_id = p_song and voter = uid) then
    raise exception 'You already gave that song a thumb.';
  end if;
  if (select count(*) from votes where voter = uid) >= 3 then
    raise exception 'You have used all your thumbs.';
  end if;
  insert into votes (song_id, voter) values (p_song, uid);
  perform bump();
  return my_votes();
end $$;

create or replace function remove_vote(p_song text) returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not signed in.'; end if;
  if (select frozen_id from show_state where id = 1) = p_song then
    raise exception 'That song is locked in.';
  end if;
  delete from votes where song_id = p_song and voter = uid;
  if found then perform bump(); end if;
  return my_votes();
end $$;

-- ---------- Performer ----------
create or replace function performer_overview() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_performer();
  return json_build_object(
    'all', coalesce((select json_agg(s order by s.sort_order) from songs s), '[]'::json),
    'voterCount', (select count(distinct voter) from votes)
  );
end $$;

create or replace function freeze_leader() returns void
language plpgsql security definer set search_path = public as $$
declare leader text;
begin
  perform require_performer();
  select id into leader from ranked_songs() limit 1;
  if leader is null then raise exception 'No songs on the list.'; end if;
  update show_state set frozen_id = leader where id = 1;
  perform bump();
end $$;

create or replace function freeze_song(p_song text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_performer();
  if not exists (select 1 from songs where id = p_song and active and not played) then
    raise exception 'Song not available.';
  end if;
  update show_state set frozen_id = p_song where id = 1;
  perform bump();
end $$;

create or replace function unfreeze() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_performer();
  update show_state set frozen_id = null where id = 1;
  perform bump();
end $$;

-- Song done: drop it from the list and hand its thumbs back to voters.
create or replace function mark_played() returns void
language plpgsql security definer set search_path = public as $$
declare f text;
begin
  perform require_performer();
  select frozen_id into f from show_state where id = 1;
  if f is null then raise exception 'Nothing is locked in.'; end if;
  update songs set played = true where id = f;
  delete from votes where song_id = f;
  update show_state set frozen_id = null where id = 1;
  perform bump();
end $$;

create or replace function set_active(p_song text, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_performer();
  update songs set active = p_active where id = p_song;
  if not p_active then
    update show_state set frozen_id = null where id = 1 and frozen_id = p_song;
  end if;
  perform bump();
end $$;

create or replace function restore_song(p_song text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_performer();
  update songs set played = false where id = p_song;
  perform bump();
end $$;

-- New show: everything back on the list, all votes cleared.
create or replace function reset_show() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_performer();
  delete from votes where true;
  update songs set played = false where true;
  update show_state set frozen_id = null where id = 1;
  perform bump();
end $$;

-- Replace the whole song list (from songs.json). Clears votes.
create or replace function load_songs(p_songs jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_performer();
  update show_state set frozen_id = null where id = 1;
  delete from votes where true;
  delete from songs where true;
  insert into songs (id, title, sort_order, active, video)
  select s ->> 'id', s ->> 'title', (ord - 1)::int,
         coalesce((s ->> 'active')::boolean, true), s ->> 'video'
  from jsonb_array_elements(p_songs) with ordinality as t(s, ord);
  perform bump();
end $$;

-- Lock down: only the functions above are callable from the browser.
revoke all on function bump(), require_performer() from public, anon, authenticated;
revoke insert, update, delete on songs, show_state, votes, performers from anon, authenticated;
revoke select on votes, performers from anon, authenticated;

-- ---------- Your performer login ----------
insert into performers (email) values ('you@example.com');
