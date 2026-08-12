-- Missão30 — schema inicial, RLS e RPCs.
-- Transcrito do CONTEXT.md (Seções 5 e 6, raiz do projeto) — primeira vez
-- que esse SQL roda contra um banco de verdade. Revisado linha a linha
-- antes de aplicar; qualquer divergência encontrada aqui deve ser
-- propagada de volta pro CONTEXT.md, que é a fonte canônica do desenho.

-- ============================================================
-- Tabelas
-- ============================================================

-- profiles: estende auth.users com campos do app. `on delete cascade` é
-- obrigatório aqui: sem ele, a exclusão de conta falha com violação de FK
-- assim que o usuário tem uma linha em profiles.
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  avatar_url text,
  reminder_time time not null default '20:00',
  reminder_enabled boolean not null default true,
  created_at timestamptz not null default timezone('utc', now())
);

-- missions: catálogo estático. Gerenciado só via seed/migrations — não
-- existe policy de INSERT/UPDATE/DELETE pro client, de propósito.
create table public.missions (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text not null,
  category text not null check (category in ('study', 'fitness', 'sleep', 'finance')),
  icon_name text not null,
  duration_days int not null default 30,
  allowed_fails int not null default 3,
  is_published boolean not null default true,
  created_at timestamptz not null default timezone('utc', now())
);

-- user_missions: uma linha por desafio aceito. duration_days/allowed_fails
-- são SNAPSHOT de missions no momento de aceitar (não um JOIN ao vivo) —
-- editar o catálogo depois nunca muda retroativamente uma missão já em
-- andamento ou já concluída.
create table public.user_missions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  mission_id uuid not null references public.missions(id),
  start_date date not null,
  duration_days int not null,
  allowed_fails int not null,
  status text not null default 'active'
    check (status in ('active', 'completed', 'failed', 'abandoned')),
  fails_count int not null default 0,
  created_at timestamptz not null default timezone('utc', now())
);

-- check_ins: append-only, imutável depois de criado (sem policy de
-- UPDATE/DELETE). O `unique` é o que garante "1 check-in por dia" no nível
-- do banco, não só na lógica do cliente.
create table public.check_ins (
  id uuid primary key default gen_random_uuid(),
  user_mission_id uuid not null references public.user_missions(id) on delete cascade,
  check_in_date date not null,
  created_at timestamptz not null default timezone('utc', now()),
  unique (user_mission_id, check_in_date)
);

-- ============================================================
-- RLS — fail-closed por padrão (esquecer uma policy de SELECT faz a tela
-- correspondente renderizar vazia, sem erro).
-- ============================================================
alter table public.profiles       enable row level security;
alter table public.missions       enable row level security;
alter table public.user_missions  enable row level security;
alter table public.check_ins      enable row level security;

-- ---------- profiles ----------
create policy "profiles_select_own" on public.profiles
  for select to authenticated using (id = auth.uid());

create policy "profiles_update_own" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- Cria a linha em profiles automaticamente no cadastro — sem isso, o 1º
-- usuário a aceitar uma missão esbarraria na FK de user_missions.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, avatar_url)
  values (new.id, new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'avatar_url');
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- missions ----------
create policy "missions_select_published" on public.missions
  for select to authenticated using (is_published = true);

-- ---------- user_missions ----------
-- Sem policy de INSERT direta — inserção só via accept_mission() abaixo.
create policy "user_missions_select_own" on public.user_missions
  for select to authenticated using (user_id = auth.uid());

-- ---------- check_ins ----------
-- Sem coluna user_id própria — a policy precisa ser um JOIN via
-- user_missions, não um `user_id = auth.uid()` direto. Sem policy de
-- insert/update/delete diretas — inserção só via create_check_in() abaixo.
create policy "check_ins_select_own" on public.check_ins
  for select to authenticated using (
    exists (select 1 from public.user_missions um
            where um.id = check_ins.user_mission_id and um.user_id = auth.uid())
  );

-- ============================================================
-- get_user_mission_state: calcula status/faltas/dia sob demanda
-- ("settle on read"). p_client_today é SEMPRE a data local do dispositivo
-- do usuário, nunca current_date do Postgres (que é UTC).
-- ============================================================
create or replace function public.get_user_mission_state(p_user_mission_id uuid, p_client_today date)
returns table (status text, fails_count int, day_number int)
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.user_missions%rowtype;
  v_passed_days int; v_checkins_before_today int; v_total_checkins int;
  v_fails int; v_window_closed boolean; v_new_status text;
