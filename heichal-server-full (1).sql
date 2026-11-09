-- =====================================================================
--  היכל המשנה · הקמת השרת מאפס (קובץ אחד)
--  מריצים פעם אחת בפרויקט Supabase חדש וריק:
--  SQL Editor ← New query ← מדביקים הכול ← Run.
--  הקובץ בנוי משלושה חלקים: א. טבלאות בסיס · ב. עדכון שרת 1 · ג. הרשאות ופונקציות משלימות.
--  בטוח להרצה חוזרת.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ================= חלק א: טבלאות בסיס =================

create table if not exists public.learners (
  id text primary key default (gen_random_uuid())::text,
  name text not null,
  idn text,
  phone text default '',
  email text default '',
  phone2 text default '',
  city text default '',
  addr text default '',
  remind jsonb,
  code_hash text,
  created_at timestamptz not null default now()
);

create table if not exists public.cycles (
  id text primary key,
  name text not null default '',
  version integer default 1,
  max integer default 0,
  status text not null default 'open',
  show boolean default true,
  start date,
  labels text[] default '{}'::text[],
  self_confirm boolean default true,
  weeks_back integer default 1
);

create table if not exists public.regs (
  id text primary key default (gen_random_uuid())::text,
  cid text not null,
  lid text not null,
  units text[] default '{}'::text[],
  pace text default 'weekly',
  ts timestamptz not null default now(),
  confirms jsonb default '[]'::jsonb,
  ch text[] default '{}'::text[]
);
create index if not exists regs_lid_idx on public.regs (lid);
create index if not exists regs_cid_idx on public.regs (cid);

create table if not exists public.reg_units (
  reg_id text not null references public.regs(id) on delete cascade,
  cid text not null,
  unit text not null
);

create table if not exists public.settings (
  key text primary key,
  value jsonb
);

create table if not exists public.campaigns (
  id text primary key,
  title text default '',
  season text default '',
  tractates text default '',
  descr text default '',
  exam text default '',
  status text not null default 'open',
  show boolean default true
);

create table if not exists public.msgs (
  id text primary key,
  sec text default '',
  title text default '',
  text text default '',
  img text default '',
  popup boolean default false,
  ts timestamptz not null default now()
);

create table if not exists public.winners (
  id text primary key,
  title text default '',
  names text[] default '{}'::text[],
  ts timestamptz not null default now()
);

create table if not exists public.inbox (
  id text primary key default (gen_random_uuid())::text,
  name text default '',
  phone text default '',
  topic text default '',
  text text default '',
  ts timestamptz not null default now(),
  done boolean default false
);

create table if not exists public.login_attempts (
  id bigserial primary key,
  idn text not null,
  ts timestamptz not null default now()
);
create index if not exists login_attempts_idn_idx on public.login_attempts (idn, ts);

create table if not exists public.learner_sessions (
  token text primary key default replace((gen_random_uuid())::text || (gen_random_uuid())::text, '-', ''),
  lid text not null,
  created_at timestamptz not null default now()
);
create index if not exists learner_sessions_lid_idx on public.learner_sessions (lid);

-- מנהלים: מי שנכנס עם חשבון (Authentication) והמייל שלו ברשימה הזו
create table if not exists public.admins (
  email text primary key
);

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from admins where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))) $$;

-- כניסת לומד: מחרוזת כניסה (token) שנשמרת בדפדפן, בתוקף 90 יום
create or replace function public._new_session(p_lid text) returns text
language plpgsql security definer set search_path to 'public' as $$
declare t text;
begin
  delete from learner_sessions where created_at < now() - interval '90 days';
  insert into learner_sessions (lid) values (p_lid) returning token into t;
  return t;
end $$;

create or replace function public._lid(p_token text) returns text
language sql stable security definer set search_path to 'public' as $$
  select lid from learner_sessions where token = p_token and created_at > now() - interval '90 days' $$;

-- יחידות רשומות: טבלת עזר שמתעדכנת אוטומטית מההרשמות
create or replace function public.sync_reg_units() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  delete from reg_units where reg_id = new.id;
  insert into reg_units (reg_id, cid, unit)
    select new.id, new.cid, u from unnest(coalesce(new.units, '{}'::text[])) as u;
  return new;
end $$;


-- ================= חלק ב: עדכון שרת 1 (כמו שהיה) =================

