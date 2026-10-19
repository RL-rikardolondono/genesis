-- Colegio-IA 024 (entrega 3 de la revisión del 18 oct 2026): la demostración como embudo de venta.
--  1) Cualquier persona registra su colegio desde la app y tiene 15 días de prueba gratis (una sola vez por correo,
--     sin renovación). Al día 15 se cierra el acceso si no ha pagado; se paga en línea con Bold (firmador central).
--  2) El primer pago cubre el mes en que termina la prueba (o el mes en curso si la prueba ya terminó).
--  3) El Superadministrador ve los colegios en prueba, con quién los registró y cuántos días les quedan.

-- 1) Datos de la prueba gratis
alter table public.colegios add column if not exists prueba_hasta date;
alter table public.colegios add column if not exists registro_email text;
alter table public.colegios add column if not exists registro_tel text;
create table if not exists public.plataforma_pruebas (
  email text primary key,              -- en minúsculas: una sola prueba por correo, nunca se renueva
  user_id text not null,
  colegio_id uuid references public.colegios(id) on delete set null,
  colegio_nombre text,
  creado_en timestamptz not null default now()
);
alter table public.plataforma_pruebas enable row level security;
revoke all on public.plataforma_pruebas from authenticated, anonymous;

-- ¿El colegio está en prueba gratis (registrado por su cuenta y sin ningún pago)?
create or replace function priv.en_prueba(c uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from colegios k where k.id = c and k.prueba_hasta is not null and not k.demo
                 and not exists (select 1 from plataforma_pagos p where p.colegio_id = k.id))
$$;

-- 2) Registro del colegio por su cuenta (quien lo registra queda como rector o rectora)
create or replace function public.registrar_colegio(p_nombre text, p_ciudad text, p_plan int, p_grados int[], p_telefono text)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare u text := priv.uid(); em text := lower(btrim(coalesce(priv.email_actual(), ''))); nm text; c uuid; a int; mid uuid; hoy date := priv.hoy_co(); g int;
        tel text := regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g');
        gtxt text[] := array['Prejardín','Jardín','Transición','Primero','Segundo','Tercero','Cuarto','Quinto','Sexto','Séptimo','Octavo','Noveno','Décimo','Undécimo'];
begin
  if u is null or em = '' then raise exception 'Inicie sesión para registrar su colegio'; end if;
  if length(btrim(coalesce(p_nombre, ''))) < 5 or length(p_nombre) > 120 then raise exception 'Escriba el nombre completo del colegio'; end if;
  if length(btrim(coalesce(p_ciudad, ''))) < 3 or length(p_ciudad) > 80 then raise exception 'Escriba la ciudad o el municipio'; end if;
  if p_plan not in (100, 250, 500, 1000) then raise exception 'Elija el número de estudiantes'; end if;
  if length(tel) not between 7 and 12 then raise exception 'Escriba un número de celular o WhatsApp válido'; end if;
  if p_grados is null or cardinality(p_grados) = 0 then raise exception 'Marque los grados que ofrece el colegio'; end if;
  if exists (select 1 from unnest(p_grados) x where x not between -2 and 11) then raise exception 'Hay un grado no válido'; end if;
  if exists (select 1 from plataforma_pruebas where email = em or user_id = u) then
    raise exception 'Con esta cuenta ya se registró un colegio de prueba. La prueba gratis es una sola vez; para continuar, pague la suscripción o escríbanos por WhatsApp al 304 437 5758.';
  end if;
  if exists (select 1 from miembros m join colegios k on k.id = m.colegio_id where m.user_id = u and m.rol = 'rector' and not k.demo) then
    raise exception 'Usted ya es rector(a) de un colegio en Colegio-IA. Entre con su perfil desde "Perfil".';
  end if;
  if (select count(*) from plataforma_pruebas where creado_en > now() - interval '1 day') >= 40 then
    raise exception 'Hoy se registraron muchos colegios. Intente mañana o escríbanos por WhatsApp al 304 437 5758.';
  end if;
  nm := coalesce((select nullif(btrim(to_jsonb(x) ->> 'name'), '') from neon_auth."user" x where x.id::text = u), split_part(em, '@', 1));
  a := extract(year from hoy)::int;
  perform set_config('micolegia.sistema', 'on', true);
  -- "Pagado hasta" queda 5 días antes del fin de la prueba: así el acceso se cierra justo al terminar los 15 días
  insert into colegios (nombre, ciudad, rector_nombre, anio, plan_max, pagado_hasta, prueba_hasta, registro_email, registro_tel, telefono, campus_activo)
  values (btrim(p_nombre), btrim(p_ciudad), nm, a, p_plan, hoy + 10, hoy + 15, em, tel, tel, true) returning id into c;
  perform priv.plan_base(c);
  perform priv.conceptos_base(c, a);
  foreach g in array (select array_agg(distinct x order by x) from unnest(p_grados) x) loop
    insert into grupos (colegio_id, nombre, grado, nivel)
    values (c, gtxt[g + 3] || ' A', g, case when g <= 0 then 'preescolar' when g <= 5 then 'primaria' when g <= 9 then 'secundaria' else 'media' end)
    on conflict do nothing;
  end loop;
  insert into miembros (colegio_id, email, nombre, rol, user_id) values (c, em, nm, 'rector', u) returning id into mid;
  insert into plataforma_pruebas (email, user_id, colegio_id, colegio_nombre) values (em, u, c, btrim(p_nombre));
  perform set_config('micolegia.sistema', '', true);
  return json_build_object('miembro_id', mid, 'colegio_id', c, 'prueba_hasta', hoy + 15);
