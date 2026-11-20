-- 043 · Colegio-IA v0.29 (20 nov 2026): correcciones de la 2.ª vuelta de la Prueba Ácida (5 colegios × 7 perfiles)
-- 1) Permisos nuevos: corregir calificaciones, aprobar excusas, comunicados sin revisión, aprobar recuperaciones y acuerdos
-- 2) Calificaciones: la secretaría ya no cambia notas (ni de periodos cerrados) salvo que el colegio se lo permita;
--    el docente pide la corrección de un periodo cerrado a coordinación
-- 3) Grados: el año del diploma es el año en que se cursó; solo graduados o estudiantes del último grado
-- 4) Documentos: una familia con pagos pendientes no pide documentos (tampoco por la API); el estudiante no ve los pagos
-- 5) Acuerdos de pago: la cuota inicial se paga al firmar para recuperar el acceso; visto bueno según el permiso
-- 6) Migración a mitad de año: «al día hasta» por estudiante (las cuotas anteriores no se cobran)
-- 7) Matrícula del año siguiente: costos de ese año y grado al que pasa; los graduandos no renuevan; quién actualizó
-- 8) Becas: no se duplica la misma beca; recibos: un rector no anula su propio recibo si hay otro rector
-- 9) Observador: tipo de situación (Ley 1620) y solo coordinación o rectoría borran anotaciones
-- 10) Comunicados que requieren aprobación; la familia restringida puede dejar entrar al estudiante (opción del colegio)
-- Se puede ejecutar más de una vez.
begin;

-- ---------- 1) Permisos ----------
create or replace function priv.permiso_defecto(clave text) returns text[]
language sql immutable as $$
  select case clave
    when 'pagos'            then array['rector','secretaria','tesoreria']
    when 'pagos_ver'        then array['rector','secretaria','tesoreria']
    when 'costos'           then array['rector','tesoreria']
    when 'matricula'        then array['rector','coordinador','secretaria']
    when 'contactos'        then array['rector','coordinador','secretaria']
    when 'citas'            then array['rector','coordinador']
    when 'autorizaciones'   then array['rector','coordinador']
    when 'becas'            then array['rector']
    when 'anular'           then array['rector']
    when 'aprobar_acuerdos' then array['rector']                                  -- visto bueno de los acuerdos de pago
    when 'calificar'        then array['rector','coordinador']                    -- corregir notas de cualquier curso y de periodos cerrados
    when 'excusas'          then array['rector','coordinador']                    -- aprobar excusas (además, el director de grupo)
    when 'comunicar'        then array['rector','coordinador','secretaria','docente'] -- comunicados sin revisión
    when 'aprobar_recup'    then array[]::text[]                                  -- vacío: la recuperación cuenta de inmediato
    else array[]::text[] end
$$;
create or replace function public.guardar_permisos(p_colegio uuid, p_permisos jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare clave text; r text; limpio jsonb := '{}';
begin
  if not priv.es_rector(p_colegio) then raise exception 'Solo el rector o la rectora pueden cambiar los permisos'; end if;
  for clave in select jsonb_object_keys(p_permisos) loop
    if clave not in ('pagos','pagos_ver','costos','matricula','contactos','citas','autorizaciones','becas','anular',
                     'aprobar_acuerdos','calificar','excusas','comunicar','aprobar_recup') then raise exception 'Permiso desconocido: %', clave; end if;
    for r in select jsonb_array_elements_text(p_permisos -> clave) loop
      if r not in ('rector','coordinador','secretaria','tesoreria','docente') then raise exception 'Cargo no válido: %', r; end if;
    end loop;
    limpio := limpio || jsonb_build_object(clave, (select coalesce(jsonb_agg(distinct x), '[]') from jsonb_array_elements_text(p_permisos -> clave) x));
  end loop;
  if jsonb_array_length(coalesce(limpio -> 'pagos', to_jsonb(priv.permiso_defecto('pagos')))) = 0 then raise exception 'Al menos un cargo debe poder registrar pagos'; end if;
  if jsonb_array_length(coalesce(limpio -> 'anular', to_jsonb(priv.permiso_defecto('anular')))) = 0 then raise exception 'Al menos un cargo debe poder anular recibos'; end if;
  if jsonb_array_length(coalesce(limpio -> 'aprobar_acuerdos', to_jsonb(priv.permiso_defecto('aprobar_acuerdos')))) = 0 then raise exception 'Al menos un cargo debe poder aprobar acuerdos de pago'; end if;
  if exists (select 1 from jsonb_array_elements_text(coalesce(limpio -> 'aprobar_recup', '[]')) x where x = 'docente') then
    raise exception 'Las recuperaciones de los docentes no las puede aprobar el mismo cargo docente';
  end if;
  update colegios set permisos = limpio where id = p_colegio;
  return limpio;
end $$;
revoke all on function public.guardar_permisos(uuid, jsonb) from public, anonymous;
grant execute on function public.guardar_permisos(uuid, jsonb) to authenticated;

-- ---------- 2) Calificaciones ----------
-- Quien registra notas: el docente de la asignatura, o quien tenga el permiso «calificar» (por defecto rectoría y coordinación)
create or replace function priv.puede_notas(e uuid, a uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from estudiantes s where s.id = e
                 and (priv.puede(s.colegio_id, 'calificar') or priv.docente_de_asig(s.grupo_id, a)))
