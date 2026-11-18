-- =====================================================================
--  QUIZ DÉBITMÈTRES — migration UNIQUE non destructive
--  Ajoute toutes les fonctionnalités portées (éditeur flexible, early answers,
--  sans code groupe, sans code animateur, RPC quiz, etc.)
--  Marge serveur : 3 secondes
--
--  Supabase > SQL Editor > coller tout ce fichier > Run
--  Idempotent : peut être relancé sans casser les données existantes.
--  Ne supprime AUCUNE table ni aucune session / réponse.
-- =====================================================================

-- ---------- 1. Animateur = tout compte connecté (plus de code secret) ----------
create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
         and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false
$$;

-- claim_admin devient un no-op utile (compat ancien front) : réussit toujours si connecté
create or replace function claim_admin(p_code text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  insert into admins(user_id) values (auth.uid()) on conflict do nothing;
  return true;
end $$;

-- ---------- 2. Nombre de questions libre (1 → 200) ----------
alter table quiz_questions drop constraint if exists quiz_questions_pos_check;
alter table quiz_questions add constraint quiz_questions_pos_check
  check (pos between 1 and 200);

create or replace function save_quiz(p_id uuid, p_title text, p_default_time int, p_questions jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := p_id;
  v_q  jsonb;
  v_i  int := 0;
  v_n  int;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  if jsonb_typeof(p_questions) <> 'array'
     or jsonb_array_length(p_questions) not between 1 and 200 then
    raise exception 'need_questions';
  end if;

  if v_id is null then
    insert into quizzes(owner, title, default_time_s)
    values (auth.uid(), trim(p_title), coalesce(p_default_time, 15))
    returning id into v_id;
  else
    update quizzes
       set title = trim(p_title),
           default_time_s = coalesce(p_default_time, 15),
           updated_at = now()
     where id = v_id and owner = auth.uid();
    if not found then raise exception 'forbidden'; end if;
  end if;

  for v_q in select * from jsonb_array_elements(p_questions) loop
    v_i := v_i + 1;
    v_n := jsonb_array_length(v_q->'options');
    if coalesce(length(trim(v_q->>'prompt')), 0) = 0
       or v_n is null or v_n not between 3 and 4
       or (v_q->>'correct') is null
       or (v_q->>'correct')::int not between 0 and v_n - 1
       or exists (
            select 1 from jsonb_array_elements_text(v_q->'options') o
            where length(trim(o)) = 0
          )
    then
      raise exception 'invalid_question_%', v_i;
    end if;

    insert into quiz_questions(quiz_id, pos, prompt, options, correct, explanation, time_s)
    values (
      v_id, v_i, trim(v_q->>'prompt'), v_q->'options',
      (v_q->>'correct')::int,
      coalesce(v_q->>'explanation', ''),
      nullif(v_q->>'time_s', '')::int
    )
    on conflict (quiz_id, pos) do update
      set prompt      = excluded.prompt,
          options     = excluded.options,
          correct     = excluded.correct,
          explanation = excluded.explanation,
          time_s      = excluded.time_s;
  end loop;

  -- autorise de raccourcir un quiz (supprime les positions au-delà)
  delete from quiz_questions where quiz_id = v_id and pos > v_i;
  return v_id;
end $$;

create or replace function create_session(p_quiz uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id   uuid;
  v_code text;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  if not exists (select 1 from quizzes where id = p_quiz and owner = auth.uid()) then
    raise exception 'forbidden';
  end if;
  if (select count(*) from quiz_questions where quiz_id = p_quiz) < 1 then
    raise exception 'need_questions';
  end if;

  -- nettoie les sessions abandonnées > 12 h
  update sessions
     set status = 'finished', finished_at = now()
   where status <> 'finished'
     and created_at < now() - interval '12 hours';

  v_code := gen_code();
  insert into sessions(quiz_id, host, code)
  values (p_quiz, auth.uid(), v_code)
  returning id into v_id;

  return jsonb_build_object('session_id', v_id, 'code', v_code);
end $$;

-- ---------- 3. RPC quiz (lecture robuste pour le tableau de bord) ----------
-- Signature table (utilisée par le front porté)
drop function if exists list_my_quizzes();
create or replace function list_my_quizzes()
returns table(
  id uuid,
  title text,
  default_time_s int,
  updated_at timestamptz,
  question_count int
)
language sql stable security definer set search_path = public as $$
  select z.id, z.title, z.default_time_s, z.updated_at,
         (select count(*)::int from quiz_questions q where q.quiz_id = z.id)
  from quizzes z
  where is_admin() and z.owner = auth.uid()
  order by z.updated_at desc
$$;

create or replace function get_quiz(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'id', z.id,
    'title', z.title,
    'default_time_s', z.default_time_s,
    'questions', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'prompt', q.prompt,
          'options', q.options,
          'correct', q.correct,
          'explanation', q.explanation,
          'time_s', q.time_s
        ) order by q.pos
      )
      from quiz_questions q where q.quiz_id = z.id
    ), '[]'::jsonb)
  )
  into r
  from quizzes z
  where z.id = p_id and z.owner = auth.uid();
  return r;
