-- Catálogo inicial (CONTEXT.md Seção 12) — sem isso a Tela 2 não roda nem
-- pra teste manual. Nomes de ícone no padrão Lucide (missao30-app/src/lib/icons.ts).
insert into public.missions (title, description, category, icon_name) values
  ('Estudar 1 Hora por Dia', 'Separe 60 minutos focados para estudar o que importa pra você, todos os dias.', 'study', 'book-open'),
  ('Ler 20 Páginas por Dia', 'Construa o hábito da leitura, 20 páginas de cada vez.', 'study', 'book'),
  ('Treinar 30 Minutos por Dia', 'Movimente o corpo por meia hora, todo santo dia.', 'fitness', 'dumbbell'),
  ('10 Mil Passos por Dia', 'Caminhe até bater 10.000 passos, no seu ritmo.', 'fitness', 'footprints'),
  ('Dormir Antes das 23h', 'Durma cedo e acorde com mais energia.', 'sleep', 'moon'),
  ('Sem Telas Antes de Dormir', 'Desligue as telas 30 minutos antes de deitar.', 'sleep', 'monitor-off'),
  ('Registrar Todos os Gastos', 'Anote cada real que sai do seu bolso, sem exceção.', 'finance', 'wallet'),
  ('Sem Gastos Supérfluos', 'Um mês inteiro sem compras por impulso.', 'finance', 'piggy-bank');
