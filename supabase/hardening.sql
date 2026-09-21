-- Darul-Ilm Challenge — grading hardening
-- Run after schema.sql. Safe to re-run.
--
-- Problem this fixes: grade_attempt() was an unlimited oracle. Calling it with
-- an empty submission returned every correct answer and explanation, and the
-- anon key that permits the call ships in every browser. Any grading function
-- that can be called repeatedly leaks the key, so grading is now one shot per
-- identity and recorded.

-- Each visitor gets one graded attempt per set. Requires anonymous sign-ins to
-- be enabled so every visitor has an auth.uid() without a sign-up form.
create table if not exists public.attempts (
  id         bigint generated always as identity primary key,
  user_id    uuid not null,
  set_id     text not null references public.question_sets(id) on delete cascade,
  answers    jsonb not null,
  score      integer not null,
  total      integer not null,
  created_at timestamptz not null default now(),
  unique (user_id, set_id)
);

create index if not exists attempts_set_idx on public.attempts (set_id);

alter table public.attempts enable row level security;

drop policy if exists "read own attempts" on public.attempts;
create policy "read own attempts" on public.attempts
  for select to anon, authenticated using (user_id = auth.uid());

drop policy if exists "hosts read all attempts" on public.attempts;
create policy "hosts read all attempts" on public.attempts
  for select to authenticated using (public.is_host());

revoke all on public.attempts from anon, authenticated;
grant select on public.attempts to anon, authenticated;
grant all    on public.attempts to service_role;
grant usage, select on sequence public.attempts_id_seq to service_role;

-- When the answer key becomes visible: 'after_close' keeps it hidden until the
-- round ends, which is airtight; 'immediate' shows it as soon as you submit.
alter table public.site_settings
  add column if not exists reveal_answers text not null default 'after_close'
  check (reveal_answers in ('immediate', 'after_close'));

