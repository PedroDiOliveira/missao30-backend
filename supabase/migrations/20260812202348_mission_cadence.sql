-- Cadência configurável por missão — CONTEXT.md Log de Decisões (novo
-- item) e Seção 7 (fórmula reescrita). Resolve o problema de missões que
-- não deveriam ser diárias (ex.: academia) sem inventar um segundo
-- produto: uma missão semanal continua sendo uma missão de 30 dias,
-- só com o que conta como "falta" medido em semanas em vez de dias.
--
-- Aditivo e retrocompatível de propósito: toda linha existente (e toda
-- missão nova que não escolher cadência) cai no default 'day'/1, que
-- reproduz exatamente o comportamento de hoje — o branch 'day' da RPC
-- abaixo é bit-a-bit idêntico ao código antigo, não uma reescrita
-- genérica que "por acaso" reduz ao caso antigo.

-- ============================================================
-- Colunas novas — mesmo padrão de snapshot que duration_days/allowed_fails
-- (missions = definição do catálogo; user_missions = cópia no momento de
-- aceitar, imune a edição retroativa do catálogo).
-- ============================================================
alter table public.missions
  add column cadence_unit text not null default 'day',
  add column cadence_target int not null default 1;

alter table public.missions
  add constraint missions_cadence_unit_check check (cadence_unit in ('day', 'week')),
  add constraint missions_cadence_target_check check (
    (cadence_unit = 'day'  and cadence_target = 1)
    or
    (cadence_unit = 'week' and cadence_target between 1 and 7)
  );

alter table public.user_missions
  add column cadence_unit text not null default 'day',
  add column cadence_target int not null default 1;

alter table public.user_missions
  add constraint user_missions_cadence_unit_check check (cadence_unit in ('day', 'week')),
  add constraint user_missions_cadence_target_check check (
    (cadence_unit = 'day'  and cadence_target = 1)
    or
    (cadence_unit = 'week' and cadence_target between 1 and 7)
  );

comment on column public.missions.allowed_fails is
  'Unidade depende de cadence_unit: em faltas-dia quando ''day'', em '
  'faltas-semana quando ''week''. Nunca reaproveitar o valor default (3, '
  'calibrado pra ~30 unidades diárias) numa missão semanal (~5 unidades) '
  'sem recalibrar — ver CONTEXT.md Log de Decisões.';

