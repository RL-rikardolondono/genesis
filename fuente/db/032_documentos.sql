-- Colegio-IA 032 (21 oct 2026): documentos que la familia paga antes de descargarlos.
--  Pedido de Ricardo: los padres no generan documentos sin pagarlos primero (constancias, certificados, paz y salvo,
--  constancia de retiro y también el boletín de cada periodo). Pagan primero y el documento se libera solo:
--   - con Bold del colegio: al confirmarse el pago en línea;
--   - con llave Bre-B o transferencia: al confirmar tesorería el comprobante;
--   - en efectivo: cuando tesorería registra el pago en la caja.
--  El precio de cada documento lo fija el colegio en Parametrización › Costos (0 o vacío = gratis).

begin;

-- 1) Precios por colegio: {"boletin": 3000, "constancia": 5000, ...}
alter table public.colegios add column if not exists doc_precios jsonb not null default '{}';
create or replace function priv.doc_tipos() returns text[] language sql immutable as
$$ select array['boletin','constancia','certificado','anteriores','pazysalvo','retiro'] $$;
create or replace function priv.doc_precio(c uuid, t text) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select greatest(coalesce((select (doc_precios ->> t)::numeric from colegios where id = c), 0), 0)
$$;
create or replace function public.colegio_doc_precios(p_colegio uuid, p_precios jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t text; v numeric; r jsonb := '{}';
begin
  if not priv.puede(p_colegio, 'costos') then raise exception 'No tiene permiso para cambiar los precios del colegio'; end if;
  foreach t in array priv.doc_tipos() loop
    v := coalesce(nullif(p_precios ->> t, '')::numeric, 0);
    if v < 0 or v > 2000000 then raise exception 'El precio de un documento debe estar entre $0 y $2.000.000'; end if;
    if v > 0 and v < 1000 then raise exception 'Si el documento se cobra, el valor mínimo es $1.000 (para poder pagarlo en línea). Use 0 si es gratis'; end if;
    r := r || jsonb_build_object(t, round(v));
  end loop;
  perform set_config('micolegia.sistema', 'on', true);
  update colegios set doc_precios = r where id = p_colegio;
  perform set_config('micolegia.sistema', '', true);
end $$;

-- 2) Solicitudes de documentos
create table if not exists public.doc_solicitudes (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  tipo text not null check (tipo in ('boletin','constancia','certificado','anteriores','pazysalvo','retiro')),
  periodo int,                 -- boletín: periodo pagado
  anio int not null,           -- año del documento (certificados de años anteriores: el año pedido)
  valor numeric(12,0) not null check (valor >= 0),
  medio text not null check (medio in ('gratis','efectivo','llave','bold')),
  estado text not null default 'Por pagar' check (estado in ('Por pagar','Por confirmar','Pagado','Cancelado')),
  referencia text check (referencia is null or length(referencia) <= 60),
  comprobante text check (comprobante is null or (length(comprobante) < 250000 and comprobante ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$')),
  con_comprobante boolean generated always as (comprobante is not null) stored,
  respuesta text check (respuesta is null or length(respuesta) <= 300),
  bold_orden text,
  creado_por text,
  creado_nombre text,
  atendido_nombre text,
  creado_en timestamptz not null default now(),
  pagado_en timestamptz
);
create index if not exists doc_sol_est on public.doc_solicitudes (estudiante_id, creado_en desc);
create index if not exists doc_sol_col on public.doc_solicitudes (colegio_id, estado);
alter table public.doc_solicitudes enable row level security;
revoke all on public.doc_solicitudes from authenticated, anonymous;
grant select on public.doc_solicitudes to authenticated;
drop policy if exists ds_ver on public.doc_solicitudes;
create policy ds_ver on public.doc_solicitudes for select to authenticated using (priv.ve_pagos(colegio_id) or priv.es_familia_de(estudiante_id));

-- 3) La familia pide el documento (el valor lo pone la base; si es gratis queda liberado de una vez)
create or replace function public.pedir_documento(p_est uuid, p_tipo text, p_periodo int, p_anio int, p_medio text)
returns doc_solicitudes language plpgsql security definer set search_path = public, pg_temp as $$
declare s estudiantes; k colegios; v numeric; r doc_solicitudes; m text := coalesce(p_medio, '');
begin
  select * into s from estudiantes where id = p_est;
  if s.id is null or not priv.es_acudiente_de(p_est) then raise exception 'Solo el acudiente del estudiante puede pedir documentos'; end if;
  if not p_tipo = any(priv.doc_tipos()) then raise exception 'Documento no válido'; end if;
  select * into k from colegios where id = s.colegio_id;
  if p_tipo = 'boletin' and (p_periodo is null or p_periodo < 1 or p_periodo > greatest(jsonb_array_length(coalesce(k.periodos, '[]')), 1)) then raise exception 'Elija el periodo del boletín'; end if;
  if p_tipo = 'anteriores' and (p_anio is null or not exists (select 1 from historial h where h.estudiante_id = p_est and h.anio = p_anio)) then
    raise exception 'No hay calificaciones de ese año para el estudiante';
  end if;
  if p_tipo = 'retiro' and s.estado = 'Activo' then raise exception 'La constancia de retiro solo se expide para estudiantes retirados'; end if;
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
end $$;

-- La familia envía el comprobante de la llave Bre-B o de la transferencia
create or replace function public.doc_comprobante(p_id uuid, p_imagen text, p_referencia text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare d doc_solicitudes;
begin
  select * into d from doc_solicitudes where id = p_id;
  if d.id is null or not priv.es_acudiente_de(d.estudiante_id) then raise exception 'No tiene permiso para esta acción'; end if;
  if d.estado not in ('Por pagar','Por confirmar') then raise exception 'Este documento ya no espera comprobante'; end if;
  if p_imagen is null and coalesce(btrim(p_referencia), '') = '' then raise exception 'Adjunte la foto del comprobante o escriba la referencia'; end if;
  update doc_solicitudes set comprobante = p_imagen, referencia = nullif(btrim(coalesce(p_referencia, '')), ''), medio = 'llave',
         estado = 'Por confirmar', respuesta = null where id = p_id;
end $$;

-- Tesorería confirma (o rechaza) el pago; la familia puede cancelar lo que no ha pagado
create or replace function public.doc_estado(p_id uuid, p_estado text, p_respuesta text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare d doc_solicitudes;
begin
  select * into d from doc_solicitudes where id = p_id for update;
  if d.id is null then raise exception 'Solicitud no encontrada'; end if;
  if not priv.maneja_pagos(d.colegio_id) then
    if d.bold_orden is not null and exists (select 1 from bold_ordenes bo where bo.orden = d.bold_orden and bo.estado = 'Pendiente') then
      raise exception 'Este documento tiene un pago en línea en verificación y no se puede cancelar';
    end if;
    if not (priv.es_acudiente_de(d.estudiante_id) and p_estado = 'Cancelado' and d.estado in ('Por pagar','Por confirmar')) then
      raise exception 'Solo puede cancelar un documento que aún no ha pagado';
    end if;
    update doc_solicitudes set estado = 'Cancelado', comprobante = null where id = p_id;
    return;
  end if;
  if d.estado in ('Pagado','Cancelado') then raise exception 'Esta solicitud ya está %', lower(d.estado); end if;
  if length(coalesce(p_respuesta, '')) > 300 then raise exception 'La respuesta es muy larga'; end if;
  if p_estado = 'Pagado' then
    update doc_solicitudes set estado = 'Pagado', pagado_en = now(), comprobante = null, atendido_nombre = priv.nombre_actual(d.colegio_id),
           respuesta = nullif(btrim(coalesce(p_respuesta, '')), '') where id = p_id;
  elsif p_estado = 'Por pagar' then
    if coalesce(btrim(p_respuesta), '') = '' then raise exception 'Escriba el motivo para la familia'; end if;
    update doc_solicitudes set estado = 'Por pagar', comprobante = null, respuesta = btrim(p_respuesta), atendido_nombre = priv.nombre_actual(d.colegio_id) where id = p_id;
  elsif p_estado = 'Cancelado' then
    update doc_solicitudes set estado = 'Cancelado', comprobante = null, respuesta = nullif(btrim(coalesce(p_respuesta, '')), ''), atendido_nombre = priv.nombre_actual(d.colegio_id) where id = p_id;
  else raise exception 'Estado no válido';
  end if;
end $$;

-- 4) Pago en línea con el Bold del colegio: la orden lleva el documento; al aprobarse queda pagado
create or replace function public.doc_bold_orden(p_id uuid) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare d doc_solicitudes; s estudiantes; k colegios; b colegio_bold; o text; nombre text;
begin
  select * into d from doc_solicitudes where id = p_id;
  if d.id is null or not priv.es_acudiente_de(d.estudiante_id) then raise exception 'No tiene permiso para esta acción'; end if;
  if d.estado <> 'Por pagar' then raise exception 'Este documento no está pendiente de pago'; end if;
  if d.bold_orden is not null and exists (select 1 from bold_ordenes bo where bo.orden = d.bold_orden and bo.estado = 'Pendiente') then
    raise exception 'Ya hay un pago en línea de este documento en verificación. Si Bold lo aprobó, el documento se libera en unos minutos.';
  end if;
  select * into s from estudiantes where id = d.estudiante_id;
  select * into k from colegios where id = d.colegio_id;
  select * into b from colegio_bold where colegio_id = d.colegio_id;
  if not k.pago_bold_auto or b.colegio_id is null then raise exception 'El colegio no tiene activo el pago en línea con Bold'; end if;
  if exists (select 1 from bold_ordenes where estudiante_id = d.estudiante_id and estado = 'Pendiente' and creado_en > now() - interval '10 minutes') then
    raise exception 'Tiene un pago en línea en proceso. Si no lo terminó, espere 10 minutos e inténtelo de nuevo.';
  end if;
  if (select count(*) from bold_ordenes where estudiante_id = d.estudiante_id and creado_en > now() - interval '1 hour') >= 10 then
    raise exception 'Ya intentó varios pagos en la última hora. Espere un momento o comuníquese con la tesorería del colegio.';
  end if;
  nombre := case d.tipo when 'boletin' then 'BOLETÍN PERIODO ' || d.periodo when 'constancia' then 'CONSTANCIA DE ESTUDIO'
    when 'certificado' then 'CONSTANCIA CON CALIFICACIONES' when 'anteriores' then 'CERTIFICADO ' || d.anio when 'pazysalvo' then 'PAZ Y SALVO'
    else 'CONSTANCIA DE RETIRO' end;
  o := 'CIA-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16));
  insert into bold_ordenes (colegio_id, estudiante_id, orden, valor, items, creado_nombre)
  values (d.colegio_id, d.estudiante_id, o, d.valor, jsonb_build_array(jsonb_build_object('doc', d.id, 'valor', d.valor, 'concepto', nombre)),
          coalesce((select max(mm.nombre) from miembros mm where mm.user_id = priv.uid() and mm.colegio_id = d.colegio_id), 'FAMILIA'));
  update doc_solicitudes set medio = 'bold', bold_orden = o where id = d.id;
  return json_build_object('orderId', o, 'amount', d.valor::bigint, 'currency', 'COP', 'apiKey', b.llave_id,
    'signature', encode(digest(o || d.valor::bigint::text || 'COP' || b.secreto, 'sha256'), 'hex'),
    'description', left(nombre || ' - ' || s.nombres || ' ' || s.apellidos, 100));
end $$;

-- bold_familia_aplicar: además de cuotas, ahora libera documentos pagados en línea
create or replace function public.bold_familia_aplicar(p_orden text, p_estado text, p_valor numeric, p_ref text) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare o bold_ordenes; it jsonb; x record; v numeric; rec int; lote uuid := gen_random_uuid(); n int := 0; quien text;
begin
  select * into o from bold_ordenes where orden = p_orden for update;
  if o.id is null or not priv.maneja_pagos(o.colegio_id) then raise exception 'No tiene permiso para esta acción'; end if;
  if o.estado in ('Aprobada', 'Duplicado') then return json_build_object('ok', true, 'repetido', true, 'recibo', o.recibo); end if;
  quien := priv.nombre_actual(o.colegio_id);
  if p_estado in ('REJECTED', 'FAILED', 'VOIDED') then
    update bold_ordenes set estado = 'Rechazada', aplicado_en = now(), aplicado_nombre = quien, bold_ref = left(p_ref, 80) where id = o.id;
    return json_build_object('ok', true, 'estado', 'Rechazada');
  end if;
  if p_estado = 'NO_ENCONTRADA' then
    if o.creado_en < now() - interval '2 hours' then update bold_ordenes set estado = 'Sin completar' where id = o.id; end if;
    return json_build_object('ok', true, 'estado', 'Sin completar');
  end if;
  if p_estado not in ('APPROVED', 'MANUAL') then return json_build_object('ok', false, 'estado', 'Pendiente'); end if;
  if p_estado = 'APPROVED' and coalesce(p_valor, 0) < o.valor then
    raise exception 'Bold aprobó un valor menor al de la orden (% de %). Revíselo en el panel de Bold y regístrelo a mano.', p_valor, o.valor;
  end if;
  for it in select value from jsonb_array_elements(o.items) loop
    if it ? 'doc' then
      update doc_solicitudes set estado = 'Pagado', medio = 'bold', pagado_en = now(), atendido_nombre = quien,
             referencia = left('Bold ' || o.orden || coalesce(' · ' || p_ref, ''), 60)
       where id = (it ->> 'doc')::uuid and estado in ('Por pagar','Por confirmar','Cancelado');   -- si el dinero llegó, el documento se libera
      if found then n := n + 1; end if;
      continue;
    end if;
    select * into x from estado_cuenta(o.estudiante_id, (it ->> 'anio')::int) e
     where e.concepto_id = (it ->> 'concepto_id')::uuid and e.mes is not distinct from (it ->> 'mes')::int limit 1;
    v := least((it ->> 'valor')::numeric, coalesce(x.saldo, 0));
    if v > 0 then
      insert into pagos (colegio_id, estudiante_id, concepto_id, anio, mes, valor, fecha, medio, referencia, observacion, lote)
      values (o.colegio_id, o.estudiante_id, (it ->> 'concepto_id')::uuid, (it ->> 'anio')::int, (it ->> 'mes')::int, v, priv.hoy_co(), 'Bold',
              'Bold ' || o.orden || coalesce(' · ' || left(p_ref, 60), ''), 'Pago en línea de la familia', lote)
      returning recibo into rec;
      n := n + 1;
    end if;
  end loop;
  update bold_ordenes set estado = case when n = 0 then 'Duplicado' else 'Aprobada' end, aplicado_en = now(), aplicado_nombre = quien, bold_ref = left(p_ref, 80), recibo = rec where id = o.id;
  return json_build_object('ok', true, 'estado', case when n = 0 then 'Duplicado' else 'Aprobada' end, 'recibo', rec, 'cuotas', n);
end $$;

-- 5) Permisos y bloqueo por mora de la suscripción
revoke execute on function public.colegio_doc_precios(uuid, jsonb), public.pedir_documento(uuid, text, int, int, text), public.doc_comprobante(uuid, text, text),
  public.doc_estado(uuid, text, text), public.doc_bold_orden(uuid) from public, anonymous;
grant execute on function public.colegio_doc_precios(uuid, jsonb), public.pedir_documento(uuid, text, int, int, text), public.doc_comprobante(uuid, text, text),
  public.doc_estado(uuid, text, text), public.doc_bold_orden(uuid) to authenticated;
drop trigger if exists zz_bloqueo on public.doc_solicitudes;
create trigger zz_bloqueo before insert or update or delete on public.doc_solicitudes for each row execute function priv.tg_bloqueo();

-- 6) Demostración: documentos con precio y un acudiente que ya pagó los boletines de los periodos 1 a 3
create or replace function priv.demo_documentos(c uuid, a int) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update colegios set doc_precios = '{"boletin": 3000, "constancia": 8000, "certificado": 10000, "anteriores": 12000, "pazysalvo": 5000, "retiro": 8000}'
   where id = c;
