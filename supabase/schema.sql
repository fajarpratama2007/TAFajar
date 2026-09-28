-- ==================================================
-- EMS Dashboard — skema Supabase
-- Jalankan seluruh file ini di Supabase -> SQL Editor (sekali).
-- Aman dijalankan ulang (idempotent).
-- ==================================================

-- ---------- peran user ----------
create table if not exists public.app_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role    text not null check (role in ('admin', 'device'))
);
alter table public.app_users enable row level security;
-- Tanpa policy = klien tidak bisa membaca/menulis tabel ini; hanya fungsi di bawah.

create or replace function public.app_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.app_users where user_id = auth.uid()
$$;
revoke all on function public.app_role() from public, anon;
grant execute on function public.app_role() to authenticated;

-- ---------- trigger updated_at ----------
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------- device_state: kondisi terbaru (1 baris per perangkat) ----------
create table if not exists public.device_state (
  device_id  text primary key,
  updated_at timestamptz not null default now(),
  data       jsonb not null default '{}'::jsonb
);
drop trigger if exists device_state_touch on public.device_state;
create trigger device_state_touch before insert or update on public.device_state
  for each row execute function public.touch_updated_at();

alter table public.device_state enable row level security;
drop policy if exists state_select on public.device_state;
drop policy if exists state_insert on public.device_state;
drop policy if exists state_update on public.device_state;
create policy state_select on public.device_state for select to authenticated
  using (public.app_role() in ('admin', 'device'));
create policy state_insert on public.device_state for insert to authenticated
  with check (public.app_role() = 'device');
create policy state_update on public.device_state for update to authenticated
  using (public.app_role() = 'device') with check (public.app_role() = 'device');

-- ---------- telemetry: histori ----------
create table if not exists public.telemetry (
  id         bigint generated always as identity primary key,
  device_id  text not null,
  created_at timestamptz not null default now(),
  state      text,
  sim        boolean,
  pol        smallint,
  pv_v real, pv_a real, pv_w real,
  ld_v real, ld_a real, ld_w real,
  bt_v real, bt_a real, bt_w real,
  h2a  real, h2t  real, surp real, srv real
);
create index if not exists telemetry_dev_time on public.telemetry (device_id, created_at desc);

alter table public.telemetry enable row level security;
drop policy if exists tele_select on public.telemetry;
drop policy if exists tele_insert on public.telemetry;
create policy tele_select on public.telemetry for select to authenticated
  using (public.app_role() in ('admin', 'device'));
create policy tele_insert on public.telemetry for insert to authenticated
  with check (public.app_role() = 'device');

-- ---------- commands: perintah dari web ke perangkat ----------
create table if not exists public.commands (
  id         bigint generated always as identity primary key,
  device_id  text not null,
  cmd        text not null check (cmd in ('polarity')),
  value      int  not null check (value in (0, 1)),
  status     text not null default 'pending' check (status in ('pending', 'done', 'rejected')),
  note       text,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
-- Hanya satu perintah "pending" per perangkat pada satu waktu.
create unique index if not exists commands_one_pending
  on public.commands (device_id) where status = 'pending';
drop trigger if exists commands_touch on public.commands;
create trigger commands_touch before update on public.commands
  for each row execute function public.touch_updated_at();

alter table public.commands enable row level security;
drop policy if exists cmd_select on public.commands;
drop policy if exists cmd_insert on public.commands;
drop policy if exists cmd_update on public.commands;
create policy cmd_select on public.commands for select to authenticated
  using (public.app_role() in ('admin', 'device'));
create policy cmd_insert on public.commands for insert to authenticated
  with check (public.app_role() = 'admin' and status = 'pending');
create policy cmd_update on public.commands for update to authenticated
  using (public.app_role() = 'device') with check (public.app_role() = 'device');

-- ---------- hak akses tabel ----------
revoke all on public.app_users, public.device_state, public.telemetry, public.commands from anon, authenticated;
grant select, insert, update on public.device_state to authenticated;
grant select, insert         on public.telemetry    to authenticated;
grant select, insert         on public.commands     to authenticated;
grant update (status, note, updated_at) on public.commands to authenticated;

-- ---------- fungsi: ambil perintah berikutnya (dipakai ESP32) ----------
create or replace function public.next_command(p_device text)
returns table(id bigint, cmd text, value int)
language plpgsql security invoker set search_path = public as $$
#variable_conflict use_column
begin
  if public.app_role() is distinct from 'device' then
    return;
  end if;
  -- perintah lebih dari 30 detik dianggap kedaluwarsa
  update public.commands c
     set status = 'rejected', note = 'kedaluwarsa'
   where c.device_id = p_device and c.status = 'pending'
     and c.created_at < now() - interval '30 seconds';
  return query
    select c.id, c.cmd, c.value from public.commands c
     where c.device_id = p_device and c.status = 'pending'
     order by c.id limit 1;
end $$;
revoke all on function public.next_command(text) from public, anon;
grant execute on function public.next_command(text) to authenticated;

-- ---------- fungsi: deret waktu ringkas untuk grafik (~240 titik) ----------
create or replace function public.telemetry_series(p_device text, p_hours int)
returns table(t timestamptz, pv_w real, ld_w real, bt_w real, ld_a real, h2t real)
language sql stable security invoker set search_path = public as $$
  select to_timestamp(floor(extract(epoch from created_at) / greatest(1, p_hours * 15))
                      * greatest(1, p_hours * 15)) as t,
         avg(pv_w)::real, avg(ld_w)::real, avg(bt_w)::real, avg(ld_a)::real, avg(h2t)::real
    from public.telemetry
   where device_id = p_device
     and created_at >= now() - make_interval(hours => least(720, greatest(1, p_hours)))
   group by 1
   order by 1
$$;
revoke all on function public.telemetry_series(text, int) from public, anon;
grant execute on function public.telemetry_series(text, int) to authenticated;

-- ---------- Realtime ----------
do $$ begin
  alter publication supabase_realtime add table public.device_state;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.commands;
exception when duplicate_object then null; end $$;

-- ==================================================
-- LANGKAH MANUAL SETELAH MEMBUAT USER
-- Authentication -> Users -> Add user (centang "Auto Confirm User"):
--   1) akun untukmu (admin, dipakai login di web)
--   2) akun perangkat (dipakai ESP32)
-- Lalu ganti email di bawah dan jalankan:
-- ==================================================
-- insert into public.app_users (user_id, role)
--   select id, 'admin'  from auth.users where email = 'EMAIL_KAMU@example.com'
--   on conflict (user_id) do update set role = excluded.role;
-- insert into public.app_users (user_id, role)
--   select id, 'device' from auth.users where email = 'EMAIL_PERANGKAT@example.com'
--   on conflict (user_id) do update set role = excluded.role;

-- ==================================================
-- OPSIONAL: hapus histori > 30 hari tiap hari (aktifkan extension pg_cron dulu)
-- ==================================================
-- select cron.schedule('ems-retention', '0 3 * * *',
--   $$delete from public.telemetry where created_at < now() - interval '30 days'$$);