begin
  select * into v_row from public.user_missions
    where id = p_user_mission_id and user_id = auth.uid();
  if not found then
    raise exception 'user_mission % not found for caller', p_user_mission_id;
  end if;

  if v_row.status <> 'active' then  -- estado terminal: congelado, nunca recalculado
    return query select v_row.status, v_row.fails_count,
      greatest(least(v_row.duration_days, p_client_today - v_row.start_date + 1), 1);
    return;
  end if;

  v_passed_days := greatest(least(p_client_today - v_row.start_date, v_row.duration_days), 0);

  select count(*) into v_checkins_before_today from public.check_ins
    where user_mission_id = v_row.id
      and check_in_date >= v_row.start_date and check_in_date < p_client_today;

  select count(*) into v_total_checkins from public.check_ins
    where user_mission_id = v_row.id
      and check_in_date >= v_row.start_date and check_in_date < v_row.start_date + v_row.duration_days;

  v_fails := greatest(v_passed_days - v_checkins_before_today, 0);
  v_window_closed := p_client_today >= v_row.start_date + v_row.duration_days;

  if v_fails > v_row.allowed_fails then
    v_new_status := 'failed';
  elsif v_window_closed or v_total_checkins = v_row.duration_days then
    v_new_status := 'completed';  -- comparecimento perfeito completa na hora
  else
    v_new_status := 'active';
  end if;

  if v_new_status <> 'active' then
    update public.user_missions set status = v_new_status, fails_count = v_fails
      where id = v_row.id and status = 'active';  -- idempotente sob race conditions
  end if;

  return query select v_new_status, v_fails,
    greatest(least(v_row.duration_days, p_client_today - v_row.start_date + 1), 1);
end;
$$;

-- ============================================================
-- accept_mission: checa o limite de missões simultâneas (v_max_active,
-- em sincronia manual com MAX_ACTIVE_MISSIONS do client) em vez de assumir
-- 1 só. Primeiro assenta defensivamente todas as ativas do usuário, só
-- então conta e compara. Não é à prova de race condition (count + insert
-- não-atômico) — risco aceito, baixa concorrência esperada (1
-- usuário/1 aparelho por vez).
-- ============================================================
create or replace function public.accept_mission(p_mission_id uuid, p_client_today date)
returns public.user_missions
language plpgsql security definer set search_path = public
as $$
declare
  v_active_id uuid;
  v_active_count int;
  v_mission public.missions%rowtype;
  v_result public.user_missions;
  v_max_active constant int := 3;
begin
  for v_active_id in
    select id from public.user_missions where user_id = auth.uid() and status = 'active'
  loop
    perform public.get_user_mission_state(v_active_id, p_client_today);
  end loop;

  select count(*) into v_active_count from public.user_missions
    where user_id = auth.uid() and status = 'active';

  if v_active_count >= v_max_active then
    raise exception 'active mission limit reached (%/%): finish or abandon one first', v_active_count, v_max_active;
  end if;

  select * into v_mission from public.missions
    where id = p_mission_id and is_published = true;
  if not found then
    raise exception 'mission % not found or not published', p_mission_id;
  end if;

  insert into public.user_missions (user_id, mission_id, start_date, duration_days, allowed_fails)
  values (auth.uid(), p_mission_id, p_client_today, v_mission.duration_days, v_mission.allowed_fails)
  returning * into v_result;

  return v_result;
end;
$$;

-- ============================================================
-- create_check_in: RPC em vez de INSERT direto, pra validar que a data
-- está dentro da janela da missão (um CHECK constraint não consegue fazer
-- isso, não pode referenciar outra tabela).
-- ============================================================
create or replace function public.create_check_in(p_user_mission_id uuid, p_check_in_date date)
returns public.check_ins
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.user_missions%rowtype;
  v_result public.check_ins;
begin
  select * into v_row from public.user_missions
    where id = p_user_mission_id and user_id = auth.uid();
  if not found then
    raise exception 'user_mission % not found for caller', p_user_mission_id;
  end if;
  if v_row.status <> 'active' then
    raise exception 'mission is not active';
  end if;
  if p_check_in_date < v_row.start_date or p_check_in_date >= v_row.start_date + v_row.duration_days then
    raise exception 'check-in date % outside mission window', p_check_in_date;
  end if;

  insert into public.check_ins (user_mission_id, check_in_date)
  values (p_user_mission_id, p_check_in_date)
  returning * into v_result;
  return v_result;
end;
$$;

-- ============================================================
-- abandon_mission: sai da missão sem precisar acumular faltas reais.
-- ============================================================
create or replace function public.abandon_mission(p_user_mission_id uuid)
returns public.user_missions
language plpgsql security definer set search_path = public
as $$
declare
  v_result public.user_missions;
begin
  update public.user_missions set status = 'abandoned'
    where id = p_user_mission_id and user_id = auth.uid() and status = 'active'
  returning * into v_result;

  if not found then
    raise exception 'mission not found, not active, or not owned by caller';
  end if;
  return v_result;
end;
$$;

-- Revoga execução pública, concede só pra authenticated.
revoke all on function public.accept_mission(uuid, date) from public;
revoke all on function public.get_user_mission_state(uuid, date) from public;
revoke all on function public.create_check_in(uuid, date) from public;
revoke all on function public.abandon_mission(uuid) from public;
grant execute on function public.accept_mission(uuid, date) to authenticated;
grant execute on function public.get_user_mission_state(uuid, date) to authenticated;
grant execute on function public.create_check_in(uuid, date) to authenticated;
grant execute on function public.abandon_mission(uuid) to authenticated;
