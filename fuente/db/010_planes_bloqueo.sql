-- Genesis 010: corrección de asistencia, planes con tope de estudiantes, modo solo consulta por mora,
-- colegio de demostración sin cobro.

-- 1) Asistencia: el disparador común fallaba con "record new has no field anio"
create or replace function priv.tg_hijo_de_estudiante() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  select colegio_id into new.colegio_id from estudiantes where id = new.estudiante_id;
  if new.colegio_id is null then raise exception 'Estudiante no encontrado'; end if;
  if tg_table_name = 'notas' then
    if not exists (select 1 from asignaturas a where a.id = new.asignatura_id and a.colegio_id = new.colegio_id) then
      raise exception 'La asignatura no pertenece al colegio del estudiante';
    end if;
  end if;
  if tg_table_name in ('notas', 'observaciones', 'piar') then
    if new.anio is null then select anio into new.anio from colegios where id = new.colegio_id; end if;
  end if;
  if priv.es_cliente() then new.actualizado_por := priv.uid(); end if;
  if tg_table_name in ('notas', 'piar') then new.actualizado_en := now(); end if;
  return new;
end $$;

-- 2) Plan contratado y colegio de demostración
alter table public.colegios add column if not exists plan_max int not null default 100 check (plan_max > 0);
alter table public.colegios add column if not exists demo boolean not null default false;
update public.colegios k set plan_max = x.tope
from (select k2.id, case when n <= 100 then 100 when n <= 250 then 250 when n <= 500 then 500 when n <= 1000 then 1000
                         else (ceil(n / 100.0) * 100)::int end tope
      from colegios k2 cross join lateral (select count(*)::int n from estudiantes s where s.colegio_id = k2.id and s.estado = 'Activo') c) x
where x.id = k.id and k.plan_max = 100;
update public.colegios set demo = true where nombre = 'Colegio Demostración Genesis';
-- protegidos: el colegio no puede cambiar su propio plan ni marcarse como demostración
create or replace function priv.tg_colegios() returns trigger
language plpgsql as $$
begin
  if priv.es_cliente() then new.activo := old.activo; new.id := old.id; new.plan_max := old.plan_max; new.demo := old.demo; end if;
  return new;
end $$;

-- 3) Mora: el mes M se paga a más tardar el día 5 del mes siguiente
create or replace function priv.en_mora(c uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from colegios k
    cross join lateral generate_series(date_trunc('month', k.creado_en)::date, date_trunc('month', current_date)::date, interval '1 month') g(m)
    where k.id = c and not k.demo
      and current_date > (g.m + interval '1 month' + interval '4 days')::date
      and not exists (select 1 from plataforma_pagos p where p.colegio_id = c and p.mes = g.m::date))
$$;
create or replace function priv.meses_pendientes(c uuid) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select count(*)::int
  from colegios k
  cross join lateral generate_series(date_trunc('month', k.creado_en)::date, date_trunc('month', current_date)::date, interval '1 month') g(m)
  where k.id = c and not k.demo and not exists (select 1 from plataforma_pagos p where p.colegio_id = c and p.mes = g.m::date)
$$;

