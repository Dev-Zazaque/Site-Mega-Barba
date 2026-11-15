-- ==========================================================
-- MEGA BARBA • Banco de dados COMPLETO (v3)
-- Pode rodar de novo quantas vezes quiser: não apaga seus dados.
-- Cole tudo no SQL Editor do Supabase e clique em RUN.
-- Inclui: agenda, duração por serviço, fidelidade, folgas.
-- ==========================================================
create extension if not exists pgcrypto with schema extensions;
create extension if not exists btree_gist with schema extensions;

-- Atendimento: terça a sábado, 09h às 19h (domingo = 0 e segunda = 1 ficam fechados)
-- ---------- TABELAS ----------
create table if not exists barbeiros (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  papel text not null default 'BARBEIRO' check (papel in ('BARBEIRO','DONO')),
  pin_hash text not null,
  turno_inicio text not null default '09:00',
  turno_fim text not null default '19:00',
  almoco_inicio text not null default '12:00',
  almoco_fim text not null default '13:00',
  ativo boolean not null default true
);

alter table barbeiros alter column turno_fim set default '19:00';
update barbeiros set turno_fim = '19:00' where turno_fim = '18:00';

create table if not exists servicos (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique,
  descricao text,
  preco numeric not null,
  ordem int not null default 0,
  duracao int not null default 60
);
alter table servicos add column if not exists duracao int not null default 60;

create table if not exists agendamentos (
  id uuid primary key default gen_random_uuid(),
  barbeiro_id uuid not null references barbeiros(id) on delete cascade,
  data date not null,
  hora text not null check (hora ~ '^\d{2}:\d{2}$'),
  cliente_nome text not null,
  cliente_whatsapp text,
  servico text not null,
  valor numeric not null default 0,
  status text not null default 'CONFIRMADO',
  duracao int not null default 60,
  brinde boolean not null default false,           -- true = serviço grátis da fidelidade
  inicio int generated always as (split_part(hora, ':', 1)::int * 60 + split_part(hora, ':', 2)::int) stored,
  criado_em timestamptz not null default now()
);
alter table agendamentos add column if not exists duracao int not null default 60;
alter table agendamentos add column if not exists brinde boolean not null default false;
alter table agendamentos add column if not exists inicio int
  generated always as (split_part(hora, ':', 1)::int * 60 + split_part(hora, ':', 2)::int) stored;

alter table agendamentos drop constraint if exists agendamentos_status_check;
alter table agendamentos add constraint agendamentos_status_check
  check (status in ('CONFIRMADO', 'BLOQUEADO', 'CONCLUIDO'));

-- sem sobreposição de horários para o mesmo barbeiro (impede agendamento duplo)
alter table agendamentos drop constraint if exists agendamentos_barbeiro_id_data_hora_key;
alter table agendamentos drop constraint if exists sem_choque;
alter table agendamentos add constraint sem_choque
  exclude using gist (barbeiro_id with =, data with =, int4range(inicio, inicio + duracao) with &&);
create index if not exists ag_whatsapp on agendamentos (cliente_whatsapp);

-- dias inteiros de folga / feriado
create table if not exists folgas (
  barbeiro_id uuid not null references barbeiros(id) on delete cascade,
  data date not null,
  motivo text,
  primary key (barbeiro_id, data)
);

-- ---------- SEGURANÇA (RLS): acesso só pelas funções abaixo ----------
alter table barbeiros enable row level security;
alter table agendamentos enable row level security;
alter table folgas enable row level security;
alter table servicos enable row level security;
drop policy if exists "servicos_publico" on servicos;
create policy "servicos_publico" on servicos for select using (true);

-- ---------- CLIENTE ----------
drop function if exists horarios_ocupados(uuid, date);

create or replace function listar_barbeiros()
returns table(id uuid, nome text, turno_inicio text, turno_fim text, almoco_inicio text, almoco_fim text)
language sql security definer set search_path = public as $$
  select id, nome, turno_inicio, turno_fim, almoco_inicio, almoco_fim
  from barbeiros where ativo and papel = 'BARBEIRO' order by nome
$$;

-- horários ocupados; em dia de folga devolve o dia inteiro bloqueado (0 a 1440 min)
create or replace function ocupacao(p_barbeiro uuid, p_data date)
returns json
language sql security definer set search_path = public as $$
  select case
    when extract(dow from p_data) in (0, 1) or exists (select 1 from folgas where barbeiro_id = p_barbeiro and data = p_data)
      then '[{"i":0,"f":1440}]'::json
    else (select coalesce(json_agg(json_build_object('i', inicio, 'f', inicio + duracao)), '[]'::json)
          from agendamentos where barbeiro_id = p_barbeiro and data = p_data)
  end
$$;

