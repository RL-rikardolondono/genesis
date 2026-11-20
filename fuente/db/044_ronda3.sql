-- 044 · Colegio-IA v0.30 (20 nov 2026): correcciones de la 3.ª vuelta de la Prueba Ácida
-- 1) Regresión del 043: el estudiante de una familia con pagos pendientes volvía a entrar (debe_vencido usaba estado_cuenta,
--    que desde el 043 solo responde al acudiente). Ahora usa el cálculo interno.
-- 2) Excusa aprobada por el director de grupo: la justificación de fallas la hace la base (todas las asignaturas)
-- 3) Nadie cambia el correo de una cuenta ya activada ni el suyo propio (evita tomarse la cuenta de otro)
-- 4) Una recuperación aprobada no la cambia ni la borra quien no puede aprobar; «Registró» conserva a quien la preparó
-- Se puede ejecutar más de una vez.
begin;

-- ---------- 1) Deuda vencida sin depender de quién pregunta ----------
create or replace function priv.cuenta_int(e uuid, y int)
returns table(concepto_id uuid, concepto text, tipo text, mes integer, valor numeric, pagado numeric, saldo numeric, vencido boolean)
language sql stable security definer set search_path = public, pg_temp as $$
  select b.concepto_id, b.concepto, b.tipo, b.mes, b.valor, b.pagado, b.saldo, b.vencido
  from priv.cuenta_base(e, y) b where b.valor > 0 or b.pagado > 0
$$;
revoke all on function priv.cuenta_int(uuid, int) from public, anonymous, authenticated;
create or replace function priv.debe_vencido(e uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select not priv.acuerdo_al_dia(e) and exists (
    select 1 from estudiantes s join colegios k on k.id = s.colegio_id
    cross join lateral generate_series(greatest(extract(year from k.creado_en)::int, k.anio - 5), k.anio) y
    cross join lateral priv.cuenta_int(s.id, y) x
    where s.id = e and x.vencido and x.saldo > 0)
$$;
create or replace function public.mi_situacion_familia(p_colegio uuid) returns json
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(json_agg(json_build_object('estudiante_id', m.estudiante_id,
           'al_dia', not (k.restringir_morosos and not (m.rol = 'estudiante' and not k.restringir_estudiante) and priv.debe_vencido(m.estudiante_id)),
           'debe', priv.debe_vencido(m.estudiante_id),
           'por_vencer', (select coalesce(sum(x.saldo), 0) from priv.cuenta_int(m.estudiante_id, k.anio) x where not x.vencido and x.saldo > 0
                          and x.mes is not null and x.mes <= extract(month from priv.hoy_co())::int),
           'dia_limite', k.dia_limite_pago)), '[]'::json)
  from miembros m join colegios k on k.id = m.colegio_id
  where m.colegio_id = p_colegio and m.user_id = priv.uid() and m.activo and m.estudiante_id is not null
$$;

-- ---------- 2) Excusa aprobada: justifica las fallas en la base ----------
create or replace function priv.tg_excusa_justifica() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.estado = 'Aprobada' and old.estado is distinct from 'Aprobada' then
    update asistencia_clase set estado = 'E' where estudiante_id = new.estudiante_id and fecha between new.desde and new.hasta and estado = 'A';
    insert into asistencia (colegio_id, estudiante_id, fecha, estado)
      select new.colegio_id, new.estudiante_id, d::date, 'E' from generate_series(new.desde, new.hasta, interval '1 day') d
      where extract(isodow from d) between 1 and 5
    on conflict (estudiante_id, fecha) do update set estado = 'E';
  end if;
  return new;
end $$;
drop trigger if exists tg_excusa_justifica on public.excusas;
create trigger tg_excusa_justifica after update on public.excusas for each row execute function priv.tg_excusa_justifica();

-- ---------- 3) Correos de las cuentas ----------
create or replace function priv.tg_miembros_correo() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not priv.es_cliente() then return new; end if;
  if lower(coalesce(new.email, '')) is distinct from lower(coalesce(old.email, '')) then
    if old.user_id is not null then raise exception 'El correo de una cuenta ya activada no se cambia. Si la persona cambió de correo, invítela de nuevo con el correo nuevo y bloquee el acceso anterior'; end if;
    if not priv.es_rector(old.colegio_id) then raise exception 'Solo la rectoría corrige el correo de una invitación pendiente'; end if;
  end if;
  if old.user_id = priv.uid() and (new.activo is distinct from old.activo or new.user_id is distinct from old.user_id) then
    raise exception 'No puede desactivar ni desvincular su propio usuario';
  end if;
  return new;
