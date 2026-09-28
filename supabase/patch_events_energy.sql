-- ==================================================
-- PATCH: retensi terkonfigurasi, log kejadian (events), ringkasan energi
-- Jalankan di Supabase -> SQL Editor. Aman dijalankan ulang.
-- (Isi yang sama juga sudah ada di schema.sql.)
-- ==================================================

-- ---------- konfigurasi (retensi data, dll) — hanya admin (SQL Editor), tertutup dari anon ----------
create table if not exists public.app_config (
  key   text primary key,
  value text not null
);
alter table public.app_config enable row level security;   -- tanpa policy = tertutup total
revoke all on public.app_config from anon, authenticated;

insert into public.app_config (key, value) values ('retention_days', '90')
on conflict (key) do nothing;

-- Hapus telemetry & events yang lebih tua dari retention_days. Dipanggil oleh pg_cron tiap hari.
-- Ganti masa retensi via SQL Editor: update public.app_config set value='180' where key='retention_days';
create or replace function public.run_retention() returns void
language plpgsql security definer set search_path = public as $$
declare
  days int;
begin
  select coalesce(value::int, 90) into days from public.app_config where key = 'retention_days';
  delete from public.telemetry where created_at < now() - make_interval(days => days);
  delete from public.events    where created_at < now() - make_interval(days => days);
end $$;
revoke all on function public.run_retention() from public, anon, authenticated;

-- pg_cron: kalau gagal (butuh privilege lebih tinggi di sebagian project Supabase),
-- aktifkan manual dulu: Dashboard -> Database -> Extensions -> cari "pg_cron" -> Enable,
-- lalu jalankan ulang BLOK INI SAJA (baris ini sampai akhir bagian retensi).
do $$ begin
  create extension if not exists pg_cron;
exception when insufficient_privilege then
  raise notice 'pg_cron perlu diaktifkan manual lewat Dashboard -> Database -> Extensions, lalu jalankan ulang blok ini.';
end $$;

do $$ begin
  perform cron.unschedule('ems-retention');
exception when others then null; end $$;
do $$ begin
  perform cron.schedule('ems-retention', '0 3 * * *', 'select public.run_retention()');
exception when others then
  raise notice 'Jadwal retensi belum terpasang (pg_cron belum aktif). Aktifkan extension pg_cron lalu jalankan ulang blok ini.';
end $$;

-- ---------- log kejadian (trip, ganti polaritas, ON/OFF simulasi) ----------
-- Dideteksi otomatis dari perubahan device_state (update tiap 0,5-5 dtk) — jauh lebih rapat
-- dari sampling telemetry (10 dtk), jadi trip sesingkat apa pun tetap tercatat.
-- Tidak perlu ubah firmware sama sekali.
create table if not exists public.events (
  id         bigint generated always as identity primary key,
  device_id  text not null,
  created_at timestamptz not null default now(),
  kind       text not null check (kind in ('state', 'polarity', 'sim')),
  from_val   text,
  to_val     text not null
);
create index if not exists events_dev_time on public.events (device_id, created_at desc);
create index if not exists events_dev_kind_time on public.events (device_id, kind, created_at desc);

alter table public.events enable row level security;
drop policy if exists events_read on public.events;
create policy events_read on public.events for select to anon, authenticated using (true);
revoke all on public.events from anon, authenticated;
grant select on public.events to anon, authenticated;

create or replace function public.log_state_events() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  old_state text; new_state text;
  old_pol   text; new_pol   text;
  old_sim   text; new_sim   text;
begin
  old_state := old.data->>'state';  new_state := new.data->>'state';
  old_pol   := old.data->>'pol';    new_pol   := new.data->>'pol';
  old_sim   := old.data->>'sim';    new_sim   := new.data->>'sim';

  if new_state is not null and new_state is distinct from old_state then
    insert into public.events (device_id, kind, from_val, to_val) values (new.device_id, 'state', old_state, new_state);
  end if;
  if new_pol is not null and new_pol is distinct from old_pol then
    insert into public.events (device_id, kind, from_val, to_val) values (new.device_id, 'polarity', old_pol, new_pol);
  end if;
  if new_sim is not null and new_sim is distinct from old_sim then
    insert into public.events (device_id, kind, from_val, to_val) values (new.device_id, 'sim', old_sim, new_sim);
  end if;
  return new;