-- Fidelidade: a cada 10 serviços CONCLUÍDOS (pagos) no mesmo WhatsApp, o próximo é grátis
create or replace function fidelidade(p_whatsapp text)
returns json
language sql security definer set search_path = public as $$
  with t as (
    select count(*) filter (where status = 'CONCLUIDO' and not brinde) as pagos,
           count(*) filter (where brinde and status in ('CONFIRMADO', 'CONCLUIDO')) as brindes
    from agendamentos where cliente_whatsapp = p_whatsapp
  )
  select json_build_object(
    'feitos', least(greatest(pagos - brindes * 10, 0), 10),
    'faltam', greatest(10 - greatest(pagos - brindes * 10, 0), 0),
    'gratis', pagos - brindes * 10 >= 10)
  from t
$$;

create or replace function criar_agendamento(
  p_barbeiro uuid, p_data date, p_hora text, p_servico text, p_nome text, p_whatsapp text)
returns void
language plpgsql security definer set search_path = public as $$
declare v numeric; d int; gratis boolean := false;
begin
  select preco, duracao into v, d from servicos where nome = p_servico;
  if v is null then raise exception 'Serviço inválido'; end if;
  if length(trim(p_nome)) < 2 or p_whatsapp !~ '^\d{10,11}$' then raise exception 'Dados inválidos'; end if;
  if p_data < (now() at time zone 'America/Sao_Paulo')::date then raise exception 'Data inválida'; end if;
  if not exists (select 1 from barbeiros where id = p_barbeiro and ativo and papel = 'BARBEIRO') then
    raise exception 'Barbeiro inválido';
  end if;
  if extract(dow from p_data) in (0, 1) or exists (select 1 from folgas where barbeiro_id = p_barbeiro and data = p_data) then
    raise exception 'HORARIO_OCUPADO';
  end if;
  if (fidelidade(p_whatsapp)->>'gratis')::boolean then v := 0; gratis := true; end if;
  insert into agendamentos (barbeiro_id, data, hora, cliente_nome, cliente_whatsapp, servico, valor, duracao, brinde)
  values (p_barbeiro, p_data, p_hora, trim(p_nome), p_whatsapp, p_servico, v, d, gratis);
exception when unique_violation or exclusion_violation then
  raise exception 'HORARIO_OCUPADO';
end $$;

drop function if exists meus_agendamentos(text);
create or replace function meus_agendamentos(p_whatsapp text)
returns table(id uuid, data date, hora text, servico text, barbeiro text,
              barbeiro_id uuid, duracao int, valor numeric, brinde boolean)
language sql security definer set search_path = public as $$
  select a.id, a.data, a.hora, a.servico, b.nome, a.barbeiro_id, a.duracao, a.valor, a.brinde
  from agendamentos a join barbeiros b on b.id = a.barbeiro_id
  where a.cliente_whatsapp = p_whatsapp and a.status = 'CONFIRMADO'
    and a.data >= (now() at time zone 'America/Sao_Paulo')::date
  order by a.data, a.hora
$$;

create or replace function cancelar_meu(p_id uuid, p_whatsapp text)
returns void
language sql security definer set search_path = public as $$
  delete from agendamentos where id = p_id and cliente_whatsapp = p_whatsapp and status = 'CONFIRMADO'
$$;

create or replace function remarcar_meu(p_id uuid, p_whatsapp text, p_data date, p_hora text)
returns void
language plpgsql security definer set search_path = public as $$
declare b uuid;
begin
  if p_data < (now() at time zone 'America/Sao_Paulo')::date then raise exception 'Data inválida'; end if;
  select barbeiro_id into b from agendamentos
   where id = p_id and cliente_whatsapp = p_whatsapp and status = 'CONFIRMADO';
  if b is null then raise exception 'Agendamento não encontrado'; end if;
  if extract(dow from p_data) in (0, 1) or exists (select 1 from folgas where barbeiro_id = b and data = p_data) then
    raise exception 'HORARIO_OCUPADO';
  end if;
  update agendamentos set data = p_data, hora = p_hora where id = p_id;
exception when unique_violation or exclusion_violation then
  raise exception 'HORARIO_OCUPADO';
end $$;

-- ---------- PAINEL (PIN validado no servidor) ----------
create or replace function auth_pin(p_pin text)
returns barbeiros
language sql security definer set search_path = public, extensions as $$
  select * from barbeiros where ativo and pin_hash = crypt(p_pin, pin_hash) limit 1
$$;
revoke all on function auth_pin(text) from public, anon, authenticated;

create or replace function painel_login(p_pin text)
returns json
language sql security definer set search_path = public, extensions as $$
  select json_build_object('id', id, 'nome', nome, 'papel', papel)
  from auth_pin(p_pin) where id is not null
$$;

drop function if exists painel_agenda(text, date);
create or replace function painel_agenda(p_pin text, p_data date)
returns table(id uuid, barbeiro_id uuid, barbeiro text, hora text, cliente_nome text,
              servico text, valor numeric, status text, duracao int, brinde boolean)
