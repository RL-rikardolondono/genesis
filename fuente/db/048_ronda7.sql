-- 048_ronda7.sql · Colegio-IA v0.34.0 · Prueba Ácida, 7.ª vuelta (24 nov 2026)
-- Idempotente: se puede aplicar varias veces (create or replace, if exists / if not exists).
-- Aplicar en el editor SQL de Neon después de 047.

-- 1) La fecha de vencimiento de las cuotas se compara con el día de Colombia (antes current_date: en Neon es la fecha UTC,
--    y desde las 7 p. m. una cuota que vence hoy ya salía vencida en el servidor pero no en la pantalla)
CREATE OR REPLACE FUNCTION priv.cuenta_base(p_estudiante uuid, p_anio integer)
 RETURNS TABLE(concepto_id uuid, concepto text, tipo text, mes integer, valor numeric, pagado numeric, saldo numeric, vencido boolean, valor_base numeric, descuento numeric, orden integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$#variable_conflict use_column
begin
  return query 
  with s as (
    select e.*, k.dia_limite_pago as dia,
           coalesce(case when h.estudiante_id is not null and coalesce(extract(year from e.fecha_matricula)::int, p_anio) <> p_anio then h.grado end, g.grado + case when p_anio > k.anio then 1 else 0 end) as grado_anio,
           case when e.al_dia_hasta is not null and extract(year from e.al_dia_hasta)::int = p_anio then null
                when extract(year from e.fecha_matricula)::int = p_anio then e.fecha_matricula
                when extract(year from h.fecha_matricula)::int = p_anio then h.fecha_matricula end as matricula_anio,
           (h.estudiante_id is not null or e.fecha_matricula is null or extract(year from e.fecha_matricula)::int <= p_anio) as cursa,
           coalesce(h.fecha_retiro, e.fecha_retiro) as retiro_anio
    from estudiantes e
    join colegios k on k.id = e.colegio_id
    left join grupos g on g.id = e.grupo_id
    left join historial h on h.estudiante_id = e.id and h.anio = p_anio
    where e.id = p_estudiante
  ),
  cobros as (
    select c.id, c.nombre, c.tipo, c.orden, m.mes, s.matricula_anio, s.dia,
           coalesce((c.valores_grado ->> (s.grado_anio)::text)::numeric, c.valor) as valor
    from s
    join conceptos c on c.colegio_id = s.colegio_id and c.anio = p_anio and c.activo
    cross join lateral (
      select unnest(case when c.periodicidad = 'mensual' then c.meses else array[c.mes_cobro] end) as mes
    ) m
    where s.cursa
      and not exists (select 1 from historial hg where hg.estudiante_id = s.id and hg.resultado = 'Graduado' and hg.anio < p_anio)
      and not exists (select 1 from grados gr where gr.estudiante_id = s.id and gr.anio < p_anio)
      and ((c.periodicidad = 'unico' and c.tipo in ('matricula', 'seguro', 'carnet'))
        or s.matricula_anio is null
        or s.matricula_anio < (make_date(p_anio, m.mes, 1) + interval '1 month'))
      and (s.retiro_anio is null or make_date(p_anio, m.mes, 1) <= s.retiro_anio)
      and (s.al_dia_hasta is null or make_date(p_anio, m.mes, 1) > s.al_dia_hasta)   -- ya pagado en el sistema anterior (migración)
  ),
  dsc as (
    -- becas activas del año: los porcentajes se suman; los valores fijos se descuentan de cada cuota; nunca pasa del valor
    select c.id, c.mes,
           least(c.valor, round(c.valor * coalesce(sum(b.valor) filter (where b.modo = 'porcentaje'), 0) / 100)
                          + coalesce(sum(b.valor) filter (where b.modo = 'valor'), 0)) as d
    from cobros c
    join becas b on b.estudiante_id = p_estudiante and b.anio = p_anio and (b.activa or c.mes <= coalesce(b.mes_corte, 0))
     and (b.aplica = c.tipo or (b.aplica = 'ambos' and c.tipo in ('pension', 'matricula')))
     and (c.tipo = 'matricula' or c.mes between b.mes_desde and b.mes_hasta)
    group by c.id, c.mes, c.valor
  ),
  pag as (
    select p.concepto_id, p.mes, sum(p.valor) as pagado
    from pagos p where p.estudiante_id = p_estudiante and p.anio = p_anio and not p.anulado
    group by 1, 2
  )
  select c.id, c.nombre, c.tipo, c.mes, c.valor - coalesce(d.d, 0),
         coalesce(pg.pagado, 0), greatest(c.valor - coalesce(d.d, 0) - coalesce(pg.pagado, 0), 0),
         priv.hoy_co() > greatest(make_date(p_anio, c.mes, c.dia), coalesce(c.matricula_anio, make_date(p_anio, c.mes, c.dia))),
         c.valor, coalesce(d.d, 0), c.orden
  from cobros c
  left join dsc d on d.id = c.id and d.mes = c.mes
  left join pag pg on pg.concepto_id = c.id and pg.mes is not distinct from c.mes
  where c.valor > 0
  order by c.mes, c.orden, c.nombre
;
end$function$;

-- 2) «Debe a la fecha» (paz y salvo, constancia de saldo): lo vencido más lo que ya llegó a su fecha límite normal (vence hoy),
--    también para quien se matriculó hoy (antes la pensión del mes en curso no contaba y la matrícula de febrero sí). Igual que la pantalla.
create or replace function priv.debe_a_hoy(e uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from estudiantes s join colegios k on k.id = s.colegio_id
    cross join lateral generate_series(greatest(k.anio - 5, 2020), k.anio) y
    cross join lateral priv.cuenta_int(s.id, y) x
    where s.id = e and x.saldo > 0
      and (x.vencido or y < extract(year from priv.hoy_co())::int
           or make_date(y, x.mes, least(greatest(coalesce(k.dia_limite_pago, 5), 1), 28)) <= priv.hoy_co()))
