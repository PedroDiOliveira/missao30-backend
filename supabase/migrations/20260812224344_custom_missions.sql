-- Criação de missão personalizada de verdade — CONTEXT.md Log de Decisões
-- (novo item). Resolve o que a Decisão #23 deixou como risco: curar
-- cadência missão-por-missão no catálogo não escala. Coluna nova, não
-- tabela nova — deixa uma missão personalizada se comportar exatamente
-- como uma curada em todo o resto do app (aceitar, medalhas, relatório),
-- sem nenhum caso especial em lugar nenhum.

alter table public.missions
  add column created_by uuid references auth.users(id) on delete cascade;

comment on column public.missions.created_by is
  'null = missão curada (seed/admin); not null = criada por um usuário via '
  '/create-mission. Nunca é publicada pro catálogo geral (ver policy de '
  'insert) — só aparece pra quem criou.';

-- Amplia a visibilidade: publicadas (curadas) OU minhas, mesma policy de
-- antes só com uma condição a mais.
alter policy "missions_select_published" on public.missions
  using (is_published = true or created_by = auth.uid());

-- Sem RPC nova de propósito: diferente de accept_mission/create_check_in
-- (que validam contra outras tabelas), criar uma missão é um insert de
-- linha única — os CHECK constraints que já existem (category,
-- cadence_unit/cadence_target) fazem a validação, RLS cobre posse. Mesmo
-- princípio de camadas já registrado na Seção 6 do CONTEXT.md.
--
-- `is_published = false` no with check NÃO é opcional: sem isso, qualquer
-- usuário autenticado poderia inserir uma missão com is_published = true e
-- ela apareceria no catálogo de todo mundo (injeção de conteúdo no
-- catálogo compartilhado).
create policy "missions_insert_own" on public.missions
  for insert to authenticated
  with check (created_by = auth.uid() and is_published = false);