-- =====================================================================
--  היכל המשנה · עדכון שרת 1
--  מביא את השרת להתאמה עם האתר (index.html) של 30.10.2026.
--  מריצים פעם אחת ב־Supabase ← SQL Editor ← New query ← Run.
--  בטוח להרצה חוזרת: לא מוחק נתונים קיימים, רק מוסיף ומעדכן.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- 1. עמודות חדשות בטבלאות קיימות ----------

-- לומדים: כניסה במספר זהות בלבד, ולכן הקוד כבר לא חובה
alter table public.learners alter column code_hash drop not null;
alter table public.learners add column if not exists status text default '';
alter table public.learners add column if not exists shul   text default '';

-- מחזורים
alter table public.cycles add column if not exists limit_hours  integer default 0;
alter table public.cycles add column if not exists opened_at    timestamptz;
alter table public.cycles add column if not exists confirm_mode text default 'all';
alter table public.cycles add column if not exists kind         text default 'reopen';
alter table public.cycles add column if not exists period_weeks integer;
alter table public.cycles add column if not exists exit_weeks   integer;
alter table public.cycles add column if not exists sd           text;          -- תמהיל: הסדר של המחזור
alter table public.cycles add column if not exists mix_id       text;
alter table public.cycles add column if not exists mix_name     text;
alter table public.cycles add column if not exists by_init      text;          -- מי פתח: admin / מזהה יוזם
alter table public.cycles add column if not exists created_at   timestamptz default now();
alter table public.cycles add column if not exists auto_next    boolean default false;
alter table public.cycles add column if not exists auto_from    text;
alter table public.cycles add column if not exists next_id      text;
alter table public.cycles add column if not exists ded          text default '';
alter table public.cycles add column if not exists min_reg      jsonb;

-- הרשמות
alter table public.regs add column if not exists ch_ts       jsonb  default '{}'::jsonb;
alter table public.regs add column if not exists jp          integer default 0;
alter table public.regs add column if not exists exit_period integer;
alter table public.regs add column if not exists left_units  text[] default '{}'::text[];

-- זוכים
alter table public.winners add column if not exists grp   text default '';
alter table public.winners add column if not exists prize text default '';

-- ---------- 2. טבלאות חדשות ----------

create table if not exists public.waitlist (
  id text primary key default (gen_random_uuid())::text,
  lid text not null,
  cid text default '',
  version integer default 1,
  seder text default '',
  prefs text[] default '{}'::text[],
  only_first boolean default false,
  note text default '',
  plan text default '',
  status text not null default 'waiting',
  assigned text default '',
  ts timestamptz not null default now()
);

create table if not exists public.activity (
  id bigserial primary key,
  lid text,
  action text not null,
  detail text default '',
  ts timestamptz not null default now()
);

create table if not exists public.exams (
  id bigint primary key,
  tractate text not null,
  chapter text not null,
  ctype integer not null default 1,
  type_name text default '',
  ord bigint default 0,
  open boolean default true
);
create table if not exists public.exam_questions (
  id bigint primary key,
  exam_id bigint not null references public.exams(id) on delete cascade,
  text text not null,
  ord integer default 0,
  multi boolean default false
);
alter table public.exam_questions add column if not exists multi boolean default false;
create table if not exists public.exam_answers (
  id bigint primary key,
  qid bigint not null references public.exam_questions(id) on delete cascade,
  text text not null,
  ord integer default 0
);
create table if not exists public.exam_correct (
  qid bigint not null references public.exam_questions(id) on delete cascade,
  aid bigint not null references public.exam_answers(id) on delete cascade,
  primary key (qid, aid)
);
create table if not exists public.exam_results (
  id bigserial primary key,
  lid text not null,
  exam_id bigint not null,
  score integer not null default 0,
  total integer not null default 0,
  bonus integer not null default 0,
  answers jsonb default '{}'::jsonb,
  texts jsonb default '{}'::jsonb,
  ts timestamptz not null default now(),
  unique (lid, exam_id)
);

-- ---------- 3. הרשאות (RLS) ----------

alter table public.waitlist add column if not exists plan text default '';
alter table public.waitlist       enable row level security;
alter table public.activity       enable row level security;
alter table public.exams          enable row level security;
alter table public.exam_questions enable row level security;
alter table public.exam_answers   enable row level security;
alter table public.exam_correct   enable row level security;
alter table public.exam_results   enable row level security;