-- Bloqueo de escritura (solo consulta) y tope de estudiantes
create or replace function priv.tg_bloqueo() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare r jsonb := to_jsonb(case when tg_op = 'DELETE' then old else new end); c uuid; k colegios;
begin
  if priv.uid() is null or priv.es_superadmin() then return case when tg_op = 'DELETE' then old else new end; end if;
  c := (r ->> 'colegio_id')::uuid;
  if c is not null and priv.en_mora(c) then
    raise exception 'El colegio está en modo de solo consulta porque la suscripción de Genesis tiene un pago vencido. Al registrarse el pago se desbloquea de inmediato.';
  end if;
  if tg_table_name = 'estudiantes' and tg_op <> 'DELETE' then
    if r ->> 'estado' = 'Activo' and (tg_op = 'INSERT' or to_jsonb(old) ->> 'estado' <> 'Activo') then
      select * into k from colegios where id = c;
      if (select count(*) from estudiantes s where s.colegio_id = c and s.estado = 'Activo' and s.id <> (r ->> 'id')::uuid) >= k.plan_max then
        raise exception 'Su plan permite hasta % estudiantes activos. Para matricular más, solicite la ampliación del plan.', k.plan_max;
      end if;
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
do $$
declare t text;
begin
  foreach t in array array['estudiantes','grupos','asignaturas','notas','asistencia','asistencia_clase','observaciones','observador',
    'logros','actividades','notas_act','recuperaciones','comunicados','excusas','horario','pagos','acudientes','piar','conceptos',
    'costos_anio','miembros','docente_grupos','tareas'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists zz_bloqueo on public.%I', t);
      execute format('create trigger zz_bloqueo before insert or update or delete on public.%I for each row execute function priv.tg_bloqueo()', t);
    end if;
  end loop;
end $$;

-- 4) Lo que ve cada usuario del colegio (aviso de solo consulta)
create or replace function public.estado_colegio(p_colegio uuid) returns json
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare k colegios;
begin
  if not priv.es_miembro(p_colegio) then raise exception 'Sin permiso'; end if;
  select * into k from colegios where id = p_colegio;
  return json_build_object('en_mora', priv.en_mora(p_colegio), 'demo', k.demo, 'plan_max', k.plan_max,
    'activos', (select count(*) from estudiantes s where s.colegio_id = p_colegio and s.estado = 'Activo'));
end $$;
revoke execute on function public.estado_colegio(uuid) from anonymous;

create or replace function public.mi_suscripcion(p_colegio uuid) returns json
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare k colegios;
begin
  if not priv.es_directivo(p_colegio) then raise exception 'Sin permiso'; end if;
  select * into k from colegios where id = p_colegio;
  return json_build_object(
    'pagado_hasta', (select max(mes) from plataforma_pagos where colegio_id = p_colegio),
    'meses_pendientes', priv.meses_pendientes(p_colegio),
    'en_mora', priv.en_mora(p_colegio), 'demo', k.demo, 'plan_max', k.plan_max, 'valor', precio_plan(k.plan_max),
    'activos', (select count(*) from estudiantes s where s.colegio_id = p_colegio and s.estado = 'Activo'),
    'ultimos', coalesce((select json_agg(json_build_object('mes', mes, 'valor', valor, 'fecha', fecha) order by mes desc)
                         from (select * from plataforma_pagos where colegio_id = p_colegio order by mes desc limit 6) x), '[]'::json));
end $$;
revoke execute on function public.mi_suscripcion(uuid) from anonymous;

drop function if exists public.plataforma_resumen();
create or replace function public.plataforma_resumen()
returns table (colegio_id uuid, nombre text, ciudad text, activo boolean, estudiantes_activos int, valor_mensual int,
               creado_en timestamptz, anio int, pagado_hasta date, meses_pendientes int, plan_max int, demo boolean, en_mora boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not priv.es_superadmin() then raise exception 'Sin permiso'; end if;
  return query
    select k.id, k.nombre, k.ciudad, k.activo,
           (select count(*)::int from estudiantes s where s.colegio_id = k.id and s.estado = 'Activo'),
           case when k.demo then 0 else precio_plan(k.plan_max) end,
           k.creado_en, k.anio,
           (select max(p.mes) from plataforma_pagos p where p.colegio_id = k.id),
           priv.meses_pendientes(k.id), k.plan_max, k.demo, priv.en_mora(k.id)
    from colegios k order by k.creado_en;
end $$;
revoke execute on function public.plataforma_resumen() from anonymous;

create or replace function public.plataforma_plan(p_colegio uuid, p_plan int, p_demo boolean default false) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not priv.es_superadmin() then raise exception 'Sin permiso'; end if;
  if p_plan is null or p_plan < 1 then raise exception 'Plan no válido'; end if;
  perform set_config('micolegia.sistema', 'on', true);
  update colegios set plan_max = p_plan, demo = coalesce(p_demo, false) where id = p_colegio;
  perform set_config('micolegia.sistema', '', true);
end $$;
revoke execute on function public.plataforma_plan(uuid, int, boolean) from anonymous;

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
notify pgrst, 'reload schema';
