-- Colegio-IA 033 (21 oct 2026): contrato de matrícula con pagaré y carta de instrucciones, y becas / subsidios.
--  Pedido de Ricardo:
--   - La app genera el contrato de prestación de servicios educativos de cada estudiante, acompañado de un pagaré
--     en blanco y su carta de instrucciones. Firman los DOS acudientes como deudores solidarios.
--   - Becas y subsidios como descuento en la pensión (o en la matrícula): porcentaje o valor fijo por cuota,
--     con motivo y meses de vigencia. El estado de cuenta, la cartera, el pago con Bold y el contrato ya cobran
--     el valor rebajado. Las becas no se borran: se anulan con motivo (queda el historial).

begin;

-- 1) Datos del contrato que fija cada colegio (representante legal, ciudad, cláusulas propias…)
alter table public.colegios add column if not exists contrato_cfg jsonb not null default '{}';
create or replace function public.colegio_contrato(p_colegio uuid, p_cfg jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
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
  if length(coalesce(p_cfg ->> 'clausulas', '')) > 8000 then raise exception 'Las cláusulas adicionales no pueden pasar de 8.000 caracteres'; end if;
  if nullif(trim(p_cfg ->> 'clausulas'), '') is not null then r := r || jsonb_build_object('clausulas', trim(p_cfg ->> 'clausulas')); end if;
  n := coalesce(nullif(p_cfg ->> 'cuotas_mora', '')::int, 2);
  if n not between 1 and 12 then raise exception 'Las cuotas en mora para llenar el pagaré van de 1 a 12'; end if;
  r := r || jsonb_build_object('cuotas_mora', n);
  perform set_config('micolegia.sistema', 'on', true);
  update colegios set contrato_cfg = r where id = p_colegio;
  perform set_config('micolegia.sistema', '', true);
  return r;
end $$;

-- 2) Becas, subsidios y descuentos por estudiante y año
create table if not exists public.becas (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  anio int not null,
  tipo text not null check (tipo in ('Beca', 'Subsidio', 'Descuento por hermanos', 'Convenio', 'Otro')),
  motivo text not null check (length(motivo) between 3 and 300),
  modo text not null check (modo in ('porcentaje', 'valor')),
  valor numeric(12,0) not null check (valor > 0),
  aplica text not null default 'pension' check (aplica in ('pension', 'matricula', 'ambos')),
  mes_desde int not null default 1 check (mes_desde between 1 and 12),
  mes_hasta int not null default 12 check (mes_hasta between 1 and 12),
  activa boolean not null default true,
  creado_por text,
  creado_nombre text,
  creado_en timestamptz not null default now(),
  anulada_nombre text,
  anulada_en timestamptz,
  anulada_motivo text,
  mes_corte int,               -- al anular: el descuento se mantiene en las cuotas hasta este mes (no es retroactivo)
  check (mes_hasta >= mes_desde),
  check (modo <> 'porcentaje' or valor <= 100)
);
alter table public.becas add column if not exists mes_corte int;
create index if not exists becas_est on public.becas (estudiante_id, anio);
create index if not exists becas_col on public.becas (colegio_id, anio);
alter table public.becas enable row level security;
revoke all on public.becas from authenticated, anonymous;
grant select on public.becas to authenticated;
drop policy if exists becas_ver on public.becas;
create policy becas_ver on public.becas for select to authenticated
  using (priv.ve_pagos(colegio_id) or priv.puede(colegio_id, 'becas') or priv.es_familia_de(estudiante_id));
drop trigger if exists zz_bloqueo on public.becas;
create trigger zz_bloqueo before insert or update or delete on public.becas for each row execute function priv.tg_bloqueo();

-- Permiso nuevo "becas" (por defecto solo el rector; cada colegio lo ajusta en Parametrización › Permisos)
do $$
declare d text;
begin
  d := pg_get_functiondef('priv.permiso_defecto'::regproc);
  if position('''becas''' in d) = 0 then
    d := replace(d, '    else array[]::text[] end',
      '    when ''becas''          then array[''rector'']                            -- asignar y anular becas, subsidios y descuentos' || chr(10) ||
      '    else array[]::text[] end');
    if position('''becas''' in d) = 0 then raise exception 'No se encontró dónde agregar el permiso de becas'; end if;
    execute d;
  end if;
  -- y Parametrización › Permisos acepta guardarlo
  d := pg_get_functiondef('public.guardar_permisos'::regproc);
  if position('''becas''' in d) = 0 then
    d := replace(d, '''citas'',''autorizaciones'')', '''citas'',''autorizaciones'',''becas'')');
    if position('''becas''' in d) = 0 then raise exception 'No se encontró dónde agregar el permiso de becas a guardar_permisos'; end if;
    execute d;
  end if;