$$;

-- 3) Inicio de directivos: «% de calificaciones registradas» con las asignaturas del plan de cada grado (igual que «Avance por docente»)
CREATE OR REPLACE FUNCTION public.resumen_colegio(p_colegio uuid)
 RETURNS json
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k colegios; bajo_hasta numeric; r json;
begin
  select * into k from colegios where id = p_colegio;
  if k.id is null or not (priv.es_directivo(p_colegio) or priv.ve_pagos(p_colegio)) then raise exception 'Sin permiso'; end if;
  select min((e->>'min')::numeric) into bajo_hasta from jsonb_array_elements(k.escala) e where e->>'d' <> 'Bajo';
  with act as (select s.* from estudiantes s where s.colegio_id = p_colegio and s.estado = 'Activo'),
  gr as (select g.* from grupos g where g.colegio_id = p_colegio),
  -- v0.34: lo esperado son las asignaturas del plan de cada grado (como «Avance por docente»), y solo cuentan esas notas
  par as (select act.id as est, a.id as asig from act join gr on gr.id = act.grupo_id join asignaturas a on a.colegio_id = p_colegio and a.nivel = gr.nivel
          and (cardinality(a.grados) = 0 or gr.grado = any(a.grados))),
  esperadas as (select count(*) n from par),
  registradas as (select count(*) n from notas x join par on par.est = x.estudiante_id and par.asig = x.asignatura_id where x.periodo = k.periodo_actual and x.anio = k.anio),
  defs as (select d.* from definitivas(p_colegio) d join act on act.id = d.estudiante_id join gr on gr.id = act.grupo_id where gr.nivel <> 'preescolar'),
  riesgo as (select act.id, act.nombres || ' ' || act.apellidos as nombre, gr.nombre as grupo, array_agg(a.nombre order by a.orden) as asignaturas
    from defs d join act on act.id = d.estudiante_id join gr on gr.id = act.grupo_id join asignaturas a on a.id = d.asignatura_id
    where d.definitiva < bajo_hasta group by act.id, act.nombres, act.apellidos, gr.nombre having count(*) >= k.max_perdidas)
  select json_build_object('activos', (select count(*) from act), 'grupos', (select count(*) from gr),
    'piar', (select count(*) from act where piar), 'esperadas', (select n from esperadas), 'registradas', (select n from registradas),
    'valor_mensual', precio_plan((select count(*)::int from act)),
    'riesgo', coalesce((select json_agg(riesgo order by grupo, nombre) from riesgo), '[]'::json)) into r;
  return r;
