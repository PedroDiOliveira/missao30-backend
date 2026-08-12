# Missão30 — Backend

Backend do Missão30, um app de hábitos de 30 dias com tolerância a falhas por design. Este repositório **não é um servidor de API customizado** — é um projeto [Supabase CLI](https://supabase.com/docs/guides/cli), responsável pelo schema do banco, pelas políticas de segurança e pela lógica de negócio que roda dentro do Postgres.

## Sumário

- [Sobre o projeto](#sobre-o-projeto)
- [Stack técnica](#stack-técnica)
- [Estrutura do projeto](#estrutura-do-projeto)
- [Pré-requisitos](#pré-requisitos)
- [Configuração inicial](#configuração-inicial)
- [Aplicando o schema](#aplicando-o-schema)
- [Aplicando o catálogo inicial (seed)](#aplicando-o-catálogo-inicial-seed)
- [Configuração manual obrigatória no painel](#configuração-manual-obrigatória-no-painel)
- [Comandos úteis](#comandos-úteis)
- [Estado atual](#estado-atual)
- [Segurança](#segurança)
- [Documentação](#documentação)

## Sobre o projeto

O app fala **direto com o Postgres do Supabase**, através de Row Level Security (RLS) e funções `SECURITY DEFINER` — não existe um servidor Node/Express/Fastify no meio. Toda a lógica de negócio que precisaria viver numa API tradicional (aceitar uma missão, registrar um check-in, calcular o estado de uma missão) vive aqui, como funções SQL (RPCs) chamadas diretamente pelo cliente Supabase do app.

Essa decisão de arquitetura, e os motivos por trás dela (incluindo por que uma API própria em Go foi avaliada e descartada), estão registradas no documento canônico do projeto — veja [Documentação](#documentação).

## Stack técnica

- **[Supabase](https://supabase.com)** — Postgres gerenciado, Auth, Row Level Security, API REST/RPC autogerada.
- **[Supabase CLI](https://supabase.com/docs/guides/cli)** — gerencia migrations, seed e o vínculo com o projeto remoto. Instalado como dependência de desenvolvimento deste repo (não precisa de instalação global).

## Estrutura do projeto

```
missao30-backend/
├── package.json              # só declara o Supabase CLI como devDependency
├── supabase/
│   ├── config.toml           # configuração do projeto (gerado por `supabase init`)
│   ├── migrations/
│   │   └── ..._init_schema.sql   # schema completo: tabelas, RLS, RPCs
│   └── seed.sql               # catálogo inicial de missões (8 missões)
└── README.md
```

Não existe `supabase/functions/` ainda — a única Edge Function prevista (exclusão de conta self-service) é pós-MVP.

## Pré-requisitos

- **Node.js** (usado só para instalar e rodar o Supabase CLI via `npx`; qualquer versão LTS recente serve).
- Uma conta gratuita em [supabase.com](https://supabase.com).

**Não é preciso ter Docker instalado.** Este projeto não usa `supabase start` (stack local via Docker) — o fluxo de trabalho aqui é sempre contra um projeto Supabase Cloud real, mesmo em desenvolvimento. Isso é uma escolha deliberada (ver [Documentação](#documentação), Log de Decisões), não uma limitação temporária.

## Configuração inicial

1. Instale as dependências (isso instala o Supabase CLI):

   ```bash
   npm install
   ```

2. Crie um projeto gratuito em [supabase.com](https://supabase.com) (não pede cartão de crédito).

3. Gere um **Personal Access Token** em [supabase.com/dashboard/account/tokens](https://supabase.com/dashboard/account/tokens) — recomendado com expiração curta (7 dias), já que esse token dá acesso de conta, não só a este projeto.

4. Vincule o CLI ao projeto (o ref do projeto aparece na URL do painel: `.../project/<ref>/...`):

   ```bash
   SUPABASE_ACCESS_TOKEN=<seu-token> npx supabase link --project-ref <seu-project-ref>
   ```

## Aplicando o schema

Com o projeto linkado, aplique a migration:

```bash
SUPABASE_ACCESS_TOKEN=<seu-token> npx supabase db push
```

Isso cria as 4 tabelas (`profiles`, `missions`, `user_missions`, `check_ins`), habilita RLS em todas, e cria as 4 funções RPC que o app usa (`accept_mission`, `get_user_mission_state`, `create_check_in`, `abandon_mission`) mais o trigger que cria o perfil automaticamente no cadastro.

Use `--dry-run` pra ver o que seria aplicado sem executar de verdade:

```bash
SUPABASE_ACCESS_TOKEN=<seu-token> npx supabase db push --dry-run
```

## Aplicando o catálogo inicial (seed)

```bash
SUPABASE_ACCESS_TOKEN=<seu-token> npx supabase db push --include-seed
```

Insere as 8 missões do catálogo (`supabase/seed.sql`). Sem isso, a tela de catálogo do app não tem nada pra mostrar.

## Configuração manual obrigatória no painel

Duas configurações que só existem pelo painel do Supabase, não têm como ser feitas por migration:

1. **Authentication → Providers → Email → desligar "Confirm email"**. Sem isso, todo cadastro novo fica esperando confirmação por e-mail antes de ganhar uma sessão — contra a filosofia de fricção zero do produto.
2. **Authentication → URL Configuration → adicionar a URL de redirect** `missao30app://reset-password` na lista de redirect URLs permitidas. Sem isso, o fluxo de "esqueci minha senha" do app falha ao tentar enviar o link de recuperação — o Supabase rejeita qualquer `redirectTo` que não esteja nessa lista.

## Comandos úteis

Consultar o banco linkado diretamente (sem precisar abrir o painel):

```bash
SUPABASE_ACCESS_TOKEN=<seu-token> npx supabase db query --linked "select count(*) from public.missions;"
```

Ver o total de projetos vinculados à sua conta (útil pra confirmar que o token está válido):

```bash
SUPABASE_ACCESS_TOKEN=<seu-token> npx supabase projects list
```

Comparar o schema local com o remoto (detecta migrations pendentes ou drift):

```bash
SUPABASE_ACCESS_TOKEN=<seu-token> npx supabase db diff --linked
```

## Estado atual

- Schema, RLS e as 4 RPCs aplicados contra um projeto Supabase real e validados via chamadas diretas à API REST/RPC (leitura anônima bloqueada por RLS, cadastro criando o perfil corretamente, as 4 RPCs testadas incluindo casos de borda — limite de missões simultâneas, check-in duplicado, abandono duplicado).
- Catálogo de 8 missões semeado.
- O app (`missao30-app`) já tem autenticação real (cadastro, login, logout, recuperação de senha) ligada a este backend.
- **Ainda mockado no app**: todo o resto — missões ativas, catálogo, perfil, medalhas — continua lendo de `mock-data.ts`. Trocar isso pra ler direto daqui é um passo futuro separado, deliberadamente não incluído nesta rodada (ver Log de Decisões no `CONTEXT.md`).
- `supabase/functions/` (Edge Functions) ainda não existe — só será necessário quando a exclusão de conta self-service for implementada, pós-MVP.

## Segurança

- A chave **anon/publishable** (a que vai no `.env` do app) é segura de expor publicamente — é o que a Row Level Security existe pra proteger.
- A chave **`service_role`** nunca deve ser usada no app nem commitada em lugar nenhum — ela ignora RLS por completo.
- O **Personal Access Token** usado pra linkar o CLI dá acesso de conta (não só a este projeto) — gere com expiração curta e não commite em nenhum arquivo deste repo.

## Documentação

Este README cobre só o dia a dia operacional deste repositório. O contexto completo do produto — decisões de arquitetura, schema comentado, algoritmos centrais, telas, log de decisões — vive em [`../CONTEXT.md`](../CONTEXT.md), a fonte canônica compartilhada entre este repo e o `missao30-app`.
