-- ==================================================
-- PATCH: sinkronisasi cepat adaptif (0,5 dtk saat ada penonton)
-- Jalankan di Supabase -> SQL Editor. Aman dijalankan ulang.
-- (Isi yang sama juga sudah ada di schema.sql.)
-- ==================================================

-- Penonton: halaman web memanggil viewer_ping() tiap ~10 detik saat tab terlihat.
create table if not exists public.viewers (
  device_id text primary key,
  last_seen timestamptz not null default now()
);
alter table public.viewers enable row level security;   -- tanpa policy = tertutup
revoke all on public.viewers from anon, authenticated;

create or replace function public.viewer_ping(p_device text) returns void
language sql security definer set search_path = public as $$
  insert into public.viewers (device_id, last_seen) values (p_device, now())
  on conflict (device_id) do update set last_seen = now();
$$;
revoke all on function public.viewer_ping(text) from public;
grant execute on function public.viewer_ping(text) to anon, authenticated;

-- ESP32: satu panggilan = kirim kondisi (+ histori bila p_log) + ambil perintah + tahu ada penonton.
-- Mengembalikan {"fast": true/false, "cmd": {"id":..,"cmd":..,"value":..} | null}
create or replace function public.device_sync(p_device text, p_secret text, p_state jsonb, p_log boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cmd  record;
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

  return jsonb_build_object(
    'fast', v_fast,
    'cmd',  case when v_cmd.id is null then null
                 else jsonb_build_object('id', v_cmd.id, 'cmd', v_cmd.cmd, 'value', v_cmd.value) end);
end $$;
revoke all on function public.device_sync(text, text, jsonb, boolean) from public;
grant execute on function public.device_sync(text, text, jsonb, boolean) to anon, authenticated;
