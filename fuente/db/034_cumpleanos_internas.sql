-- Colegio-IA 034 (30 oct 2026)
--  1) Recordatorio de cumpleaños: estudiantes (fecha de nacimiento de la ficha) y directivos/docentes (fecha nueva en
--     Usuarios y accesos). Lo ven solo los directivos (rector, coordinación y secretaría) en una ventana al entrar
--     una vez al día y en un recuadro del Inicio: los de hoy y los de los próximos 7 días.
--  2) Instituciones internas del dueño (directiva del 30 oct 2026): el Superadministrador marca un colegio como
--     "interno" (con motivo): queda activo para siempre, sin prueba, sin cobros y sin límite de estudiantes.
--     Se marca de una vez el Colegio Cristiano Anglocolombiano (orden del 29 oct 2026).
--  3) Superadministrador: «Cuentas y accesos» (todas las cuentas de todos los colegios, con último ingreso y bloqueo
--     con motivo). Las contraseñas están cifradas: nadie puede verlas.

begin;

-- 1) Cumpleaños
alter table public.miembros add column if not exists fnac date;
alter table public.miembros drop constraint if exists miembros_fnac_ok;
alter table public.miembros add constraint miembros_fnac_ok check (fnac is null or fnac between date '1920-01-01' and date '2015-12-31');

-- próximo cumpleaños a partir de una fecha (29 de febrero se celebra el 28 en años no bisiestos)
create or replace function priv.prox_cumple(f date, desde date) returns date
language sql immutable as $$
  with a as (select y, make_date(y, extract(month from f)::int,
                    least(extract(day from f)::int, extract(day from (make_date(y, extract(month from f)::int, 1) + interval '1 month - 1 day'))::int)) as d
             from (values (extract(year from desde)::int), (extract(year from desde)::int + 1)) v(y))
  select min(d) from a where d >= desde
$$;

create or replace function public.cumpleanos(p_colegio uuid, p_dias int default 7)
returns table(tipo text, id uuid, nombre text, detalle text, fecha date, dias int, edad int, telefono text, acudiente text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare hoy date := priv.hoy_co(); n int := least(greatest(coalesce(p_dias, 7), 0), 31);
begin
  -- solo directivos: rector(a), coordinación y secretaría
  if not exists (select 1 from miembros m where m.colegio_id = p_colegio and m.user_id = priv.uid() and m.activo
                 and m.rol in ('rector', 'coordinador', 'secretaria')) then
    raise exception 'Sin permiso';
  end if;
  return query
    select x.tipo, x.id, x.nombre, x.detalle, x.fecha, (x.fecha - hoy)::int, (extract(year from x.fecha) - extract(year from x.fnac))::int, x.tel, x.acu
    from (
      select 'estudiante'::text as tipo, s.id, s.nombres || ' ' || s.apellidos as nombre, coalesce(g.nombre, '') as detalle, s.fnac,
             priv.prox_cumple(s.fnac, hoy) as fecha,
             coalesce(a.telefono, s.acudiente_tel, s.telefono) as tel, coalesce(a.nombres, s.acudiente_nombre) as acu
      from estudiantes s
      left join grupos g on g.id = s.grupo_id
      left join lateral (select a.telefono, a.nombres from acudientes a where a.estudiante_id = s.id and nullif(a.telefono, '') is not null
                         order by a.responsable_pago desc, a.orden limit 1) a on true
      where s.colegio_id = p_colegio and s.estado = 'Activo' and s.fnac is not null
      union all
      (select distinct on (lower(m.email)) 'funcionario', m.id, m.nombre,
             case m.rol when 'rector' then 'Rector(a)' when 'coordinador' then 'Coordinación' when 'secretaria' then 'Secretaría'
                        when 'tesoreria' then 'Tesorería' else 'Docente' end,
             m.fnac, priv.prox_cumple(m.fnac, hoy), null::text, null::text
      from miembros m
      where m.colegio_id = p_colegio and m.activo and m.estudiante_id is null and m.fnac is not null
        and m.rol in ('rector', 'coordinador', 'secretaria', 'tesoreria', 'docente')
      order by lower(m.email), case m.rol when 'rector' then 1 when 'coordinador' then 2 when 'secretaria' then 3 when 'tesoreria' then 4 else 5 end)
    ) x
    where x.fecha - hoy between 0 and n
    order by x.fecha, x.tipo desc, x.nombre;
end $$;

-- 2) Instituciones internas
alter table public.colegios add column if not exists interna boolean not null default false;
alter table public.colegios add column if not exists interna_motivo text;
alter table public.colegios add column if not exists interna_en timestamptz;
alter table public.colegios add column if not exists interna_por text;
create or replace function priv.tg_colegios() returns trigger
language plpgsql as $$
begin
  if priv.es_cliente() then
    new.activo := old.activo; new.id := old.id; new.plan_max := old.plan_max; new.demo := old.demo; new.pagado_hasta := old.pagado_hasta;
    new.interna := old.interna; new.interna_motivo := old.interna_motivo; new.interna_en := old.interna_en; new.interna_por := old.interna_por;
  end if;
  return new;