do $$
declare t text;
begin
  foreach t in array array['waitlist','activity','exams','exam_questions','exam_answers','exam_correct','exam_results'] loop
    execute format('drop policy if exists admin_all on public.%I', t);
    execute format('create policy admin_all on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t);
  end loop;
end $$;

-- המבחנים, השאלות והתשובות גלויים לכולם. התשובות הנכונות והציונים – רק למנהל.
drop policy if exists pub_read on public.exams;
create policy pub_read on public.exams for select to anon, authenticated using (true);
drop policy if exists pub_read on public.exam_questions;
create policy pub_read on public.exam_questions for select to anon, authenticated using (true);
drop policy if exists pub_read on public.exam_answers;
create policy pub_read on public.exam_answers for select to anon, authenticated using (true);

-- הגדרות: גלויות לציבור, חוץ מהגדרות רגישות (סיסמאות מנהלי משנה, קודי יוזמים)
drop policy if exists pub_read on public.settings;
create policy pub_read on public.settings for select to anon, authenticated
  using (key not in ('subs', 'initiators', 'invites', 'privCodes'));

-- ---------- 4. יחידות תפוסות ----------

create unique index if not exists reg_units_cid_unit on public.reg_units (cid, unit);

drop trigger if exists regs_sync_units on public.regs;
create trigger regs_sync_units after insert or update of units, cid on public.regs
  for each row execute function public.sync_reg_units();

create or replace function public.del_reg_units() returns trigger language plpgsql as $$
begin delete from public.reg_units where reg_id = old.id; return old; end $$;
drop trigger if exists regs_del_units on public.regs;
create trigger regs_del_units after delete on public.regs
  for each row execute function public.del_reg_units();

-- שבוע ומחזור נוכחיים של מחזור (לפי שעון ישראל)
create or replace function public._week_idx(c public.cycles) returns integer language sql stable as $$
  select floor((((now() at time zone 'Asia/Jerusalem')::date - c.start))::numeric / 7)::int $$;
create or replace function public._pw(c public.cycles) returns integer language sql stable as $$
  select greatest(coalesce(c.period_weeks, 1), 1) $$;
create or replace function public._cur_period(c public.cycles) returns integer language sql stable as $$
  select case when public._week_idx(c) < 0 then 0 else public._week_idx(c) / public._pw(c) end $$;
create or replace function public._join_period(c public.cycles) returns integer language sql stable as $$
  select case when c.kind <> 'rolling' or public._week_idx(c) < 0 then 0
              when public._week_idx(c) % public._pw(c) = 0 then public._week_idx(c) / public._pw(c)
              else public._week_idx(c) / public._pw(c) + 1 end $$;

-- אם taken_units היה טבלה ולא תצוגה – מחליפים אותו בתצוגה
do $$ begin
  if exists (select 1 from pg_tables where schemaname = 'public' and tablename = 'taken_units') then
    execute 'drop table public.taken_units';
  end if;
end $$;

-- היחידות שתפוסות כרגע (בלי שמות). מי שיצא מחבורה קבועה – היחידות שלו מתפנות
create or replace view public.taken_units as
  select ru.cid, ru.unit
  from public.reg_units ru
  join public.regs r on r.id = ru.reg_id
  join public.cycles c on c.id = ru.cid
  where c.kind <> 'rolling' or r.exit_period is null or r.exit_period >= public._cur_period(c);
grant select on public.taken_units to anon, authenticated;

-- ---------- 5. פונקציות הלומד ----------

create or replace function public._act(p_lid text, p_action text, p_detail text) returns void
language sql security definer set search_path to 'public' as $$
  insert into activity (lid, action, detail) values (p_lid, p_action, left(coalesce(p_detail,''), 500)) $$;

create or replace function public._learner_json(p_lid text) returns jsonb
language sql security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'learner', (select jsonb_build_object('id',l.id,'name',l.name,'idn',l.idn,'phone',l.phone,'email',l.email,'phone2',l.phone2,
                 'city',l.city,'addr',l.addr,'remind',l.remind,'status',l.status,'shul',l.shul) from learners l where l.id = p_lid),
    'regs', coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'cid',r.cid,'lid',r.lid,'units',to_jsonb(r.units),'pace',r.pace,
                 'ts',(extract(epoch from r.ts)*1000)::bigint,'confirms',to_jsonb(r.confirms),'ch',to_jsonb(r.ch),'ch_ts',coalesce(r.ch_ts,'{}'::jsonb),
                 'jp',coalesce(r.jp,0),'exit_period',r.exit_period,'left_units',to_jsonb(coalesce(r.left_units,'{}'::text[]))) order by r.ts)
               from regs r where r.lid = p_lid), '[]'::jsonb),
    'waits', coalesce((select jsonb_agg(to_jsonb(w) order by w.ts) from waitlist w where w.lid = p_lid), '[]'::jsonb))
