-- Genesis 015: regla de cobro de SkyNet Genesis.
-- "Pagado hasta" por colegio; del día 5 al 9 sin pago: aviso con cuenta regresiva; desde el día 10: acceso cerrado
-- (lo aplica la base de datos); pago por llave con "Ya pagué" + comprobante, que el administrador confirma o rechaza.

-- 1) Pagado hasta
alter table public.colegios add column if not exists pagado_hasta date;
alter table public.colegios alter column pagado_hasta set default (date_trunc('month', current_date) + interval '1 month - 1 day')::date;
update public.colegios k set pagado_hasta = coalesce(
    (select (max(p.mes) + interval '1 month - 1 day')::date from plataforma_pagos p where p.colegio_id = k.id),
    (date_trunc('month', k.creado_en) + interval '1 month - 1 day')::date)
  where pagado_hasta is null;

-- el colegio no puede cambiar su propio "pagado hasta"
create or replace function priv.tg_colegios() returns trigger
language plpgsql as $$
begin
  if priv.es_cliente() then new.activo := old.activo; new.id := old.id; new.plan_max := old.plan_max; new.demo := old.demo; new.pagado_hasta := old.pagado_hasta; end if;
  return new;
end $$;

-- 2) Estado de cobro: activa / aviso (días 5 a 9 sin pago) / cerrada (desde el día 10)
create or replace function priv.dias_sin_pago(p_hasta date) returns int language sql stable as $$
  select greatest(current_date - p_hasta, 0) $$;
create or replace function priv.estado_cobro(p_activo boolean, p_demo boolean, p_hasta date) returns text language sql stable as $$
  select case when not p_activo then 'suspendido'
              when p_demo or p_hasta is null or current_date - p_hasta < 5 then 'activa'
              when current_date - p_hasta < 10 then 'aviso'
              else 'cerrada' end $$;
create or replace function priv.acceso_ok(p_activo boolean, p_demo boolean, p_hasta date) returns boolean language sql stable as $$
  select p_activo and (p_demo or p_hasta is null or current_date - p_hasta < 10) $$;
create or replace function priv.meses_debe(p_hasta date) returns int language sql stable as $$
  select greatest(1, ((extract(year from current_date) * 12 + extract(month from current_date)) - (extract(year from p_hasta) * 12 + extract(month from p_hasta)))::int) $$;

-- Membresía sin tener en cuenta el pago (para ver el estado y pagar aunque el acceso esté cerrado)
create or replace function priv.roles_base(c uuid) returns text[]
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(array_agg(distinct m.rol), '{}')
  from miembros m join colegios k on k.id = m.colegio_id
  where m.colegio_id = c and m.user_id = priv.uid() and m.activo and k.activo
$$;
create or replace function priv.es_miembro_base(c uuid) returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select cardinality(priv.roles_base(c)) > 0 $$;
create or replace function priv.es_directivo_base(c uuid) returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select priv.roles_base(c) && array['rector','coordinador','secretaria','tesoreria'] $$;

-- 3) El acceso cerrado por pago se aplica en todos los permisos (lectura y escritura)
do $$
declare f text; d text;
begin
  foreach f in array array['roles_en','es_familia_de','docente_de_grupo','puede_ver_estudiante','docente_de_asig','mis_estudiantes'] loop
    select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'priv' and p.proname = f;
    if d is not null and position('priv.acceso_ok' in d) = 0 then
      execute replace(d, 'k.activo', 'priv.acceso_ok(k.activo, k.demo, k.pagado_hasta)');
    end if;
  end loop;
end $$;
-- los miembros siguen viendo el nombre de su colegio (para la pantalla de pago)
drop policy if exists colegios_ver on public.colegios;
create policy colegios_ver on public.colegios for select to authenticated using (priv.es_miembro_base(id) or priv.es_superadmin());
-- modo solo consulta anterior: ahora equivale a "cerrada"
create or replace function priv.en_mora(c uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from colegios k where k.id = c and priv.estado_cobro(true, k.demo, k.pagado_hasta) = 'cerrada')
$$;

-- 4) Datos de pago de SkyNet Genesis (llave, enlace Bold, WhatsApp de soporte)
create table if not exists public.plataforma_config (
  id int primary key default 1 check (id = 1),
  llave text, titular text, bold_url text, whatsapp text default '3044375758',
  actualizado_en timestamptz default now()
);
insert into public.plataforma_config (id) values (1) on conflict do nothing;
alter table public.plataforma_config enable row level security;
grant select, update on public.plataforma_config to authenticated;
drop policy if exists pc_ver on public.plataforma_config;
create policy pc_ver on public.plataforma_config for select to authenticated using (true);
drop policy if exists pc_admin on public.plataforma_config;
create policy pc_admin on public.plataforma_config for update to authenticated using (priv.es_superadmin()) with check (priv.es_superadmin());