end $$;
revoke execute on function public.registrar_colegio(text, text, int, int[], text) from public, anonymous;
grant execute on function public.registrar_colegio(text, text, int, int[], text) to authenticated;

-- 3) La app sabe si el colegio está en prueba y cuántos días le quedan
do $$
declare d text;
begin
  d := pg_get_functiondef('public.estado_colegio'::regproc);
  if position('en_prueba' in d) = 0 then
    d := replace(d, $q$'valor_mes', precio_plan(k.plan_max),$q$,
      $q$'valor_mes', precio_plan(k.plan_max), 'en_prueba', priv.en_prueba(p_colegio), 'prueba_hasta', k.prueba_hasta,
    'dias_prueba', case when priv.en_prueba(p_colegio) then greatest(0, k.prueba_hasta - priv.hoy_co()) end,$q$);
    if position('en_prueba' in d) = 0 then raise exception 'No se pudo actualizar estado_colegio'; end if;
    execute d;
  end if;
  d := pg_get_functiondef('public.mi_suscripcion'::regproc);
  if position('en_prueba' in d) = 0 then
    d := replace(d, $q$'en_mora', priv.en_mora(p_colegio),$q$,
      $q$'en_mora', priv.en_mora(p_colegio), 'en_prueba', priv.en_prueba(p_colegio), 'prueba_hasta', k.prueba_hasta,
    'dias_prueba', case when priv.en_prueba(p_colegio) then greatest(0, k.prueba_hasta - priv.hoy_co()) end,$q$);
    if position('en_prueba' in d) = 0 then raise exception 'No se pudo actualizar mi_suscripcion'; end if;
    execute d;
  end if;
end $$;

-- 4) Pago con Bold: el primer pago de un colegio en prueba cubre el mes en que termina la prueba
--    (o el mes en curso si ya terminó), en lugar del mes siguiente a "Pagado hasta"
do $$
declare d text;
begin
  if to_regprocedure('public.bold_pago_aprobado(text, integer, integer, text, text)') is null then
    raise notice 'bold_pago_aprobado no existe en esta base (se omite)'; return;
  end if;
  d := pg_get_functiondef('public.bold_pago_aprobado(text, integer, integer, text, text)'::regprocedure);
  if position('prueba_hasta' in d) = 0 then
    d := replace(d, $q$m := (date_trunc('month', coalesce(k.pagado_hasta, current_date)) + interval '1 month')::date;$q$,
      $q$if k.prueba_hasta is not null and not exists (select 1 from plataforma_pagos x where x.colegio_id = v_id) then
    m := date_trunc('month', greatest(current_date, k.prueba_hasta - 1))::date;
  else
    m := (date_trunc('month', coalesce(k.pagado_hasta, current_date)) + interval '1 month')::date;
  end if;$q$);
    if position('prueba_hasta' in d) = 0 then raise notice 'AVISO: no se pudo actualizar bold_pago_aprobado'; return; end if;
    execute d;
  end if;
end $$;

-- 5) Superadministrador: colegios registrados por su cuenta (en prueba o ya pagando)
create or replace function public.plataforma_pruebas_lista() returns json
language sql stable security definer set search_path = public, pg_temp as $$
  select case when not priv.es_superadmin() then null else coalesce(json_agg(json_build_object(
    'colegio_id', k.id, 'nombre', k.nombre, 'ciudad', k.ciudad, 'email', k.registro_email, 'tel', k.registro_tel, 'rector', k.rector_nombre,
    'creado', k.creado_en, 'prueba_hasta', k.prueba_hasta, 'plan_max', k.plan_max, 'en_prueba', priv.en_prueba(k.id),
    'dias', greatest(0, k.prueba_hasta - priv.hoy_co()),
    'estudiantes', (select count(*) from estudiantes s where s.colegio_id = k.id and s.estado = 'Activo'),
    'pagos', (select count(*) from plataforma_pagos p where p.colegio_id = k.id)) order by k.creado_en desc), '[]'::json) end
  from colegios k where k.prueba_hasta is not null and not k.demo
$$;
revoke execute on function public.plataforma_pruebas_lista() from public, anonymous;
grant execute on function public.plataforma_pruebas_lista() to authenticated;

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
notify pgrst, 'reload schema';
