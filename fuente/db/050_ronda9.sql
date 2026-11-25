-- 050_ronda9.sql · Colegio-IA v0.36.0 · Prueba Ácida, 9.ª vuelta (25 nov 2026)
-- Idempotente. Aplicar en Neon después de 049.

-- 1) SEGURIDAD: la fila de colegios ya no se lee completa por la Data API. Cualquier miembro (familia, estudiante, docente,
--    tesorería…) lee solo las columnas públicas; lo reservado llega por public.colegio_privado() según el cargo.
--    Reservado: registro_email, registro_tel, prueba_ultimo_correo, interna, interna_motivo, interna_en, interna_por,
--    bold_llave_id, admision_codigo, firma_rector, permisos, pagado_hasta, prueba_hasta, plan_max.
--    IMPORTANTE para versiones futuras: una columna NUEVA de colegios no se puede leer desde la app hasta darle
--    «grant select (columna) on public.colegios to authenticated» (si es pública) o agregarla a colegio_privado.
revoke select on public.colegios from authenticated;
revoke select (registro_email, registro_tel, prueba_ultimo_correo, interna, interna_motivo, interna_en, interna_por,
               bold_llave_id, admision_codigo, firma_rector, permisos, pagado_hasta, prueba_hasta, plan_max) on public.colegios from authenticated;
grant select (id, nombre, nit, dane, resolucion, ciudad, direccion, telefono, rector_nombre, secretaria_nombre, anio, periodo_actual, max_perdidas, periodos, escala, activo, creado_en, web, lema, logo, dia_limite_pago, politica_datos, asistencia_por_clase, demo, restringir_morosos, pago_efectivo, pago_efectivo_texto, pago_llave, pago_llave_valor, pago_llave_titular, pago_bold, pago_bold_url, red_facebook, red_instagram, red_youtube, red_tiktok, tienda_activa, tienda_texto, atencion, campus_activo, campus_grados, gemas_activas, pago_bold_auto, cierre_inactividad, horario_cfg, doc_precios, contrato_cfg, periodos_ciclos, periodo_actual_ciclos, admisiones_abiertas, admision_anio, admision_grados, admision_texto, matricula_linea, matricula_anio, matricula_hasta, grados_cfg, restringir_estudiante) on public.colegios to authenticated;

create or replace function public.colegio_privado(p_colegio uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare k colegios; r jsonb := '{}';
begin
  select * into k from colegios where id = p_colegio;
  if k.id is null or not (priv.es_miembro_base(p_colegio) or priv.es_superadmin()) then return r; end if;
  if priv.es_personal(p_colegio) or priv.es_superadmin() then
    r := r || jsonb_build_object('permisos', k.permisos, 'plan_max', k.plan_max, 'interna', k.interna, 'pagado_hasta', k.pagado_hasta,
                                 'prueba_hasta', k.prueba_hasta, 'firma_rector', k.firma_rector);
    if priv.es_directivo(p_colegio) or priv.puede(p_colegio, 'matricula') then r := r || jsonb_build_object('admision_codigo', k.admision_codigo); end if;
    if priv.maneja_pagos(p_colegio) or priv.es_rector(p_colegio) then r := r || jsonb_build_object('bold_llave_id', k.bold_llave_id); end if;
  elsif k.demo or exists (select 1 from doc_solicitudes ds join miembros m on m.estudiante_id = ds.estudiante_id
                          where m.user_id = priv.uid() and m.activo and ds.colegio_id = p_colegio and ds.estado = 'Pagado') then
    -- familia y estudiante: la firma de la rectoría solo cuando ya tienen un documento expedido (va impresa en él)
    r := r || jsonb_build_object('firma_rector', k.firma_rector);
  end if;
  return r;
end $$;
revoke all on function public.colegio_privado(uuid) from public, anonymous;
grant execute on function public.colegio_privado(uuid) to authenticated;

-- resumen_colegio leía toda la fila con los permisos de quien llama: ahora corre como dueño (ya revisa el permiso al empezar)
alter function public.resumen_colegio(uuid) security definer;

-- 2) Mensajes en español por la API (antes salían los «check constraint» en inglés) y datos normalizados
--    Pagos: valor 0 o negativo
CREATE OR REPLACE FUNCTION priv.tg_pagos_saldo()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare sal numeric;
begin
  if current_user <> 'authenticated' then new.valor := round(new.valor); return new; end if;   -- solo lo que llega directo de la aplicación (no Bold ni procesos del sistema; a esos se les redondea como antes)
  -- v0.34: pesos enteros y fechas posibles
  if new.valor <> trunc(new.valor) then raise exception 'El valor del pago va en pesos enteros, sin centavos'; end if;
  if new.valor <= 0 then raise exception 'El valor del pago debe ser mayor que 0'; end if;   -- v0.36: en español (antes salía el check en inglés)
  if new.valor > 1000000000 then raise exception 'El valor del pago es demasiado alto. Revise los ceros'; end if;
  if new.fecha is null or new.fecha > priv.hoy_co() + 31 or new.fecha < make_date(new.anio - 1, 1, 1) then
    raise exception 'La fecha del pago no es válida: no puede ser de más de un mes adelante ni de años anteriores al cobro';
  end if;
  if new.concepto_id is null then raise exception 'Cada pago debe corresponder a un cobro (concepto y mes)'; end if;
  if new.mes is null then new.mes := priv.mes_cuota(new.estudiante_id, new.anio, new.concepto_id); end if;   -- cobro único (matrícula, seguro): se toma su mes
  sal := priv.saldo_cuota(new.estudiante_id, new.anio, new.concepto_id, new.mes);
  if sal is not null and new.valor > sal then
    raise exception 'El valor (%) supera el saldo de esa cuota (%). Revise el valor o la cuota', to_char(new.valor, 'FM999G999G999'), to_char(sal, 'FM999G999G999');
  end if;
  return new;