$$;
-- Después del cierre del periodo solo quien tiene el permiso «calificar»
create or replace function priv.notas_abiertas(c uuid, p int, g uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select priv.puede(c, 'calificar') or coalesce((
    select priv.hoy_co() <= (x->>'cierre')::date
    from jsonb_array_elements(coalesce(priv.cal_grupo(c, g), '[]')) x
    where (x->>'n')::int = p and coalesce(x->>'cierre', '') <> ''), true)
$$;
create or replace function priv.notas_abiertas(c uuid, p int) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select priv.puede(c, 'calificar') or coalesce((
    select priv.hoy_co() <= (x->>'cierre')::date
    from colegios k, jsonb_array_elements(k.periodos) x
    where k.id = c and (x->>'n')::int = p and coalesce(x->>'cierre', '') <> ''), true)
$$;
drop policy if exists notas_ins on public.notas;
create policy notas_ins on public.notas for insert to authenticated
  with check (priv.puede_notas(estudiante_id, asignatura_id)
    and priv.notas_abiertas(colegio_id, periodo, (select s.grupo_id from estudiantes s where s.id = estudiante_id)));
drop policy if exists notas_upd on public.notas;
create policy notas_upd on public.notas for update to authenticated
  using (priv.puede_notas(estudiante_id, asignatura_id)
    and priv.notas_abiertas(colegio_id, periodo, (select s.grupo_id from estudiantes s where s.id = estudiante_id)))
  with check (priv.puede_notas(estudiante_id, asignatura_id)
    and priv.notas_abiertas(colegio_id, periodo, (select s.grupo_id from estudiantes s where s.id = estudiante_id)));
drop policy if exists notas_del on public.notas;
create policy notas_del on public.notas for delete to authenticated
  using (priv.puede_notas(estudiante_id, asignatura_id)
    and priv.notas_abiertas(colegio_id, periodo, (select s.grupo_id from estudiantes s where s.id = estudiante_id)));
create or replace function priv.puede_actividad(a uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from actividades x where x.id = a
    and (priv.puede(x.colegio_id, 'calificar') or priv.docente_de_asig(x.grupo_id, x.asignatura_id))
    and priv.notas_abiertas(x.colegio_id, x.periodo, x.grupo_id))
$$;
drop policy if exists act_esc on public.actividades;
create policy act_esc on public.actividades for all to authenticated
  using (priv.puede(colegio_id, 'calificar') or priv.docente_de_asig(grupo_id, asignatura_id))
  with check (exists (select 1 from grupos g where g.id = grupo_id and (priv.puede(g.colegio_id, 'calificar') or priv.docente_de_asig(grupo_id, asignatura_id))));

-- Recuperaciones: si el colegio pide aprobación, la nota cuenta cuando la aprueba el cargo indicado
alter table public.recuperaciones add column if not exists aprobada boolean not null default true;
alter table public.recuperaciones add column if not exists aprobada_por text;
drop policy if exists rec_esc on public.recuperaciones;
create policy rec_esc on public.recuperaciones for all to authenticated
  using (priv.puede_notas(estudiante_id, asignatura_id)) with check (priv.puede_notas(estudiante_id, asignatura_id));
create or replace function priv.tg_recup_aprobar() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare c uuid;
begin
  if not priv.es_cliente() then return new; end if;
  select colegio_id into c from estudiantes where id = new.estudiante_id;
  if cardinality(priv.permiso_roles(c, 'aprobar_recup')) = 0 or priv.puede(c, 'aprobar_recup') then
    if new.nota is not null and (tg_op = 'INSERT' or new.nota is distinct from old.nota or not old.aprobada) then
      new.aprobada := true; new.aprobada_por := case when cardinality(priv.permiso_roles(c, 'aprobar_recup')) > 0 then priv.nombre_actual(c) end;
    end if;
  else
    -- quien no aprueba: una nota nueva o cambiada queda por aprobar
    if new.nota is not null and (tg_op = 'INSERT' or new.nota is distinct from old.nota) then new.aprobada := false; new.aprobada_por := null;
    elsif tg_op = 'UPDATE' then new.aprobada := old.aprobada; new.aprobada_por := old.aprobada_por; end if;
  end if;
  return new;
end $$;
drop trigger if exists tg_recup_aprobar on public.recuperaciones;
create trigger tg_recup_aprobar before insert or update on public.recuperaciones for each row execute function priv.tg_recup_aprobar();

-- Solicitudes de corrección de calificaciones de periodos cerrados
create table if not exists public.correcciones (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references colegios(id) on delete cascade,
  grupo_id uuid references grupos(id) on delete cascade,
  asignatura_id uuid references asignaturas(id) on delete cascade,
  anio int not null, periodo int not null,
  motivo text not null check (length(btrim(motivo)) between 3 and 1000),
  estado text not null default 'Pendiente' check (estado in ('Pendiente','Atendida')),
  creado_por text, creado_nombre text, creado_en timestamptz not null default now(),
  atendida_nombre text, atendida_en timestamptz);
alter table public.correcciones enable row level security;
revoke all on public.correcciones from public, anonymous, authenticated;
grant select, insert, update on public.correcciones to authenticated;
drop policy if exists corr_ver on public.correcciones;
create policy corr_ver on public.correcciones for select to authenticated using (priv.puede(colegio_id, 'calificar') or creado_por = priv.uid());
drop policy if exists corr_ins on public.correcciones;
create policy corr_ins on public.correcciones for insert to authenticated with check (priv.es_personal(colegio_id));
drop policy if exists corr_upd on public.correcciones;
create policy corr_upd on public.correcciones for update to authenticated using (priv.puede(colegio_id, 'calificar')) with check (priv.puede(colegio_id, 'calificar'));
create or replace function priv.tg_correcciones() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then new.creado_por := priv.uid(); new.creado_nombre := priv.nombre_actual(new.colegio_id); new.estado := 'Pendiente';
  elsif new.estado = 'Atendida' and old.estado <> 'Atendida' then new.atendida_nombre := priv.nombre_actual(new.colegio_id); new.atendida_en := now(); end if;
  return new;
end $$;
drop trigger if exists tg_correcciones on public.correcciones;
create trigger tg_correcciones before insert or update on public.correcciones for each row execute function priv.tg_correcciones();

-- Excusas: las aprueba quien tenga el permiso «excusas» o el director(a) del grupo del estudiante
drop policy if exists exc_upd on public.excusas;
create policy exc_upd on public.excusas for update to authenticated
  using (exists (select 1 from estudiantes s where s.id = estudiante_id and (priv.puede(s.colegio_id, 'excusas') or exists (
          select 1 from grupos gr join miembros m on m.id = gr.director_miembro_id where gr.id = s.grupo_id and m.user_id = priv.uid() and m.activo))))
  with check (exists (select 1 from estudiantes s where s.id = estudiante_id and (priv.puede(s.colegio_id, 'excusas') or exists (
          select 1 from grupos gr join miembros m on m.id = gr.director_miembro_id where gr.id = s.grupo_id and m.user_id = priv.uid() and m.activo))));

-- Excusas: la foto del soporte se conserva durante el año (evidencia); se borran las de hace más de 13 meses
create or replace function priv.tg_excusas() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    select colegio_id into new.colegio_id from estudiantes where id = new.estudiante_id;
    new.enviada_por := (select coalesce(max(m.nombre), '') from miembros m where m.user_id = priv.uid() and m.estudiante_id = new.estudiante_id);
    new.estado := 'Pendiente'; new.revisada_por := null; new.respuesta := null;
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
end $$;

-- ---------- 3) Grados ----------
create or replace function public.registrar_grados(p_colegio uuid, p_ests uuid[], p_titulo text, p_fecha date, p_libro text, p_acta_desde int, p_folio_desde int) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare k colegios; e uuid; n int := 0; a int; f int; s estudiantes; g grupos; y int; ult int;
begin
  if not (priv.es_rector(p_colegio) or priv.puede(p_colegio, 'matricula')) then raise exception 'Solo la rectoría o la secretaría registran grados'; end if;
  if length(btrim(coalesce(p_titulo, ''))) < 5 then raise exception 'Escriba el título que se otorga'; end if;
  if p_fecha is null then raise exception 'Escriba la fecha de la ceremonia de grado'; end if;
  select * into k from colegios where id = p_colegio;
  select max(gr.grado) into ult from grupos gr where gr.colegio_id = p_colegio and gr.nivel <> 'preescolar';
  a := greatest(coalesce(p_acta_desde, 1), coalesce((select max(acta) + 1 from grados where colegio_id = p_colegio), 1));
  f := coalesce(p_folio_desde, 1);
  foreach e in array coalesce(p_ests, '{}') loop
    select * into s from estudiantes where id = e and colegio_id = p_colegio;
    if s.id is null then continue; end if;
    if exists (select 1 from grados gg where gg.estudiante_id = e and gg.titulo = upper(btrim(p_titulo))) then continue; end if;
    select * into g from grupos where id = s.grupo_id;
    if s.estado = 'Graduado' then
      -- ya cerró su año: el grado es del año en que se graduó
      y := coalesce((select max(h.anio) from historial h where h.estudiante_id = e and h.resultado = 'Graduado'), k.anio - 1);
    elsif s.estado = 'Activo' and g.grado in (11, 26, ult) then
      y := k.anio;
    else
      raise exception '% no está en el último grado ni figura como graduado(a)', s.nombres || ' ' || s.apellidos;
    end if;
    insert into grados (colegio_id, estudiante_id, anio, titulo, fecha, acta, libro, folio, diploma, creado_por)
    values (p_colegio, e, y, upper(btrim(p_titulo)), p_fecha, a, nullif(btrim(coalesce(p_libro, '')), ''), f::text, y || '-' || lpad(a::text, 4, '0'), priv.nombre_actual(p_colegio));
    a := a + 1; f := f + 1; n := n + 1;
  end loop;
  update colegios set grados_cfg = coalesce(grados_cfg, '{}') || jsonb_build_object('titulo', upper(btrim(p_titulo)), 'fecha', p_fecha, 'libro', p_libro) where id = p_colegio;
  return n;