end $function$;

-- 4) emitir_documento: con un estudiante de otro colegio responde siempre «Estudiante no válido» (no revela si tiene deuda)
CREATE OR REPLACE FUNCTION public.emitir_documento(p_colegio uuid, p_est uuid, p_tipo text, p_anio integer, p_titulo text, p_resumen jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare h text; c text; s estudiantes; g grupos; r jsonb := '{}'; dir boolean := priv.es_directivo(p_colegio); t text; x jsonb := coalesce(p_resumen, '{}'); k text;
begin
  if not (dir or priv.ve_pagos(p_colegio) or (p_est is not null and priv.es_acudiente_de(p_est))) then raise exception 'No tiene permiso para emitir documentos'; end if;
  t := case p_tipo when 'constancia' then 'Constancia de estudio' when 'certificado' then 'Constancia de estudio con calificaciones' when 'certificado_anio' then 'Certificado de estudios'
    when 'informe_final' then 'Informe final' when 'acta_grado' then 'Acta de grado' when 'diploma' then 'Diploma' when 'paz_salvo' then 'Paz y salvo' when 'retiro' then 'Constancia de retiro' end;
  if t is null then raise exception 'Tipo de documento no válido'; end if;
  -- v0.34: primero se revisa que el estudiante sea de este colegio (antes, con un estudiante ajeno, se sabía si tenía deuda)
  select * into s from estudiantes where id = p_est and colegio_id = p_colegio;
  if p_est is not null and s.id is null then raise exception 'Estudiante no válido'; end if;
  if p_tipo = 'paz_salvo' and p_est is not null and priv.debe_a_hoy(p_est) then raise exception 'Tiene saldo pendiente a la fecha (vencido o que vence hoy): el paz y salvo se expide cuando esté al día'; end if;
  if p_tipo in ('acta_grado', 'diploma') and not dir then raise exception 'Solo la rectoría o la secretaría expiden actas de grado y diplomas'; end if;
  if p_tipo = 'retiro' and s.estado = 'Activo' then raise exception 'La constancia de retiro solo se expide para estudiantes retirados'; end if;
  if not dir and not priv.ve_pagos(p_colegio) then   -- la familia: solo lo que pidió y ya está pagado (la pantalla lo cobra; la base lo exige)
    if p_tipo = 'informe_final' then raise exception 'El informe final lo expide la secretaría del colegio'; end if;
    if not exists (select 1 from doc_solicitudes ds where ds.estudiante_id = p_est and ds.estado = 'Pagado'
        and ds.tipo = case p_tipo when 'certificado_anio' then 'anteriores' when 'paz_salvo' then 'pazysalvo' else p_tipo end
        and case when p_tipo = 'certificado_anio' then ds.anio = p_anio else ds.pagado_en > now() - interval '30 days' end) then
      raise exception 'Primero pida y pague este documento en «Documentos»';
    end if;
    if p_tipo = 'paz_salvo' and priv.debe_a_hoy(p_est) then
      raise exception 'Tiene saldo pendiente. El paz y salvo se expide cuando esté al día (vea Estado de cuenta)';
    end if;
  end if;
  if s.id is not null then
    select * into g from grupos where id = s.grupo_id;
    r := jsonb_build_object('estudiante', s.nombres || ' ' || s.apellidos,
      'documento', s.tipo_doc || ' ' || repeat('•', greatest(length(s.doc) - 4, 0)) || right(s.doc, 4), 'grado', coalesce(g.nombre, ''), 'estado', s.estado);
  end if;
  if p_tipo in ('acta_grado', 'diploma') then
    x := (select jsonb_build_object('titulo_otorgado', gr.titulo, 'acta', gr.acta::text, 'diploma', gr.diploma, 'fecha_de_grado', to_char(gr.fecha, 'DD/MM/YYYY'))
          from grados gr where gr.estudiante_id = p_est order by gr.fecha desc limit 1);
    if x is null then raise exception 'El estudiante no tiene grado registrado'; end if;
    r := r || x;
  elsif p_tipo = 'certificado_anio' then
    r := r || coalesce((select jsonb_build_object('grado', coalesce(h.grupo_nombre, ''), 'resultado', coalesce(h.resultado, ''))
                        from historial h where h.estudiante_id = p_est and h.anio = p_anio order by h.grado desc nulls last limit 1), '{}');
  elsif p_tipo = 'informe_final' and dir then
    -- el resultado lo calcula el colegio en pantalla; solo se acepta uno de los textos conocidos
    if x->>'resultado' in ('Cumple', 'Parcial', 'Promovido(a)') or x->>'resultado' like 'No cumple (%' then r := r || jsonb_build_object('resultado', x->>'resultado'); end if;
  end if;
  h := md5(coalesce(p_est::text, '') || '|' || p_tipo || '|' || coalesce(p_anio, 0) || '|' || r::text || '|' || priv.hoy_co());
  select codigo into c from documentos_emitidos where colegio_id = p_colegio and huella = h and anulado_en is null limit 1;
  if c is not null then return c; end if;
  loop
    c := upper(substr(translate(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), '01', ''), 1, 12));
    c := substr(c, 1, 4) || '-' || substr(c, 5, 4) || '-' || substr(c, 9, 4);
    exit when length(c) = 14 and not exists (select 1 from documentos_emitidos where codigo = c);
  end loop;
  insert into documentos_emitidos (codigo, colegio_id, estudiante_id, tipo, anio, titulo, resumen, huella, emitido_por)
  values (c, p_colegio, p_est, p_tipo, p_anio, t, r, h, priv.nombre_actual(p_colegio));
  return c;
