-- ==================================================
-- PATCH: logging battAvg & koreksi fuzzy ke telemetry
-- Jalankan di Supabase -> SQL Editor. Aman dijalankan ulang.
-- (Isi yang sama juga sudah ada di schema.sql.)
-- Firmware ESP32 harus sudah versi baru (mengirim field "bavg" & "fcor")
-- agar kolom ini mulai terisi datanya.
-- ==================================================

alter table public.telemetry add column if not exists batt_avg_w   real;
alter table public.telemetry add column if not exists fuzzy_corr_a real;

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
      (device_id, state, sim, pol, pv_v, pv_a, pv_w, ld_v, ld_a, ld_w, bt_v, bt_a, bt_w, h2a, h2t, surp, srv,
       batt_avg_w, fuzzy_corr_a)
    values (
      p_device, p_state->>'state', (p_state->>'sim')::boolean, (p_state->>'pol')::smallint,
      (p_state#>>'{pv,v}')::real, (p_state#>>'{pv,a}')::real, (p_state#>>'{pv,w}')::real,
      (p_state#>>'{ld,v}')::real, (p_state#>>'{ld,a}')::real, (p_state#>>'{ld,w}')::real,
      (p_state#>>'{bt,v}')::real, (p_state#>>'{bt,a}')::real, (p_state#>>'{bt,w}')::real,
      (p_state->>'h2a')::real, (p_state->>'h2t')::real, (p_state->>'surp')::real, (p_state->>'srv')::real,
      (p_state->>'bavg')::real, (p_state->>'fcor')::real);
  end if;
end $$;
revoke all on function public.device_push(text, text, jsonb, boolean) from public;
grant execute on function public.device_push(text, text, jsonb, boolean) to anon, authenticated;
