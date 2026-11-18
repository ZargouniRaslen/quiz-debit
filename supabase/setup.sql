-- =====================================================================
--  Quiz Débitmètres : INSTALLATION COMPLÈTE EN UN SEUL FICHIER
--  À utiliser sur une base Supabase NEUVE (premier lancement).
--  Supabase > SQL Editor > coller tout ce fichier > Run
--
--  Fonctionnalités :
--    • 1 à 200 questions par quiz
--    • Réponses autorisées pendant « Préparez-vous »
--    • Marge serveur : 3 secondes
--    • Pas de code animateur (tout compte connecté = animateur)
--    • Pas de code de groupe pour les binômes
--    • RPC list_my_quizzes / get_quiz / quiz_counts
--
--  ⚠ ATTENTION : l'étape 0 SUPPRIME toutes les tables et fonctions du schéma
--  "public". Les comptes Authentication ne sont pas touchés.
--  Sur une base neuve, c'est sans effet.
-- =====================================================================

-- ---------- 0. Remise à zéro ----------
do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'public' loop
    execute format('drop table if exists public.%I cascade', r.tablename);
  end loop;
  for r in
    select p.oid::regprocedure as sig from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('drop function if exists %s cascade', r.sig);
  end loop;
end $$;

-- =====================================================================
--  QUIZ LIVE (type Kahoot) : migration à exécuter dans Supabase > SQL Editor
--  Principe de sécurité conservé : le navigateur n'accède à AUCUNE table
--  directement (sauf lecture de ses propres quiz pour l'admin connecté).
--  Tout passe par des fonctions RPC "security definer".
-- =====================================================================

-- ---------- 1. Animateurs ----------
-- Pas de code secret : tout utilisateur connecté (Supabase Auth) est animateur.
-- Pour restreindre les inscriptions, désactivez "Allow new users to sign up" dans Authentication > Sign In / Providers.
create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
$$;

-- ---------- 2. Quiz et questions (créés par l'admin) ----------
create table if not exists quizzes (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references auth.users(id) on delete cascade default auth.uid(),
  title text not null check (length(trim(title)) between 1 and 120),
  default_time_s int not null default 15 check (default_time_s between 5 and 300),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists quiz_questions (
  id uuid primary key default gen_random_uuid(),
  quiz_id uuid not null references quizzes(id) on delete cascade,
  pos int not null check (pos between 1 and 200),
  prompt text not null check (length(trim(prompt)) > 0),
  options jsonb not null check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 3 and 4),
  correct int not null check (correct between 0 and 3),
  explanation text not null default '',
  time_s int check (time_s is null or time_s between 5 and 300),   -- null = durée par défaut du quiz
  unique (quiz_id, pos),
  check (correct < jsonb_array_length(options))
);

alter table quizzes        enable row level security;
alter table quiz_questions enable row level security;
revoke all on quizzes, quiz_questions from anon, authenticated;
grant select on quizzes, quiz_questions to authenticated;   -- lecture seule, filtrée par RLS ; l'écriture passe par save_quiz()

drop policy if exists quizzes_owner_read on quizzes;
create policy quizzes_owner_read on quizzes for select to authenticated
  using (owner = auth.uid() and is_admin());

drop policy if exists quiz_questions_owner_read on quiz_questions;
create policy quiz_questions_owner_read on quiz_questions for select to authenticated
  using (is_admin() and exists (select 1 from quizzes z where z.id = quiz_id and z.owner = auth.uid()));

-- Création / modification atomique d'un quiz de 1 à 200 questions
-- p_questions = [{prompt, options:[...3 ou 4...], correct:int, explanation:text, time_s:int|null}, ... xN]
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
  delete from quiz_questions where quiz_id = v_id and pos > v_i;   -- le quiz peut raccourcir
  return v_id;
end $$;

create or replace function delete_quiz(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  delete from quizzes where id = p_id and owner = auth.uid();   -- supprime aussi ses sessions et résultats
end $$;

-- Importe le quiz d'exemple « Débitmètres (exemple) » (13 questions) dans le compte de l'animateur connecté
create or replace function import_legacy_questions() returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  insert into quizzes(owner, title, default_time_s) values (auth.uid(), 'Débitmètres (exemple) 中国', 20) returning id into v_id;
  insert into quiz_questions(quiz_id, pos, prompt, options, correct, explanation)
  select v_id, t.o::int, t.e->>'prompt', t.e->'options', (t.e->>'correct')::int, t.e->>'explanation'
  from jsonb_array_elements($json$[
    {"prompt":"Quelle est la capitale de la Chine ?","options":["Shanghai","Pékin","Canton","Nankin"],"correct":1,"explanation":"Pékin (Beijing) est la capitale depuis 1949 ; Shanghai est la plus grande ville."},
    {"prompt":"Quelle dynastie a unifié la Chine en 221 av. J.-C. ?","options":["Les Han","Les Tang","Les Qin","Les Ming"],"correct":2,"explanation":"Qin Shi Huang, le Premier Empereur, a unifié les royaumes combattants. Le nom « Chine » viendrait de Qin."},
    {"prompt":"Quel animal est l'emblème naturel de la Chine ?","options":["Le tigre","Le yack","La grue","Le panda géant"],"correct":3,"explanation":"Le panda géant vit dans les montagnes du Sichuan, du Shaanxi et du Gansu."},
    {"prompt":"Quel est le plus long fleuve de Chine ?","options":["Le Yangzi (Yangtsé)","Le fleuve Jaune","Le Mékong","L'Amour"],"correct":0,"explanation":"Le Yangzi mesure environ 6 300 km, c'est le plus long fleuve d'Asie."},
    {"prompt":"Quel sommet, le plus haut du monde, est situé à la frontière entre la Chine et le Népal ?","options":["Le K2","L'Everest","Le Lhotse","Le Makalu"],"correct":1,"explanation":"L'Everest culmine à 8 849 m ; les Chinois l'appellent Qomolangma (Zhumulangma)."},
    {"prompt":"Comment appelle-t-on aussi le Nouvel An chinois ?","options":["La fête de la Mi-automne","La fête des Lanternes","La fête du Printemps","La fête des Bateaux-dragons"],"correct":2,"explanation":"La fête du Printemps (Chunjie) ouvre l'année lunaire ; la fête des Lanternes la clôt 15 jours plus tard."},
    {"prompt":"Quelle pâtisserie mange-t-on traditionnellement à la fête de la Mi-automne ?","options":["Le gâteau de lune","Le jiaozi","Le zongzi","Le mantou"],"correct":0,"explanation":"Le gâteau de lune (yuebing) symbolise la pleine lune et la réunion familiale."},
    {"prompt":"Laquelle de ces inventions est d'origine chinoise ?","options":["La machine à vapeur","Le télégraphe","La pile électrique","Le papier"],"correct":3,"explanation":"Le papier, la poudre, la boussole et l'imprimerie sont les « quatre grandes inventions » chinoises."},
    {"prompt":"Quelle est la longueur totale approximative de la Grande Muraille, selon le relevé officiel de 2012 ?","options":["2 000 km","8 850 km","21 000 km","50 000 km"],"correct":2,"explanation":"Le relevé de 2012 a estimé l'ensemble des murailles de toutes les époques à environ 21 196 km."},
    {"prompt":"Quelle est la langue la plus parlée en Chine ?","options":["Le mandarin","Le cantonais","Le shanghaïen (wu)","Le hakka"],"correct":0,"explanation":"Le mandarin (putonghua) est la langue officielle et la plus parlée au monde en langue maternelle."},
    {"prompt":"Près de quelle ville se trouve l'armée de terre cuite de l'empereur Qin ?","options":["Pékin","Chengdu","Xi'an","Luoyang"],"correct":2,"explanation":"Les quelque 8 000 soldats de terre cuite ont été découverts en 1974 près de Xi'an, dans le Shaanxi."},
    {"prompt":"Quelle boisson est originaire de Chine ?","options":["Le café","Le thé","Le cacao"],"correct":1,"explanation":"Selon la légende, l'empereur Shennong aurait découvert le thé il y a près de 5 000 ans."},
    {"prompt":"Lequel de ces animaux ne fait PAS partie du zodiaque chinois ?","options":["Le dragon","Le tigre","Le rat","Le chat"],"correct":3,"explanation":"Les 12 animaux sont : rat, bœuf, tigre, lapin, dragon, serpent, cheval, chèvre, singe, coq, chien, cochon."}
  ]$json$::jsonb) with ordinality as t(e, o);
  return v_id;
end $$;

-- ---------- 3. Sessions en direct, joueurs, réponses ----------
create table if not exists sessions (
  id uuid primary key default gen_random_uuid(),
  quiz_id uuid not null references quizzes(id) on delete cascade,
  host uuid not null references auth.users(id) on delete cascade,
  code text not null check (code ~ '^[A-Z]{4}$'),
  status text not null default 'lobby' check (status in ('lobby','question','results','scores','finished')),
  current_pos int not null default 0,              -- 0 = pas commencé, sinon 1..N
  question_started_at timestamptz,
  question_ends_at timestamptz,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
-- Un code n'est unique que parmi les sessions non terminées (il peut être réutilisé ensuite)
create unique index if not exists sessions_active_code on sessions(code) where status <> 'finished';

create table if not exists players (
  id uuid primary key default gen_random_uuid(),      -- sert aussi de "jeton" secret côté navigateur
  session_id uuid not null references sessions(id) on delete cascade,
  kind text not null check (kind in ('solo','binome')),
  name1 text not null,
  name2 text,
  display_name text generated always as (coalesce(name1 || ' & ' || name2, name1)) stored,
  joined_at timestamptz not null default now()
);
create unique index if not exists players_unique_name on players(session_id, lower(display_name));

create table if not exists player_answers (
  session_id uuid not null references sessions(id) on delete cascade,
  player_id uuid not null references players(id) on delete cascade,
  question_id uuid not null references quiz_questions(id) on delete cascade,
  pos int not null,
  choice int,                                -- null = pas de réponse
  is_correct boolean not null default false,
  time_ms int not null default 0,            -- mesuré par le serveur ; sans réponse = durée complète
  points int not null default 0,
  answered_at timestamptz not null default now(),
  primary key (player_id, question_id)
);
create index if not exists player_answers_session_pos on player_answers(session_id, pos);

alter table sessions        enable row level security;
alter table players         enable row level security;
alter table player_answers  enable row level security;
revoke all on sessions, players, player_answers from anon, authenticated;

-- ---------- 4. Fonctions internes ----------
create or replace function gen_code() returns text
language plpgsql volatile set search_path = public as $$
declare v_alpha text := 'ABCDEFGHJKLMNPQRSTUVWXYZ'; v_c text; v_i int;   -- sans I ni O (confusion avec 1 et 0)
begin
  loop
    v_c := '';
    for v_i in 1..4 loop
      v_c := v_c || substr(v_alpha, 1 + floor(random() * length(v_alpha))::int, 1);
    end loop;
    exit when not exists (select 1 from sessions where code = v_c and status <> 'finished');
  end loop;
  return v_c;
end $$;

-- Classement : points desc, puis bonnes réponses desc, puis temps total asc
create or replace function session_leaderboard(p_session uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(r) order by r.rank, r.name), '[]'::jsonb)
  from (
    select pl.id as player_id, pl.display_name as name, pl.kind,
           coalesce(sum(pa.points), 0)::int as points,
           (count(*) filter (where pa.is_correct))::int as correct,
           coalesce(sum(pa.time_ms), 0)::int as time_ms,
           rank() over (order by coalesce(sum(pa.points), 0) desc,
                                 count(*) filter (where pa.is_correct) desc,
                                 coalesce(sum(pa.time_ms), 0) asc) as rank
    from players pl
    left join player_answers pa on pa.player_id = pl.id
    where pl.session_id = p_session
    group by pl.id
  ) r
$$;

-- ---------- 5. Côté admin ----------
create or replace function create_session(p_quiz uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_code text;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  if not exists (select 1 from quizzes where id = p_quiz and owner = auth.uid()) then raise exception 'forbidden'; end if;
  if (select count(*) from quiz_questions where quiz_id = p_quiz) < 1 then raise exception 'need_questions'; end if;
  -- nettoyage : les sessions abandonnées depuis plus de 12 h libèrent leur code
  update sessions set status = 'finished', finished_at = now()
   where status <> 'finished' and created_at < now() - interval '12 hours';
  v_code := gen_code();
  insert into sessions(quiz_id, host, code) values (p_quiz, auth.uid(), v_code) returning id into v_id;
  return jsonb_build_object('session_id', v_id, 'code', v_code);
end $$;

-- Machine à états. p_from / p_from_pos rendent l'appel idempotent
-- (double clic, minuteur + clic simultanés) : si l'état a déjà changé, rien ne se passe.
-- lobby -> question(1) -> results(1) -> scores(1) -> question(2) -> ... -> results(N) -> finished
create or replace function host_advance(p_session uuid, p_from text default null, p_from_pos int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_s sessions; v_total int; v_q quiz_questions; v_sec int; v_lim_ms int;
  c_lead interval := interval '3 seconds';    -- compte à rebours "Préparez-vous" avant chaque question
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  select * into v_s from sessions where id = p_session and host = auth.uid() for update;
  if not found then raise exception 'forbidden'; end if;

  if p_from is not null and (v_s.status <> p_from or (p_from_pos is not null and v_s.current_pos <> p_from_pos)) then
    return jsonb_build_object('status', v_s.status, 'pos', v_s.current_pos, 'noop', true);
  end if;

  select count(*) into v_total from quiz_questions where quiz_id = v_s.quiz_id;

  if v_s.status in ('lobby', 'scores') then
    if v_s.status = 'lobby' and not exists (select 1 from players where session_id = v_s.id) then
      raise exception 'no_players';
    end if;
    select * into v_q from quiz_questions where quiz_id = v_s.quiz_id and pos = v_s.current_pos + 1;
    if not found then
      update sessions set status = 'finished', finished_at = now() where id = v_s.id;
    else
      select coalesce(v_q.time_s, z.default_time_s) into v_sec from quizzes z where z.id = v_s.quiz_id;
      update sessions
         set status = 'question', current_pos = v_s.current_pos + 1,
             question_started_at = now() + c_lead,
             question_ends_at = now() + c_lead + make_interval(secs => v_sec)
       where id = v_s.id;
    end if;

  elsif v_s.status = 'question' then
    -- clôture : les joueurs sans réponse reçoivent 0 point et le temps complet
    v_lim_ms := round(extract(epoch from (v_s.question_ends_at - v_s.question_started_at)) * 1000)::int;
    select * into v_q from quiz_questions where quiz_id = v_s.quiz_id and pos = v_s.current_pos;
    insert into player_answers(session_id, player_id, question_id, pos, choice, is_correct, time_ms, points)
    select v_s.id, pl.id, v_q.id, v_s.current_pos, null, false, v_lim_ms, 0
      from players pl
     where pl.session_id = v_s.id
       and not exists (select 1 from player_answers pa where pa.player_id = pl.id and pa.question_id = v_q.id);
    update sessions set status = 'results' where id = v_s.id;

  elsif v_s.status = 'results' then
    if v_s.current_pos >= v_total then
      update sessions set status = 'finished', finished_at = now() where id = v_s.id;
    else
      update sessions set status = 'scores' where id = v_s.id;
    end if;
  end if;

  select * into v_s from sessions where id = p_session;
  return jsonb_build_object('status', v_s.status, 'pos', v_s.current_pos);
end $$;

create or replace function end_session(p_session uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  update sessions set status = 'finished', finished_at = now() where id = p_session and host = auth.uid();
end $$;

create or replace function kick_player(p_player uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  delete from players pl using sessions s
   where pl.id = p_player and s.id = pl.session_id and s.host = auth.uid() and s.status = 'lobby';
end $$;

-- Tout ce dont l'écran admin a besoin (appelée toutes les ~1 s + à chaque événement temps réel)
create or replace function host_state(p_session uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_s sessions; v_z quizzes; v_q quiz_questions; v_total int; v_res jsonb;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  select * into v_s from sessions where id = p_session and host = auth.uid();
  if not found then raise exception 'forbidden'; end if;
  select * into v_z from quizzes where id = v_s.quiz_id;
  select count(*) into v_total from quiz_questions where quiz_id = v_s.quiz_id;

  v_res := jsonb_build_object(
    'status', v_s.status, 'pos', v_s.current_pos, 'total', v_total, 'code', v_s.code,
    'title', v_z.title, 'now', now(),
    'player_count', (select count(*) from players where session_id = v_s.id));

  if v_s.status = 'lobby' then
    v_res := v_res || jsonb_build_object('players',
      (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', display_name, 'kind', kind) order by joined_at), '[]'::jsonb)
         from players where session_id = v_s.id));
  end if;

  if v_s.status in ('question', 'results', 'scores') then
    select * into v_q from quiz_questions where quiz_id = v_s.quiz_id and pos = v_s.current_pos;
    v_res := v_res || jsonb_build_object(
      'question', jsonb_build_object('id', v_q.id, 'prompt', v_q.prompt, 'options', v_q.options),
      'starts_at', v_s.question_started_at, 'ends_at', v_s.question_ends_at,
      'time_s', round(extract(epoch from (v_s.question_ends_at - v_s.question_started_at)))::int,
      'answered_count', (select count(*) from player_answers pa
                          where pa.session_id = v_s.id and pa.pos = v_s.current_pos and pa.choice is not null));
  end if;

  if v_s.status in ('results', 'scores') then
    v_res := v_res || jsonb_build_object(
      'correct', v_q.correct,
      'explanation', v_q.explanation,
      -- nombre de réponses par choix : {"0": 4, "2": 7}
      'choice_counts', (select coalesce(jsonb_object_agg(t.choice::text, t.n), '{}'::jsonb)
                          from (select pa.choice, count(*) as n from player_answers pa
                                 where pa.session_id = v_s.id and pa.pos = v_s.current_pos and pa.choice is not null
                                 group by pa.choice) t),
      -- classement de la question : bonnes réponses d'abord, puis du plus rapide au plus lent
      'results', (select coalesce(jsonb_agg(jsonb_build_object(
                           'player_id', pl.id, 'name', pl.display_name, 'choice', pa.choice,
                           'is_correct', pa.is_correct, 'time_ms', pa.time_ms, 'points', pa.points)
                         order by pa.is_correct desc, pa.points desc, pa.time_ms asc, pl.display_name), '[]'::jsonb)
                    from player_answers pa join players pl on pl.id = pa.player_id
                   where pa.session_id = v_s.id and pa.pos = v_s.current_pos));
  end if;

  if v_s.status in ('scores', 'finished') then
    v_res := v_res || jsonb_build_object('leaderboard', session_leaderboard(v_s.id));
  end if;
  return v_res;
end $$;

create or replace function list_my_sessions() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'id', x.id, 'code', x.code, 'title', z.title, 'status', x.status,
            'created_at', x.created_at, 'finished_at', x.finished_at,
            'players', (select count(*) from players pl where pl.session_id = x.id)
          ) order by x.created_at desc), '[]'::jsonb)
          from sessions x join quizzes z on z.id = x.quiz_id where x.host = auth.uid());
end $$;

-- Données complètes pour le PDF (classement + détail par groupe et par question)
create or replace function session_report(p_session uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_s sessions; v_z quizzes;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  select * into v_s from sessions where id = p_session and host = auth.uid();
  if not found then raise exception 'forbidden'; end if;
  select * into v_z from quizzes where id = v_s.quiz_id;
  return jsonb_build_object(
    'session', jsonb_build_object('id', v_s.id, 'code', v_s.code, 'status', v_s.status,
                                  'created_at', v_s.created_at, 'finished_at', v_s.finished_at),
    'title', v_z.title,
    'questions', (select coalesce(jsonb_agg(jsonb_build_object('pos', pos, 'prompt', prompt, 'options', options, 'correct', correct) order by pos), '[]'::jsonb)
                    from quiz_questions where quiz_id = v_s.quiz_id),
    'leaderboard', session_leaderboard(v_s.id),
    'answers', (select coalesce(jsonb_agg(jsonb_build_object('player_id', player_id, 'pos', pos, 'choice', choice,
                                  'is_correct', is_correct, 'time_ms', time_ms, 'points', points)), '[]'::jsonb)
                  from player_answers where session_id = v_s.id));
end $$;

-- ---------- 6. Côté joueur (anonyme) ----------
create or replace function join_session(p_code text, p_kind text, p_name1 text, p_name2 text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_s sessions; v_p players;
  v_n1 text := trim(coalesce(p_name1, ''));
  v_n2 text := nullif(trim(coalesce(p_name2, '')), '');
begin
  if p_kind not in ('solo', 'binome') then raise exception 'bad_kind'; end if;
  if length(v_n1) < 2 then raise exception 'name_required'; end if;
  if p_kind = 'binome' and (v_n2 is null or length(v_n2) < 2) then raise exception 'binome_incomplete'; end if;
  if p_kind = 'solo' then v_n2 := null; end if;

  select * into v_s from sessions where code = upper(trim(coalesce(p_code, ''))) and status <> 'finished';
  if not found then raise exception 'unknown_code'; end if;
  if v_s.status <> 'lobby' then raise exception 'already_started'; end if;

  begin
    insert into players(session_id, kind, name1, name2)
    values (v_s.id, p_kind, left(v_n1, 60), left(v_n2, 60)) returning * into v_p;
  exception when unique_violation then
    raise exception 'name_taken';
  end;
  return jsonb_build_object('player_id', v_p.id, 'session_id', v_s.id);
end $$;

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
  if v_s.status <> 'question' or now() > v_s.question_ends_at + interval '3 seconds' then
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

-- Tout ce dont l'écran joueur a besoin (appelée toutes les ~2 s + à chaque événement temps réel)
create or replace function player_state(p_player uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_p players; v_s sessions; v_q quiz_questions; v_a player_answers;
  v_total int; v_res jsonb; v_lb jsonb; v_me jsonb;
begin
  select * into v_p from players where id = p_player;
  if not found then return jsonb_build_object('status', 'gone'); end if;
  select * into v_s from sessions where id = v_p.session_id;
  select count(*) into v_total from quiz_questions where quiz_id = v_s.quiz_id;

  v_res := jsonb_build_object('status', v_s.status, 'pos', v_s.current_pos, 'total', v_total, 'now', now(),
                              'name', v_p.display_name, 'code', v_s.code,
                              'player_count', (select count(*) from players where session_id = v_s.id));

  if v_s.status = 'question' then
    select * into v_q from quiz_questions where quiz_id = v_s.quiz_id and pos = v_s.current_pos;
    select * into v_a from player_answers where player_id = v_p.id and question_id = v_q.id;
    v_res := v_res || jsonb_build_object(
      'question', jsonb_build_object('id', v_q.id, 'prompt', v_q.prompt, 'options', v_q.options),
      'starts_at', v_s.question_started_at, 'ends_at', v_s.question_ends_at,
      'answered', found, 'my_choice', v_a.choice);
  end if;

  if v_s.status in ('results', 'scores', 'finished') and v_s.current_pos > 0 then
    select * into v_q from quiz_questions where quiz_id = v_s.quiz_id and pos = v_s.current_pos;
    select * into v_a from player_answers where player_id = v_p.id and question_id = v_q.id;
    v_res := v_res || jsonb_build_object('last', jsonb_build_object(
      'correct_choice', v_q.correct, 'explanation', v_q.explanation, 'options', v_q.options,
      'my_choice', v_a.choice, 'is_correct', coalesce(v_a.is_correct, false),
      'points', coalesce(v_a.points, 0), 'time_ms', v_a.time_ms));
  end if;

  if v_s.status in ('results', 'scores', 'finished') then
    v_lb := session_leaderboard(v_s.id);
    select e into v_me from jsonb_array_elements(v_lb) e where e->>'player_id' = v_p.id::text;
    v_res := v_res || jsonb_build_object('me', v_me);
    if v_s.status = 'scores' then
      v_res := v_res || jsonb_build_object('leaderboard',
        (select coalesce(jsonb_agg(t.e order by t.ord), '[]'::jsonb)
           from (select x.e, x.ord from jsonb_array_elements(v_lb) with ordinality as x(e, ord) order by x.ord limit 5) t));
    elsif v_s.status = 'finished' then
      v_res := v_res || jsonb_build_object('leaderboard', v_lb);
    end if;
  end if;
  return v_res;
end $$;

-- ---------- 7. Droits d'exécution ----------
-- Par défaut Postgres autorise PUBLIC à exécuter toute fonction : on retire tout, puis on accorde au cas par cas.
revoke all on function
  is_admin(), save_quiz(uuid,text,int,jsonb), delete_quiz(uuid), import_legacy_questions(),
  gen_code(), session_leaderboard(uuid), create_session(uuid), host_advance(uuid,text,int), end_session(uuid),
  kick_player(uuid), host_state(uuid), list_my_sessions(), session_report(uuid),
  join_session(text,text,text,text), submit_answer(uuid,int), player_state(uuid)
from public, anon, authenticated;

-- Joueurs anonymes (page d'accueil, non connectés)
grant execute on function join_session(text,text,text,text), submit_answer(uuid,int), player_state(uuid) to anon, authenticated;
-- Admin connecté (chaque fonction revérifie is_admin() en interne)
grant execute on function
  is_admin(), save_quiz(uuid,text,int,jsonb), delete_quiz(uuid), import_legacy_questions(),
  create_session(uuid), host_advance(uuid,text,int), end_session(uuid), kick_player(uuid),
  host_state(uuid), list_my_sessions(), session_report(uuid)
to authenticated;
-- gen_code() et session_leaderboard() restent internes (appelées uniquement par les fonctions ci-dessus).

-- ---------- Lecture des quiz par RPC (voir aussi migration_quizzes.sql) ----------
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