end $function$;

-- 5) Acuerdo de pago: la cuota inicial y las cuotas suman la deuda, y la deuda no supera lo que se debe
CREATE OR REPLACE FUNCTION public.acuerdo_guardar(p_est uuid, p_numero text, p_total numeric, p_inicial numeric, p_cuotas jsonb)
 RETURNS acuerdos_pago
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare s estudiantes; r acuerdos_pago; c jsonb;
begin
  select * into s from estudiantes where id = p_est;
  if s.id is null or not priv.maneja_pagos(s.colegio_id) then raise exception 'No tiene permiso para registrar acuerdos de pago'; end if;
  if coalesce(p_total, 0) <= 0 then raise exception 'El acuerdo necesita una deuda mayor que 0'; end if;
  if coalesce(p_inicial, 0) < 0 or coalesce(p_inicial, 0) > p_total then raise exception 'Revise la cuota inicial'; end if;
  for c in select jsonb_array_elements(coalesce(p_cuotas, '[]')) loop
    if (c ->> 'fecha') is null or coalesce((c ->> 'valor')::numeric, 0) <= 0 then raise exception 'Revise las cuotas del acuerdo'; end if;
  end loop;
  -- v0.34: la cuota inicial más las cuotas suman la deuda reconocida, y la deuda no supera lo que el estudiante debe
  if round(coalesce(p_inicial, 0)) + coalesce((select sum(round((x ->> 'valor')::numeric)) from jsonb_array_elements(coalesce(p_cuotas, '[]')) x), 0) <> round(p_total) then
    raise exception 'La cuota inicial y las cuotas deben sumar la deuda reconocida (%)', to_char(round(p_total), 'FM999G999G999');
  end if;
  if round(p_total) > coalesce((select sum(x.saldo) from colegios k cross join lateral generate_series(greatest(k.anio - 5, 2020), k.anio) y
       cross join lateral priv.cuenta_int(p_est, y) x where k.id = s.colegio_id and x.saldo > 0), 0) then
    raise exception 'La deuda del acuerdo es mayor que lo que debe el estudiante';
  end if;
  update acuerdos_pago set estado = 'Terminado', motivo = 'Reemplazado por un acuerdo nuevo', terminado_nombre = priv.nombre_actual(s.colegio_id), terminado_en = now()
   where estudiante_id = p_est and estado = 'Vigente';
  insert into acuerdos_pago (colegio_id, estudiante_id, numero, total, inicial, cuotas, creado_por, creado_nombre, aprobado, aprobado_nombre)
  values (s.colegio_id, p_est, left(p_numero, 30), round(p_total), round(coalesce(p_inicial, 0)), coalesce(p_cuotas, '[]'), priv.uid(), priv.nombre_actual(s.colegio_id),
          priv.puede(s.colegio_id, 'aprobar_acuerdos'), case when priv.puede(s.colegio_id, 'aprobar_acuerdos') then priv.nombre_actual(s.colegio_id) end)
  returning * into r;
  return r;