end $$;

create or replace function quiz_counts() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  return jsonb_build_object(
    'mine',  (select count(*) from quizzes where owner = auth.uid()),
    'total', (select count(*) from quizzes)
  );
end $$;

-- ---------- 4. Join sans code de groupe (colonne group_code conservée pour l'existant) ----------
-- On garde l'ancienne signature à 5 args pour compat, mais le groupe n'est plus obligatoire.
drop function if exists join_session(text, text, text, text);
drop function if exists join_session(text, text, text, text, text);

create or replace function join_session(
  p_code  text,
  p_kind  text,
  p_name1 text,
  p_name2 text default null,
  p_group text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_s  sessions;
  v_p  players;
  v_n1 text := trim(coalesce(p_name1, ''));
  v_n2 text := nullif(trim(coalesce(p_name2, '')), '');
  v_g  text := nullif(upper(trim(coalesce(p_group, ''))), '');
begin
  if p_kind not in ('solo', 'binome') then raise exception 'bad_kind'; end if;
  if length(v_n1) < 2 then raise exception 'name_required'; end if;
  if p_kind = 'binome' and (v_n2 is null or length(v_n2) < 2) then
    raise exception 'binome_incomplete';
  end if;
  -- p_group optionnel (plus d'erreur group_required)
  if p_kind = 'solo' then v_n2 := null; v_g := null; end if;

  select * into v_s
  from sessions
  where code = upper(trim(coalesce(p_code, '')))
    and status <> 'finished';
  if not found then raise exception 'unknown_code'; end if;
  if v_s.status <> 'lobby' then raise exception 'already_started'; end if;

  begin
    insert into players(session_id, kind, name1, name2, group_code)
    values (v_s.id, p_kind, left(v_n1, 60), left(v_n2, 60), left(v_g, 20))
    returning * into v_p;
  exception when unique_violation then
    raise exception 'name_taken';
  end;

  return jsonb_build_object('player_id', v_p.id, 'session_id', v_s.id);
end $$;

-- ---------- 5. submit_answer : réponses anticipées + marge 3 s ----------
create or replace function submit_answer(p_player uuid, p_choice int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_p   players;
  v_s   sessions;
  v_q   quiz_questions;
  v_lim int;
  v_el  int;
  v_ok  boolean;
  v_pts int := 0;
begin
  select * into v_p from players where id = p_player;
  if not found then raise exception 'unknown_player'; end if;

  select * into v_s from sessions where id = v_p.session_id for share;

  -- Autorise les réponses dès le statut 'question' (y compris pendant « Préparez-vous »)
  -- Marge réseau : 3 secondes après la fin officielle du chrono
  if v_s.status <> 'question'
     or now() > v_s.question_ends_at + interval '3 seconds' then
    raise exception 'closed';
  end if;

  select * into v_q
  from quiz_questions
  where quiz_id = v_s.quiz_id and pos = v_s.current_pos;

  if p_choice is null
     or p_choice < 0
     or p_choice >= jsonb_array_length(v_q.options) then
    raise exception 'bad_choice';
  end if;

  v_lim := round(extract(epoch from (v_s.question_ends_at - v_s.question_started_at)) * 1000)::int;
  -- temps écoulé borné : 0 si réponse pendant le lead-in, v_lim au plus tard
  v_el  := least(v_lim, greatest(0,
            round(extract(epoch from (now() - v_s.question_started_at)) * 1000)::int));
  v_ok  := (p_choice = v_q.correct);

  if v_ok then
    v_pts := round(1000 * (1 - 0.5 * v_el::numeric / nullif(v_lim, 0)))::int;
  end if;

  insert into player_answers(
    session_id, player_id, question_id, pos, choice, is_correct, time_ms, points
  ) values (
    v_s.id, v_p.id, v_q.id, v_s.current_pos, p_choice, v_ok, v_el, v_pts
  )
  on conflict (player_id, question_id) do nothing;

  if not found then raise exception 'already_answered'; end if;

  return jsonb_build_object('ok', true);
end $$;

-- ---------- 6. Droits ----------
revoke all on function
  is_admin(),
  claim_admin(text),
  save_quiz(uuid, text, int, jsonb),
  create_session(uuid),
  list_my_quizzes(),
  get_quiz(uuid),
  quiz_counts(),
  join_session(text, text, text, text, text),
  submit_answer(uuid, int)
from public, anon, authenticated;

grant execute on function is_admin(), claim_admin(text) to authenticated;
grant execute on function
  save_quiz(uuid, text, int, jsonb),
  create_session(uuid),
  list_my_quizzes(),
  get_quiz(uuid),
  quiz_counts()
to authenticated;
grant execute on function
  join_session(text, text, text, text, text),
  submit_answer(uuid, int)
to anon, authenticated;

notify pgrst, 'reload schema';

-- Fin. Vérification rapide (optionnel) :
-- select proname from pg_proc where pronamespace = 'public'::regnamespace
--   and proname in ('save_quiz','submit_answer','join_session','list_my_quizzes','get_quiz');