end $$;

create or replace function public.beca_guardar(p_est uuid, p_datos jsonb) returns becas
language plpgsql security definer set search_path = public, pg_temp as $$
declare s estudiantes; k colegios; r becas; v numeric; md text; ap text; d1 int; d2 int; tp text; mo text;
begin
  select * into s from estudiantes where id = p_est;
  if s.id is null then raise exception 'Estudiante no encontrado'; end if;
  if not priv.puede(s.colegio_id, 'becas') then raise exception 'No tiene permiso para asignar becas (Parametrización › Permisos)'; end if;
  if s.estado <> 'Activo' then raise exception 'Solo se asignan becas a estudiantes activos'; end if;
  select * into k from colegios where id = s.colegio_id;
  tp := p_datos ->> 'tipo'; mo := upper(trim(coalesce(p_datos ->> 'motivo', ''))); md := p_datos ->> 'modo'; ap := coalesce(p_datos ->> 'aplica', 'pension');
  v := round(coalesce(nullif(p_datos ->> 'valor', '')::numeric, 0));
  d1 := coalesce(nullif(p_datos ->> 'mes_desde', '')::int, 1); d2 := coalesce(nullif(p_datos ->> 'mes_hasta', '')::int, 12);
  if tp is null or tp not in ('Beca', 'Subsidio', 'Descuento por hermanos', 'Convenio', 'Otro') then raise exception 'Elija el tipo (beca, subsidio, descuento…)'; end if;
  if length(mo) < 3 then raise exception 'Escriba el motivo o la entidad que otorga el beneficio'; end if;
  if md not in ('porcentaje', 'valor') then raise exception 'Elija si el descuento es un porcentaje o un valor fijo'; end if;
  if v <= 0 then raise exception 'Escriba el valor del descuento'; end if;
  if md = 'porcentaje' and v > 100 then raise exception 'El porcentaje no puede pasar de 100'; end if;
  if ap not in ('pension', 'matricula', 'ambos') then raise exception 'Elija a qué cobro se aplica'; end if;
  if d1 not between 1 and 12 or d2 not between 1 and 12 or d2 < d1 then raise exception 'Revise los meses de vigencia'; end if;
  perform pg_advisory_xact_lock(hashtext('becas' || p_est::text));
  -- no más del 100% en ningún mes sumando las becas en porcentaje que ya tiene el estudiante
  if md = 'porcentaje' then
    if ap in ('matricula', 'ambos') and v + coalesce((select sum(b.valor) from becas b where b.estudiante_id = p_est and b.anio = k.anio and b.activa
          and b.modo = 'porcentaje' and b.aplica in ('matricula', 'ambos')), 0) > 100 then
      raise exception 'Con las becas que ya tiene, el descuento de la matrícula pasaría del 100%%';
    end if;
    if ap in ('pension', 'ambos') and exists (select 1 from generate_series(d1, d2) m
          where v + coalesce((select sum(b.valor) from becas b where b.estudiante_id = p_est and b.anio = k.anio and (b.activa or m <= coalesce(b.mes_corte, 0)) and b.modo = 'porcentaje'
                and b.aplica in ('pension', 'ambos') and m between b.mes_desde and b.mes_hasta), 0) > 100) then
      raise exception 'Con las becas que ya tiene, el descuento de la pensión pasaría del 100%% en algún mes';
    end if;
  end if;
  if exists (select 1 from bold_ordenes o where o.estudiante_id = p_est and o.estado = 'Pendiente') then
    raise exception 'Este estudiante tiene un pago en línea en verificación. Espere a que se confirme o se cancele y luego asigne la beca';
  end if;
  -- no se aplica a cuotas que ya tienen pagos (el dinero pagado no se pierde ni queda como saldo a favor sin control)
  if ap in ('pension', 'ambos') and exists (select 1 from pagos p join conceptos c on c.id = p.concepto_id
        where p.estudiante_id = p_est and p.anio = k.anio and not p.anulado and c.tipo = 'pension' and p.mes between d1 and d2) then
    raise exception 'Ya hay pagos de pensión entre % y %. Haga que la beca empiece en el mes siguiente al último pagado',
      (array['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'])[d1],
      (array['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'])[d2];
  end if;
  if ap in ('matricula', 'ambos') and exists (select 1 from pagos p join conceptos c on c.id = p.concepto_id
        where p.estudiante_id = p_est and p.anio = k.anio and not p.anulado and c.tipo = 'matricula') then
    raise exception 'La matrícula de este año ya tiene pagos: el descuento solo puede aplicarse a la pensión';
  end if;
  insert into becas (colegio_id, estudiante_id, anio, tipo, motivo, modo, valor, aplica, mes_desde, mes_hasta, creado_por, creado_nombre)
  values (s.colegio_id, p_est, k.anio, tp, mo, md, v, ap, d1, d2, priv.uid()::text,
          coalesce((select max(m.nombre) from miembros m where m.colegio_id = s.colegio_id and m.user_id = priv.uid()), 'SISTEMA'))
  returning * into r;
  return r;
