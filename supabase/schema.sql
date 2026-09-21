-- Darul-Ilm Challenge — Supabase schema
-- Paste the whole file into the Supabase SQL editor and run it once.
--
-- The point of this schema is that the correct answers never leave the
-- database until a visitor has submitted. Visitors read questions through a
-- view that has no answer column, and grading happens in grade_attempt().

-- ---------------------------------------------------------------- tables --

create table if not exists public.question_sets (
  id                   text primary key
                         check (id ~ '^[a-z0-9][a-z0-9-]{1,63}$'),
  title_en             text not null check (length(btrim(title_en)) > 0),
  title_rw             text,
  title_ar             text,
  opens_at             timestamptz not null,
  closes_at            timestamptz not null,
  seconds_per_question integer not null default 30
                         check (seconds_per_question between 5 and 600),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint closes_after_opens check (closes_at > opens_at)
);

create table if not exists public.questions (
  id            bigint generated always as identity primary key,
  set_id        text not null references public.question_sets(id) on delete cascade,
  position      integer not null check (position >= 0),
  prompt        jsonb not null,   -- {"en":"…","rw":"…","ar":"…"}
  options       jsonb not null,   -- {"en":["…"],"rw":["…"],"ar":["…"]}
  correct_index integer not null check (correct_index >= 0),
  explanation   jsonb,            -- {"en":"…", …}
  unique (set_id, position)
);

create index if not exists questions_set_idx on public.questions (set_id, position);

-- one row, holding site-wide settings such as the hero photo
create table if not exists public.site_settings (
  id       boolean primary key default true check (id),
  hero_url text
);
insert into public.site_settings (id, hero_url)
  values (true, null) on conflict (id) do nothing;

-- who is allowed to publish
create table if not exists public.hosts (
  user_id uuid primary key,
  added_at timestamptz not null default now()
);

-- ------------------------------------------------------------- helpers ---

create or replace function public.is_host()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.hosts where user_id = auth.uid());
$$;

-- A set's state is derived from the clock, never stored.
create or replace function public.phase_of(opens timestamptz, closes timestamptz)
returns text language sql stable as $$   -- stable, not immutable: it reads now()
  select case
    when now() <  opens  then 'scheduled'
    when now() >= closes then 'closed'
    else 'live'
  end;
$$;

-- --------------------------------------------------------- public views --

-- Questions WITHOUT correct_index or explanation. This is the only route
-- visitors have to question text, so the answers cannot be read ahead.
create or replace view public.public_questions as
  select q.id, q.set_id, q.position, q.prompt, q.options
  from public.questions q
  join public.question_sets s on s.id = q.set_id
  where now() >= s.opens_at;

create or replace view public.public_sets as
  select s.id, s.title_en, s.title_rw, s.title_ar,
         s.opens_at, s.closes_at, s.seconds_per_question,
         public.phase_of(s.opens_at, s.closes_at) as phase,
         (select count(*) from public.questions q where q.set_id = s.id) as question_count
  from public.question_sets s
  where now() >= s.opens_at;

-- ------------------------------------------------------------- grading ---

-- Returns the score and, only now, the correct answers and explanations.
-- p_answers is {"0": 2, "1": 0, …} keyed by question position.
create or replace function public.grade_attempt(p_set_id text, p_answers jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_opens timestamptz;
  v_detail jsonb;
  v_score integer;
  v_total integer;
begin
  select opens_at into v_opens from public.question_sets where id = p_set_id;
  if not found then
    raise exception 'No such set: %', p_set_id using errcode = 'no_data_found';
  end if;
  if now() < v_opens then
    raise exception 'That set has not opened yet' using errcode = 'check_violation';
  end if;

  select
    jsonb_agg(jsonb_build_object(
      'position',    q.position,
      'given',       nullif(p_answers ->> q.position::text, '')::integer,
      'correct',     q.correct_index,
      'explanation', q.explanation,
      'is_right',    nullif(p_answers ->> q.position::text, '')::integer
                       is not distinct from q.correct_index
    ) order by q.position),
    count(*) filter (
      where nullif(p_answers ->> q.position::text, '')::integer
              is not distinct from q.correct_index),
    count(*)
  into v_detail, v_score, v_total
  from public.questions q
  where q.set_id = p_set_id;

  return jsonb_build_object(
    'set_id', p_set_id, 'score', coalesce(v_score, 0),
    'total', coalesce(v_total, 0), 'detail', coalesce(v_detail, '[]'::jsonb));
end;
$$;

-- ----------------------------------------------------------------- RLS ---

alter table public.question_sets enable row level security;
alter table public.questions     enable row level security;
alter table public.site_settings enable row level security;
alter table public.hosts         enable row level security;

drop policy if exists "hosts manage sets" on public.question_sets;
create policy "hosts manage sets" on public.question_sets
  for all to authenticated using (public.is_host()) with check (public.is_host());

drop policy if exists "hosts manage questions" on public.questions;
create policy "hosts manage questions" on public.questions
  for all to authenticated using (public.is_host()) with check (public.is_host());

drop policy if exists "anyone reads settings" on public.site_settings;
create policy "anyone reads settings" on public.site_settings
  for select to anon, authenticated using (true);

drop policy if exists "hosts write settings" on public.site_settings;
create policy "hosts write settings" on public.site_settings
  for update to authenticated using (public.is_host()) with check (public.is_host());

-- No select policy on question_sets/questions for anon: the base tables are
-- unreadable, and the views above are the only public route in.

-- --------------------------------------------------------------- grants --

revoke all on public.questions     from anon, authenticated;
revoke all on public.question_sets from anon, authenticated;
revoke all on public.hosts         from anon, authenticated;

grant select on public.public_questions to anon, authenticated;
grant select on public.public_sets      to anon, authenticated;
grant select on public.site_settings    to anon, authenticated;
grant update on public.site_settings    to authenticated;
grant all    on public.question_sets    to authenticated;
grant all    on public.questions        to authenticated;
grant usage, select on all sequences in schema public to authenticated;

grant execute on function public.grade_attempt(text, jsonb) to anon, authenticated;

-- ------------------------------------------------------- storage bucket --
-- Run this part in Supabase too. It is not covered by the local test run,
-- because the storage schema only exists inside Supabase.

insert into storage.buckets (id, name, public)
  values ('hero', 'hero', true) on conflict (id) do nothing;

drop policy if exists "public read hero" on storage.objects;
create policy "public read hero" on storage.objects
  for select to anon, authenticated using (bucket_id = 'hero');

drop policy if exists "hosts upload hero" on storage.objects;
create policy "hosts upload hero" on storage.objects
  for insert to authenticated with check (bucket_id = 'hero' and public.is_host());

drop policy if exists "hosts replace hero" on storage.objects;
create policy "hosts replace hero" on storage.objects
  for update to authenticated using (bucket_id = 'hero' and public.is_host());

drop policy if exists "hosts delete hero" on storage.objects;
create policy "hosts delete hero" on storage.objects
  for delete to authenticated using (bucket_id = 'hero' and public.is_host());
