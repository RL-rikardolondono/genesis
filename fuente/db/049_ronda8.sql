-- 049_ronda8.sql · Colegio-IA v0.35.0 · Prueba Ácida, 8.ª vuelta (25 nov 2026)
-- Idempotente (create or replace, if exists). Aplicar en Neon después de 048.

-- 1) Validaciones también en el servidor (antes solo en la pantalla): teléfono y código DANE del colegio, cédula del representante legal,
--    documentos de estudiantes y acudientes, teléfono de acudientes y datos de las solicitudes de admisión.
--    Solo para lo que llega de la aplicación (priv.es_cliente) y solo cuando el dato cambia: los registros antiguos se pueden seguir editando.
create or replace function priv.doc_ok(td text, d text) returns boolean
language sql immutable as $$
  select case when d is null or btrim(d) = '' then true
              when upper(coalesce(td, '')) in ('CC', 'TI', 'RC', 'NUIP') then regexp_replace(d, '[\s.]', '', 'g') ~ '^[0-9]{5,15}$'
              else regexp_replace(d, '[\s.]', '', 'g') ~ '^[0-9A-Za-z]{4,20}$' end
$$;
create or replace function priv.tel_ok(t text) returns boolean
language sql immutable as $$
  select t is null or btrim(t) = '' or (btrim(t) ~ '^[0-9 ()+-]+$' and length(regexp_replace(t, '[^0-9]', '', 'g')) between 7 and 13)
$$;

create or replace function priv.tg_colegios_validar() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if not priv.es_cliente() then return new; end if;
  if new.telefono is distinct from old.telefono and not priv.tel_ok(new.telefono) then
    raise exception 'Escriba un teléfono válido: solo números (de 7 a 13 cifras)';
  end if;
  if new.dane is distinct from old.dane and coalesce(btrim(new.dane), '') <> '' and regexp_replace(new.dane, '\s', '', 'g') !~ '^[0-9]{12}$' then
    raise exception 'El código DANE tiene 12 números (sin letras ni guiones)';
  end if;
  if new.contrato_cfg is distinct from old.contrato_cfg and not priv.doc_ok('CC', new.contrato_cfg ->> 'rep_doc') then
    raise exception 'La cédula del representante legal lleva solo números (sin puntos ni letras)';
  end if;
  return new;
end $$;
drop trigger if exists tg_colegios_validar on public.colegios;
create trigger tg_colegios_validar before update on public.colegios for each row execute function priv.tg_colegios_validar();

create or replace function priv.tg_doc_validar() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if not priv.es_cliente() then return new; end if;
  if (tg_op = 'INSERT' or new.doc is distinct from old.doc or new.tipo_doc is distinct from old.tipo_doc) and not priv.doc_ok(new.tipo_doc, new.doc) then
    raise exception 'El número de documento no es válido: con CC, TI, RC o NUIP lleva solo números, sin puntos ni letras';
  end if;
  if tg_table_name = 'acudientes' and (tg_op = 'INSERT' or new.telefono is distinct from old.telefono) and not priv.tel_ok(new.telefono) then
    raise exception 'El teléfono del acudiente no es válido: solo números, de 7 a 13 cifras';
  end if;
  return new;
end $$;
drop trigger if exists tg_doc_validar on public.estudiantes;
create trigger tg_doc_validar before insert or update on public.estudiantes for each row execute function priv.tg_doc_validar();
drop trigger if exists tg_doc_validar on public.acudientes;
create trigger tg_doc_validar before insert or update on public.acudientes for each row execute function priv.tg_doc_validar();

create or replace function priv.tg_admision_validar() returns trigger
language plpgsql set search_path = public, pg_temp as $$
declare a jsonb;
begin
  if not priv.es_cliente() then return new; end if;
  if tg_op = 'UPDATE' and new.datos is not distinct from old.datos and new.acudientes is not distinct from old.acudientes then return new; end if;
  if not priv.doc_ok(new.datos ->> 'tipo_doc', new.datos ->> 'doc') then
    raise exception 'El número de documento del aspirante no es válido: con TI, RC, NUIP o CC lleva solo números';
  end if;
  if not priv.tel_ok(new.datos ->> 'telefono') then raise exception 'El teléfono del aspirante no es válido: solo números, de 7 a 13 cifras'; end if;
  for a in select jsonb_array_elements(coalesce(new.acudientes, '[]'::jsonb)) loop
    if not priv.doc_ok(coalesce(a ->> 'tipo_doc', 'CC'), a ->> 'doc') then raise exception 'El documento del acudiente no es válido: la cédula lleva solo números'; end if;
    if not priv.tel_ok(a ->> 'telefono') then raise exception 'El celular del acudiente no es válido: solo números, de 7 a 13 cifras'; end if;
  end loop;
  return new;
