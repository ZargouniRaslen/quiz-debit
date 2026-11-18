-- =====================================================================
--  MIGRATION NON DESTRUCTIVE : lecture des quiz par fonctions RPC
--  Supabase > SQL Editor > coller > Run. Ne supprime rien (contrairement à setup.sql).
-- =====================================================================

-- Liste des quiz de l'animateur connecté, avec le nombre de questions
create or replace function list_my_quizzes()
returns table(id uuid, title text, default_time_s int, updated_at timestamptz, question_count int)
language sql stable security definer set search_path = public as $$
  select z.id, z.title, z.default_time_s, z.updated_at,
         (select count(*)::int from quiz_questions q where q.quiz_id = z.id)
  from quizzes z
  where is_admin() and z.owner = auth.uid()
  order by z.updated_at desc
$$;

-- Un quiz complet (titre, durée, questions dans l'ordre) ; null si introuvable ou pas à vous
create or replace function get_quiz(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object('id', z.id, 'title', z.title, 'default_time_s', z.default_time_s,
    'questions', coalesce((select jsonb_agg(jsonb_build_object('prompt', q.prompt, 'options', q.options,
        'correct', q.correct, 'explanation', q.explanation, 'time_s', q.time_s) order by q.pos)
      from quiz_questions q where q.quiz_id = z.id), '[]'::jsonb))
  into r from quizzes z where z.id = p_id and z.owner = auth.uid();
  return r;
end $$;

-- Diagnostic : combien de quiz sont à vous / existent dans la base (pour repérer un mauvais compte)
create or replace function quiz_counts() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  return jsonb_build_object('mine', (select count(*) from quizzes where owner = auth.uid()), 'total', (select count(*) from quizzes));
end $$;

revoke all on function list_my_quizzes(), get_quiz(uuid), quiz_counts() from public, anon, authenticated;
grant execute on function list_my_quizzes(), get_quiz(uuid), quiz_counts() to authenticated;
notify pgrst, 'reload schema';