-- ============================================================
-- get_user_mission_state: mesmo "settle on read" de sempre. day_number e
-- o fechamento de janela continuam calculados uma vez só, fora de
-- qualquer branch (matemática de data cega à cadência). Só o cálculo de
-- faltas/conclusão antecipada se bifurca por cadence_unit.
-- ============================================================
create or replace function public.get_user_mission_state(p_user_mission_id uuid, p_client_today date)
returns table (status text, fails_count int, day_number int)
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.user_missions%rowtype;
  v_passed_days int; v_checkins_before_today int; v_total_checkins int;
  v_fails int; v_window_closed boolean; v_new_status text;
  v_week_start date; v_last_day date; v_last_week_start date;
  v_bucket_start date; v_bucket_end date; v_capacity int; v_target int;
  v_checkins_in_bucket int; v_all_targets_met boolean;
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

  v_window_closed := p_client_today >= v_row.start_date + v_row.duration_days;

  if v_row.cadence_unit = 'day' then
    -- Branch intocado: idêntico à fórmula original antes desta migration,
    -- garante zero regressão pra toda missão diária (a esmagadora maioria).
    v_passed_days := greatest(least(p_client_today - v_row.start_date, v_row.duration_days), 0);

    select count(*) into v_checkins_before_today from public.check_ins
      where user_mission_id = v_row.id
        and check_in_date >= v_row.start_date and check_in_date < p_client_today;

    select count(*) into v_total_checkins from public.check_ins
      where user_mission_id = v_row.id
        and check_in_date >= v_row.start_date and check_in_date < v_row.start_date + v_row.duration_days;

    v_fails := greatest(v_passed_days - v_checkins_before_today, 0);

    if v_fails > v_row.allowed_fails then
      v_new_status := 'failed';
    elsif v_window_closed or v_total_checkins = v_row.duration_days then
      v_new_status := 'completed';  -- comparecimento perfeito completa na hora
    else
      v_new_status := 'active';
    end if;

  else -- cadence_unit = 'week'
    -- Agrupa os dias da missão em semanas dom-sáb via extract(dow from d)
    -- (0=domingo..6=sábado, bate numericamente com Date.getDay() do JS) —
    -- NUNCA date_trunc('week', ...), que é segunda-feira/ISO e quebraria a
    -- paridade com computeMissionState() no client.
    v_fails := 0;
    v_all_targets_met := true;

    v_last_day := v_row.start_date + v_row.duration_days - 1;
    v_week_start := v_row.start_date - extract(dow from v_row.start_date)::int;
    v_last_week_start := v_last_day - extract(dow from v_last_day)::int;

    while v_week_start <= v_last_week_start loop
      v_bucket_start := greatest(v_week_start, v_row.start_date);
      v_bucket_end := least(v_week_start + 7, v_row.start_date + v_row.duration_days);
      v_capacity := v_bucket_end - v_bucket_start;
      -- Meta proporcional à capacidade da semana (não min(target, capacidade)
      -- — isso deixaria semanas de borda mais difíceis que semanas cheias).
      v_target := round((v_row.cadence_target * v_capacity)::numeric / 7)::int;

      select count(*) into v_checkins_in_bucket from public.check_ins
        where user_mission_id = v_row.id
          and check_in_date >= v_bucket_start and check_in_date < v_bucket_end;

      if v_checkins_in_bucket < v_target then
        v_all_targets_met := false;  -- usado pra conclusão antecipada, sem gate de "decorrida"
        if v_bucket_end <= p_client_today then  -- semana já totalmente decorrida
          v_fails := v_fails + 1;
        end if;
      end if;

      v_week_start := v_week_start + 7;
    end loop;

    if v_fails > v_row.allowed_fails then
      v_new_status := 'failed';
    elsif v_window_closed or v_all_targets_met then
      -- v_all_targets_met sem gate de "decorrida" == toda semana (mesmo a
      -- ainda em andamento) já bateu a própria meta — equivalente semanal
      -- do comparecimento perfeito do branch diário. NÃO é comparar a soma
      -- total de check-ins contra a soma das metas: isso deixaria uma
      -- semana zerada ser "compensada" por excesso em outra, contradizendo
      -- a própria regra de falta-por-semana.
      v_new_status := 'completed';
    else
      v_new_status := 'active';
    end if;
  end if;

  if v_new_status <> 'active' then
    -- Alias + qualificação explícita (um.status) é obrigatório aqui: a
    -- assinatura `returns table (status text, ...)` desta função cria uma
    -- variável interna chamada `status`, que colide com a coluna
    -- `status` de user_missions num `status = 'active'` cru — bug
    -- pré-existente (já estava assim antes desta migration, nunca tinha
    -- sido exercitado até o teste desta rodada), corrigido aqui de quebra.
    update public.user_missions um set status = v_new_status, fails_count = v_fails
      where um.id = v_row.id and um.status = 'active';  -- idempotente sob race conditions
  end if;

  return query select v_new_status, v_fails,
    greatest(least(v_row.duration_days, p_client_today - v_row.start_date + 1), 1);
end;
$$;

-- ============================================================
-- accept_mission: snapshot precisa incluir cadence_unit/cadence_target,
-- senão uma missão semanal do catálogo silenciosamente vira diária no
-- momento de aceitar (cai no default da coluna, sem erro nenhum).
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

  insert into public.user_missions (
    user_id, mission_id, start_date, duration_days, allowed_fails, cadence_unit, cadence_target
  )
  values (
    auth.uid(), p_mission_id, p_client_today, v_mission.duration_days, v_mission.allowed_fails,
    v_mission.cadence_unit, v_mission.cadence_target
  )
  returning * into v_result;

  return v_result;
end;
$$;

-- ============================================================
-- Converte "Treinar 30 Minutos por Dia" no exemplo real de cadência
-- semanal (o próprio caso que motivou esta migration). allowed_fails
-- recalibrado pra 1: ~5 semanas num desafio de 30 dias, então 1 semana de
-- tolerância é proporcionalmente parecido com o "3 de 30" diário, sem ser
-- leniente demais (o default de 3 toleraria 60% das semanas em branco).
-- ============================================================
update public.missions
set title = 'Treinar 3x por Semana',
    description = 'Treine com intensidade 3 vezes na semana — descansar nos outros dias faz parte do plano, não é falha.',
    cadence_unit = 'week',
    cadence_target = 3,
    allowed_fails = 1
where title = 'Treinar 30 Minutos por Dia';