end $$;

-- ---------- 4) Documentos y pagos de la familia ----------
do $$
declare d text := pg_get_functiondef('public.pedir_documento(uuid, text, integer, integer, text)'::regprocedure);
begin
  if position('Tiene pagos pendientes' in d) = 0 then
    d := replace(d, $q$  if p_tipo = 'retiro' and s.estado = 'Activo' then raise exception 'La constancia de retiro solo se expide para estudiantes retirados'; end if;$q$,
      $q$  if p_tipo = 'retiro' and s.estado = 'Activo' then raise exception 'La constancia de retiro solo se expide para estudiantes retirados'; end if;
  if k.restringir_morosos and priv.debe_vencido(p_est) then
    raise exception 'Tiene pagos pendientes: los documentos se piden cuando esté al día (vea Estado de cuenta)';
  end if;$q$);
    if position('Tiene pagos pendientes' in d) = 0 then raise exception 'No se pudo ajustar pedir_documento'; end if;
    execute d;
  end if;
end $$;
-- El estudiante no ve los pagos ni los comprobantes de su familia (solo el acudiente y quien maneja la cartera)
drop policy if exists pagos_ver on public.pagos;
create policy pagos_ver on public.pagos for select using (priv.ve_pagos(colegio_id) or priv.es_acudiente_de(estudiante_id));
drop policy if exists cmp_ver on public.comprobantes;
create policy cmp_ver on public.comprobantes for select using (priv.ve_pagos(colegio_id) or priv.es_acudiente_de(estudiante_id));
drop policy if exists bo_ver on public.bold_ordenes;
create policy bo_ver on public.bold_ordenes for select using (priv.ve_pagos(colegio_id) or priv.es_acudiente_de(estudiante_id));
create or replace function public.estado_cuenta(p_estudiante uuid, p_anio integer)
returns table(concepto_id uuid, concepto text, tipo text, mes integer, valor numeric, pagado numeric, saldo numeric, vencido boolean)
language sql stable security definer set search_path = public, pg_temp as $function$
  select b.concepto_id, b.concepto, b.tipo, b.mes, b.valor, b.pagado, b.saldo, b.vencido
  from estudiantes e
  cross join lateral priv.cuenta_base(e.id, p_anio) b
  where e.id = p_estudiante and (priv.ve_pagos(e.colegio_id) or priv.es_acudiente_de(e.id))
    and (b.valor > 0 or b.pagado > 0)