end $$;
drop trigger if exists tg_admision_validar on public.admisiones;
create trigger tg_admision_validar before insert or update on public.admisiones for each row execute function priv.tg_admision_validar();

-- 2) Costos: sin centavos ni negativos también por la API (antes 1,5 se redondeaba en silencio; numeric(12,0) lo cambiaba antes de revisar)
alter table public.conceptos alter column valor type numeric using valor;
create or replace function priv.tg_conceptos_cambio() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if coalesce(new.valor, 0) <> trunc(coalesce(new.valor, 0)) or exists (select 1 from jsonb_each_text(coalesce(new.valores_grado, '{}')) v where v.value ~ '^-?[0-9]+\.[0-9]*[1-9]') then
    raise exception 'Los valores de los cobros van en pesos enteros, sin centavos';
  end if;
  if coalesce(new.valor, 0) < 0 or exists (select 1 from jsonb_each_text(coalesce(new.valores_grado, '{}')) v where v.value ~ '^-') then
    raise exception 'Los valores de los cobros no pueden ser negativos';
  end if;
  if coalesce(new.valor, 0) > 100000000 or exists (select 1 from jsonb_each_text(coalesce(new.valores_grado, '{}')) v where v.value ~ '^[0-9.]+$' and v.value::numeric > 100000000) then
    raise exception 'El valor es demasiado alto para un cobro escolar (máximo $100.000.000). Revise los ceros';
  end if;
  if tg_op = 'UPDATE' and (new.valor is distinct from old.valor or new.valores_grado is distinct from old.valores_grado) and priv.uid() is not null then
    new.cambio_nombre := priv.nombre_actual(new.colegio_id); new.cambio_en := now();
  elsif tg_op = 'UPDATE' then new.cambio_nombre := old.cambio_nombre; new.cambio_en := old.cambio_en;
  else new.cambio_nombre := null; new.cambio_en := null;
  end if;
  return new;
end $$;

-- 3) Paz y salvo pedido por la familia con saldo que vence hoy: el mensaje dice «saldo pendiente a la fecha» (no «vencido»)
CREATE OR REPLACE FUNCTION public.pedir_documento(p_est uuid, p_tipo text, p_periodo integer, p_anio integer, p_medio text)
 RETURNS doc_solicitudes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare s estudiantes; k colegios; v numeric; r doc_solicitudes; m text := coalesce(p_medio, '');