end $function$;

-- 6) Comunicados: los borradores pendientes de aprobación no los ven tesorería, secretaría ni otros docentes
CREATE OR REPLACE FUNCTION priv.ve_comunicado(c comunicados)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- v0.34: los borradores pendientes de aprobación solo los ven quien los escribió y quienes los aprueban (rectoría y coordinación)
  select (priv.es_personal(c.colegio_id) and (c.aprobado or c.creado_por = priv.uid() or priv.roles_en(c.colegio_id) && array['rector','coordinador'])) or (c.aprobado and priv.es_miembro(c.colegio_id) and (
    c.destino = 'todos'
    or (c.destino = 'grupo' and exists (select 1 from estudiantes s where s.grupo_id = c.grupo_id and s.id in (select priv.mis_estudiantes())))
    or (c.destino = 'estudiante' and c.estudiante_id in (select priv.mis_estudiantes()))))
$function$;

-- 7) Excusas: fechas razonables y motivo de máximo 500 caracteres (también por la API)
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

-- 8) Pagos que llegan de la aplicación: sin centavos (antes se redondeaban en silencio), sin valores enormes y con fechas posibles
alter table public.pagos alter column valor type numeric using valor;   -- sin escala fija: así 1000,55 llega como tal y se rechaza
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

-- 9) Actividades ocultas del campus: la familia y el estudiante no las ven en «Ver detalle» (la política anterior miraba el campus
--    con los permisos de la familia, que no ve los ítems ocultos, y por eso no los excluía)
create or replace function priv.act_oculta(a uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from campus_items i join campus_unidades u on u.id = i.unidad_id where i.actividad_id = a and (not i.visible or not u.visible))
$$;
drop policy if exists act_ver on public.actividades;
create policy act_ver on public.actividades for select using (priv.es_personal(colegio_id) or (priv.es_miembro(colegio_id) and not priv.act_oculta(id)));

-- 10) Recibos de documentos pagados con consecutivo propio del colegio (D-1, D-2…) en vez de un código
alter table public.doc_solicitudes add column if not exists recibo integer;
create or replace function priv.tg_doc_recibo() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.estado = 'Pagado' and new.recibo is null and coalesce(new.valor, 0) > 0 then
    perform pg_advisory_xact_lock(hashtext('recibo_doc' || new.colegio_id::text));
    select coalesce(max(recibo), 0) + 1 into new.recibo from doc_solicitudes where colegio_id = new.colegio_id;
  end if;
  return new;
end $$;
drop trigger if exists tg_doc_recibo on public.doc_solicitudes;
create trigger tg_doc_recibo before insert or update of estado on public.doc_solicitudes for each row execute function priv.tg_doc_recibo();
do $$ declare r record; begin
  for r in select id, colegio_id from doc_solicitudes where estado = 'Pagado' and recibo is null and coalesce(valor, 0) > 0 order by colegio_id, pagado_en nulls first, creado_en loop
    update doc_solicitudes set recibo = (select coalesce(max(recibo), 0) + 1 from doc_solicitudes where colegio_id = r.colegio_id) where id = r.id;
  end loop;
end $$;

-- 11) Costos: tope de valor y rastro de quién cambió el valor (la tesorería puede cambiarlo por permiso; ahora queda a la vista)
alter table public.conceptos add column if not exists cambio_nombre text;
alter table public.conceptos add column if not exists cambio_en timestamptz;
create or replace function priv.tg_conceptos_cambio() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
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
drop trigger if exists tg_conceptos_cambio on public.conceptos;
create trigger tg_conceptos_cambio before insert or update on public.conceptos for each row execute function priv.tg_conceptos_cambio();