end $$;

drop trigger if exists device_state_events on public.device_state;
create trigger device_state_events after update on public.device_state
  for each row execute function public.log_state_events();

-- Ringkasan durasi & jumlah kemunculan tiap state dalam rentang waktu (untuk hitung trip, uptime%, dll).
create or replace function public.event_summary(p_device text, p_from timestamptz, p_to timestamptz)
returns table(state text, occurrences bigint, total_seconds double precision)
language sql stable security invoker set search_path = public as $$
  with s as (
    select to_val as state, created_at,
           lead(created_at) over (order by created_at) as next_at
      from public.events
     where device_id = p_device and kind = 'state'
       and created_at >= p_from and created_at <= p_to
  )
  select state, count(*)::bigint as occurrences,
         sum(extract(epoch from (coalesce(next_at, p_to) - created_at)))::double precision as total_seconds
    from s
   group by state
   order by total_seconds desc nulls last
$$;
revoke all on function public.event_summary(text, timestamptz, timestamptz) from public;
grant execute on function public.event_summary(text, timestamptz, timestamptz) to anon, authenticated;

-- ---------- energi (integral daya x waktu dari tabel telemetry mentah) ----------
create or replace function public.energy_summary(p_device text, p_from timestamptz, p_to timestamptz)
returns table(pv_wh real, ld_wh real, bt_charge_wh real, bt_discharge_wh real, samples bigint, span_hours real)
language sql stable security invoker set search_path = public as $$
  with t as (
    select created_at, pv_w, ld_w, bt_w,
           lag(created_at) over (order by created_at) as prev_at
      from public.telemetry
     where device_id = p_device and created_at >= p_from and created_at <= p_to
  ),
  d as (
    select pv_w, ld_w, bt_w,
           least(extract(epoch from (created_at - prev_at)), 60) as dt_s
      from t where prev_at is not null
  )
  select
    (coalesce(sum(pv_w * dt_s), 0) / 3600)::real as pv_wh,
    (coalesce(sum(ld_w * dt_s), 0) / 3600)::real as ld_wh,
    (coalesce(sum(case when bt_w > 0 then bt_w * dt_s else 0 end), 0) / 3600)::real as bt_charge_wh,
    (coalesce(sum(case when bt_w < 0 then -bt_w * dt_s else 0 end), 0) / 3600)::real as bt_discharge_wh,
    (select count(*) from t)::bigint as samples,
    (extract(epoch from (p_to - p_from)) / 3600)::real as span_hours
  from d
$$;
revoke all on function public.energy_summary(text, timestamptz, timestamptz) from public;
grant execute on function public.energy_summary(text, timestamptz, timestamptz) to anon, authenticated;

-- Rekap energi per hari, p_days hari terakhir (untuk tabel "energi harian").
create or replace function public.daily_energy(p_device text, p_days int default 30)
returns table(day date, pv_wh real, ld_wh real, bt_charge_wh real, bt_discharge_wh real)
language sql stable security invoker set search_path = public as $$
  with t as (
    select created_at, pv_w, ld_w, bt_w,
           lag(created_at) over (order by created_at) as prev_at
      from public.telemetry
     where device_id = p_device
       and created_at >= now() - make_interval(days => least(365, greatest(1, p_days)))
  ),
  d as (
    select date_trunc('day', created_at) as day, pv_w, ld_w, bt_w,
           least(extract(epoch from (created_at - prev_at)), 60) as dt_s
      from t where prev_at is not null
  )
  select day::date,
         (sum(pv_w * dt_s) / 3600)::real,
         (sum(ld_w * dt_s) / 3600)::real,
         (sum(case when bt_w > 0 then bt_w * dt_s else 0 end) / 3600)::real,
         (sum(case when bt_w < 0 then -bt_w * dt_s else 0 end) / 3600)::real
    from d
   group by day
   order by day
$$;
revoke all on function public.daily_energy(text, int) from public;
grant execute on function public.daily_energy(text, int) to anon, authenticated;

-- ---------- Realtime untuk events ----------
do $$ begin
  alter publication supabase_realtime add table public.events;
exception when duplicate_object then null; end $$;