language plpgsql security definer set search_path = public, extensions as $$
declare u barbeiros;
begin
  u := auth_pin(p_pin);
  if u.id is null then raise exception 'PIN inválido'; end if;
  return query
    select a.id, a.barbeiro_id, b.nome, a.hora, a.cliente_nome, a.servico, a.valor, a.status, a.duracao, a.brinde
    from agendamentos a join barbeiros b on b.id = a.barbeiro_id
    where a.data = p_data and (u.papel = 'DONO' or a.barbeiro_id = u.id)
    order by a.hora;
end $$;

create or replace function painel_bloquear(p_pin text, p_data date, p_hora text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u barbeiros;
begin
  u := auth_pin(p_pin);
  if u.id is null or u.papel <> 'BARBEIRO' then raise exception 'Sem permissão'; end if;
  insert into agendamentos (barbeiro_id, data, hora, cliente_nome, servico, valor, status, duracao)
  values (u.id, p_data, p_hora, 'Bloqueado pelo barbeiro', 'Pausa', 0, 'BLOQUEADO', 30)
  on conflict do nothing;
end $$;

create or replace function painel_cancelar(p_pin text, p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u barbeiros;
begin
  u := auth_pin(p_pin);
  if u.id is null then raise exception 'PIN inválido'; end if;
  delete from agendamentos where id = p_id and (u.papel = 'DONO' or barbeiro_id = u.id);
end $$;

create or replace function painel_concluir(p_pin text, p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u barbeiros;
begin
  u := auth_pin(p_pin);
  if u.id is null then raise exception 'PIN inválido'; end if;
  update agendamentos set status = 'CONCLUIDO'
  where id = p_id and status = 'CONFIRMADO' and (u.papel = 'DONO' or barbeiro_id = u.id);
end $$;

create or replace function painel_salvar_turno(p_pin text, p_ti text, p_tf text, p_ai text, p_af text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u barbeiros;
begin
  u := auth_pin(p_pin);
  if u.id is null or u.papel <> 'BARBEIRO' then raise exception 'Sem permissão'; end if;
  update barbeiros set turno_inicio = p_ti, turno_fim = p_tf, almoco_inicio = p_ai, almoco_fim = p_af where id = u.id;
end $$;

-- Folga: o dia está marcado como folga?
create or replace function painel_folga_dia(p_pin text, p_data date)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare u barbeiros; f folgas;
begin
  u := auth_pin(p_pin);
  if u.id is null then raise exception 'PIN inválido'; end if;
  select * into f from folgas where barbeiro_id = u.id and data = p_data;
  return json_build_object('folga', f.barbeiro_id is not null, 'motivo', f.motivo);
end $$;

-- Folga: marcar (p_ativar = true) ou remover o dia inteiro
create or replace function painel_folga(p_pin text, p_data date, p_ativar boolean, p_motivo text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u barbeiros;
begin
  u := auth_pin(p_pin);
  if u.id is null or u.papel <> 'BARBEIRO' then raise exception 'Sem permissão'; end if;
  if p_ativar then
    if exists (select 1 from agendamentos where barbeiro_id = u.id and data = p_data and status = 'CONFIRMADO') then
      raise exception 'Cancele ou conclua os agendamentos deste dia antes de marcar a folga.';
    end if;
    insert into folgas (barbeiro_id, data, motivo) values (u.id, p_data, nullif(trim(p_motivo), ''))
    on conflict do nothing;
  else
    delete from folgas where barbeiro_id = u.id and data = p_data;
  end if;
end $$;

-- ---------- DADOS INICIAIS (só entram se ainda não existirem) ----------
insert into servicos (nome, descricao, preco, ordem, duracao) values
  ('Corte de Cabelo', 'Degradê, tesoura ou máquina', 35, 1, 30),
  ('Barba Completa', 'Toalha quente e alinhamento', 25, 2, 30),
  ('Combo Cabelo + Barba', 'O pacote completo com desconto', 55, 3, 60)
on conflict (nome) do nothing;

delete from barbeiros where nome in ('Matheus', 'Lucas');

insert into barbeiros (nome, papel, pin_hash)
select 'Wallace', 'BARBEIRO', extensions.crypt('1234', extensions.gen_salt('bf'))
where not exists (select 1 from barbeiros where nome = 'Wallace');
insert into barbeiros (nome, papel, pin_hash)
select 'Alexsandro', 'BARBEIRO', extensions.crypt('4321', extensions.gen_salt('bf'))
where not exists (select 1 from barbeiros where nome = 'Alexsandro');
insert into barbeiros (nome, papel, pin_hash)
select 'Dono da Barbearia', 'DONO', extensions.crypt('9999', extensions.gen_salt('bf'))
where not exists (select 1 from barbeiros where papel = 'DONO');