$function$;

-- La familia restringida por pagos: el colegio decide si el estudiante también queda restringido
alter table public.colegios add column if not exists restringir_estudiante boolean not null default true;
create or replace function priv.mis_estudiantes_al_dia() returns setof uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select m.estudiante_id from miembros m join colegios k on k.id = m.colegio_id
  where m.user_id = priv.uid() and m.activo and m.estudiante_id is not null
    and priv.acceso_ok(k.activo, k.demo, k.pagado_hasta)
    and (not k.restringir_morosos or (m.rol = 'estudiante' and not k.restringir_estudiante) or not priv.debe_vencido(m.estudiante_id))
$$;
create or replace function public.mi_situacion_familia(p_colegio uuid) returns json
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(json_agg(json_build_object('estudiante_id', m.estudiante_id,
           'al_dia', not (k.restringir_morosos and not (m.rol = 'estudiante' and not k.restringir_estudiante) and priv.debe_vencido(m.estudiante_id)),
           'debe', priv.debe_vencido(m.estudiante_id),
           'por_vencer', (select coalesce(sum(x.saldo), 0) from estado_cuenta(m.estudiante_id, k.anio) x where not x.vencido and x.saldo > 0
                          and x.mes is not null and x.mes <= extract(month from priv.hoy_co())::int),
           'dia_limite', k.dia_limite_pago)), '[]'::json)
  from miembros m join colegios k on k.id = m.colegio_id
  where m.colegio_id = p_colegio and m.user_id = priv.uid() and m.activo and m.estudiante_id is not null
