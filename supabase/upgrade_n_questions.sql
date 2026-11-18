-- quiz-chine : nombre de questions libre (1 à 200)
-- À exécuter UNE FOIS dans Supabase > SQL Editor si la base existe déjà (live_migration.sql déjà appliqué).
alter table quiz_questions drop constraint if exists quiz_questions_pos_check;
alter table quiz_questions add constraint quiz_questions_pos_check check (pos between 1 and 200);

create or replace function save_quiz(p_id uuid, p_title text, p_default_time int, p_questions jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := p_id; v_q jsonb; v_i int := 0; v_n int;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  if jsonb_typeof(p_questions) <> 'array' or jsonb_array_length(p_questions) not between 1 and 200 then
    raise exception 'need_questions';
  end if;
  if v_id is null then
    insert into quizzes(owner, title, default_time_s)
    values (auth.uid(), trim(p_title), coalesce(p_default_time, 15)) returning id into v_id;
  else
    update quizzes set title = trim(p_title), default_time_s = coalesce(p_default_time, 15), updated_at = now()
    where id = v_id and owner = auth.uid();
    if not found then raise exception 'forbidden'; end if;
  end if;

  for v_q in select * from jsonb_array_elements(p_questions) loop
    v_i := v_i + 1;
    v_n := jsonb_array_length(v_q->'options');
    if coalesce(length(trim(v_q->>'prompt')), 0) = 0
       or v_n is null or v_n not between 3 and 4
       or (v_q->>'correct') is null or (v_q->>'correct')::int not between 0 and v_n - 1
       or exists (select 1 from jsonb_array_elements_text(v_q->'options') o where length(trim(o)) = 0)
    then
      raise exception 'invalid_question_%', v_i;
    end if;
    insert into quiz_questions(quiz_id, pos, prompt, options, correct, explanation, time_s)
    values (v_id, v_i, trim(v_q->>'prompt'), v_q->'options', (v_q->>'correct')::int,
            coalesce(v_q->>'explanation', ''), nullif(v_q->>'time_s', '')::int)
    on conflict (quiz_id, pos) do update
      set prompt = excluded.prompt, options = excluded.options, correct = excluded.correct,
          explanation = excluded.explanation, time_s = excluded.time_s;
  end loop;
  delete from quiz_questions where quiz_id = v_id and pos > v_i;
  return v_id;
end $$;

create or replace function create_session(p_quiz uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_code text;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  if not exists (select 1 from quizzes where id = p_quiz and owner = auth.uid()) then raise exception 'forbidden'; end if;
  if (select count(*) from quiz_questions where quiz_id = p_quiz) < 1 then raise exception 'need_questions'; end if;
  update sessions set status = 'finished', finished_at = now()
   where status <> 'finished' and created_at < now() - interval '12 hours';
  v_code := gen_code();
  insert into sessions(quiz_id, host, code) values (p_quiz, auth.uid(), v_code) returning id into v_id;
  return jsonb_build_object('session_id', v_id, 'code', v_code);
end $$;
