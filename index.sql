-- Execute uma única vez no SQL Editor do seu projeto Supabase.
-- Antes de executar, troque FUTEBOL-QUARTA-TROQUE-POR-CODIGO-LONGO
-- por um código único e compartilhe esse código só com o seu grupo.

create extension if not exists pgcrypto;

create table public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  invite_code text not null unique,
  created_at timestamptz not null default now()
);

create table public.memberships (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  nickname text not null,
  created_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

create table public.players (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  unique (group_id, owner_id)
);

create table public.games (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  scheduled_date date not null,
  created_at timestamptz not null default now(),
  unique (group_id, scheduled_date)
);

create table public.attendance (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  status text check (status is null or status in ('going','maybe','not_going')),
  paid boolean not null default false,
  updated_at timestamptz not null default now(),
  unique (game_id, player_id)
);

insert into public.groups (name, invite_code)
values ('Futebol de quarta', 'BOLA19-21970237-43QUARTA07');

-- Funções usadas pelas políticas; SECURITY DEFINER com search_path fixo.
create or replace function public.is_group_member(p_group_id uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.memberships m
    where m.group_id = p_group_id and m.user_id = auth.uid()
  );
$$;

create or replace function public.join_football_group(p_invite_code text, p_nickname text)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare
  v_group_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Sessão não autenticada';
  end if;
  if length(trim(coalesce(p_nickname, ''))) < 2 then
    raise exception 'Digite um nome com pelo menos 2 caracteres';
  end if;
  select g.id into v_group_id
  from public.groups g
  where g.invite_code = trim(p_invite_code);
  if v_group_id is null then
    raise exception 'Código do grupo inválido';
  end if;
  insert into public.memberships (group_id, user_id, nickname)
  values (v_group_id, auth.uid(), trim(p_nickname))
  on conflict (group_id, user_id) do update set nickname = excluded.nickname;
  insert into public.players (group_id, owner_id, name)
  values (v_group_id, auth.uid(), trim(p_nickname))
  on conflict (group_id, owner_id) do update set name = excluded.name;
  return v_group_id;
end;
$$;

grant execute on function public.is_group_member(uuid) to authenticated;
grant execute on function public.join_football_group(text, text) to authenticated;
grant usage on schema public to authenticated;
grant select on public.groups, public.memberships, public.players, public.games, public.attendance to authenticated;
grant insert, update, delete on public.players, public.attendance to authenticated;
grant insert on public.games to authenticated;

alter table public.groups enable row level security;
alter table public.memberships enable row level security;
alter table public.players enable row level security;
alter table public.games enable row level security;
alter table public.attendance enable row level security;

create policy "members can read their group" on public.groups
for select to authenticated using (public.is_group_member(id));

create policy "members can see their own membership" on public.memberships
for select to authenticated using (user_id = auth.uid());

create policy "members can read group players" on public.players
for select to authenticated using (public.is_group_member(group_id));
create policy "members can add their own player" on public.players
for insert to authenticated with check (owner_id = auth.uid() and public.is_group_member(group_id));
create policy "members can update their own player" on public.players
for update to authenticated using (owner_id = auth.uid() and public.is_group_member(group_id))
with check (owner_id = auth.uid() and public.is_group_member(group_id));
create policy "members can remove their own player" on public.players
for delete to authenticated using (owner_id = auth.uid() and public.is_group_member(group_id));

create policy "members can read group games" on public.games
for select to authenticated using (public.is_group_member(group_id));
create policy "members can create group games" on public.games
for insert to authenticated with check (public.is_group_member(group_id));

create policy "members can read group attendance" on public.attendance
for select to authenticated using (
  exists (select 1 from public.games g where g.id = game_id and public.is_group_member(g.group_id))
);
create policy "members can add attendance" on public.attendance
for insert to authenticated with check (
  exists (
    select 1 from public.games g join public.players p on p.group_id = g.group_id
    where g.id = game_id and p.id = player_id and public.is_group_member(g.group_id)
  )
);
create policy "members can update attendance" on public.attendance
for update to authenticated using (
  exists (select 1 from public.games g where g.id = game_id and public.is_group_member(g.group_id))
) with check (
  exists (
    select 1 from public.games g join public.players p on p.group_id = g.group_id
    where g.id = game_id and p.id = player_id and public.is_group_member(g.group_id)
  )
);
create policy "members can remove attendance" on public.attendance
for delete to authenticated using (
  exists (select 1 from public.games g where g.id = game_id and public.is_group_member(g.group_id))
);

-- Ativa as mudanças em tempo real para os três dados exibidos no app.
alter publication supabase_realtime add table public.players;
alter publication supabase_realtime add table public.games;
alter publication supabase_realtime add table public.attendance;