-- 5) Comprobantes de pago de la suscripción ("Ya pagué")
create table if not exists public.plataforma_comprobantes (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  meses int not null default 1 check (meses between 1 and 24),
  valor numeric(12,0) not null check (valor > 0),
  referencia text,
  imagen text check (imagen is null or length(imagen) < 250000),
  estado text not null default 'Pendiente' check (estado in ('Pendiente','Confirmado','Rechazado')),
  respuesta text,
  enviado_por text,
  creado_en timestamptz not null default now(),
  revisado_en timestamptz
);
create unique index if not exists plataforma_comprobantes_uno on public.plataforma_comprobantes (colegio_id) where estado = 'Pendiente';
create or replace function priv.tg_plat_comp() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not priv.es_directivo_base(new.colegio_id) then raise exception 'Solo los directivos del colegio pueden reportar el pago'; end if;
  if new.imagen is null and coalesce(btrim(new.referencia), '') = '' then raise exception 'Adjunte la foto del comprobante o escriba la referencia'; end if;
  new.estado := 'Pendiente'; new.respuesta := null; new.revisado_en := null; new.creado_en := now();
  new.enviado_por := (select max(m.nombre) from miembros m where m.colegio_id = new.colegio_id and m.user_id = priv.uid());
  return new;
end $$;
drop trigger if exists tg_plat_comp on public.plataforma_comprobantes;
create trigger tg_plat_comp before insert on public.plataforma_comprobantes for each row execute function priv.tg_plat_comp();
alter table public.plataforma_comprobantes enable row level security;
grant select, insert on public.plataforma_comprobantes to authenticated;
drop policy if exists pcc_ver on public.plataforma_comprobantes;
create policy pcc_ver on public.plataforma_comprobantes for select to authenticated using (priv.es_directivo_base(colegio_id) or priv.es_superadmin());
drop policy if exists pcc_ins on public.plataforma_comprobantes;
create policy pcc_ins on public.plataforma_comprobantes for insert to authenticated with check (priv.es_directivo_base(colegio_id));

-- 6) Al registrar un pago de suscripción, "pagado hasta" avanza solo
create or replace function priv.tg_plat_pago() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform set_config('micolegia.sistema', 'on', true);
  update colegios set pagado_hasta = greatest(coalesce(pagado_hasta, '1900-01-01'), (date_trunc('month', new.mes) + interval '1 month - 1 day')::date)
  where id = new.colegio_id;
  perform set_config('micolegia.sistema', '', true);
  return new;
end $$;
drop trigger if exists tg_plat_pago on public.plataforma_pagos;
create trigger tg_plat_pago after insert on public.plataforma_pagos for each row execute function priv.tg_plat_pago();

-- 7) Funciones del administrador de la plataforma
create or replace function public.plataforma_revisar_comprobante(p_id uuid, p_aprobar boolean, p_respuesta text default null) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare c plataforma_comprobantes; k colegios; i int; m date;
begin
  if not priv.es_superadmin() then raise exception 'Sin permiso'; end if;
  select * into c from plataforma_comprobantes where id = p_id for update;
  if c.id is null or c.estado <> 'Pendiente' then raise exception 'El comprobante ya fue revisado'; end if;
  if p_aprobar then
    select * into k from colegios where id = c.colegio_id;
    m := (date_trunc('month', coalesce(k.pagado_hasta, current_date)) + interval '1 month')::date;
    for i in 1 .. c.meses loop
      insert into plataforma_pagos (colegio_id, mes, valor, fecha, medio, referencia)
        values (c.colegio_id, m, round(c.valor / c.meses), current_date, 'Llave', coalesce(c.referencia, 'Comprobante'));
      m := (m + interval '1 month')::date;
    end loop;
    update plataforma_comprobantes set estado = 'Confirmado', imagen = null, revisado_en = now(), respuesta = p_respuesta where id = p_id;
  else
    if coalesce(btrim(p_respuesta), '') = '' then raise exception 'Escriba el motivo del rechazo'; end if;
    update plataforma_comprobantes set estado = 'Rechazado', imagen = null, revisado_en = now(), respuesta = p_respuesta where id = p_id;
  end if;
  return json_build_object('pagado_hasta', (select pagado_hasta from colegios where id = c.colegio_id));
end $$;
create or replace function public.plataforma_pagado_hasta(p_colegio uuid, p_fecha date) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not priv.es_superadmin() then raise exception 'Sin permiso'; end if;
  perform set_config('micolegia.sistema', 'on', true);
  update colegios set pagado_hasta = p_fecha where id = p_colegio;
  perform set_config('micolegia.sistema', '', true);
end $$;