begin
  select * into s from estudiantes where id = p_est;
  if s.id is null or not priv.es_acudiente_de(p_est) then raise exception 'Solo el acudiente del estudiante puede pedir documentos'; end if;
  if not p_tipo = any(priv.doc_tipos()) then raise exception 'Documento no válido'; end if;
  select * into k from colegios where id = s.colegio_id;
  if p_tipo = 'boletin' and (p_periodo is null or p_periodo < 1 or p_periodo > greatest(jsonb_array_length(coalesce(priv.cal_grupo(k.id, s.grupo_id), '[]')), 1)) then raise exception 'Elija el periodo del boletín'; end if;
  if p_tipo = 'anteriores' and (p_anio is null or not exists (select 1 from historial h where h.estudiante_id = p_est and h.anio = p_anio)) then
    raise exception 'No hay calificaciones de ese año para el estudiante';
  end if;
  if p_tipo = 'pazysalvo' and priv.debe_a_hoy(p_est) then
    raise exception 'Tiene un saldo pendiente a la fecha (vencido o que vence hoy). El paz y salvo se expide cuando esté al día (vea Estado de cuenta)';
  end if;
  if p_tipo = 'retiro' and s.estado = 'Activo' then raise exception 'La constancia de retiro solo se expide para estudiantes retirados'; end if;
  if k.restringir_morosos and priv.debe_vencido(p_est) then
    raise exception 'Tiene pagos pendientes: los documentos se piden cuando esté al día (vea Estado de cuenta)';
  end if;
  -- si ya está pagado y vigente, se devuelve el mismo
  select * into r from doc_solicitudes d where d.estudiante_id = p_est and d.tipo = p_tipo and d.estado = 'Pagado'
     and d.periodo is not distinct from case when p_tipo = 'boletin' then p_periodo end
     and d.anio = case when p_tipo = 'anteriores' then p_anio else k.anio end
     and (p_tipo in ('boletin','anteriores') or d.pagado_en > now() - interval '30 days')
   order by d.pagado_en desc limit 1;
  if r.id is not null then return r; end if;
  -- si ya hay uno esperando pago, se devuelve ese
  select * into r from doc_solicitudes d where d.estudiante_id = p_est and d.tipo = p_tipo and d.estado in ('Por pagar','Por confirmar')
     and d.periodo is not distinct from case when p_tipo = 'boletin' then p_periodo end
     and d.anio = case when p_tipo = 'anteriores' then p_anio else k.anio end limit 1;
  if r.id is not null then
    if r.estado = 'Por pagar' and r.bold_orden is null and m <> r.medio and r.valor > 0
       and ((m = 'efectivo' and k.pago_efectivo) or (m = 'llave' and k.pago_llave and k.pago_llave_valor is not null) or (m = 'bold' and k.pago_bold_auto)) then
      update doc_solicitudes set medio = m where id = r.id returning * into r;
    end if;
    return r;
  end if;
  if (select count(*) from doc_solicitudes where estudiante_id = p_est and estado in ('Por pagar','Por confirmar')) >= 6 then
    raise exception 'Tiene 6 documentos sin pagar. Pague o cancele alguno antes de pedir otro.';
  end if;
  v := priv.doc_precio(k.id, p_tipo);
  if v = 0 then m := 'gratis';
  elsif m not in ('efectivo','llave','bold')
     or (m = 'efectivo' and not k.pago_efectivo)
     or (m = 'llave' and not (k.pago_llave and k.pago_llave_valor is not null))
     or (m = 'bold' and not k.pago_bold_auto) then
    raise exception 'Elija un medio de pago que el colegio reciba';
  end if;
  insert into doc_solicitudes (colegio_id, estudiante_id, tipo, periodo, anio, valor, medio, estado, creado_por, creado_nombre, pagado_en)
  values (k.id, p_est, p_tipo, case when p_tipo = 'boletin' then p_periodo end, case when p_tipo = 'anteriores' then p_anio else k.anio end,
          v, m, case when v = 0 then 'Pagado' else 'Por pagar' end, priv.uid(),
          coalesce((select max(mm.nombre) from miembros mm where mm.user_id = priv.uid() and mm.colegio_id = k.id), 'FAMILIA'), case when v = 0 then now() end)
  returning * into r;
  return r;
end $function$;

-- 4) Pantalla de activación: «¿Estaba registrando su colegio?» solo para quien no tiene ningún acceso (tampoco uno bloqueado)
create or replace function public.tengo_invitacion() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from miembros m where (lower(m.email) = lower(coalesce(priv.email_actual(), '')) and m.user_id is null) or m.user_id = priv.uid())
$$;
revoke all on function public.tengo_invitacion() from public, anonymous;
grant execute on function public.tengo_invitacion() to authenticated;

