-- ==================================================
-- EMS Dashboard — skema Supabase (TANPA login / role user)
-- Jalankan seluruh file ini di Supabase -> SQL Editor (sekali).
-- Aman dijalankan ulang (idempotent) dan membersihkan skema lama berbasis login.
--
-- Model akses:
--   * Web (kunci anon)  : hanya BACA data + kirim perintah polaritas.
--   * ESP32 (kunci anon + rahasia perangkat) : menulis lewat fungsi device_* di bawah.
--     Tanpa rahasia yang benar, siapa pun tidak bisa memalsukan data.
-- ==================================================

-- ---------- bersihkan skema lama (berbasis login) ----------
drop function if exists public.app_role() cascade;   -- ikut menghapus policy lama
drop table    if exists public.app_users;
drop function if exists public.next_command(text);

-- ---------- trigger updated_at ----------
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------- rahasia perangkat ----------
create table if not exists public.device_secrets (
  device_id   text primary key,
  secret_hash text not null
);
alter table public.device_secrets enable row level security;   -- tanpa policy = tertutup
revoke all on public.device_secrets from anon, authenticated;

create or replace function public.check_device(p_device text, p_secret text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (
    select 1 from public.device_secrets s
     where s.device_id = p_device
       and s.secret_hash = encode(digest(coalesce(p_secret, ''), 'sha256'), 'hex'));
$$;
revoke all on function public.check_device(text, text) from public, anon, authenticated;

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
drop policy if exists state_read on public.device_state;
create policy state_read on public.device_state for select to anon, authenticated using (true);

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
drop policy if exists tele_read on public.telemetry;
create policy tele_read on public.telemetry for select to anon, authenticated using (true);

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

-- Jeda minimal 10 detik antar perintah (cegah spam relay)
create or replace function public.commands_cooldown() returns trigger
language plpgsql as $$
begin
  if exists (select 1 from public.commands c
              where c.device_id = new.device_id
                and c.created_at > now() - interval '10 seconds') then
    raise exception 'terlalu cepat, tunggu beberapa detik' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists commands_cooldown_trg on public.commands;
create trigger commands_cooldown_trg before insert on public.commands
  for each row execute function public.commands_cooldown();

alter table public.commands enable row level security;
drop policy if exists cmd_read   on public.commands;
drop policy if exists cmd_insert on public.commands;
create policy cmd_read   on public.commands for select to anon, authenticated using (true);
create policy cmd_insert on public.commands for insert to anon, authenticated
  with check (status = 'pending' and note is null);

-- ---------- hak akses tabel (web hanya baca + kirim perintah) ----------
revoke all on public.device_state, public.telemetry, public.commands from anon, authenticated;
grant select on public.device_state, public.telemetry, public.commands to anon, authenticated;
grant insert (device_id, cmd, value) on public.commands to anon, authenticated;

-- ---------- fungsi untuk ESP32 (memakai rahasia perangkat) ----------
-- Kirim kondisi terbaru; p_log = true juga menyimpan satu baris histori.
create or replace function public.device_push(p_device text, p_secret text, p_state jsonb, p_log boolean default false)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.check_device(p_device, p_secret) then
    raise exception 'unauthorized' using errcode = '28000';
  end if;

  insert into public.device_state (device_id, data) values (p_device, p_state)
  on conflict (device_id) do update set data = excluded.data;

  if p_log then
    insert into public.telemetry
      (device_id, state, sim, pol, pv_v, pv_a, pv_w, ld_v, ld_a, ld_w, bt_v, bt_a, bt_w, h2a, h2t, surp, srv)
    values (
      p_device, p_state->>'state', (p_state->>'sim')::boolean, (p_state->>'pol')::smallint,
      (p_state#>>'{pv,v}')::real, (p_state#>>'{pv,a}')::real, (p_state#>>'{pv,w}')::real,
      (p_state#>>'{ld,v}')::real, (p_state#>>'{ld,a}')::real, (p_state#>>'{ld,w}')::real,
      (p_state#>>'{bt,v}')::real, (p_state#>>'{bt,a}')::real, (p_state#>>'{bt,w}')::real,
      (p_state->>'h2a')::real, (p_state->>'h2t')::real, (p_state->>'surp')::real, (p_state->>'srv')::real);
  end if;
end $$;
revoke all on function public.device_push(text, text, jsonb, boolean) from public;
grant execute on function public.device_push(text, text, jsonb, boolean) to anon, authenticated;

-- Ambil perintah berikutnya (perintah > 30 detik dianggap kedaluwarsa).
create or replace function public.device_next_command(p_device text, p_secret text)
returns table(id bigint, cmd text, value int)
language plpgsql security definer set search_path = public, extensions as $$
#variable_conflict use_column
begin
  if not public.check_device(p_device, p_secret) then
    raise exception 'unauthorized' using errcode = '28000';
  end if;
  update public.commands c
     set status = 'rejected', note = 'kedaluwarsa'
   where c.device_id = p_device and c.status = 'pending'
     and c.created_at < now() - interval '30 seconds';
  return query
    select c.id, c.cmd, c.value from public.commands c
     where c.device_id = p_device and c.status = 'pending'
     order by c.id limit 1;
end $$;
revoke all on function public.device_next_command(text, text) from public;
grant execute on function public.device_next_command(text, text) to anon, authenticated;

-- Laporkan hasil perintah.
create or replace function public.device_ack_command(p_device text, p_secret text, p_id bigint, p_status text, p_note text default null)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.check_device(p_device, p_secret) then
    raise exception 'unauthorized' using errcode = '28000';
  end if;
  if p_status not in ('done', 'rejected') then
    raise exception 'status tidak valid';
  end if;
  update public.commands
     set status = p_status, note = p_note
   where id = p_id and device_id = p_device and status = 'pending';
end $$;
revoke all on function public.device_ack_command(text, text, bigint, text, text) from public;
grant execute on function public.device_ack_command(text, text, bigint, text, text) to anon, authenticated;

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
revoke all on function public.telemetry_series(text, int) from public;
grant execute on function public.telemetry_series(text, int) to anon, authenticated;

-- ---------- Realtime ----------
do $$ begin
  alter publication supabase_realtime add table public.device_state;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.commands;
exception when duplicate_object then null; end $$;

-- ==================================================
-- LANGKAH MANUAL: daftarkan rahasia perangkat (SEKALI)
-- Buat rahasia acak (misal 24+ karakter), simpan di secrets.h ESP32 (DEVICE_SECRET),
-- lalu jalankan SQL ini dengan rahasia yang sama (hanya hash-nya yang disimpan):
-- ==================================================
-- insert into public.device_secrets (device_id, secret_hash)
-- values ('ems-01', encode(extensions.digest('RAHASIA_PERANGKAT_ANDA', 'sha256'), 'hex'))
-- on conflict (device_id) do update set secret_hash = excluded.secret_hash;

-- ==================================================
-- OPSIONAL: hapus histori > 30 hari tiap hari (aktifkan extension pg_cron dulu)
-- ==================================================
-- select cron.schedule('ems-retention', '0 3 * * *',
--   $$delete from public.telemetry where created_at < now() - interval '30 days'$$);
