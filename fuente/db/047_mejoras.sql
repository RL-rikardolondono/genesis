-- 047 · Colegio-IA v0.33 (21 nov 2026): mejoras pendientes de las vueltas 5 y 6 de la Prueba Ácida
-- 1) Pagos: desde la aplicación no se registra un pago sin concepto ni por más del saldo de esa cuota (antes se podía por la API)
-- 2) Nadie crea por la API un acceso ya ligado a una cuenta (p. ej. una secretaría que se agrega como acudiente);
--    las cuentas se ligan con el código de activación (o solas, cuando el acudiente de otro hijo ya tiene cuenta)
-- 3) Estudiantes migrados «al día hasta» un mes: lo que deben desde el mes siguiente vence normal (no se toma la fecha
--    de la carga como fecha de matrícula) y el contrato muestra el año completo desde ese mes
-- 4) La lista de estudiantes en riesgo del inicio cuenta la recuperación aprobada (igual que el boletín)
-- 5) La familia no ve actividades de contenidos ni unidades ocultas del campus
begin;

-- ---------- 1) Pagos ----------
create or replace function priv.saldo_cuota(e uuid, y int, c uuid, m int) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select case when priv.ve_pagos((select colegio_id from estudiantes where id = e)) then
    (select coalesce(sum(x.saldo), 0) from priv.cuenta_base(e, y) x where x.concepto_id = c and x.mes is not distinct from m) end
$$;
create or replace function priv.mes_cuota(e uuid, y int, c uuid) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select case when count(*) = 1 then min(x.mes) end from priv.cuenta_base(e, y) x where x.concepto_id = c
$$;
revoke all on function priv.mes_cuota(uuid, int, uuid) from public, anonymous;
grant execute on function priv.mes_cuota(uuid, int, uuid) to authenticated;
revoke all on function priv.saldo_cuota(uuid, int, uuid, int) from public, anonymous;
grant execute on function priv.saldo_cuota(uuid, int, uuid, int) to authenticated;
create or replace function priv.tg_pagos_saldo() returns trigger
language plpgsql set search_path = public, pg_temp as $$
declare sal numeric;
begin
  if current_user <> 'authenticated' then return new; end if;   -- solo lo que llega directo de la aplicación (no Bold ni procesos del sistema)
  if new.concepto_id is null then raise exception 'Cada pago debe corresponder a un cobro (concepto y mes)'; end if;
  if new.mes is null then new.mes := priv.mes_cuota(new.estudiante_id, new.anio, new.concepto_id); end if;   -- cobro único (matrícula, seguro): se toma su mes
  sal := priv.saldo_cuota(new.estudiante_id, new.anio, new.concepto_id, new.mes);
  if sal is not null and new.valor > sal then
    raise exception 'El valor (%) supera el saldo de esa cuota (%). Revise el valor o la cuota', to_char(new.valor, 'FM999G999G999'), to_char(sal, 'FM999G999G999');
  end if;
  return new;
end $$;
drop trigger if exists tg_pagos_saldo on public.pagos;
create trigger tg_pagos_saldo before insert on public.pagos for each row execute function priv.tg_pagos_saldo();

-- ---------- 2) Accesos ligados solo por activación ----------
create or replace function priv.tg_miembros_alta() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if current_user = 'authenticated' and new.user_id is not null then
    raise exception 'El acceso se crea como invitación: la persona lo activa con el código que le entrega el colegio';
  end if;
  return new;
end $$;
drop trigger if exists a_miembros_alta on public.miembros;
create trigger a_miembros_alta before insert on public.miembros for each row execute function priv.tg_miembros_alta();

-- ---------- 3) Migrados «al día hasta» ----------
do $$
declare d text := pg_get_functiondef('priv.cuenta_base(uuid,integer)'::regprocedure);
begin
  if position('e.al_dia_hasta is not null and extract' in d) = 0 then
    d := replace(d, $q$           case when extract(year from e.fecha_matricula)::int = p_anio then e.fecha_matricula$q$,
      $q$           case when e.al_dia_hasta is not null and extract(year from e.al_dia_hasta)::int = p_anio then null
                when extract(year from e.fecha_matricula)::int = p_anio then e.fecha_matricula$q$);
    if position('e.al_dia_hasta is not null and extract' in d) = 0 then raise exception 'No se pudo ajustar cuenta_base'; end if;
    execute d;
  end if;
end $$;

-- ---------- 4) Definitivas con la recuperación aprobada ----------
do $$
declare d text := pg_get_functiondef('public.definitivas(uuid,integer)'::regprocedure);
begin
  if position('recuperaciones' in d) = 0 then
    d := replace(d, 'sum(n.valor * p.peso)', $q$sum(greatest(n.valor, coalesce((select max(r.nota) from recuperaciones r where r.estudiante_id = n.estudiante_id and r.asignatura_id = n.asignatura_id
        and r.anio = n.anio and r.periodo = n.periodo and r.nota is not null and coalesce(r.aprobada, true)), n.valor)) * p.peso)$q$);
    if position('recuperaciones' in d) = 0 then raise exception 'No se pudo ajustar definitivas'; end if;
    execute d;
  end if;
end $$;

-- ---------- 5) La familia no ve actividades de contenidos ocultos del campus (ni de unidades ocultas) ----------
drop policy if exists act_ver on public.actividades;
create policy act_ver on public.actividades for select to authenticated using (priv.es_personal(colegio_id) or (priv.es_miembro(colegio_id)
  and not exists (select 1 from campus_items i join campus_unidades u on u.id = i.unidad_id
                  where i.actividad_id = actividades.id and (not i.visible or not u.visible))));

commit;
notify pgrst, 'reload schema';
