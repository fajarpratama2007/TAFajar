-- ==================================================
-- PATCH: batas arus cut-off configurable dari web (1-15A, hard clamp di firmware)
-- Jalankan di Supabase -> SQL Editor. Aman dijalankan ulang.
-- (Isi yang sama juga sudah ada di schema.sql.)
-- ==================================================

create table if not exists public.overload_settings (
  device_id  text primary key,
  cutoff_a   real not null default 7 check (cutoff_a between 1 and 15),
  rev        bigint not null default 1,
  updated_at timestamptz not null default now()
);
alter table public.overload_settings enable row level security;
drop policy if exists overload_read on public.overload_settings;
create policy overload_read on public.overload_settings for select to anon, authenticated using (true);
revoke all on public.overload_settings from anon, authenticated;
grant select on public.overload_settings to anon, authenticated;

create or replace function public.set_overload_cutoff(p_device text, p_cutoff real)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_cutoff is null or p_cutoff < 1 or p_cutoff > 15 then
    raise exception 'batas arus harus antara 1 dan 15 A';
  end if;

  insert into public.overload_settings (device_id, cutoff_a, rev, updated_at)
  values (p_device, p_cutoff, 1, now())
  on conflict (device_id) do update set
    rev = public.overload_settings.rev +
          case when public.overload_settings.cutoff_a is distinct from excluded.cutoff_a then 1 else 0 end,
    cutoff_a = excluded.cutoff_a,
    updated_at = now();
end $$;
revoke all on function public.set_overload_cutoff(text, real) from public;
grant execute on function public.set_overload_cutoff(text, real) to anon, authenticated;

create or replace function public.device_sync(p_device text, p_secret text, p_state jsonb, p_log boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cmd  record;
  v_sim  record;
  v_cut  record;
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
  select * into v_cut from public.overload_settings s where s.device_id = p_device;

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
                        'h2_full', v_sim.h2_full) end,
    'cut',  case when v_cut.device_id is null then null
                 else jsonb_build_object('rev', v_cut.rev, 'a', v_cut.cutoff_a) end);
end $$;
revoke all on function public.device_sync(text, text, jsonb, boolean) from public;
grant execute on function public.device_sync(text, text, jsonb, boolean) to anon, authenticated;