end $$;
do $$
declare d text;
begin
  d := pg_get_functiondef('priv.crear_demo'::regproc);
  if position('demo_documentos' in d) = 0 then
    d := replace(d, '  perform priv.demo_revision7(c, a);', '  perform priv.demo_revision7(c, a);' || chr(10) || '  perform priv.demo_documentos(c, a);');
    if position('demo_documentos' in d) = 0 then raise exception 'No se encontró dónde agregar los documentos a la demostración'; end if;
    execute d;
  end if;
  -- al entrar como acudiente a la demo, los boletines de los periodos ya cerrados quedan pagados
  d := pg_get_functiondef('public.entrar_demo'::regproc);
  if position('doc_solicitudes' in d) = 0 then
    d := replace(d, '  insert into demo_visitas (user_id, email, nombre, rol) values (u, em, nm, p_rol);',
      '  if p_rol = ''acudiente'' then' || chr(10) ||
      '    insert into doc_solicitudes (colegio_id, estudiante_id, tipo, periodo, anio, valor, medio, estado, creado_por, creado_nombre, pagado_en, atendido_nombre)' || chr(10) ||
      '    select k.id, m2.estudiante_id, ''boletin'', p, k.anio, 3000, ''efectivo'', ''Pagado'', u, nm, now(), ''TESORERÍA''' || chr(10) ||
      '    from miembros m2 cross join generate_series(1, greatest(k.periodo_actual - 1, 1)) p' || chr(10) ||
      '    where m2.colegio_id = k.id and m2.user_id = u and m2.rol = ''acudiente'' and m2.estudiante_id is not null' || chr(10) ||
      '      and not exists (select 1 from doc_solicitudes x where x.estudiante_id = m2.estudiante_id and x.tipo = ''boletin'' and x.periodo = p);' || chr(10) ||
      '  end if;' || chr(10) ||
      '  insert into demo_visitas (user_id, email, nombre, rol) values (u, em, nm, p_rol);');
    if position('doc_solicitudes' in d) = 0 then raise exception 'No se encontró dónde agregar los boletines pagados de la demostración'; end if;
    execute d;
  end if;
end $$;
select priv.demo_documentos(id, anio) from colegios where demo;

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
commit;
notify pgrst, 'reload schema';