end $$;

create or replace function public.beca_anular(p_beca uuid, p_motivo text) returns becas
language plpgsql security definer set search_path = public, pg_temp as $$
declare b becas;
begin
  select * into b from becas where id = p_beca;
  if b.id is null then raise exception 'Beca no encontrada'; end if;
  if not priv.puede(b.colegio_id, 'becas') then raise exception 'No tiene permiso para anular becas'; end if;
  if not b.activa then raise exception 'Esta beca ya estaba anulada'; end if;
  if length(trim(coalesce(p_motivo, ''))) < 3 then raise exception 'Escriba el motivo de la anulación'; end if;
  -- no es retroactivo: las cuotas hasta el mes en curso conservan el descuento; desde el mes siguiente se cobra completo
  update becas set activa = false, anulada_motivo = upper(trim(p_motivo)), anulada_en = now(),
         -- también conservan el descuento las pensiones ya pagadas por adelantado
         mes_corte = greatest(case when b.anio < extract(year from priv.hoy_co())::int then 12
                                   when b.anio > extract(year from priv.hoy_co())::int then 0
                                   else extract(month from priv.hoy_co())::int end,
                              coalesce((select max(p.mes) from pagos p join conceptos c on c.id = p.concepto_id
                                         where p.estudiante_id = b.estudiante_id and p.anio = b.anio and not p.anulado and c.tipo = 'pension'), 0)),
         anulada_nombre = coalesce((select max(m.nombre) from miembros m where m.colegio_id = b.colegio_id and m.user_id = priv.uid()), 'SISTEMA')
   where id = p_beca returning * into b;
  return b;
end $$;