-- 8) Lo que ve el colegio
create or replace function public.estado_colegio(p_colegio uuid) returns json
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare k colegios; cfg plataforma_config; pc plataforma_comprobantes; e text;
begin
  if not (priv.es_miembro_base(p_colegio) or priv.es_superadmin()) then raise exception 'Sin permiso'; end if;
  select * into k from colegios where id = p_colegio;
  select * into cfg from plataforma_config where id = 1;
  select * into pc from plataforma_comprobantes where colegio_id = p_colegio order by creado_en desc limit 1;
  e := priv.estado_cobro(k.activo, k.demo, k.pagado_hasta);
  return json_build_object('cobro', e, 'en_mora', e = 'cerrada', 'demo', k.demo, 'plan_max', k.plan_max,
    'pagado_hasta', k.pagado_hasta, 'dias', case when e = 'aviso' then 10 - priv.dias_sin_pago(k.pagado_hasta) else null end,
    'meses_debe', case when e in ('aviso', 'cerrada') or current_date > k.pagado_hasta then priv.meses_debe(k.pagado_hasta) else 0 end,
    'valor_mes', precio_plan(k.plan_max),
    'directivo', priv.es_directivo_base(p_colegio),
    'llave', cfg.llave, 'titular', cfg.titular, 'bold_url', cfg.bold_url, 'whatsapp', coalesce(cfg.whatsapp, '3044375758'),
    'comprobante', case when pc.id is null then null else json_build_object('estado', pc.estado, 'fecha', pc.creado_en, 'respuesta', pc.respuesta, 'valor', pc.valor) end,
    'activos', case when priv.acceso_ok(k.activo, k.demo, k.pagado_hasta) then (select count(*) from estudiantes s where s.colegio_id = p_colegio and s.estado = 'Activo') end);
end $$;

create or replace function public.mi_suscripcion(p_colegio uuid) returns json
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare k colegios;
begin
  if not priv.es_directivo_base(p_colegio) then raise exception 'Sin permiso'; end if;
  select * into k from colegios where id = p_colegio;
  return json_build_object(
    'pagado_hasta', k.pagado_hasta, 'cobro', priv.estado_cobro(k.activo, k.demo, k.pagado_hasta),
    'meses_pendientes', case when current_date > k.pagado_hasta then priv.meses_debe(k.pagado_hasta) else 0 end,
    'en_mora', priv.en_mora(p_colegio), 'demo', k.demo, 'plan_max', k.plan_max, 'valor', precio_plan(k.plan_max),
    'activos', (select count(*) from estudiantes s where s.colegio_id = p_colegio and s.estado = 'Activo'),
    'ultimos', coalesce((select json_agg(json_build_object('id', id, 'mes', mes, 'valor', valor, 'fecha', fecha, 'medio', medio, 'referencia', referencia) order by mes desc)
                         from (select * from plataforma_pagos where colegio_id = p_colegio order by mes desc limit 12) x), '[]'::json));
end $$;

drop function if exists public.plataforma_resumen();
create or replace function public.plataforma_resumen()
returns table (colegio_id uuid, nombre text, ciudad text, activo boolean, estudiantes_activos int, valor_mensual int,
               creado_en timestamptz, anio int, pagado_hasta date, meses_pendientes int, plan_max int, demo boolean, en_mora boolean,
               cobro text, dias int, comprobante_id uuid)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not priv.es_superadmin() then raise exception 'Sin permiso'; end if;
  return query
    select k.id, k.nombre, k.ciudad, k.activo,
           (select count(*)::int from estudiantes s where s.colegio_id = k.id and s.estado = 'Activo'),
           case when k.demo then 0 else precio_plan(k.plan_max) end,
           k.creado_en, k.anio, k.pagado_hasta,
           case when k.demo or current_date <= k.pagado_hasta then 0 else priv.meses_debe(k.pagado_hasta) end,
           k.plan_max, k.demo, priv.en_mora(k.id),
           priv.estado_cobro(k.activo, k.demo, k.pagado_hasta),
           case when priv.estado_cobro(k.activo, k.demo, k.pagado_hasta) = 'aviso' then 10 - priv.dias_sin_pago(k.pagado_hasta) end,
           (select pc.id from plataforma_comprobantes pc where pc.colegio_id = k.id and pc.estado = 'Pendiente')
    from colegios k order by k.creado_en;
end $$;

revoke execute on function public.plataforma_resumen() from anonymous;
revoke execute on function public.plataforma_revisar_comprobante(uuid, boolean, text) from anonymous;
revoke execute on function public.plataforma_pagado_hasta(uuid, date) from anonymous;
revoke execute on function public.estado_colegio(uuid) from anonymous;
revoke execute on function public.mi_suscripcion(uuid) from anonymous;
revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
notify pgrst, 'reload schema';