end $$;

create or replace function public.plataforma_interna(p_colegio uuid, p_interna boolean, p_motivo text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare k colegios; act int;
begin
  if not priv.es_superadmin() then raise exception 'Sin permiso'; end if;
  select * into k from colegios where id = p_colegio;
  if k.id is null then raise exception 'Colegio no encontrado'; end if;
  if k.demo then raise exception 'El colegio de demostración no se marca como interno'; end if;
  if length(trim(coalesce(p_motivo, ''))) < 3 then raise exception 'Escriba el motivo'; end if;
  select count(*) into act from estudiantes s where s.colegio_id = p_colegio and s.estado = 'Activo';
  perform set_config('micolegia.sistema', 'on', true);
  if k.interna = p_interna then raise exception 'Sin cambios: el colegio ya estaba %', case when p_interna then 'marcado como interno' else 'como cliente normal' end; end if;
  if p_interna then
    update colegios set interna = true, interna_motivo = trim(p_motivo), interna_en = now(),
           interna_por = coalesce((select u.email from neon_auth."user" u where u.id::text = priv.uid()), 'superadministrador'),
           pagado_hasta = date '2099-12-31', prueba_hasta = null, plan_max = 99999, activo = true
     where id = p_colegio;
  else
    update colegios set interna = false, interna_motivo = trim(p_motivo), interna_en = now(),
           interna_por = coalesce((select u.email from neon_auth."user" u where u.id::text = priv.uid()), 'superadministrador'),
           pagado_hasta = (date_trunc('month', priv.hoy_co()) + interval '1 month - 1 day')::date,
           plan_max = case when act <= 100 then 100 when act <= 250 then 250 when act <= 500 then 500 when act <= 1000 then 1000
                           else (ceil(act / 100.0) * 100)::int end
     where id = p_colegio;
  end if;
  perform set_config('micolegia.sistema', '', true);
end $$;

-- el resumen del Superadministrador trae la marca de interna (cambia el tipo de retorno: se vuelve a crear)
drop function if exists public.plataforma_resumen();
create function public.plataforma_resumen()
 returns table(colegio_id uuid, nombre text, ciudad text, activo boolean, estudiantes_activos integer, valor_mensual integer, creado_en timestamptz,
               anio integer, pagado_hasta date, meses_pendientes integer, plan_max integer, demo boolean, en_mora boolean, cobro text, dias integer,
               comprobante_id uuid, interna boolean, interna_motivo text)
 language plpgsql stable security definer set search_path = public, pg_temp as $function$
begin
  if not priv.es_superadmin() then raise exception 'Sin permiso'; end if;
  return query
    select k.id, k.nombre, k.ciudad, k.activo,
           (select count(*)::int from estudiantes s where s.colegio_id = k.id and s.estado = 'Activo'),
           case when k.demo or k.interna then 0 else precio_plan(k.plan_max) end,
           k.creado_en, k.anio, k.pagado_hasta,
           case when k.demo or k.interna or current_date <= k.pagado_hasta then 0 else priv.meses_debe(k.pagado_hasta) end,
           k.plan_max, k.demo, priv.en_mora(k.id),
           priv.estado_cobro(k.activo, k.demo, k.pagado_hasta),
           case when priv.estado_cobro(k.activo, k.demo, k.pagado_hasta) = 'aviso' then 10 - priv.dias_sin_pago(k.pagado_hasta) end,
           (select pc.id from plataforma_comprobantes pc where pc.colegio_id = k.id and pc.estado = 'Pendiente'),
           k.interna, k.interna_motivo
    from colegios k order by k.creado_en;
end $function$;

-- el correo diario de la prueba gratis nunca va a una institución interna
do $$
declare d text;
begin
  d := pg_get_functiondef('public.pruebas_para_correo'::regproc);
  if position('k.interna' in d) = 0 then
    d := replace(d, 'where k.activo and not k.demo and', 'where k.activo and not k.demo and not k.interna and');
    if position('k.interna' in d) = 0 then raise exception 'No se encontró dónde excluir las instituciones internas del correo de prueba'; end if;
    execute d;
  end if;
end $$;

-- 3) Cuentas y accesos (Superadministrador)
alter table public.miembros add column if not exists bloqueo_motivo text;
create or replace function public.plataforma_cuentas()
returns table(miembro_id uuid, colegio_id uuid, colegio text, nombre text, email text, rol text, estudiante text, activo boolean,
              cuenta_creada boolean, ultimo_acceso timestamptz, creado_en timestamptz, bloqueo_motivo text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not priv.es_superadmin() then raise exception 'Sin permiso'; end if;
  return query
    select m.id, k.id, k.nombre, m.nombre, m.email, m.rol, case when s.id is null then null else s.nombres || ' ' || s.apellidos end, m.activo,
           m.user_id is not null, m.ultimo_acceso, m.creado_en, m.bloqueo_motivo
    from miembros m join colegios k on k.id = m.colegio_id left join estudiantes s on s.id = m.estudiante_id
    where not k.demo
    order by k.nombre, case m.rol when 'rector' then 1 when 'coordinador' then 2 when 'secretaria' then 3 when 'tesoreria' then 4 when 'docente' then 5 else 6 end, m.nombre, m.id;
end $$;
-- un bloqueo del Superadministrador (con motivo) no lo puede quitar el colegio
create or replace function priv.tg_miembros() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  new.email := lower(btrim(new.email));
  if tg_op = 'INSERT' then
    if priv.es_cliente() then
      new.user_id := null; new.bloqueo_motivo := null;
      if exists (select 1 from miembros b where b.colegio_id = new.colegio_id and lower(b.email) = lower(btrim(new.email)) and b.bloqueo_motivo is not null) then
        raise exception 'Esta cuenta está bloqueada por la administración de Colegio-IA. Comuníquese con soporte (WhatsApp 304 437 5758)';
      end if;
    end if;
    new.codigo := priv.nuevo_codigo();
  else
    new.colegio_id := old.colegio_id;
    if priv.es_cliente() then
      new.user_id := old.user_id; new.codigo := old.codigo; new.bloqueo_motivo := old.bloqueo_motivo;
      if old.bloqueo_motivo is not null then new.activo := old.activo; end if;
    end if;
    if new.email <> old.email then new.user_id := null; new.codigo := priv.nuevo_codigo(); end if;
  end if;
  if new.estudiante_id is not null and not exists (select 1 from estudiantes s where s.id = new.estudiante_id and s.colegio_id = new.colegio_id) then
    raise exception 'El estudiante no pertenece al colegio';
  end if;
  return new;
end $$;
create or replace function priv.tg_miembros_permiso() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare dir text[] := array['rector','coordinador','secretaria','tesoreria'];
begin
  if not priv.es_cliente() or priv.es_superadmin() then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then
    if old.bloqueo_motivo is not null then raise exception 'Esta cuenta está bloqueada por la administración de Colegio-IA y no se puede quitar'; end if;
    if old.rol = any(dir) and not priv.es_rector(old.colegio_id) then raise exception 'Solo el rector o la rectora pueden quitar usuarios directivos'; end if;
    return old;
  end if;
  if (new.rol = any(dir) or (tg_op = 'UPDATE' and old.rol = any(dir))) and not priv.es_rector(new.colegio_id) then
    raise exception 'Solo el rector o la rectora pueden crear o cambiar usuarios directivos (rectoría, coordinación, secretaría y tesorería)';
  end if;
  if tg_op = 'UPDATE' and old.user_id = priv.uid() and old.activo and not new.activo then
    raise exception 'No puede desactivar su propio usuario';
  end if;
  return new;
end $$;
create or replace function public.plataforma_bloquear(p_miembro uuid, p_bloquear boolean, p_motivo text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not priv.es_superadmin() then raise exception 'Sin permiso'; end if;
  if p_bloquear and length(trim(coalesce(p_motivo, ''))) < 3 then raise exception 'Escriba el motivo del bloqueo'; end if;
  perform set_config('micolegia.sistema', 'on', true);
  update miembros set activo = not p_bloquear, bloqueo_motivo = case when p_bloquear then trim(p_motivo) end where id = p_miembro;
  if not found then raise exception 'Cuenta no encontrada'; end if;
  perform set_config('micolegia.sistema', '', true);
end $$;

-- 4) Demostración: dos estudiantes cumplen hoy, dos en los próximos días, y fechas para los funcionarios
create or replace function priv.demo_cumple(c uuid, a int) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare h date := priv.hoy_co(); r record; i int := 0; t date;
begin
  for r in select s.id, s.fnac from estudiantes s where s.colegio_id = c and s.estado = 'Activo' and s.fnac is not null order by s.folio limit 4 loop
    t := h + (array[0, 0, 2, 5])[i + 1];
    update estudiantes set fnac = make_date(extract(year from r.fnac)::int, extract(month from t)::int,
                                             case when extract(month from t) = 2 and extract(day from t) = 29 then 28 else extract(day from t)::int end)
     where id = r.id;
    i := i + 1;
  end loop;
  update miembros m set fnac = make_date(1980 + (abs(hashtext(m.email)) % 15), 1 + (abs(hashtext(m.email || 'm')) % 12), 1 + (abs(hashtext(m.email || 'd')) % 28))
   where m.colegio_id = c and m.estudiante_id is null and m.fnac is null;
end $$;
do $$
declare d text;
begin
  d := pg_get_functiondef('priv.crear_demo'::regproc);
  if position('demo_cumple' in d) = 0 then
    d := replace(d, '  perform priv.demo_contrato(c, a);', '  perform priv.demo_contrato(c, a);' || chr(10) || '  perform priv.demo_cumple(c, a);');
    if position('demo_cumple' in d) = 0 then raise exception 'No se encontró dónde agregar los cumpleaños a la demostración'; end if;
    execute d;
  end if;
end $$;
select priv.demo_cumple(id, anio) from colegios where demo;

-- 5) Colegio Cristiano Anglocolombiano: institución interna (orden del dueño del 29 oct 2026)
do $$
declare n int;
begin
  select count(*) into n from colegios where not demo and nombre ilike '%anglocolombiano%';
  if n > 1 then raise exception 'Hay % colegios con el nombre Anglocolombiano: márquelo a mano desde el panel', n; end if;
  if n = 1 then
    perform set_config('micolegia.sistema', 'on', true);
    update colegios set interna = true, interna_motivo = 'Institución propia del dueño de SkyNet Genesis (orden del 29 oct 2026)',
           interna_en = now(), interna_por = 'SQL 034', pagado_hasta = date '2099-12-31', prueba_hasta = null, plan_max = 99999, activo = true
     where not demo and nombre ilike '%anglocolombiano%';
    perform set_config('micolegia.sistema', '', true);
  end if;
end $$;

grant execute on function public.cumpleanos(uuid, int), public.plataforma_interna(uuid, boolean, text), public.plataforma_resumen(),
  public.plataforma_cuentas(), public.plataforma_bloquear(uuid, boolean, text) to authenticated;
revoke execute on function public.cumpleanos(uuid, int), public.plataforma_interna(uuid, boolean, text), public.plataforma_resumen(),
  public.plataforma_cuentas(), public.plataforma_bloquear(uuid, boolean, text) from public, anonymous;

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
revoke execute on function priv.cuenta_base(uuid, integer), priv.demo_contrato(uuid, integer), priv.demo_cumple(uuid, integer) from authenticated;
commit;
notify pgrst, 'reload schema';
