-- Darul-Ilm Challenge — rankings and optional phone numbers
-- Run after schema.sql and hardening.sql. Safe to re-run.
--
-- Entrants are anonymous and never see a ranking. Leaving a phone number is
-- optional: it is only there so a host can reach someone about a prize, which
-- is not promised. The ranking is a host tool and covers everyone who
-- submitted, whether or not they left a number.

alter table public.attempts add column if not exists phone text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'attempts_phone_ck') then
    alter table public.attempts
      add constraint attempts_phone_ck
      check (phone is null or phone ~ '^\+?[0-9]{9,15}$');
  end if;
end $$;

create index if not exists attempts_board_idx on public.attempts (set_id, score desc, created_at);

-- There is no public leaderboard. An earlier build exposed a masked one to
-- entrants; it is removed rather than left in place unused, so nothing can
-- read scores but a host.
drop view if exists public.leaderboard;
drop function if exists public.mask_phone(text);

-- Every entrant, best score first. Someone who left a number is counted once
-- across all their anonymous identities; someone who did not is counted per
-- submission, which is the most that can be known about them.
create or replace function public.host_leaderboard(p_set_id text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  if not public.is_host() then
    raise exception 'Not authorised' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'rank', r.rank, 'phone', r.phone, 'score', r.score,
           'total', r.total, 'at', r.created_at) order by r.rank, r.created_at), '[]'::jsonb)
    into v_out
  from (
    select b.phone, b.score, b.total, b.created_at,
           rank() over (order by b.score desc, b.created_at asc) as rank
    from (
      select distinct on (coalesce(a.phone, a.user_id::text))
             a.phone, a.score, a.total, a.created_at
      from public.attempts a
      where a.set_id = p_set_id
      order by coalesce(a.phone, a.user_id::text), a.score desc, a.created_at asc
    ) b
  ) r;
  return v_out;
end;
$$;

create or replace function public.forget_phones(p_set_id text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare n integer;
begin
  if not public.is_host() then
    raise exception 'Not authorised' using errcode = '42501';
  end if;
  update public.attempts set phone = null where set_id = p_set_id and phone is not null;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'cleared', n);
end;
$$;

drop function if exists public.grade_attempt(text, jsonb);

create or replace function public.grade_attempt(p_set_id text, p_answers jsonb, p_phone text default null)
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
  v_phone   text;
begin
  if v_uid is null then
    raise exception 'Sign in before submitting an attempt' using errcode = '28000';
  end if;

  select opens_at, closes_at into v_opens, v_closes
    from public.question_sets where id = p_set_id;
  if not found then
    raise exception 'No such set: %', p_set_id using errcode = 'no_data_found';
  end if;
  if now() < v_opens then
    raise exception 'That set has not opened yet' using errcode = 'check_violation';
  end if;

  -- A number is optional. If one is typed it must be a real number; leaving
  -- the field empty is fine and simply means no prize contact.
  v_phone := nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'), '');
  if btrim(coalesce(p_phone, '')) <> ''
     and (v_phone is null or v_phone !~ '^\+?[0-9]{9,15}$') then
    raise exception 'That phone number does not look right' using errcode = '22023';
  end if;

  select answers, score, total into v_answers, v_score, v_total
    from public.attempts where user_id = v_uid and set_id = p_set_id;

  if found then
    v_first := false;
    update public.attempts set phone = coalesce(phone, v_phone)
      where user_id = v_uid and set_id = p_set_id;
  else
    v_answers := coalesce(p_answers, '{}'::jsonb);
    select
      count(*) filter (
        where nullif(v_answers ->> q.position::text, '')::integer
                is not distinct from q.correct_index),
      count(*)
      into v_score, v_total
      from public.questions q where q.set_id = p_set_id;

    insert into public.attempts (user_id, set_id, answers, score, total, phone)
      values (v_uid, p_set_id, v_answers, coalesce(v_score,0), coalesce(v_total,0), v_phone);
  end if;

  select reveal_answers into v_reveal from public.site_settings where id;

  if now() >= v_closes or coalesce(v_reveal, 'after_close') = 'immediate' then
    select jsonb_agg(jsonb_build_object(
             'position', q.position,
             'given', nullif(v_answers ->> q.position::text, '')::integer,
             'correct', q.correct_index,
             'explanation', q.explanation,
             'is_right', nullif(v_answers ->> q.position::text, '')::integer
                           is not distinct from q.correct_index
           ) order by q.position)
      into v_detail
      from public.questions q where q.set_id = p_set_id;
  else
    select jsonb_agg(jsonb_build_object(
             'position', q.position,
             'given', nullif(v_answers ->> q.position::text, '')::integer,
             'is_right', nullif(v_answers ->> q.position::text, '')::integer
                           is not distinct from q.correct_index
           ) order by q.position)
      into v_detail
      from public.questions q where q.set_id = p_set_id;
  end if;

  return jsonb_build_object(
    'set_id', p_set_id, 'score', coalesce(v_score,0), 'total', coalesce(v_total,0),
    'first', v_first, 'left_number', v_phone is not null,
    'key_shown', (now() >= v_closes or coalesce(v_reveal,'after_close') = 'immediate'),
    'detail', coalesce(v_detail, '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------- grants --
revoke execute on function public.grade_attempt(text, jsonb, text) from public;
grant  execute on function public.grade_attempt(text, jsonb, text) to anon, authenticated, service_role;

revoke execute on function public.host_leaderboard(text) from public, anon;
grant  execute on function public.host_leaderboard(text) to authenticated, service_role;

revoke execute on function public.forget_phones(text) from public, anon;
grant  execute on function public.forget_phones(text) to authenticated, service_role;