$$;
do $$
declare d text := pg_get_functiondef('public.colegio_cobros(uuid, jsonb)'::regprocedure);
begin
  if position('restringir_estudiante' in d) = 0 then
    d := replace(d, $q$'pago_bold_url','restringir_morosos')$q$, $q$'pago_bold_url','restringir_morosos','restringir_estudiante')$q$);
    d := replace(d, $q$    restringir_morosos  = case when p_datos ? 'restringir_morosos' then (p_datos ->> 'restringir_morosos')::boolean else restringir_morosos end$q$,
      $q$    restringir_morosos  = case when p_datos ? 'restringir_morosos' then (p_datos ->> 'restringir_morosos')::boolean else restringir_morosos end,
    restringir_estudiante = case when p_datos ? 'restringir_estudiante' then (p_datos ->> 'restringir_estudiante')::boolean else restringir_estudiante end$q$);
    if position('restringir_estudiante = case' in d) = 0 then raise exception 'No se pudo ajustar colegio_cobros'; end if;
    execute d;
  end if;
end $$;

-- ---------- 5) Acuerdos de pago ----------
alter table public.acuerdos_pago add column if not exists aprobado boolean not null default true;
alter table public.acuerdos_pago add column if not exists aprobado_nombre text;
-- La cuota inicial se paga al firmar (sin días de gracia); las cuotas, con 5 días de margen; y el acuerdo debe tener visto bueno
create or replace function priv.acuerdo_al_dia(e uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from acuerdos_pago a
    where a.estudiante_id = e and a.estado = 'Vigente' and a.aprobado
      and priv.hoy_co() <= coalesce((select max((c ->> 'fecha')::date) from jsonb_array_elements(a.cuotas) c), (a.creado_en at time zone 'America/Bogota')::date) + 5
      and coalesce((select sum(p.valor) from pagos p where p.estudiante_id = e and not p.anulado and p.registrado_en >= a.creado_en - interval '1 day'), 0)
          >= a.inicial
             + coalesce((select sum((c ->> 'valor')::numeric) from jsonb_array_elements(a.cuotas) c where (c ->> 'fecha')::date < priv.hoy_co() - 5), 0))
$$;
create or replace function public.acuerdo_guardar(p_est uuid, p_numero text, p_total numeric, p_inicial numeric, p_cuotas jsonb) returns acuerdos_pago
language plpgsql security definer set search_path = public, pg_temp as $$
declare s estudiantes; r acuerdos_pago; c jsonb;
begin
  select * into s from estudiantes where id = p_est;
  if s.id is null or not priv.maneja_pagos(s.colegio_id) then raise exception 'No tiene permiso para registrar acuerdos de pago'; end if;
  if coalesce(p_total, 0) <= 0 then raise exception 'El acuerdo necesita una deuda mayor que 0'; end if;
  if coalesce(p_inicial, 0) < 0 or coalesce(p_inicial, 0) > p_total then raise exception 'Revise la cuota inicial'; end if;
  for c in select jsonb_array_elements(coalesce(p_cuotas, '[]')) loop
    if (c ->> 'fecha') is null or coalesce((c ->> 'valor')::numeric, 0) <= 0 then raise exception 'Revise las cuotas del acuerdo'; end if;
  end loop;
  update acuerdos_pago set estado = 'Terminado', motivo = 'Reemplazado por un acuerdo nuevo', terminado_nombre = priv.nombre_actual(s.colegio_id), terminado_en = now()
   where estudiante_id = p_est and estado = 'Vigente';
  insert into acuerdos_pago (colegio_id, estudiante_id, numero, total, inicial, cuotas, creado_por, creado_nombre, aprobado, aprobado_nombre)
  values (s.colegio_id, p_est, left(p_numero, 30), round(p_total), round(coalesce(p_inicial, 0)), coalesce(p_cuotas, '[]'), priv.uid(), priv.nombre_actual(s.colegio_id),
          priv.puede(s.colegio_id, 'aprobar_acuerdos'), case when priv.puede(s.colegio_id, 'aprobar_acuerdos') then priv.nombre_actual(s.colegio_id) end)
  returning * into r;
  return r;