end $$;
drop trigger if exists tg_miembros_correo on public.miembros;
create trigger tg_miembros_correo before update on public.miembros for each row execute function priv.tg_miembros_correo();

-- ---------- 4) Recuperaciones aprobadas ----------
create or replace function priv.tg_recup_aprobar() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare c uuid; exige boolean; apr boolean;
begin
  if not priv.es_cliente() then return coalesce(new, old); end if;
  select colegio_id into c from estudiantes where id = coalesce(new.estudiante_id, old.estudiante_id);
  exige := cardinality(priv.permiso_roles(c, 'aprobar_recup')) > 0; apr := priv.puede(c, 'aprobar_recup');
  if tg_op = 'DELETE' then
    if exige and not apr and old.aprobada and old.nota is not null then raise exception 'Esta recuperación ya fue aprobada: solo quien aprueba recuperaciones puede quitarla'; end if;
    return old;
  end if;
  if tg_op = 'UPDATE' then new.registrado_por := old.registrado_por; end if;   -- «Registró» sigue siendo quien la preparó
  if not exige or apr then
    if new.nota is not null and (tg_op = 'INSERT' or new.nota is distinct from old.nota or not old.aprobada) then
      new.aprobada := true; new.aprobada_por := case when exige then priv.nombre_actual(c) end;
    end if;
  else
    if tg_op = 'UPDATE' and old.aprobada and old.nota is not null and new.nota is distinct from old.nota then
      raise exception 'Esta recuperación ya fue aprobada: para cambiarla, pídalo a quien aprueba recuperaciones';
    end if;
    if new.nota is not null and (tg_op = 'INSERT' or new.nota is distinct from old.nota) then new.aprobada := false; new.aprobada_por := null;
    elsif tg_op = 'UPDATE' then new.aprobada := old.aprobada; new.aprobada_por := old.aprobada_por; end if;
  end if;
  return new;
end $$;
drop trigger if exists tg_recup_aprobar on public.recuperaciones;
drop trigger if exists zz_recup_aprobar on public.recuperaciones;
-- «zz»: corre después de tg_recuperaciones (que pone registrado_por), para conservar a quien la preparó
create trigger zz_recup_aprobar before insert or update or delete on public.recuperaciones for each row execute function priv.tg_recup_aprobar();

-- ---------- 5) Quien fue bloqueado ve de qué colegio y a quién llamar ----------
create or replace function public.mis_bloqueos() returns json
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(json_agg(json_build_object('rol', m.rol, 'colegio', k.nombre, 'telefono', k.telefono)), '[]'::json)
  from miembros m join colegios k on k.id = m.colegio_id where m.user_id = priv.uid() and not m.activo
$$;
revoke all on function public.mis_bloqueos() from public, anonymous;
grant execute on function public.mis_bloqueos() to authenticated;

-- ---------- 6) Gemas por entrar: solo cuando entra el estudiante (no su acudiente) ----------
do $$
declare d text := pg_get_functiondef('public.gemas_entrada(uuid)'::regprocedure);
begin
  if position('soy_estudiante' in d) = 0 then
    d := replace(d, $q$  if p_est is null or p_est not in (select priv.mis_estudiantes_al_dia()) then return 0; end if;$q$,
      $q$  if p_est is null or p_est not in (select priv.mis_estudiantes_al_dia()) or not priv.soy_estudiante(p_est) then return 0; end if;$q$);
    if position('soy_estudiante' in d) = 0 then raise exception 'No se pudo ajustar gemas_entrada'; end if;
    execute d;
  end if;
