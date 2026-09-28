-- ==================================================
-- PATCH: kontrol Simulation Mode dari jarak jauh
-- Jalankan di Supabase -> SQL Editor. Aman dijalankan ulang.
-- (Isi yang sama juga sudah ada di schema.sql.)
--
-- Simulasi = kondisi yang DIINGINKAN (bukan antrean perintah):
--   web -> set_sim() -> tabel sim_settings -> ikut kembali di device_sync() -> ESP32
-- Pengaman: simulasi otomatis dianggap MATI bila tidak ada aktivitas dari halaman > 5 menit.
-- ==================================================

create table if not exists public.sim_settings (
  device_id  text primary key,
  enabled    boolean not null default false,
  partial    boolean not null default false,
  pv_v real not null default 12, pv_a real not null default 0,
  ld_v real not null default 12, ld_a real not null default 0,
  bt_v real not null default 12, bt_a real not null default 0,
  h2_full    boolean not null default false,
  rev        bigint  not null default 0,          -- naik hanya bila nilai berubah
  updated_at timestamptz not null default now()   -- detak terakhir dari halaman web
);
alter table public.sim_settings enable row level security;
drop policy if exists sim_read on public.sim_settings;
create policy sim_read on public.sim_settings for select to anon, authenticated using (true);
revoke all on public.sim_settings from anon, authenticated;
grant select on public.sim_settings to anon, authenticated;

create or replace function public.set_sim(
  p_device text, p_enabled boolean, p_partial boolean,
  p_pv_v real, p_pv_a real, p_ld_v real, p_ld_a real, p_bt_v real, p_bt_a real, p_h2_full boolean)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_pv_v not between 0 and 24 or p_pv_a not between 0 and 12
     or p_ld_v not between 0 and 24 or p_ld_a not between 0 and 12
     or p_bt_v not between 10 and 15 or p_bt_a not between -10 and 10 then
    raise exception 'nilai di luar rentang';
  end if;

  insert into public.sim_settings
    (device_id, enabled, partial, pv_v, pv_a, ld_v, ld_a, bt_v, bt_a, h2_full, rev, updated_at)
  values (p_device, p_enabled, p_partial, p_pv_v, p_pv_a, p_ld_v, p_ld_a, p_bt_v, p_bt_a, p_h2_full, 1, now())
  on conflict (device_id) do update set
    rev = public.sim_settings.rev + case
            when (public.sim_settings.enabled, public.sim_settings.partial,
                  public.sim_settings.pv_v, public.sim_settings.pv_a,
                  public.sim_settings.ld_v, public.sim_settings.ld_a,
                  public.sim_settings.bt_v, public.sim_settings.bt_a, public.sim_settings.h2_full)
                 is distinct from
                 (excluded.enabled, excluded.partial, excluded.pv_v, excluded.pv_a,
                  excluded.ld_v, excluded.ld_a, excluded.bt_v, excluded.bt_a, excluded.h2_full)
            then 1 else 0 end,
    enabled = excluded.enabled, partial = excluded.partial,
    pv_v = excluded.pv_v, pv_a = excluded.pv_a,
    ld_v = excluded.ld_v, ld_a = excluded.ld_a,
    bt_v = excluded.bt_v, bt_a = excluded.bt_a,
    h2_full = excluded.h2_full,
    updated_at = now();
end $$;
revoke all on function public.set_sim(text, boolean, boolean, real, real, real, real, real, real, boolean) from public;
grant execute on function public.set_sim(text, boolean, boolean, real, real, real, real, real, real, boolean) to anon, authenticated;

-- device_sync: sekarang juga mengembalikan pengaturan simulasi.
-- {"fast":bool, "cmd":{...}|null, "sim":{"rev":n,"enabled":bool(efektif),"partial":..,"pv_v":..}|null}
create or replace function public.device_sync(p_device text, p_secret text, p_state jsonb, p_log boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cmd  record;
  v_sim  record;
  v_fast boolean;
begin
  perform public.device_push(p_device, p_secret, p_state, p_log);   -- ikut memeriksa rahasia

  update public.commands c
     set status = 'rejected', note = 'kedaluwarsa'
   where c.device_id = p_device and c.status = 'pending'
     and c.created_at < now() - interval '30 seconds';

  select c.id, c.cmd, c.value into v_cmd
    from public.commands c
   where c.device_id = p_device and c.status = 'pending'
   order by c.id limit 1;

  select coalesce((select v.last_seen > now() - interval '30 seconds'
                     from public.viewers v where v.device_id = p_device), false)
    into v_fast;

  select * into v_sim from public.sim_settings s where s.device_id = p_device;

  return jsonb_build_object(
    'fast', v_fast,
    'cmd',  case when v_cmd.id is null then null
                 else jsonb_build_object('id', v_cmd.id, 'cmd', v_cmd.cmd, 'value', v_cmd.value) end,
    'sim',  case when v_sim.device_id is null then null
                 else jsonb_build_object(
                        'rev',     v_sim.rev,
                        'enabled', v_sim.enabled and v_sim.updated_at > now() - interval '5 minutes',
                        'partial', v_sim.partial,
                        'pv_v', v_sim.pv_v, 'pv_a', v_sim.pv_a,
                        'ld_v', v_sim.ld_v, 'ld_a', v_sim.ld_a,
                        'bt_v', v_sim.bt_v, 'bt_a', v_sim.bt_a,
                        'h2_full', v_sim.h2_full) end);
end $$;
revoke all on function public.device_sync(text, text, jsonb, boolean) from public;
grant execute on function public.device_sync(text, text, jsonb, boolean) to anon, authenticated;