$$;

-- כניסה: לפי הגדרת המנהל (loginMode) – מספר זהות בלבד / עם 4 ספרות אחרונות של הטלפון / עם קוד אישי
drop function if exists public.learner_id_login(text);
create or replace function public.learner_id_login(p_idn text, p_pin text default null) returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare l learners; v text := regexp_replace(coalesce(p_idn,''), '\D', '', 'g'); mode text; pin text := regexp_replace(coalesce(p_pin,''), '\D', '', 'g');
begin
  if length(v) < 5 then raise exception 'bad_id'; end if;
  if (select count(*) from login_attempts where idn = v and ts > now() - interval '15 minutes') >= 20 then raise exception 'locked'; end if;
  select * into l from learners where lpad(regexp_replace(coalesce(idn,''), '\D', '', 'g'), 9, '0') = lpad(v, 9, '0') limit 1;
  if l.id is null then insert into login_attempts (idn) values (v); raise exception 'not_found'; end if;
  mode := coalesce((select value #>> '{}' from settings where key = 'loginMode'),
                   case when coalesce((select value #>> '{}' from settings where key = 'loginCode'),'false') = 'true' then 'pin' else 'id' end);
  if mode = 'phone4' then
    if right(regexp_replace(coalesce(l.phone,''), '\D', '', 'g'), 4) <> pin or length(pin) <> 4 then
      insert into login_attempts (idn) values (v); raise exception 'bad_phone4'; end if;
  elsif mode = 'pin' then
    if pin !~ '^\d{4}$' then raise exception 'bad_code'; end if;
    if l.code_hash is null then update learners set code_hash = crypt(pin, gen_salt('bf')) where id = l.id;   -- כניסה ראשונה: הקוד נשמר
    elsif l.code_hash <> crypt(pin, l.code_hash) then insert into login_attempts (idn) values (v); raise exception 'bad_credentials'; end if;
  end if;
  delete from login_attempts where idn = v;
  perform public._act(l.id, 'כניסה', '');
  return public._learner_json(l.id) || jsonb_build_object('token', public._new_session(l.id));
end $$;

-- הרשמה (בלי קוד)
create or replace function public.learner_register(p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare v_lid text; v_idn text := regexp_replace(coalesce(p->>'idn',''), '\D', '', 'g');
begin
  if coalesce(length(p->>'name'),0) < 2 or length(v_idn) < 5 then raise exception 'bad_input'; end if;
  if exists (select 1 from learners where lpad(regexp_replace(coalesce(idn,''), '\D', '', 'g'), 9, '0') = lpad(v_idn, 9, '0')) then raise exception 'exists'; end if;
  insert into learners (name, idn, code_hash, phone, email, phone2, city, addr, remind, status, shul)
  values (left(p->>'name',100), v_idn, null, left(coalesce(p->>'phone',''),30), left(coalesce(p->>'email',''),120),
          left(coalesce(p->>'phone2',''),30), left(coalesce(p->>'city',''),80), left(coalesce(p->>'addr',''),160), p->'remind',
          left(coalesce(p->>'status',''),40), left(coalesce(p->>'shul',''),120))
  returning id into v_lid;
  perform public._act(v_lid, 'הרשמה', '');
  if p ? 'cid' and jsonb_array_length(coalesce(p->'units','[]'::jsonb)) > 0 then
    perform public._do_reg(v_lid, p->>'cid', array(select jsonb_array_elements_text(p->'units')), p->>'pace');
  end if;
  return public._learner_json(v_lid) || jsonb_build_object('token', public._new_session(v_lid));
end $$;

-- בחירת יחידות (כולל חבורה קבועה ואימוץ יחידה פנויה במחזור שבלימוד)
create or replace function public._do_reg(p_lid text, p_cid text, p_units text[], p_pace text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare c cycles; have int; v_jp int := 0; adopt boolean;
begin
  select * into c from cycles where id = p_cid;
  if c.id is null then raise exception 'closed'; end if;
  adopt := c.status = 'learning' and coalesce(c.kind,'') <> 'rolling' and coalesce(c.show,true)
           and public._week_idx(c) >= 0 and public._week_idx(c) < public._pw(c) - 1
           and coalesce((select (value->>c.id)::boolean from settings where key = 'adoptOff'), false) = false;
  if c.status <> 'open' and not adopt then raise exception 'closed'; end if;
  if cardinality(p_units) = 0 then raise exception 'no_units'; end if;
  select coalesce(sum(cardinality(units)),0) into have from regs where lid = p_lid and cid = p_cid;
  if c.max > 0 and not (coalesce(c.limit_hours,0) > 0 and c.opened_at is not null and now() >= c.opened_at + make_interval(hours => c.limit_hours))
     and have + cardinality(p_units) > c.max then raise exception 'over_max'; end if;
  if c.kind = 'rolling' then
    v_jp := public._join_period(c);
    -- יחידות של מי שיצא מהחבורה עוברות לצד, כדי שיתפנו
    update regs set left_units = coalesce(left_units,'{}') || units, units = '{}'
     where cid = p_cid and exit_period is not null and exit_period < v_jp and units && p_units;
  end if;
  begin
    insert into regs (cid, lid, units, pace, jp) values (p_cid, p_lid, p_units, case when p_pace in ('weekly','daily') then p_pace else 'weekly' end, v_jp);
  exception when unique_violation then raise exception 'taken'; end;
  perform public._act(p_lid, 'בחירת פרקים', c.name || ': ' || array_to_string(p_units, ', '));
end $$;

-- אישור לימוד של כמה פרקים בבת אחת
create or replace function public.learner_confirm_many(p_token text, p_reg text, p_keys text[]) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v text := public._lid(p_token); r regs; c cycles; k text; code text; w int; wi int; ok text[] := '{}'; tsj jsonb;
begin
  if v is null then raise exception 'no_session'; end if;
  select * into r from regs where id = p_reg and lid = v;
  if r.id is null then raise exception 'not_found'; end if;
  select * into c from cycles where id = r.cid;
  if not coalesce(c.self_confirm, true) then raise exception 'not_allowed'; end if;
  wi := public._week_idx(c);
  foreach k in array coalesce(p_keys,'{}') loop
    code := split_part(k, ':', 1); w := nullif(split_part(k, ':', 2), '')::int;
    if w is null or w < 1 or code = '' then raise exception 'bad_key'; end if;
    if c.kind <> 'rolling' and not (code = any(r.units)) then raise exception 'bad_key'; end if;
    if coalesce(c.confirm_mode,'all') = 'all' then
      if c.kind = 'rolling' and (w - 1) / public._pw(c) > greatest(public._cur_period(c), coalesce(r.jp,0)) then raise exception 'not_allowed'; end if;
    else
      if (w - 1) > wi or (c.weeks_back < 99 and (w - 1) < wi - c.weeks_back) then raise exception 'not_allowed'; end if;
    end if;
    ok := ok || k;
  end loop;
  tsj := coalesce(r.ch_ts, '{}'::jsonb);
  foreach k in array ok loop if not (k = any(r.ch)) then tsj := tsj || jsonb_build_object(k, now()); end if; end loop;
  update regs set ch = (select array(select distinct unnest(ch || ok))), ch_ts = tsj where id = r.id;
  perform public._act(v, 'אישור לימוד', c.name || ': ' || array_to_string(ok, ', '));
  return public._learner_json(v);
end $$;

-- אישור של פרק אחד (נשאר לתאימות)
create or replace function public.learner_confirm(p_token text, p_reg text, p_key text) returns jsonb
language sql security definer set search_path to 'public' as $$
  select public.learner_confirm_many(p_token, p_reg, array[p_key]) $$;

-- יציאה מחבורה קבועה (או ביטול היציאה)
create or replace function public.learner_exit(p_token text, p_reg text, p_cancel boolean) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v text := public._lid(p_token); r regs; c cycles; p int; pw int; ew int; dl date; eff int;
begin
  if v is null then raise exception 'no_session'; end if;
  select * into r from regs where id = p_reg and lid = v;
  if r.id is null then raise exception 'not_found'; end if;
  select * into c from cycles where id = r.cid;
  if c.kind <> 'rolling' then raise exception 'not_allowed'; end if;
  if p_cancel then
    update regs set exit_period = null where id = r.id;
    perform public._act(v, 'ביטול בקשת יציאה', c.name);
  else
    pw := public._pw(c); p := greatest(public._cur_period(c), coalesce(r.jp,0));
    ew := coalesce(c.exit_weeks, case when pw <= 4 then 1 else 2 end);
    dl := c.start + ((p + 1) * pw * 7) - (7 * ew);
    eff := case when (now() at time zone 'Asia/Jerusalem')::date > dl then p + 1 else p end;
    update regs set exit_period = eff where id = r.id;
    perform public._act(v, 'בקשת יציאה', c.name);
  end if;
  return public._learner_json(v);
end $$;

-- ביטול יחידה על ידי הלומד: רק אם המנהל הפעיל (unitCancel = any, או before = עד תחילת התקופה)
create or replace function public.learner_release(p_token text, p_reg text, p_unit text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v text := public._lid(p_token); r regs; c cycles; m text; p int; ps date;
begin
  if v is null then raise exception 'no_session'; end if;
  select * into r from regs where id = p_reg and lid = v;
  if r.id is null or not (p_unit = any(r.units)) then raise exception 'not_found'; end if;
  select * into c from cycles where id = r.cid;
  m := coalesce((select value #>> '{}' from settings where key = 'unitCancel'), 'no');
  if m = 'no' then raise exception 'not_allowed'; end if;
  if m <> 'any' then
    p := case when c.kind = 'rolling' then greatest(public._cur_period(c), coalesce(r.jp,0)) else 0 end;
    ps := c.start + (p * public._pw(c) * 7);
    if (now() at time zone 'Asia/Jerusalem')::date >= ps then raise exception 'too_late'; end if;
  end if;
  if array_length(array_remove(r.units, p_unit), 1) is null then delete from regs where id = r.id;
  else update regs set units = array_remove(r.units, p_unit) where id = r.id; end if;
  perform public._act(v, 'ביטול יחידה', c.name || ': ' || p_unit);
  return public._learner_json(v);
end $$;

-- כניסה למחזור פרטי בקוד: הקודים לא גלויים לציבור, השרת בודק ומחזיר רק את מזהה המחזור
create or replace function public.check_priv_code(p_code text) returns text
language sql stable security definer set search_path to 'public' as $$
  select e.key from settings s, jsonb_each_text(s.value) e
  where s.key = 'privCodes' and length(trim(coalesce(p_code,''))) > 0 and trim(e.value) = trim(p_code)
  limit 1 $$;

-- רשימת המתנה
create or replace function public.learner_wait_add(p_token text, p jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v text := public._lid(p_token);
begin
  if v is null then raise exception 'no_session'; end if;
  insert into waitlist (lid, cid, version, seder, prefs, only_first, note, plan)
  values (v, coalesce(p->>'cid',''), coalesce((p->>'version')::int,1), coalesce(p->>'seder',''),
          array(select jsonb_array_elements_text(coalesce(p->'prefs','[]'::jsonb))), coalesce((p->>'only_first')::boolean,false), left(coalesce(p->>'note',''),1000), left(coalesce(p->>'plan',''),100));
  perform public._act(v, 'רשימת המתנה', coalesce(p->>'seder',''));
  return public._learner_json(v);
end $$;
create or replace function public.learner_wait_cancel(p_token text, p_id text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v text := public._lid(p_token);
begin
  if v is null then raise exception 'no_session'; end if;
  update waitlist set status = 'cancelled' where id = p_id and lid = v and status = 'waiting';
  return public._learner_json(v);
end $$;

-- ---------- 6. מבחנים ----------

-- כמה שאלות חובה (לפי הגדרת המנהל): 0 = כולן
create or replace function public._exam_req(p_exam bigint, p_n int) returns int
language plpgsql stable security definer set search_path to 'public' as $$
declare e exams; t int; v int;
begin
  select * into e from exams where id = p_exam;
  t := ((e.ctype - 1) % 10) + 1;
  v := coalesce(nullif((select value->>(p_exam::text) from settings where key = 'exReqE'),'')::int,
                nullif((select value->>(t::text) from settings where key = 'exReq'),'')::int, 0);
  if v > 0 and v < p_n then return v; end if;
  return 0;
end $$;

-- התשובות הנכונות של מבחן: שאלה רגילה – מספר, שאלה עם כמה נכונות – רשימה
create or replace function public._exam_key(p_exam bigint) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_object_agg(q.id::text,
           case when count_ok > 1 then ok_arr else ok_arr->0 end), '{}'::jsonb)
  from (select q.id, count(ec.aid) as count_ok, jsonb_agg(ec.aid order by ec.aid) as ok_arr
        from exam_questions q join exam_correct ec on ec.qid = q.id
        where q.exam_id = p_exam group by q.id) q $$;

create or replace function public.exam_submit(p_token text, p_exam bigint, p_answers jsonb, p_texts jsonb default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v text := public._lid(p_token); v_key jsonb; q record; sc int := 0; n int := 0; req int; got jsonb; ok jsonb; tot int; bonus int := 0;
begin
  if v is null then raise exception 'no_session'; end if;
  if exists (select 1 from exam_results where lid = v and exam_id = p_exam) then raise exception 'already'; end if;
  v_key := public._exam_key(p_exam);
  for q in select id from exam_questions where exam_id = p_exam and exists (select 1 from exam_correct ec where ec.qid = exam_questions.id) loop
    n := n + 1;
    got := p_answers -> (q.id::text); ok := v_key -> (q.id::text);
    if jsonb_typeof(ok) = 'array' then
      if jsonb_typeof(got) = 'array' and
         (select coalesce(jsonb_agg(x order by x),'[]') from (select (jsonb_array_elements_text(got))::bigint x) s) =
         (select coalesce(jsonb_agg(x order by x),'[]') from (select (jsonb_array_elements_text(ok))::bigint x) s) then sc := sc + 1; end if;
    elsif got is not null and (got #>> '{}') = (ok #>> '{}') then sc := sc + 1; end if;
  end loop;
  req := public._exam_req(p_exam, n);
  if req > 0 then bonus := greatest(sc - req, 0); sc := least(sc, req); tot := req; else tot := n; end if;
  insert into exam_results (lid, exam_id, score, total, bonus, answers, texts) values (v, p_exam, sc, tot, bonus, coalesce(p_answers,'{}'), coalesce(p_texts,'{}'));
  perform public._act(v, 'מבחן', (select tractate || ' ' || chapter || ' (' || type_name || '): ' || sc || '/' || tot from exams where id = p_exam));
  return jsonb_build_object('score', sc, 'total', tot, 'bonus', bonus, 'answers', coalesce(p_answers,'{}'), 'correct', v_key);
end $$;

create or replace function public.exam_review(p_token text, p_exam bigint) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v text := public._lid(p_token); r exam_results;
begin
  if v is null then raise exception 'no_session'; end if;
  select * into r from exam_results where lid = v and exam_id = p_exam;
  if r.id is null then raise exception 'not_taken'; end if;
  return jsonb_build_object('score', r.score, 'total', r.total, 'bonus', r.bonus, 'answers', r.answers, 'texts', r.texts, 'correct', public._exam_key(p_exam));
end $$;

create or replace function public.exam_mine(p_token text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v text := public._lid(p_token);
begin
  if v is null then raise exception 'no_session'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('exam', exam_id, 'score', score, 'total', total, 'bonus', bonus, 'texts', texts)) from exam_results where lid = v), '[]'::jsonb);
end $$;

-- ---------- 7. גישה לפונקציות ----------
grant execute on function public.learner_id_login(text, text) to anon, authenticated;
grant execute on function public.learner_register(jsonb) to anon, authenticated;
grant execute on function public.learner_confirm_many(text, text, text[]) to anon, authenticated;
grant execute on function public.learner_confirm(text, text, text) to anon, authenticated;
grant execute on function public.learner_exit(text, text, boolean) to anon, authenticated;
grant execute on function public.learner_wait_add(text, jsonb) to anon, authenticated;
grant execute on function public.check_priv_code(text) to anon, authenticated;
grant execute on function public.learner_release(text, text, text) to anon, authenticated;
grant execute on function public.learner_wait_cancel(text, text) to anon, authenticated;
grant execute on function public.exam_submit(text, bigint, jsonb, jsonb) to anon, authenticated;
grant execute on function public.exam_review(text, bigint) to anon, authenticated;
grant execute on function public.exam_mine(text) to anon, authenticated;
-- פונקציות פנימיות: לא נגישות מבחוץ
revoke execute on function public._do_reg(text, text, text[], text) from anon, authenticated, public;
revoke execute on function public._act(text, text, text) from anon, authenticated, public;
revoke execute on function public._exam_key(bigint) from anon, authenticated, public;
revoke execute on function public._exam_req(bigint, int) from anon, authenticated, public;

-- הפונקציה הישנה של כניסה עם קוד: לא בשימוש יותר
drop function if exists public.learner_login(text, text);

notify pgrst, 'reload schema';
-- סוף חלק ב


-- ================= חלק ג: פונקציות והרשאות משלימות =================

-- בחירת יחידות על ידי לומד מחובר
create or replace function public.learner_add_reg(p_token text, p_cid text, p_units text[], p_pace text, p_remind jsonb default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v text := public._lid(p_token);
begin
  if v is null then raise exception 'no_session'; end if;
  perform public._do_reg(v, p_cid, p_units, p_pace);
  if p_remind is not null then update learners set remind = p_remind where id = v; end if;
  return public._learner_json(v);
end $$;

-- פרטי הלומד המחובר (בטעינת האתר)
create or replace function public.learner_me(p_token text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v text := public._lid(p_token);
begin
  if v is null then raise exception 'no_session'; end if;
  return public._learner_json(v);
end $$;

create or replace function public.learner_logout(p_token text) returns void
language sql security definer set search_path to 'public' as $$
  delete from learner_sessions where token = p_token $$;

grant execute on function public.learner_add_reg(text, text, text[], text, jsonb) to anon, authenticated;
grant execute on function public.learner_me(text) to anon, authenticated;
grant execute on function public.learner_logout(text) to anon, authenticated;

-- פונקציות פנימיות: לא נגישות מבחוץ (חשוב: אחרת אפשר היה ליצור כניסה בשם לומד)
revoke execute on function public._new_session(text) from anon, authenticated, public;
revoke execute on function public._lid(text) from anon, authenticated, public;
revoke execute on function public._learner_json(text) from anon, authenticated, public;
revoke execute on function public.sync_reg_units() from anon, authenticated, public;

-- ---------- הרשאות לטבלאות הבסיס ----------
alter table public.learners          enable row level security;
alter table public.cycles            enable row level security;
alter table public.regs              enable row level security;
alter table public.reg_units         enable row level security;
alter table public.settings          enable row level security;
alter table public.campaigns         enable row level security;
alter table public.msgs              enable row level security;
alter table public.winners           enable row level security;
alter table public.inbox             enable row level security;
alter table public.login_attempts    enable row level security;
alter table public.learner_sessions  enable row level security;
alter table public.admins            enable row level security;

do $$
declare t text;
begin
  -- מנהל: הכול
  foreach t in array array['learners','cycles','regs','reg_units','settings','campaigns','msgs','winners','inbox','login_attempts','learner_sessions'] loop
    execute format('drop policy if exists admin_all on public.%I', t);
    execute format('create policy admin_all on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t);
  end loop;
  -- ציבור: קריאה בלבד של מה שמוצג באתר
  foreach t in array array['cycles','campaigns','msgs','winners'] loop
    execute format('drop policy if exists pub_read on public.%I', t);
    execute format('create policy pub_read on public.%I for select to anon, authenticated using (true)', t);
  end loop;
end $$;

-- רשימת המנהלים: אף אחד לא רואה אותה מבחוץ (הבדיקה נעשית בתוך הפונקציה)
drop policy if exists no_access on public.admins;
create policy no_access on public.admins for all to authenticated using (false) with check (false);

-- פנייה למערכת: כל אחד יכול לשלוח, רק המנהל קורא
drop policy if exists pub_insert on public.inbox;
create policy pub_insert on public.inbox for insert to anon, authenticated
  with check (length(coalesce(text,'')) <= 3000 and length(coalesce(name,'')) <= 200 and length(coalesce(phone,'')) <= 60 and coalesce(done,false) = false);

-- ---------- אחרי ההרצה: יצירת מנהל ----------
-- 1. ב־Supabase: Authentication ← Users ← Add user (מייל וסיסמה).
-- 2. מריצים בנפרד, עם המייל שיצרת:
--      insert into public.admins (email) values ('YOUR@EMAIL.COM');

notify pgrst, 'reload schema';
-- סוף הקובץ