end $$;
create or replace function public.acuerdo_aprobar(p_id uuid) returns acuerdos_pago
language plpgsql security definer set search_path = public, pg_temp as $$
declare a acuerdos_pago;
begin
  select * into a from acuerdos_pago where id = p_id;
  if a.id is null or not priv.puede(a.colegio_id, 'aprobar_acuerdos') then raise exception 'No tiene permiso para aprobar acuerdos de pago'; end if;
  if a.estado <> 'Vigente' then raise exception 'El acuerdo ya no está vigente'; end if;
  update acuerdos_pago set aprobado = true, aprobado_nombre = priv.nombre_actual(a.colegio_id) where id = p_id returning * into a;
  return a;
end $$;
revoke all on function public.acuerdo_aprobar(uuid) from public, anonymous;
grant execute on function public.acuerdo_aprobar(uuid) to authenticated;

-- ---------- 6) Migración: «al día hasta» ----------
alter table public.estudiantes add column if not exists al_dia_hasta date;
do $$
declare d text := pg_get_functiondef('priv.cuenta_base(uuid, integer)'::regprocedure);
begin
  if position('al_dia_hasta' in d) = 0 then
    d := replace(d, $q$      and (s.retiro_anio is null or make_date(p_anio, m.mes, 1) <= s.retiro_anio)$q$,
      $q$      and (s.retiro_anio is null or make_date(p_anio, m.mes, 1) <= s.retiro_anio)
      and (s.al_dia_hasta is null or make_date(p_anio, m.mes, 1) > s.al_dia_hasta)   -- ya pagado en el sistema anterior (migración)$q$);
    -- matrícula del año siguiente: los costos del grado al que pasa
    d := replace(d, $q$then h.grado end, g.grado) as grado_anio,$q$, $q$then h.grado end, g.grado + case when p_anio > k.anio then 1 else 0 end) as grado_anio,$q$);
    if position('al_dia_hasta' in d) = 0 or position('p_anio > k.anio' in d) = 0 then raise exception 'No se pudo ajustar cuenta_base'; end if;
    execute d;
  end if;
end $$;

-- ---------- 7) Matrícula en línea del año siguiente ----------
-- Al abrirla para un año sin costos, se copian los del año actual como punto de partida (el colegio los revisa)
create or replace function priv.tg_ml_costos() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.matricula_linea and new.matricula_anio is not null and new.matricula_anio > new.anio
     and not exists (select 1 from conceptos c where c.colegio_id = new.id and c.anio = new.matricula_anio) then
    insert into conceptos (colegio_id, anio, nombre, tipo, periodicidad, valor, valores_grado, mes_cobro, meses, orden, activo)
      select c.colegio_id, new.matricula_anio, c.nombre, c.tipo, c.periodicidad, c.valor, c.valores_grado, c.mes_cobro, c.meses, c.orden, c.activo
      from conceptos c where c.colegio_id = new.id and c.anio = new.anio;
  end if;
  return new;
end $$;
drop trigger if exists tg_ml_costos on public.colegios;
create trigger tg_ml_costos after insert or update of matricula_linea, matricula_anio on public.colegios for each row execute function priv.tg_ml_costos();
-- Los graduandos del último grado no renuevan matrícula
create or replace function priv.ml_abierta(s estudiantes) returns colegios
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare k colegios; g grupos;
begin
  select * into k from colegios where id = s.colegio_id;
  if not k.matricula_linea or k.matricula_anio is null or (k.matricula_hasta is not null and priv.hoy_co() > k.matricula_hasta) then raise exception 'La matrícula en línea está cerrada'; end if;
  if s.estado <> 'Activo' then raise exception 'La matrícula en línea es para estudiantes activos'; end if;
  select * into g from grupos where id = s.grupo_id;
  if k.matricula_anio > k.anio and g.nivel <> 'preescolar' and (g.grado in (11, 26) or g.grado = (select max(x.grado) from grupos x where x.colegio_id = k.id and x.nivel <> 'preescolar')) then
    raise exception 'El estudiante termina su último grado este año: no renueva la matrícula';
  end if;
  return k;
end $$;
-- Quién actualizó los datos: el nombre de la persona, no «Sistema»
do $$
declare d text := pg_get_functiondef('public.ml_datos(uuid, jsonb, jsonb)'::regprocedure);
begin
  if position('v_quien' in d) = 0 then
    d := replace(d, $q$declare s estudiantes; k colegios; d jsonb := coalesce(p_datos, '{}'); x jsonb;$q$,
                    $q$declare s estudiantes; k colegios; d jsonb := coalesce(p_datos, '{}'); x jsonb; v_quien text;$q$);
    d := replace(d, $q$  k := priv.ml_abierta(s);
  if btrim(coalesce(d->>'direccion', '')) = ''$q$, $q$  k := priv.ml_abierta(s);
  v_quien := priv.nombre_actual(s.colegio_id);
  if btrim(coalesce(d->>'direccion', '')) = ''$q$);
    d := replace(d, $q$values (s.colegio_id, p_est, k.matricula_anio, now(), priv.nombre_actual(s.colegio_id))$q$, $q$values (s.colegio_id, p_est, k.matricula_anio, now(), v_quien)$q$);
    if position('v_quien)' in d) = 0 then raise exception 'No se pudo ajustar ml_datos'; end if;
    execute d;
  end if;