end $function$;

--    Excusas: fecha final antes de la inicial
CREATE OR REPLACE FUNCTION priv.tg_excusas()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if tg_op = 'INSERT' then
    select colegio_id into new.colegio_id from estudiantes where id = new.estudiante_id;
    new.enviada_por := (select coalesce(max(m.nombre), '') from miembros m where m.user_id = priv.uid() and m.estudiante_id = new.estudiante_id);
    new.estado := 'Pendiente'; new.revisada_por := null; new.respuesta := null;
    if new.hasta < new.desde then raise exception 'La fecha final de la excusa no puede ser anterior a la inicial'; end if;   -- v0.36: en español
    -- v0.34: fechas razonables y motivo corto
    if new.desde < priv.hoy_co() - 120 or new.hasta > priv.hoy_co() + 60 then
      raise exception 'La excusa debe ser de los últimos 4 meses o de los próximos 2 meses. Para otras fechas, comuníquese con coordinación';
    end if;
    if length(coalesce(new.motivo, '')) > 500 then raise exception 'El motivo de la excusa es muy largo (máximo 500 caracteres)'; end if;
    update excusas set soporte = null
     where colegio_id = new.colegio_id and soporte is not null
       and ((estado = 'Rechazada' and creado_en < now() - interval '30 days') or creado_en < now() - interval '13 months');
    return new;
  end if;
  if pg_trigger_depth() > 1 then  -- limpieza automática: solo se permite quitar la foto
    new := old; new.soporte := null; return new;
  end if;
  if not exists (select 1 from estudiantes s where s.id = old.estudiante_id and (priv.puede(s.colegio_id, 'excusas') or exists (
       select 1 from grupos gr join miembros m on m.id = gr.director_miembro_id where gr.id = s.grupo_id and m.user_id = priv.uid() and m.activo))) then
    raise exception 'Las excusas las aprueba coordinación, rectoría o el director(a) de grupo';
  end if;
  new.colegio_id := old.colegio_id; new.estudiante_id := old.estudiante_id; new.desde := old.desde; new.hasta := old.hasta;
  new.motivo := old.motivo; new.enviada_por := old.enviada_por; new.soporte := old.soporte;
  new.revisada_por := priv.nombre_actual(old.colegio_id);
  return new;
end $function$;

--    Documentos de estudiantes y acudientes: se guardan sin puntos ni espacios
CREATE OR REPLACE FUNCTION priv.tg_doc_validar()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not priv.es_cliente() then return new; end if;
  if new.doc is not null then new.doc := regexp_replace(new.doc, '[\s.]', '', 'g'); end if;   -- v0.36: documento sin puntos ni espacios
  if (tg_op = 'INSERT' or new.doc is distinct from old.doc or new.tipo_doc is distinct from old.tipo_doc) and not priv.doc_ok(new.tipo_doc, new.doc) then
    raise exception 'El número de documento no es válido: con CC, TI, RC o NUIP lleva solo números, sin puntos ni letras';
  end if;
  if tg_table_name = 'acudientes' and (tg_op = 'INSERT' or new.telefono is distinct from old.telefono) and not priv.tel_ok(new.telefono) then
    raise exception 'El teléfono del acudiente no es válido: solo números, de 7 a 13 cifras';
  end if;
  return new;
end $function$;

--    Cédula del representante legal: sin puntos
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
    if nullif(trim(p_cfg ->> t), '') is not null then r := r || jsonb_build_object(t, case when t = 'rep_doc' then regexp_replace(p_cfg ->> t, '[\s.]', '', 'g') else upper(trim(p_cfg ->> t)) end); end if;   -- v0.36: la cédula se guarda sin puntos
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

--    Tienda: precio en pesos enteros, mayor que 0 y máximo $20.000.000, con mensaje claro (antes 1,5 se redondeaba y lo demás salía en inglés)
drop trigger if exists tg_productos_precio on public.productos;   -- antes de cambiar el tipo (el disparador depende de la columna)
alter table public.productos alter column precio type numeric using precio;
create or replace function priv.tg_productos_precio() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if new.precio is null or new.precio <= 0 then raise exception 'Escriba el precio del artículo (mayor que 0)'; end if;
  if new.precio <> trunc(new.precio) then raise exception 'El precio va en pesos enteros, sin centavos'; end if;
  if new.precio > 20000000 then raise exception 'El precio máximo de un artículo es $20.000.000. Revise los ceros'; end if;
  return new;
end $$;
drop trigger if exists tg_productos_precio on public.productos;
create trigger tg_productos_precio before insert or update of precio on public.productos for each row execute function priv.tg_productos_precio();
