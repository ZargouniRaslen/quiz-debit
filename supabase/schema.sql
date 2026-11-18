-- ============ TABLES ============
create table if not exists questions (
  id int primary key, prompt text not null, options jsonb not null,
  correct int not null, explanation text not null
);
create table if not exists settings (key text primary key, value text not null);
insert into settings values ('admin_code', 'done') on conflict do nothing;  -- change with: update settings set value='monCode' where key='admin_code';

create table if not exists attempts (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('solo','binome')),
  name1 text not null, name2 text, group_no text,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  duration_ms int, score int, total int,
  late boolean not null default false
);
create table if not exists answers (
  attempt_id uuid references attempts(id) on delete cascade,
  question_id int references questions(id),
  choice int,                       -- 0=A, 1=B, 2=C ; null = sans réponse
  time_ms int not null default 0,   -- temps passé sur la page de la question
  is_correct boolean not null default false,
  primary key (attempt_id, question_id)
);

-- ============ SECURITY : le navigateur n'accède à rien directement ============
alter table questions enable row level security;
alter table settings  enable row level security;
alter table attempts  enable row level security;
alter table answers   enable row level security;
revoke all on questions, settings, attempts, answers from anon, authenticated;

-- ============ FUNCTIONS (seul point d'entrée du site) ============
create or replace function get_questions() returns jsonb
language sql security definer set search_path = public stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'prompt',prompt,'options',options) order by id),'[]'::jsonb) from questions
$$;