-- 12) Correos de usuarios con formato válido (p. ej. «doc@@colegio.co» ya no se acepta). Solo al crear o cambiar el correo
--     (es un disparador y no una restricción, para no impedir cambios en filas antiguas que tengan otro formato)
alter table public.miembros drop constraint if exists miembros_correo_check;
create or replace function priv.tg_miembros_correo_ok() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if not priv.es_cliente() then return new; end if;   -- procesos del sistema (demostración, admisiones) quedan como estaban
  if (tg_op = 'INSERT' or new.email is distinct from old.email)
     and not (coalesce(new.email, '') ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@.]{2,}$' and position('..' in new.email) = 0) then
    raise exception 'El correo % no es válido. Escríbalo como nombre@correo.com', coalesce(new.email, '');
  end if;
  return new;
end $$;
drop trigger if exists tg_miembros_correo_ok on public.miembros;
create trigger tg_miembros_correo_ok before insert or update of email on public.miembros for each row execute function priv.tg_miembros_correo_ok();

-- 13) Graduandos: saldo pendiente de cada estudiante (para el aviso en Certificados, grados y actas)
create or replace function public.deudas_estudiantes(p_colegio uuid, p_ests uuid[]) returns table(estudiante_id uuid, deuda numeric)
language sql stable security definer set search_path = public, pg_temp as $$
  select s.id, sum(x.saldo)
  from estudiantes s join colegios k on k.id = s.colegio_id
  cross join lateral generate_series(greatest(k.anio - 5, 2020), k.anio) y
  cross join lateral priv.cuenta_int(s.id, y) x
  where s.colegio_id = p_colegio and s.id = any(p_ests) and (priv.es_directivo(p_colegio) or priv.ve_pagos(p_colegio))
    and x.saldo > 0 and (x.vencido or y < extract(year from priv.hoy_co())::int or make_date(y, x.mes, least(greatest(coalesce(k.dia_limite_pago, 5), 1), 28)) <= priv.hoy_co())
  group by s.id
$$;
revoke all on function public.deudas_estudiantes(uuid, uuid[]) from public, anonymous;
grant execute on function public.deudas_estudiantes(uuid, uuid[]) to authenticated;

-- 14) Registro: aviso de colegio con el mismo nombre en la misma ciudad (solo dice sí o no)
create or replace function public.colegio_nombre_existe(p_nombre text, p_ciudad text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select priv.uid() is not null and exists (select 1 from colegios k where not k.demo
    and upper(btrim(k.nombre)) = upper(btrim(coalesce(p_nombre, ''))) and upper(btrim(coalesce(k.ciudad, ''))) = upper(btrim(coalesce(p_ciudad, ''))))
$$;
revoke all on function public.colegio_nombre_existe(text, text) from public, anonymous;
grant execute on function public.colegio_nombre_existe(text, text) to authenticated;

-- 15) Registro con bachillerato por ciclos (CLEI 3 a 6)
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
    perform public.crear_ciclo(c, g - 20, 1, null);
  end loop;
  insert into plataforma_pruebas (email, user_id, colegio_id, colegio_nombre) values (em, u, c, btrim(p_nombre));
  perform set_config('micolegia.sistema', '', true);
  return json_build_object('miembro_id', mid, 'colegio_id', c, 'prueba_hasta', hoy + 15);
end $function$;

-- 16) Enlace de admisiones: el nombre del colegio se ve antes de crear la cuenta (solo el nombre)
create or replace function public.admision_colegio(p_codigo text) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select k.nombre from colegios k where k.admision_codigo = upper(btrim(coalesce(p_codigo, ''))) and length(btrim(coalesce(p_codigo, ''))) >= 4 limit 1
$$;
revoke all on function public.admision_colegio(text) from public;
grant execute on function public.admision_colegio(text) to anonymous, authenticated;

-- 17) Pantalla de activación: ¿la persona tiene una invitación pendiente? (si no, se le ofrece primero registrar su colegio)
create or replace function public.tengo_invitacion() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from miembros m where lower(m.email) = lower(coalesce(priv.email_actual(), '')) and m.user_id is null and m.activo)
$$;
revoke all on function public.tengo_invitacion() from public, anonymous;
grant execute on function public.tengo_invitacion() to authenticated;