create or replace function public.grade_attempt(p_set_id text, p_answers jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_uid     uuid := auth.uid();
  v_opens   timestamptz;
  v_closes  timestamptz;
  v_reveal  text;
  v_score   integer;
  v_total   integer;
  v_answers jsonb;
  v_detail  jsonb;
  v_first   boolean := true;
begin
  if v_uid is null then
    raise exception 'Sign in before submitting an attempt'
      using errcode = '28000';
  end if;

  select opens_at, closes_at into v_opens, v_closes
    from public.question_sets where id = p_set_id;
  if not found then
    raise exception 'No such set: %', p_set_id using errcode = 'no_data_found';
  end if;
  if now() < v_opens then
    raise exception 'That set has not opened yet' using errcode = 'check_violation';
  end if;

  -- One graded attempt per visitor per set. A second call replays the first
  -- result rather than regrading, so the function cannot be used as an oracle.
  select answers, score, total into v_answers, v_score, v_total
    from public.attempts where user_id = v_uid and set_id = p_set_id;

  if found then
    v_first := false;
  else
    v_answers := coalesce(p_answers, '{}'::jsonb);
    select
      count(*) filter (
        where nullif(v_answers ->> q.position::text, '')::integer
                is not distinct from q.correct_index),
      count(*)
      into v_score, v_total
      from public.questions q where q.set_id = p_set_id;

    insert into public.attempts (user_id, set_id, answers, score, total)
      values (v_uid, p_set_id, v_answers, coalesce(v_score,0), coalesce(v_total,0));
  end if;

  select reveal_answers into v_reveal from public.site_settings where id;

  -- The key is only ever included once the round has closed, or when the host
  -- has chosen immediate reveal.
  if now() >= v_closes or coalesce(v_reveal, 'after_close') = 'immediate' then
    select jsonb_agg(jsonb_build_object(
             'position',    q.position,
             'given',       nullif(v_answers ->> q.position::text, '')::integer,
             'correct',     q.correct_index,
             'explanation', q.explanation,
             'is_right',    nullif(v_answers ->> q.position::text, '')::integer
                              is not distinct from q.correct_index
           ) order by q.position)
      into v_detail
      from public.questions q where q.set_id = p_set_id;
  else
    -- While the round is live: which ones were right, but not what was right.
    select jsonb_agg(jsonb_build_object(
             'position', q.position,
             'given',    nullif(v_answers ->> q.position::text, '')::integer,
             'is_right', nullif(v_answers ->> q.position::text, '')::integer
                           is not distinct from q.correct_index
           ) order by q.position)
      into v_detail
      from public.questions q where q.set_id = p_set_id;
  end if;

  return jsonb_build_object(
    'set_id',      p_set_id,
    'score',       coalesce(v_score, 0),
    'total',       coalesce(v_total, 0),
    'first',       v_first,
    'key_shown',   (now() >= v_closes or coalesce(v_reveal,'after_close') = 'immediate'),
    'detail',      coalesce(v_detail, '[]'::jsonb));
end;
$$;

revoke execute on function public.grade_attempt(text, jsonb) from public;
grant  execute on function public.grade_attempt(text, jsonb) to anon, authenticated, service_role;

-- Answer key for a set that has already closed. Nothing is exposed early.
create or replace function public.answer_key(p_set_id text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_closes timestamptz; v_out jsonb;
begin
  select closes_at into v_closes from public.question_sets where id = p_set_id;
  if not found then
    raise exception 'No such set: %', p_set_id using errcode = 'no_data_found';
  end if;
  if now() < v_closes then
    raise exception 'That set is still open' using errcode = 'check_violation';
  end if;
  select jsonb_agg(jsonb_build_object(
           'position', q.position, 'prompt', q.prompt, 'options', q.options,
           'correct', q.correct_index, 'explanation', q.explanation
         ) order by q.position)
    into v_out from public.questions q where q.set_id = p_set_id;
  return coalesce(v_out, '[]'::jsonb);
end;
$$;

revoke execute on function public.answer_key(text) from public;
grant  execute on function public.answer_key(text) to anon, authenticated, service_role;

-- ================================================================ least privilege ==
-- Hosts previously wrote to the base tables directly, which meant "authenticated"
-- held SELECT/INSERT/UPDATE/DELETE/TRUNCATE on questions — including
-- correct_index. With anonymous sign-ins on, every visitor is "authenticated",
-- so the answers were one bad policy away from being readable, and TRUNCATE is
-- not filtered by RLS at all.
--
-- Hosts now write only through the security-definer functions below, and the
-- base tables are unreachable to both anon and authenticated.

create or replace function public.publish_set(p_set jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_id    text;
  v_title jsonb;
  v_secs  integer;
  v_opens timestamptz;
  v_closes timestamptz;
  v_count integer;
begin
  if not public.is_host() then
    raise exception 'Not authorised' using errcode = '42501';
  end if;

  v_id := lower(btrim(coalesce(p_set ->> 'id', '')));
  if v_id !~ '^[a-z0-9][a-z0-9-]{1,63}$' then
    raise exception 'id must be lowercase letters, numbers and hyphens (2-64 characters)'
      using errcode = '22023';
  end if;

  v_title := coalesce(p_set -> 'title', '{}'::jsonb);
  if coalesce(btrim(v_title ->> 'en'), '') = '' then
    raise exception 'An English title is required' using errcode = '22023';
  end if;

  v_opens  := (p_set ->> 'opensAt')::timestamptz;
  v_closes := (p_set ->> 'closesAt')::timestamptz;
  if v_opens is null or v_closes is null then
    raise exception 'opensAt and closesAt must be valid timestamps' using errcode = '22023';
  end if;
  if v_closes <= v_opens then
    raise exception 'closesAt must be after opensAt' using errcode = '22023';
  end if;

  v_secs := coalesce((p_set ->> 'secondsPerQuestion')::integer, 30);
  if v_secs < 5 or v_secs > 600 then
    raise exception 'secondsPerQuestion must be between 5 and 600' using errcode = '22023';
  end if;

  if jsonb_typeof(p_set -> 'questions') is distinct from 'array'
     or jsonb_array_length(p_set -> 'questions') = 0 then
    raise exception 'Add at least one question' using errcode = '22023';
  end if;

  -- every question must have English text, two or more options, and a correct
  -- index that actually points at one of them
  select count(*) into v_count
  from jsonb_array_elements(p_set -> 'questions') q
  where coalesce(btrim(q #>> '{q,en}'), '') = ''
     or jsonb_typeof(q #> '{o,en}') is distinct from 'array'
     or jsonb_array_length(q #> '{o,en}') < 2
     or (q ->> 'c') is null
     or (q ->> 'c')::integer < 0
     or (q ->> 'c')::integer >= jsonb_array_length(q #> '{o,en}');
  if v_count > 0 then
    raise exception '% question(s) are missing text, options, or a marked answer', v_count
      using errcode = '22023';
  end if;

  insert into public.question_sets
    (id, title_en, title_rw, title_ar, opens_at, closes_at, seconds_per_question, updated_at)
  values
    (v_id, btrim(v_title ->> 'en'),
     nullif(btrim(coalesce(v_title ->> 'rw', '')), ''),
     nullif(btrim(coalesce(v_title ->> 'ar', '')), ''),
     v_opens, v_closes, v_secs, now())
  on conflict (id) do update set
    title_en = excluded.title_en, title_rw = excluded.title_rw,
    title_ar = excluded.title_ar, opens_at = excluded.opens_at,
    closes_at = excluded.closes_at,
    seconds_per_question = excluded.seconds_per_question,
    updated_at = now();

  delete from public.questions where set_id = v_id;
  insert into public.questions (set_id, position, prompt, options, correct_index, explanation)
  select v_id, (ord - 1)::integer, e -> 'q', e -> 'o',
         (e ->> 'c')::integer, e -> 'e'
  from jsonb_array_elements(p_set -> 'questions') with ordinality as t(e, ord);

  select count(*) into v_count from public.questions where set_id = v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'questions', v_count);
end;
$$;

create or replace function public.delete_set(p_set_id text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_host() then
    raise exception 'Not authorised' using errcode = '42501';
  end if;
  delete from public.question_sets where id = p_set_id;
  if not found then
    raise exception 'No such set: %', p_set_id using errcode = 'no_data_found';
  end if;
  return jsonb_build_object('ok', true, 'id', p_set_id);
end;
$$;

-- Hosts need to see scheduled sets too, which the public view hides.
create or replace function public.host_sets()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  if not public.is_host() then
    raise exception 'Not authorised' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id,
           'title', jsonb_build_object('en', s.title_en, 'rw', s.title_rw, 'ar', s.title_ar),
           'opensAt', s.opens_at, 'closesAt', s.closes_at,
           'secondsPerQuestion', s.seconds_per_question,
           'phase', public.phase_of(s.opens_at, s.closes_at),
           'questions', (select count(*) from public.questions q where q.set_id = s.id),
           'attempts', (select count(*) from public.attempts a where a.set_id = s.id)
         ) order by s.opens_at desc), '[]'::jsonb)
    into v_out from public.question_sets s;
  return v_out;
end;
$$;

-- Full set, answers included, for the host to load back into the editor.
create or replace function public.host_set_detail(p_set_id text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  if not public.is_host() then
    raise exception 'Not authorised' using errcode = '42501';
  end if;
  select jsonb_build_object(
           'id', s.id,
           'title', jsonb_build_object('en', s.title_en, 'rw', s.title_rw, 'ar', s.title_ar),
           'opensAt', s.opens_at, 'closesAt', s.closes_at,
           'secondsPerQuestion', s.seconds_per_question,
           'questions', (select coalesce(jsonb_agg(jsonb_build_object(
                             'c', q.correct_index, 'q', q.prompt,
                             'o', q.options, 'e', q.explanation) order by q.position), '[]'::jsonb)
                         from public.questions q where q.set_id = s.id))
    into v_out from public.question_sets s where s.id = p_set_id;
  if v_out is null then
    raise exception 'No such set: %', p_set_id using errcode = 'no_data_found';
  end if;
  return v_out;
end;
$$;

create or replace function public.set_hero(p_url text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_host() then
    raise exception 'Not authorised' using errcode = '42501';
  end if;
  if p_url is not null and p_url !~ '^https://[A-Za-z0-9.-]+/' then
    raise exception 'Hero must be an https URL' using errcode = '22023';
  end if;
  update public.site_settings set hero_url = p_url where id;
  return jsonb_build_object('ok', true, 'hero', p_url);
end;
$$;

create or replace function public.set_reveal_policy(p_policy text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_host() then
    raise exception 'Not authorised' using errcode = '42501';
  end if;
  if p_policy not in ('immediate', 'after_close') then
    raise exception 'Policy must be immediate or after_close' using errcode = '22023';
  end if;
  update public.site_settings set reveal_answers = p_policy where id;
  return jsonb_build_object('ok', true, 'reveal_answers', p_policy);
end;
$$;

-- Take the base tables away from every browser-facing role. After this, anon
-- and authenticated can reach data only through the views and the functions
-- above, so the answers are protected by grants as well as by RLS.
revoke all on public.questions     from anon, authenticated;
revoke all on public.question_sets from anon, authenticated;
revoke all on public.site_settings from anon, authenticated;
revoke all on public.attempts      from anon, authenticated;
revoke all on public.hosts         from anon, authenticated;

grant select on public.site_settings    to anon, authenticated;
grant select on public.attempts         to anon, authenticated;
grant select on public.public_sets      to anon, authenticated;
grant select on public.public_questions to anon, authenticated;

revoke execute on function public.publish_set(jsonb)       from public, anon;
revoke execute on function public.delete_set(text)         from public, anon;
revoke execute on function public.host_sets()              from public, anon;
revoke execute on function public.host_set_detail(text)    from public, anon;
revoke execute on function public.set_hero(text)           from public, anon;
revoke execute on function public.set_reveal_policy(text)  from public, anon;

grant execute on function public.publish_set(jsonb)      to authenticated, service_role;
grant execute on function public.delete_set(text)        to authenticated, service_role;
grant execute on function public.host_sets()             to authenticated, service_role;
grant execute on function public.host_set_detail(text)   to authenticated, service_role;
grant execute on function public.set_hero(text)          to authenticated, service_role;
grant execute on function public.set_reveal_policy(text) to authenticated, service_role;