end $$;
-- ---------- 7) Matrícula en línea: queda el nombre del acudiente que actualizó (no «Sistema») ----------
do $$
declare d text := pg_get_functiondef('public.ml_datos(uuid, jsonb, jsonb)'::regprocedure);
begin
  if position('v_quien := coalesce' in d) = 0 then
    d := replace(d, $q$  v_quien := priv.nombre_actual(s.colegio_id);$q$,
      $q$  v_quien := coalesce((select max(mm.nombre) from miembros mm where mm.user_id = priv.uid() and mm.estudiante_id = p_est and mm.activo), priv.nombre_actual(s.colegio_id));$q$);
    if position('v_quien := coalesce' in d) = 0 then raise exception 'No se pudo ajustar ml_datos'; end if;
    execute d;
  end if;
end $$;
-- ---------- 8) Si el Superadministrador ya dejó el colegio pagado más allá de la prueba, deja de verse «en prueba» ----------
create or replace function priv.en_prueba(c uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from colegios k where k.id = c and k.prueba_hasta is not null and not k.demo
                 and coalesce(k.pagado_hasta, k.prueba_hasta) <= k.prueba_hasta
                 and not exists (select 1 from plataforma_pagos p where p.colegio_id = k.id))
$$;

-- ---------- 9) Excusas: saber si tiene foto del soporte sin descargarla ----------
alter table public.excusas add column if not exists con_soporte boolean generated always as (soporte is not null) stored;
-- ---------- 10) Colegios nuevos: los comunicados de los docentes pasan por revisión de coordinación o rectoría ----------
create or replace function priv.tg_colegio_permisos_ini() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if not (coalesce(new.permisos, '{}'::jsonb) ? 'comunicar') then
    new.permisos := coalesce(new.permisos, '{}'::jsonb) || jsonb_build_object('comunicar', jsonb_build_array('rector', 'coordinador', 'secretaria'));
  end if;
  return new;
end $$;
drop trigger if exists tg_colegio_permisos_ini on public.colegios;
create trigger tg_colegio_permisos_ini before insert on public.colegios for each row execute function priv.tg_colegio_permisos_ini();

-- ---------- 11) Cartera rápida: el cálculo del estado de cuenta pasa a plpgsql (el plan se reutiliza; con 1.350 estudiantes, de ~4 s a ~0,2 s) ----------
do $$
declare d text := pg_get_functiondef('priv.cuenta_base(uuid,int)'::regprocedure); b text;
begin
  if position('LANGUAGE sql' in d) > 0 then
    b := substring(d from position('AS $function$' in d) + 13);
    b := left(b, position('$function$' in b) - 1);
    execute format($f$create or replace function priv.cuenta_base(p_estudiante uuid, p_anio integer)
      returns table(concepto_id uuid, concepto text, tipo text, mes integer, valor numeric, pagado numeric, saldo numeric, vencido boolean, valor_base numeric, descuento numeric, orden integer)
      language plpgsql stable security definer set search_path = public, pg_temp as %L$f$,
      E'#variable_conflict use_column\nbegin\n  return query ' || b || E';\nend');
  end if;
end $$;

create or replace function public.cartera(p_colegio uuid, p_anio integer)
 returns table(estudiante_id uuid, nombre text, grupo text, estado text, cobrado numeric, pagado numeric, saldo_vencido numeric, saldo_total numeric)
 language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_actual int := (select anio from colegios where id = p_colegio);
begin
  if not priv.ve_pagos(p_colegio) then raise exception 'Sin permiso'; end if;
  return query
    select e.id, e.apellidos || ' ' || e.nombres,
           case when p_anio < v_actual then coalesce((select h.grupo_nombre from historial h where h.estudiante_id = e.id and h.anio = p_anio), g.nombre) else g.nombre end,
           e.estado,
           coalesce(sum(x.valor), 0), coalesce(sum(x.pagado), 0),
           coalesce(sum(x.saldo) filter (where x.vencido), 0), coalesce(sum(x.saldo), 0)
    from estudiantes e
    left join grupos g on g.id = e.grupo_id
    left join lateral (select b.* from priv.cuenta_base(e.id, p_anio) b where b.valor > 0 or b.pagado > 0) x on true
    where e.colegio_id = p_colegio and (e.estado <> 'Graduado' or p_anio < v_actual)
    group by e.id, e.apellidos, e.nombres, g.nombre, e.estado
    having p_anio >= v_actual or coalesce(sum(x.valor), 0) > 0
    order by 3 nulls last, e.apellidos;
end $$;

commit;
notify pgrst, 'reload schema';