end $$;

-- ---------- 8) Becas y recibos ----------
create or replace function priv.tg_becas_doble() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if exists (select 1 from becas b where b.estudiante_id = new.estudiante_id and b.anio = new.anio and b.activa
               and b.tipo = new.tipo and b.modo = new.modo and b.valor = new.valor and b.aplica = new.aplica and b.id <> new.id) then
    raise exception 'El estudiante ya tiene esa misma beca o descuento (%). Si quiere cambiarla, anule la anterior', new.tipo;
  end if;
  return new;
end $$;
drop trigger if exists tg_becas_doble on public.becas;
create trigger tg_becas_doble before insert on public.becas for each row execute function priv.tg_becas_doble();

create or replace function priv.tg_pagos_anular() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if priv.es_cliente() and new.anulado and not old.anulado then
    if not priv.puede(old.colegio_id, 'anular') then
      raise exception 'Anular un recibo lo hace quien tenga el permiso «Anular recibos» (por defecto, la rectoría)';
    end if;
    if old.registrado_por = priv.uid() and (not priv.es_rector(old.colegio_id)
        or exists (select 1 from miembros m where m.colegio_id = old.colegio_id and m.rol = 'rector' and m.activo and m.user_id is not null and m.user_id <> priv.uid())) then
      raise exception 'Quien registró el pago no puede anular su propio recibo: pídaselo a %',
        case when priv.es_rector(old.colegio_id) then 'la otra persona de la rectoría' else 'la rectoría' end;
    end if;
    if length(btrim(coalesce(new.anulado_motivo, ''))) < 4 then raise exception 'Escriba el motivo de la anulación'; end if;
  end if;
  return new;
end $$;

-- ---------- 9) Observador ----------
alter table public.observador add column if not exists situacion text check (situacion in ('Tipo I','Tipo II','Tipo III'));
drop policy if exists obsv_del on public.observador;
create policy obsv_del on public.observador for delete to authenticated using (priv.roles_en(colegio_id) && array['rector','coordinador']);

-- ---------- 10) Comunicados con revisión ----------
alter table public.comunicados add column if not exists aprobado boolean not null default true;
alter table public.comunicados add column if not exists aprobado_nombre text;
create or replace function priv.tg_com_aprobar() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not priv.es_cliente() then return new; end if;
  if tg_op = 'INSERT' then
    new.aprobado := priv.puede(new.colegio_id, 'comunicar');
  elsif new.aprobado and not old.aprobado then
    if not (priv.roles_en(new.colegio_id) && array['rector','coordinador']) then new.aprobado := false;
    else new.aprobado_nombre := priv.nombre_actual(new.colegio_id); end if;
  end if;
  return new;
end $$;
drop trigger if exists tg_com_aprobar on public.comunicados;
create trigger tg_com_aprobar before insert or update on public.comunicados for each row execute function priv.tg_com_aprobar();
create or replace function priv.ve_comunicado(c public.comunicados) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select priv.es_personal(c.colegio_id) or (c.aprobado and priv.es_miembro(c.colegio_id) and (
    c.destino = 'todos'
    or (c.destino = 'grupo' and exists (select 1 from estudiantes s where s.grupo_id = c.grupo_id and s.id in (select priv.mis_estudiantes())))
    or (c.destino = 'estudiante' and c.estudiante_id in (select priv.mis_estudiantes()))))
$$;

-- ---------- 11) Códigos de activación de los directivos: solo los ve la rectoría ----------
-- Coordinación y secretaría siguen viendo a los directivos (nombre, cargo, estado, último acceso), pero sin su código.
drop policy if exists miembros_ver on public.miembros;
create policy miembros_ver on public.miembros for select to authenticated
  using (user_id = priv.uid() or priv.es_rector(colegio_id)
         or (priv.es_directivo(colegio_id) and rol not in ('rector','coordinador','secretaria','tesoreria')));
