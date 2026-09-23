-- Darul-Ilm Challenge — phone collection and rankings
-- Run after schema.sql and hardening.sql. Safe to re-run.
--
-- Entrants stay anonymous: no name is ever asked for. A phone number is taken
-- at submission so the host can reach the winners, and it is treated as
-- private throughout — the public board shows a masked number, and only a
-- host can see which number scored what.

alter table public.attempts add column if not exists phone text;

-- Digits, optionally led by +. Stored normalised (spaces and dashes stripped).
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'attempts_phone_ck') then
    alter table public.attempts
      add constraint attempts_phone_ck
      check (phone is null or phone ~ '^\+?[0-9]{9,15}$');
  end if;
end $$;

create index if not exists attempts_board_idx on public.attempts (set_id, score desc, created_at);

-- 0788123456 -> 078•••••56
create or replace function public.mask_phone(p text)
returns text language sql immutable as $$
  select case
    when p is null or length(p) < 6 then '•••'
    else left(p, 3) || repeat('•', greatest(length(p) - 5, 1)) || right(p, 2)
  end;
$$;

-- One row per phone per set: the best attempt that number achieved, so extra
-- anonymous identities cannot stuff the board.
create or replace view public.leaderboard as
  select set_id, rank, who, score, total, created_at
  from (
    select b.set_id,
           -- masked inline so the view needs no EXECUTE grant on a helper
           case when length(b.phone) < 6 then '•••'
                else left(b.phone,3) || repeat('•', greatest(length(b.phone)-5,1)) || right(b.phone,2)
           end as who,
           b.score, b.total, b.created_at,
           rank() over (partition by b.set_id
                        order by b.score desc, b.created_at asc) as rank
    from (
      select distinct on (a.set_id, a.phone)
             a.set_id, a.phone, a.score, a.total, a.created_at
      from public.attempts a
      where a.phone is not null
      order by a.set_id, a.phone, a.score desc, a.created_at asc
    ) b
  ) r
  where rank <= 50;

-- Same board, but with real numbers. Hosts only.
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
      select distinct on (a.phone) a.phone, a.score, a.total, a.created_at
      from public.attempts a
      where a.set_id = p_set_id and a.phone is not null
      order by a.phone, a.score desc, a.created_at asc
    ) b
  ) r;
  return v_out;
end;
$$;

-- Grading now records the number. Dropping the two-argument version first so
-- the old and new signatures cannot both resolve.
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

  v_phone := nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'), '');
  -- Something was typed but it is not a number: say so rather than quietly
  -- dropping it and leaving the entrant thinking they are ranked.
  if btrim(coalesce(p_phone, '')) <> ''
     and (v_phone is null or v_phone !~ '^\+?[0-9]{9,15}$') then
    raise exception 'That phone number does not look right' using errcode = '22023';
  end if;

  select answers, score, total into v_answers, v_score, v_total
    from public.attempts where user_id = v_uid and set_id = p_set_id;

  if found then
    v_first := false;
    -- A number may be added to an attempt already made, but not swapped.
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
    'first', v_first, 'ranked', v_phone is not null,
    'key_shown', (now() >= v_closes or coalesce(v_reveal,'after_close') = 'immediate'),
    'detail', coalesce(v_detail, '[]'::jsonb));
end;
$$;

-- Let a host clear the numbers once prizes are handed out.
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

-- ---------------------------------------------------------------- grants --
-- attempts itself stays unreadable; the masked view is the only public route.
revoke all on public.leaderboard from anon, authenticated;
grant select on public.leaderboard to anon, authenticated;

revoke execute on function public.grade_attempt(text, jsonb, text) from public;
grant  execute on function public.grade_attempt(text, jsonb, text) to anon, authenticated, service_role;

revoke execute on function public.host_leaderboard(text) from public, anon;
grant  execute on function public.host_leaderboard(text) to authenticated, service_role;

revoke execute on function public.forget_phones(text) from public, anon;
grant  execute on function public.forget_phones(text) to authenticated, service_role;

-- mask_phone is kept for ad-hoc use; masking is one-way, so EXECUTE is harmless.
grant execute on function public.mask_phone(text) to anon, authenticated, service_role;