-- 3) Estado de cuenta con becas. El cálculo pasa a priv.cuenta_base (sin revisar permisos, lo usa también el contrato);
--    public.estado_cuenta conserva sus columnas y su control de permisos.
create or replace function priv.cuenta_base(p_estudiante uuid, p_anio integer)
returns table(concepto_id uuid, concepto text, tipo text, mes integer, valor numeric, pagado numeric, saldo numeric, vencido boolean, valor_base numeric, descuento numeric, orden integer)
language sql stable security definer set search_path = public, pg_temp as $function$
  with s as (
    select e.*, k.dia_limite_pago as dia,
           coalesce(case when h.estudiante_id is not null and coalesce(extract(year from e.fecha_matricula)::int, p_anio) <> p_anio then h.grado end, g.grado) as grado_anio,
           case when extract(year from e.fecha_matricula)::int = p_anio then e.fecha_matricula
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
      and ((c.periodicidad = 'unico' and c.tipo in ('matricula', 'seguro', 'carnet'))
        or s.matricula_anio is null
        or s.matricula_anio < (make_date(p_anio, m.mes, 1) + interval '1 month'))
      and (s.retiro_anio is null or make_date(p_anio, m.mes, 1) <= s.retiro_anio)
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
         current_date > greatest(make_date(p_anio, c.mes, c.dia), coalesce(c.matricula_anio, make_date(p_anio, c.mes, c.dia))),
         c.valor, coalesce(d.d, 0), c.orden
  from cobros c
  left join dsc d on d.id = c.id and d.mes = c.mes
  left join pag pg on pg.concepto_id = c.id and pg.mes is not distinct from c.mes
  where c.valor > 0
  order by c.mes, c.orden, c.nombre
$function$;

create or replace function public.estado_cuenta(p_estudiante uuid, p_anio integer)
returns table(concepto_id uuid, concepto text, tipo text, mes integer, valor numeric, pagado numeric, saldo numeric, vencido boolean)
language sql stable security definer set search_path = public, pg_temp as $function$
  -- security definer: necesita leer el historial (año cursado), que tesorería no ve; el permiso se valida aquí
  select b.concepto_id, b.concepto, b.tipo, b.mes, b.valor, b.pagado, b.saldo, b.vencido
  from estudiantes e
  cross join lateral priv.cuenta_base(e.id, p_anio) b
  where e.id = p_estudiante and (priv.ve_pagos(e.colegio_id) or priv.es_familia_de(e.id))
    and (b.valor > 0 or b.pagado > 0)   -- con beca del 100% la cuota no se cobra (salvo que ya tuviera pagos)
$function$;

-- 4) Datos del contrato de un estudiante: costos del año (con y sin beca) y becas vigentes
create or replace function public.contrato_datos(p_est uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s estudiantes; k colegios;
begin
  select * into s from estudiantes where id = p_est;
  if s.id is null then raise exception 'Estudiante no encontrado'; end if;
  if not (priv.puede(s.colegio_id, 'matricula') or priv.ve_pagos(s.colegio_id)) then raise exception 'No tiene permiso para generar contratos'; end if;
  select * into k from colegios where id = s.colegio_id;
  return jsonb_build_object(
    'anio', k.anio,
    'conceptos', coalesce((select jsonb_agg(to_jsonb(x) order by x.orden, x.nombre) from (
        select b.concepto_id, max(b.concepto) as nombre, max(b.tipo) as tipo, min(b.orden) as orden, count(*) as cuotas,
               array_agg(b.mes order by b.mes) as meses, max(b.valor_base) as valor_cuota, sum(b.valor_base) as total_base,
               sum(b.valor) as total, max(b.descuento) as descuento_cuota,
               coalesce(array_agg(b.mes order by b.mes) filter (where b.descuento > 0), '{}') as meses_beca
        from priv.cuenta_base(p_est, k.anio) b group by b.concepto_id) x), '[]'),
    -- también las anuladas que siguen aplicando a cuotas ya causadas o pagadas (hasta mes_corte)
    'becas', coalesce((select jsonb_agg(to_jsonb(bc) order by bc.creado_en) from becas bc where bc.estudiante_id = p_est and bc.anio = k.anio
                        and (bc.activa or coalesce(bc.mes_corte, 0) >= bc.mes_desde or (bc.aplica <> 'pension' and coalesce(bc.mes_corte, 0) >= 1))), '[]'));
end $$;

grant execute on function public.colegio_contrato(uuid, jsonb), public.beca_guardar(uuid, jsonb), public.beca_anular(uuid, text),
  public.contrato_datos(uuid), public.estado_cuenta(uuid, integer) to authenticated;
revoke execute on function public.colegio_contrato(uuid, jsonb), public.beca_guardar(uuid, jsonb), public.beca_anular(uuid, text),
  public.contrato_datos(uuid) from public, anonymous;

-- 5) Demostración: datos del contrato y una beca de ejemplo (a un estudiante que no es hijo del acudiente de la demo)
create or replace function priv.demo_contrato(c uuid, a int) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e uuid; m1 int;
begin
  update colegios set contrato_cfg = jsonb_build_object('titular', upper(nombre), 'titular_nit', coalesce(nit, '900.000.000-0'),
      'rep_nombre', upper(coalesce(rector_nombre, 'RECTOR(A)')), 'rep_doc', '12.345.678', 'rep_cargo', 'RECTOR(A) Y REPRESENTANTE LEGAL',
      'ciudad', upper(coalesce(ciudad, 'SANTA MARTA')), 'cuotas_mora', 2)
   where id = c;
  select s.id into e from estudiantes s
   where s.colegio_id = c and s.estado = 'Activo'
     and not exists (select 1 from miembros m where m.estudiante_id = s.id and m.rol in ('acudiente', 'estudiante'))
   order by s.folio desc limit 1;
  -- la beca empieza después de la última pensión ya pagada (así no queda pagado de más)
  m1 := least(coalesce((select max(p.mes) from pagos p join conceptos k on k.id = p.concepto_id
                         where p.estudiante_id = e and p.anio = a and not p.anulado and k.tipo = 'pension'), 0) + 1, 12);
  if e is not null and not exists (select 1 from becas b where b.estudiante_id = e and b.anio = a) then
    insert into becas (colegio_id, estudiante_id, anio, tipo, motivo, modo, valor, aplica, mes_desde, mes_hasta, creado_nombre)
    values (c, e, a, 'Beca', 'BECA POR RENDIMIENTO ACADÉMICO (EJEMPLO DE LA DEMOSTRACIÓN)', 'porcentaje', 30, 'pension', m1, 12, 'RECTORÍA');
  end if;
end $$;
do $$
declare d text;
begin
  d := pg_get_functiondef('priv.crear_demo'::regproc);
  if position('demo_contrato' in d) = 0 then
    d := replace(d, '  perform priv.demo_documentos(c, a);', '  perform priv.demo_documentos(c, a);' || chr(10) || '  perform priv.demo_contrato(c, a);');
    if position('demo_contrato' in d) = 0 then raise exception 'No se encontró dónde agregar el contrato a la demostración'; end if;
    execute d;
  end if;
end $$;
select priv.demo_contrato(id, anio) from colegios where demo;

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
-- cuenta_base no revisa permisos: solo la usan funciones SECURITY DEFINER (estado_cuenta, contrato_datos)
revoke execute on function priv.cuenta_base(uuid, integer), priv.demo_contrato(uuid, integer) from authenticated;
commit;
notify pgrst, 'reload schema';
