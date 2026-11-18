-- =====================================================================
--  MIGRATION NON DESTRUCTIVE : réponses autorisées pendant le « Préparez-vous »
--  Supabase > SQL Editor > coller > Run. Ne supprime rien.
-- =====================================================================
create or replace function submit_answer(p_player uuid, p_choice int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_p players; v_s sessions; v_q quiz_questions;
  v_lim int; v_el int; v_ok boolean; v_pts int := 0;
begin
  select * into v_p from players where id = p_player;
  if not found then raise exception 'unknown_player'; end if;
  select * into v_s from sessions where id = v_p.session_id for share;   -- bloque si l'admin clôture en même temps

  -- on peut répondre dès l'affichage de la question, même pendant le « Préparez-vous »
  if v_s.status <> 'question' or now() > v_s.question_ends_at + interval '1 second' then
    raise exception 'closed';
  end if;
  select * into v_q from quiz_questions where quiz_id = v_s.quiz_id and pos = v_s.current_pos;
  if p_choice is null or p_choice < 0 or p_choice >= jsonb_array_length(v_q.options) then raise exception 'bad_choice'; end if;

  v_lim := round(extract(epoch from (v_s.question_ends_at - v_s.question_started_at)) * 1000)::int;
  v_el  := least(v_lim, greatest(0, round(extract(epoch from (now() - v_s.question_started_at)) * 1000)::int));
  v_ok  := (p_choice = v_q.correct);
  -- Barème (type Kahoot) : 1000 points si instantané, 500 si au dernier moment, 0 si faux
  if v_ok then v_pts := round(1000 * (1 - 0.5 * v_el::numeric / v_lim))::int; end if;

  insert into player_answers(session_id, player_id, question_id, pos, choice, is_correct, time_ms, points)
  values (v_s.id, v_p.id, v_q.id, v_s.current_pos, p_choice, v_ok, v_el, v_pts)
  on conflict (player_id, question_id) do nothing;
  if not found then raise exception 'already_answered'; end if;

  return jsonb_build_object('ok', true);   -- ne révèle PAS si la réponse est bonne avant la fin du temps
end $$;