create or replace function start_attempt(p_kind text, p_name1 text, p_name2 text, p_group text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v attempts;
begin
  if lower(trim(coalesce(p_name1,''))) = (select value from settings where key='admin_code') then
    return jsonb_build_object('admin', true);
  end if;
  if length(trim(coalesce(p_name1,''))) < 2 then raise exception 'name_required'; end if;
  if p_kind = 'binome' and (length(trim(coalesce(p_name2,''))) < 2 or length(trim(coalesce(p_group,''))) < 1) then
    raise exception 'binome_incomplete';
  end if;
  insert into attempts(kind,name1,name2,group_no)
  values (p_kind, left(trim(p_name1),80), nullif(left(trim(coalesce(p_name2,'')),80),''), nullif(left(trim(coalesce(p_group,'')),10),''))
  returning * into v;
  return jsonb_build_object('id', v.id, 'started_at', v.started_at, 'now', now());
end $$;

create or replace function submit_attempt(p_id uuid, p_answers jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a attempts; sc int; tot int; el int;
begin
  select * into a from attempts where id = p_id for update;
  if not found then raise exception 'unknown_attempt'; end if;
  if a.finished_at is not null then
    return jsonb_build_object('score',a.score,'total',a.total,'duration_ms',a.duration_ms);
  end if;
  insert into answers(attempt_id,question_id,choice,time_ms,is_correct)
  select p_id, q.id, x.choice, greatest(0, least(coalesce(x.ms,0), 600000)), coalesce(x.choice = q.correct, false)
  from questions q
  left join jsonb_to_recordset(p_answers) as x(q int, choice int, ms int) on x.q = q.id;
  select count(*) filter (where is_correct), count(*) into sc, tot from answers where attempt_id = p_id;
  el := least(extract(epoch from now() - a.started_at) * 1000, 3600000)::int;
  update attempts set finished_at = now(), score = sc, total = tot,
         duration_ms = least(el, 300000), late = el > 330000 where id = p_id;
  return jsonb_build_object('score',sc,'total',tot,'duration_ms',least(el,300000));
end $$;

create or replace function admin_data(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if lower(trim(coalesce(p_code,''))) is distinct from (select value from settings where key='admin_code') then
    raise exception 'forbidden';
  end if;
  return jsonb_build_object(
    'questions', (select coalesce(jsonb_agg(to_jsonb(q) order by q.id),'[]'::jsonb) from questions q),
    'attempts',  (select coalesce(jsonb_agg(jsonb_build_object('id',id,'kind',kind,'name1',name1,'name2',name2,
                   'group_no',group_no,'score',score,'duration_ms',duration_ms,'late',late)),'[]'::jsonb)
                  from attempts where finished_at is not null),
    'answers',   (select coalesce(jsonb_agg(to_jsonb(a)),'[]'::jsonb) from answers a
                  join attempts t on t.id = a.attempt_id where t.finished_at is not null));
end $$;

grant execute on function get_questions(), start_attempt(text,text,text,text),
                          submit_attempt(uuid,jsonb), admin_data(text) to anon;

-- ============ VUE POUR LES NOTES : Table Editor > results ============
create or replace view results as
select rank() over (order by t.score desc, t.duration_ms asc) as rang,
  case when t.kind='binome' then t.name1||' & '||t.name2||' (groupe '||t.group_no||')' else t.name1 end as candidat,
  t.kind, t.score, t.total, round(t.duration_ms/1000.0,1) as duree_s, t.late as hors_delai,
  max(chr(65+a.choice)) filter (where a.question_id=1)  as q1,
  max(chr(65+a.choice)) filter (where a.question_id=2)  as q2,
  max(chr(65+a.choice)) filter (where a.question_id=3)  as q3,
  max(chr(65+a.choice)) filter (where a.question_id=4)  as q4,
  max(chr(65+a.choice)) filter (where a.question_id=5)  as q5,
  max(chr(65+a.choice)) filter (where a.question_id=6)  as q6,
  max(chr(65+a.choice)) filter (where a.question_id=7)  as q7,
  max(chr(65+a.choice)) filter (where a.question_id=8)  as q8,
  max(chr(65+a.choice)) filter (where a.question_id=9)  as q9,
  max(chr(65+a.choice)) filter (where a.question_id=10) as q10,
  t.finished_at
from attempts t join answers a on a.attempt_id = t.id
where t.finished_at is not null
group by t.id order by rang, t.finished_at;
revoke all on results from anon, authenticated;

-- ============ QUESTIONS (0=A, 1=B, 2=C) ============
insert into questions(id,prompt,options,correct,explanation) values
(1,'Relation directe entre Qm et Qv ?','["Qm = Qv / ρ","Qm = ρ · Qv","Qm = v · A"]',1,
 'Le débit massique (kg/s) est le débit volumique (m³/s) multiplié par la masse volumique (kg/m³) : Qm = ρ · Qv. Qv / ρ n''a pas la bonne unité, et v · A est simplement l''expression de Qv.'),
(2,'Régime pour Re = 8 000 ?','["Laminaire","Transitoire","Turbulent"]',2,
 'Au-delà de Re = 4 000, l''écoulement est turbulent (profil plat, très fréquent en industrie). Laminaire : Re < 2 000. Transitoire : entre 2 000 et 4 000.'),
(3,'Pourquoi le massique pour les gaz ?','["Les gaz n''ont pas de vitesse","Le volume varie avec P et T","C''est moins cher"]',1,
 'Un gaz est compressible : son volume, donc Qv, dépend fortement de la pression et de la température. Qm reste conservatif, la masse ne varie pas.'),
(4,'Quelle plage de Re correspond au régime transitoire ?','["2 000 – 4 000","Re < 2 000","Re > 4 000"]',0,
 'Entre 2 000 et 4 000 l''écoulement est instable, à éviter pour une mesure fiable. En dessous : laminaire ; au-dessus : turbulent.'),
(5,'1 bar est égal à :','["10³ Pa","10⁵ Pa","10⁷ Pa"]',1,
 '1 bar = 10⁵ Pa. À retenir aussi : 1 atm ≈ 1,013 bar.'),
(6,'Une température de 25 °C vaut :','["248,15 K","25 K","298,15 K"]',2,
 'T(K) = t(°C) + 273,15, donc 25 + 273,15 = 298,15 K.'),
(7,'Quelle technologie mesure directement un débit massique ?','["Coriolis (tubes vibrants)","Diaphragme","Vortex"]',0,
 'Le Coriolis (comme le massique thermique) mesure la masse directement. Le diaphragme et le vortex donnent un débit volumique.'),
(8,'La répétabilité d''un débitmètre est :','["L''écart entre valeur mesurée et valeur vraie","Le rapport Qmax / Qmin","La capacité à redonner le même résultat dans les mêmes conditions"]',2,
 'La première proposition définit la précision, la deuxième l''étendue de mesure (turndown). La répétabilité est la capacité à redonner le même résultat.'),
(9,'Un débitmètre de calibre 100 m³/h a une étendue de 10 : 1. Débit minimal mesurable avec la précision annoncée ?','["1 m³/h","10 m³/h","90 m³/h"]',1,
 'Étendue = Qmax / Qmin = 10, donc Qmin = 100 / 10 = 10 m³/h (de 10 % à 100 % du calibre).'),
(10,'Un diaphragme ou un Venturi mesure le débit grâce à :','["La pression différentielle ΔP","L''effet Coriolis","L''induction électromagnétique"]',0,
 'Les organes déprimogènes créent une chute de pression ΔP liée au débit : mesure volumique indirecte. Coriolis et induction (Faraday) sont d''autres principes.')
on conflict (id) do nothing;