-- 5) Registro con ciclos: todos los cursos se llaman igual (CLEI 3, CLEI 4, CLEI 5, CLEI 6); antes 5 y 6 quedaban «CLEI 5 SEMESTRE 1»
CREATE OR REPLACE FUNCTION public.registrar_colegio(p_nombre text, p_ciudad text, p_plan integer, p_grados integer[], p_telefono text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare u text := priv.uid(); em text := lower(btrim(coalesce(priv.email_actual(), ''))); nm text; c uuid; a int; mid uuid; hoy date := priv.hoy_co(); g int;
        tel text := regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g');
        gtxt text[] := array['Prejardín','Jardín','Transición','Primero','Segundo','Tercero','Cuarto','Quinto','Sexto','Séptimo','Octavo','Noveno','Décimo','Undécimo'];
begin
  if u is null or em = '' then raise exception 'Inicie sesión para registrar su colegio'; end if;
  if length(btrim(coalesce(p_nombre, ''))) < 5 or length(p_nombre) > 120 then raise exception 'Escriba el nombre completo del colegio'; end if;
  if length(btrim(coalesce(p_ciudad, ''))) < 3 or length(p_ciudad) > 80 then raise exception 'Escriba la ciudad o el municipio'; end if;
  if not (p_plan in (100, 250, 500, 1000) or (p_plan between 1100 and 3000 and p_plan % 100 = 0)) then raise exception 'Elija el número de estudiantes'; end if;
  if length(tel) not between 7 and 12 then raise exception 'Escriba un número de celular o WhatsApp válido'; end if;
  if p_grados is null or cardinality(p_grados) = 0 then raise exception 'Marque los grados que ofrece el colegio'; end if;
  if exists (select 1 from unnest(p_grados) x where x not between -2 and 11 and x not between 23 and 26) then raise exception 'Hay un grado no válido'; end if;
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
  foreach g in array coalesce((select array_agg(distinct x order by x) from unnest(p_grados) x where x <= 11), '{}'::int[]) loop
    insert into grupos (colegio_id, nombre, grado, nivel)
    values (c, gtxt[g + 3] || ' A', g, case when g <= 0 then 'preescolar' when g <= 5 then 'primaria' when g <= 9 then 'secundaria' else 'media' end)
    on conflict do nothing;
  end loop;
  insert into miembros (colegio_id, email, nombre, rol, user_id) values (c, em, nm, 'rector', u) returning id into mid;
  -- v0.34: bachillerato por ciclos (CLEI 3 a 6) desde el registro: un curso por ciclo, con su plan de estudios y su calendario
  foreach g in array coalesce((select array_agg(distinct x order by x) from unnest(p_grados) x where x between 23 and 26), '{}'::int[]) loop
    perform public.crear_ciclo(c, g - 20, 1, 'CLEI ' || (g - 20));   -- v0.35: nombres iguales para todos los ciclos (CLEI 3 … CLEI 6)
  end loop;
  insert into plataforma_pruebas (email, user_id, colegio_id, colegio_nombre) values (em, u, c, btrim(p_nombre));
  perform set_config('micolegia.sistema', '', true);
  return json_build_object('miembro_id', mid, 'colegio_id', c, 'prueba_hasta', hoy + 15);
end $function$;

-- 6) Datos del contrato: la cédula del representante legal también se valida en la función que los guarda
CREATE OR REPLACE FUNCTION public.colegio_contrato(p_colegio uuid, p_cfg jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare extra text[]; r jsonb := '{}'; t text; n int;
begin
  if not priv.puede(p_colegio, 'costos') then raise exception 'No tiene permiso para cambiar el contrato (permiso "Costos y medios de pago")'; end if;
  if jsonb_typeof(p_cfg) <> 'object' then raise exception 'Datos no válidos'; end if;
  select array_agg(x) into extra from jsonb_object_keys(p_cfg) x
   where x not in ('titular', 'titular_nit', 'rep_nombre', 'rep_doc', 'rep_cargo', 'ciudad', 'cuotas_mora', 'clausulas');
  if extra is not null then raise exception 'Dato no permitido: %', array_to_string(extra, ', '); end if;
  foreach t in array array['titular', 'titular_nit', 'rep_nombre', 'rep_doc', 'rep_cargo', 'ciudad'] loop
    if length(coalesce(p_cfg ->> t, '')) > 160 then raise exception 'Texto demasiado largo'; end if;
    if nullif(trim(p_cfg ->> t), '') is not null then r := r || jsonb_build_object(t, upper(trim(p_cfg ->> t))); end if;
  end loop;
  if not priv.doc_ok('CC', p_cfg ->> 'rep_doc') then raise exception 'La cédula del representante legal lleva solo números (sin puntos ni letras)'; end if;   -- v0.35
  if length(coalesce(p_cfg ->> 'clausulas', '')) > 8000 then raise exception 'Las cláusulas adicionales no pueden pasar de 8.000 caracteres'; end if;
  if nullif(trim(p_cfg ->> 'clausulas'), '') is not null then r := r || jsonb_build_object('clausulas', trim(p_cfg ->> 'clausulas')); end if;
  n := coalesce(nullif(p_cfg ->> 'cuotas_mora', '')::int, 2);
  if n not between 1 and 12 then raise exception 'Las cuotas en mora para llenar el pagaré van de 1 a 12'; end if;
  r := r || jsonb_build_object('cuotas_mora', n);
  perform set_config('micolegia.sistema', 'on', true);
  update colegios set contrato_cfg = r where id = p_colegio;
  perform set_config('micolegia.sistema', '', true);
  return r;
end $function$;