drop policy if exists miembros_admin on public.miembros;
drop policy if exists miembros_ins on public.miembros;
create policy miembros_ins on public.miembros for insert to authenticated with check (priv.es_directivo(colegio_id));
drop policy if exists miembros_upd on public.miembros;
create policy miembros_upd on public.miembros for update to authenticated using (priv.es_directivo(colegio_id)) with check (priv.es_directivo(colegio_id));
drop policy if exists miembros_del on public.miembros;
create policy miembros_del on public.miembros for delete to authenticated using (priv.es_directivo(colegio_id));
create or replace function public.equipo_directivo(p_colegio uuid) returns setof json
language sql stable security definer set search_path = public, pg_temp as $$
  select json_build_object('id', m.id, 'colegio_id', m.colegio_id, 'nombre', m.nombre, 'email', m.email, 'rol', m.rol, 'activo', m.activo,
                           'user_id', m.user_id, 'ultimo_acceso', m.ultimo_acceso, 'estudiante_id', null, 'codigo', null)
  from miembros m
  where m.colegio_id = p_colegio and m.rol in ('rector','coordinador','secretaria','tesoreria') and priv.es_personal(p_colegio)
  order by m.rol, m.nombre
$$;
revoke all on function public.equipo_directivo(uuid) from public, anonymous;
grant execute on function public.equipo_directivo(uuid) to authenticated;

-- ---------- 12) Campus: un ítem oculto no lo ve el estudiante (en la regla, «visible» se leía de la unidad y no del ítem) ----------
drop policy if exists ci_ver on public.campus_items;
create policy ci_ver on public.campus_items for select to authenticated using (exists (
  select 1 from campus_unidades u where u.id = campus_items.unidad_id and (priv.ve_campus(u.grupo_id, u.asignatura_id)
    or (campus_items.visible and u.visible and priv.campus_grupo_ok(u.grupo_id) and priv.mi_est_en_grupo(u.grupo_id) is not null))));
-- la actividad de la planilla que viene de un ítem oculto tampoco la ve la familia
drop policy if exists act_ver on public.actividades;
create policy act_ver on public.actividades for select to authenticated using (priv.es_personal(colegio_id) or (priv.es_miembro(colegio_id)
  and not exists (select 1 from campus_items i where i.actividad_id = actividades.id and not i.visible)));

-- ---------- 13) Observación del boletín: la escribe el director(a) de grupo (o coordinación/rectoría) y queda quién ----------
create or replace function priv.escribe_obs(e uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from estudiantes s where s.id = e and (priv.roles_en(s.colegio_id) && array['rector','coordinador'] or exists (
    select 1 from grupos gr join miembros m on m.id = gr.director_miembro_id where gr.id = s.grupo_id and m.user_id = priv.uid() and m.activo)))
$$;
alter table public.observaciones add column if not exists autor_nombre text;
create or replace function priv.tg_obs_autor() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin if priv.es_cliente() then new.autor_nombre := priv.nombre_actual(new.colegio_id); end if; return new; end $$;
drop trigger if exists tg_obs_autor on public.observaciones;
create trigger tg_obs_autor before insert or update on public.observaciones for each row execute function priv.tg_obs_autor();
drop policy if exists observaciones_ins on public.observaciones;
create policy observaciones_ins on public.observaciones for insert to authenticated with check (priv.escribe_obs(estudiante_id));
drop policy if exists observaciones_upd on public.observaciones;
create policy observaciones_upd on public.observaciones for update to authenticated using (priv.escribe_obs(estudiante_id)) with check (priv.escribe_obs(estudiante_id));
drop policy if exists observaciones_del on public.observaciones;
create policy observaciones_del on public.observaciones for delete to authenticated using (priv.escribe_obs(estudiante_id));

-- ---------- 14) Bajar de plan cuando hay menos estudiantes activos (desde el próximo pago; lo ya pagado no se devuelve) ----------
create or replace function public.plan_bajar(p_colegio uuid, p_plan int) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare k colegios; act int;
begin
  if not priv.es_rector(p_colegio) then raise exception 'Solo la rectoría puede cambiar el plan'; end if;
  select * into k from colegios where id = p_colegio;
  if k.demo or k.interna then raise exception 'Este colegio no tiene plan que ajustar'; end if;
  if not priv.plan_valido(p_plan) then raise exception 'Plan no válido'; end if;
  if p_plan >= k.plan_max then raise exception 'Elija un plan menor que el actual'; end if;
  select count(*) into act from estudiantes where colegio_id = p_colegio and estado = 'Activo';
  if act > p_plan then raise exception 'Tiene % estudiantes activos: el plan debe ser de al menos ese número', act; end if;
  perform set_config('micolegia.sistema', 'on', true);
  update colegios set plan_max = p_plan where id = p_colegio;
  perform set_config('micolegia.sistema', '', true);
  insert into plataforma_cambios_plan (colegio_id, plan_antes, plan_nuevo, meses, valor, origen, quien)
  values (p_colegio, k.plan_max, p_plan, 0, 0, 'bajada', priv.email_actual());
  return json_build_object('plan_antes', k.plan_max, 'plan', p_plan, 'precio', precio_plan(p_plan));
end $$;
revoke all on function public.plan_bajar(uuid, int) from public, anonymous;
grant execute on function public.plan_bajar(uuid, int) to authenticated;

commit;
notify pgrst, 'reload schema';
