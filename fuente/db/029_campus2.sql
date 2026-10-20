-- Colegio-IA 029 (entrega 6 de la revisión del 19-20 oct 2026): campus virtual con lo mejor de Moodle.
--  1) Opciones de revisión de cada cuestionario (como Moodle): cuándo ve el estudiante su calificación y las respuestas
--     correctas: justo después del intento, solo después del cierre (fecha límite) o nunca. Por defecto: después del cierre.
--  2) Imagen, descripción y fechas de cada curso (curso = curso + asignatura) y banner de cada unidad.
--  3) Reiniciar un curso al terminar el año: borra entregas y vistos, conserva los contenidos del docente.
--  4) Copiar una unidad (con sus contenidos y preguntas) a otro curso; copiar preguntas de otro cuestionario.

-- 1) Opciones de revisión ---------------------------------------------------------------------------------
alter table public.campus_items add column if not exists ver_nota text not null default 'cierre';
alter table public.campus_items add column if not exists ver_respuestas text not null default 'cierre';
alter table public.campus_items drop constraint if exists campus_items_ver_chk;
alter table public.campus_items add constraint campus_items_ver_chk check (ver_nota in ('intento','cierre','nunca') and ver_respuestas in ('intento','cierre','nunca'));
create or replace function priv.ver_ahora(modo text, fecha timestamptz) returns boolean
language sql stable as $$ select modo = 'intento' or (modo = 'cierre' and (fecha is null or now() > fecha)) $$;

create or replace function public.campus_cuestionario(p_item uuid, p_est uuid) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare i campus_items; e campus_entregas; pr jsonb; out jsonb := '[]'; x jsonb;
begin
  if not priv.soy_estudiante(p_est) then raise exception 'Las evaluaciones y tareas las responde el estudiante desde su propia cuenta'; end if;
  i := priv.item_para(p_item, p_est);
  if i.tipo <> 'cuestionario' then raise exception 'Este contenido no es un cuestionario'; end if;
  select * into e from campus_entregas where item_id = i.id and estudiante_id = p_est;
  select preguntas into pr from campus_preguntas where item_id = i.id;
  for x in select value from jsonb_array_elements(coalesce(pr, '[]')) loop
    out := out || jsonb_build_array(jsonb_build_object('t', x ->> 't', 'q', x ->> 'q', 'pts', (x ->> 'pts')::int,
      'o', case when x ->> 't' = 'om' then x -> 'o' end,
      'izq', case when x ->> 't' = 'emp' then (select jsonb_agg(pp.v -> 0 order by pp.n) from jsonb_array_elements(x -> 'p') with ordinality pp(v, n)) end,
      'der', case when x ->> 't' = 'emp' then (select jsonb_agg(pp.v -> 1 order by random()) from jsonb_array_elements(x -> 'p') pp(v)) end));
  end loop;
  return json_build_object('titulo', i.titulo, 'texto', i.texto, 'fecha', i.fecha, 'intentos', i.intentos, 'usados', coalesce(e.intentos, 0),
                           'nota', case when priv.ver_ahora(i.ver_nota, i.fecha) then e.nota end,
                           'oculto', e.id is not null and not priv.ver_ahora(i.ver_nota, i.fecha), 'ver_desde', i.fecha, 'preguntas', out);
end $$;


create or replace function public.campus_responder(p_item uuid, p_est uuid, p_resp jsonb) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare i campus_items; e campus_entregas; pr jsonb; x jsonb; r jsonb; k int := 0; tot numeric := 0; got numeric := 0; ok int := 0;
        pares int; bien int; v numeric; gm int := 0; detalle jsonb := '[]'; pasa boolean; vn boolean; vr boolean;
begin
  if not priv.soy_estudiante(p_est) then raise exception 'Las evaluaciones y tareas las responde el estudiante desde su propia cuenta'; end if;
  i := priv.item_para(p_item, p_est);
  if i.tipo <> 'cuestionario' then raise exception 'Este contenido no es un cuestionario'; end if;
  select * into e from campus_entregas where item_id = i.id and estudiante_id = p_est;
  if coalesce(e.intentos, 0) >= i.intentos then raise exception 'Ya usó todos los intentos de este cuestionario'; end if;
  if i.fecha is not null and now() > i.fecha then raise exception 'La fecha límite de este cuestionario ya pasó'; end if;
  select preguntas into pr from campus_preguntas where item_id = i.id;
  if pr is null or jsonb_array_length(pr) = 0 then raise exception 'El cuestionario aún no tiene preguntas'; end if;
  if jsonb_typeof(p_resp) <> 'array' then raise exception 'Respuestas no válidas'; end if;
  for x in select value from jsonb_array_elements(pr) loop
    r := p_resp -> k; k := k + 1;
    tot := tot + greatest(1, coalesce((x ->> 'pts')::int, 1));
    pasa := false;
    if x ->> 't' = 'om' then
      pasa := r is not null and jsonb_typeof(r) = 'number' and (r #>> '{}')::int = (x ->> 'c')::int;
      if pasa then got := got + greatest(1, coalesce((x ->> 'pts')::int, 1)); end if;
    elsif x ->> 't' = 'vf' then
      pasa := r is not null and jsonb_typeof(r) = 'boolean' and (r #>> '{}')::boolean = (x ->> 'c')::boolean;
      if pasa then got := got + greatest(1, coalesce((x ->> 'pts')::int, 1)); end if;
    elsif x ->> 't' = 'corta' then
      pasa := r is not null and jsonb_typeof(r) = 'string' and priv.norm_txt(r #>> '{}') in (select priv.norm_txt(a) from jsonb_array_elements_text(x -> 'c') a);
      if pasa then got := got + greatest(1, coalesce((x ->> 'pts')::int, 1)); end if;
    elsif x ->> 't' = 'emp' then
      pares := jsonb_array_length(x -> 'p'); bien := 0;
      if r is not null and jsonb_typeof(r) = 'array' then
        select count(*) into bien from jsonb_array_elements(x -> 'p') with ordinality p(par, n)
         where priv.norm_txt(r ->> (n::int - 1)) = priv.norm_txt(par ->> 1);
      end if;
      pasa := bien = pares;
      if pares > 0 then got := got + greatest(1, coalesce((x ->> 'pts')::int, 1)) * bien / pares; end if;
    end if;
    if pasa then ok := ok + 1; end if;
    detalle := detalle || jsonb_build_array(pasa);
  end loop;
  v := round(got / tot * 100);
  insert into campus_entregas (colegio_id, item_id, estudiante_id, respuestas, intentos, nota, estado, entregado_en, entregado_nombre, calificado_en, calificado_nombre)
  values (i.colegio_id, i.id, p_est, p_resp, 1, v, 'Calificada', now(), priv.mi_nombre_familia(i.colegio_id), now(), 'Calificación automática')
  on conflict (item_id, estudiante_id) do update set respuestas = excluded.respuestas, intentos = campus_entregas.intentos + 1,
    nota = greatest(coalesce(campus_entregas.nota, 0), excluded.nota), estado = 'Calificada', entregado_en = now(), entregado_nombre = excluded.entregado_nombre,
    calificado_en = now(), calificado_nombre = excluded.calificado_nombre
  returning * into e;
  perform priv.campus_a_calificaciones(i, p_est, e.nota);
  vn := priv.ver_ahora(i.ver_nota, i.fecha); vr := priv.ver_ahora(i.ver_respuestas, i.fecha);
  if vn then
    gm := priv.dar_gemas(p_est, 'cuestionario', i.id::text, 5 + (v / 10)::int);
    if v >= 92 then gm := gm + priv.dar_gemas(p_est, 'excelente', i.id::text, 10); end if;
  else
    gm := priv.dar_gemas(p_est, 'cuestionario', i.id::text, 8);   -- sin revelar el resultado antes del cierre
  end if;
  return json_build_object('nota', case when vn then v end, 'mejor', case when vn then e.nota end, 'correctas', case when vr then ok end,
                           'total', k, 'gemas', gm, 'detalle', case when vr then detalle end, 'oculto', not vn, 'ver_desde', i.fecha,
                           'quedan', greatest(0, i.intentos - e.intentos));
end $$;


-- La familia lee sus entregas con esta función: oculta la calificación y las respuestas hasta que se puedan ver
create or replace function public.campus_mis_entregas(p_est uuid, p_items uuid[]) returns json
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(json_agg(json_build_object('id', e.id, 'item_id', e.item_id, 'estudiante_id', e.estudiante_id, 'texto', e.texto, 'url', e.url,
    'intentos', e.intentos, 'estado', e.estado, 'entregado_en', e.entregado_en, 'comentario', e.comentario,
    'nota', case when i.tipo <> 'cuestionario' or priv.ver_ahora(i.ver_nota, i.fecha) then e.nota end,
    'oculto', i.tipo = 'cuestionario' and not priv.ver_ahora(i.ver_nota, i.fecha))), '[]'::json)
  from campus_entregas e join campus_items i on i.id = e.item_id
  where e.estudiante_id = p_est and e.item_id = any(p_items) and p_est in (select priv.mis_estudiantes_al_dia())
$$;
revoke execute on function public.campus_mis_entregas(uuid, uuid[]) from public, anonymous;
grant execute on function public.campus_mis_entregas(uuid, uuid[]) to authenticated;
-- Las familias ya no leen la tabla de entregas directamente (solo con la función anterior)
drop policy if exists ce2_ver on public.campus_entregas;
create policy ce2_ver on public.campus_entregas for select using (exists (select 1 from campus_items i join campus_unidades u on u.id = i.unidad_id
  where i.id = campus_entregas.item_id and priv.ve_campus(u.grupo_id, u.asignatura_id)));
-- Calificaciones: la familia no ve la nota de un cuestionario del campus hasta que se pueda ver
drop policy if exists nact_ver on public.notas_act;
create policy nact_ver on public.notas_act for select using (priv.puede_calificar(estudiante_id) or (estudiante_id in (select priv.mis_estudiantes_al_dia())
  and not exists (select 1 from campus_items ci where ci.actividad_id = notas_act.actividad_id and ci.tipo = 'cuestionario' and not priv.ver_ahora(ci.ver_nota, ci.fecha))));

-- 2) Imagen y datos de cada curso, banner de cada unidad ------------------------------------------------------
create table if not exists public.campus_cursos (
  grupo_id uuid not null references public.grupos(id) on delete cascade,
  asignatura_id uuid not null references public.asignaturas(id) on delete cascade,
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  imagen text check (imagen is null or length(imagen) <= 400000),
  descripcion text check (descripcion is null or length(descripcion) <= 1000),
  inicio date, fin date,
  actualizado_en timestamptz not null default now(),
  primary key (grupo_id, asignatura_id)
);
alter table public.campus_cursos enable row level security;
grant select, insert, update, delete on public.campus_cursos to authenticated;
drop policy if exists cc_ver on public.campus_cursos;
create policy cc_ver on public.campus_cursos for select using (priv.ve_campus(grupo_id, asignatura_id) or priv.mi_est_en_grupo(grupo_id) is not null);
drop policy if exists cc_esc on public.campus_cursos;
create policy cc_esc on public.campus_cursos for all using (priv.edita_campus(grupo_id, asignatura_id)) with check (priv.edita_campus(grupo_id, asignatura_id));
alter table public.campus_unidades add column if not exists banner text check (banner is null or length(banner) <= 500000);

-- 3) Reiniciar un curso del campus (fin de año o semestre) ----------------------------------------------------
create or replace function public.campus_reiniciar(p_grupo uuid, p_asig uuid) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare ne int; nv int;
begin
  if not priv.edita_campus(p_grupo, p_asig) then raise exception 'No tiene permiso para reiniciar este curso'; end if;
  delete from campus_entregas e using campus_items i, campus_unidades u
   where e.item_id = i.id and i.unidad_id = u.id and u.grupo_id = p_grupo and u.asignatura_id = p_asig;
  get diagnostics ne = row_count;
  delete from campus_vistos v using campus_items i, campus_unidades u
   where v.item_id = i.id and i.unidad_id = u.id and u.grupo_id = p_grupo and u.asignatura_id = p_asig;
  get diagnostics nv = row_count;
  return json_build_object('entregas', ne, 'vistos', nv);
end $$;
revoke execute on function public.campus_reiniciar(uuid, uuid) from public, anonymous;
grant execute on function public.campus_reiniciar(uuid, uuid) to authenticated;

-- 4) Copiar una unidad a otro curso (contenidos y preguntas; sin entregas) -----------------------------------
create or replace function public.campus_copiar_unidad(p_unidad uuid, p_grupo uuid, p_periodo int) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare u campus_unidades; nu uuid; it campus_items; ni uuid;
begin
  select * into u from campus_unidades where id = p_unidad;
  if u.id is null or not priv.ve_campus(u.grupo_id, u.asignatura_id) then raise exception 'Unidad no encontrada'; end if;
  if not priv.edita_campus(p_grupo, u.asignatura_id) then raise exception 'No tiene permiso para agregar contenidos en ese curso'; end if;
  insert into campus_unidades (colegio_id, grupo_id, asignatura_id, anio, periodo, titulo, descripcion, orden, visible, banner, creado_nombre)
  values (u.colegio_id, p_grupo, u.asignatura_id, (select anio from colegios where id = u.colegio_id), coalesce(p_periodo, u.periodo), u.titulo, u.descripcion,
          (select coalesce(max(orden), 0) + 1 from campus_unidades where grupo_id = p_grupo and asignatura_id = u.asignatura_id), u.visible, u.banner, u.creado_nombre)
  returning id into nu;
  for it in select * from campus_items where unidad_id = u.id order by orden, creado_en loop
    insert into campus_items (colegio_id, unidad_id, tipo, titulo, texto, url, fecha, calificable, intentos, puntos, visible, orden, ver_nota, ver_respuestas)
    values (it.colegio_id, nu, it.tipo, it.titulo, it.texto, it.url, it.fecha, it.calificable, it.intentos, it.puntos, it.visible, it.orden, it.ver_nota, it.ver_respuestas)
    returning id into ni;
    if it.tipo = 'cuestionario' then
      perform set_config('micolegia.preg', 'on', true);
      insert into campus_preguntas (item_id, colegio_id, preguntas) select ni, colegio_id, preguntas from campus_preguntas where item_id = it.id;
      update campus_items set n_preg = it.n_preg, puntos = it.puntos where id = ni;
      perform set_config('micolegia.preg', '', true);
    end if;
  end loop;
  return nu;
end $$;
revoke execute on function public.campus_copiar_unidad(uuid, uuid, int) from public, anonymous;
grant execute on function public.campus_copiar_unidad(uuid, uuid, int) to authenticated;

-- Banco de preguntas: cuestionarios del colegio que este docente puede ver, para copiar sus preguntas
create or replace function public.campus_banco(p_asig uuid) returns json
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(json_agg(json_build_object('id', i.id, 'titulo', i.titulo, 'curso', g.nombre, 'anio', u.anio, 'n', i.n_preg) order by u.anio desc, g.nombre, i.titulo), '[]'::json)
  from campus_items i join campus_unidades u on u.id = i.unidad_id join grupos g on g.id = u.grupo_id
  where i.tipo = 'cuestionario' and i.n_preg > 0 and u.asignatura_id = p_asig and priv.ve_campus(u.grupo_id, u.asignatura_id)
$$;
create or replace function public.campus_preguntas_de(p_item uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select p.preguntas from campus_preguntas p join campus_items i on i.id = p.item_id join campus_unidades u on u.id = i.unidad_id
  where p.item_id = p_item and priv.ve_campus(u.grupo_id, u.asignatura_id)
$$;
revoke execute on function public.campus_banco(uuid), public.campus_preguntas_de(uuid) from public, anonymous;
grant execute on function public.campus_banco(uuid), public.campus_preguntas_de(uuid) to authenticated;

-- Participantes del curso con su último acceso (personal del campus)
create or replace function public.campus_participantes(p_grupo uuid, p_asig uuid) returns json
language sql stable security definer set search_path = public, pg_temp as $$
  select case when not priv.ve_campus(p_grupo, p_asig) then null else coalesce(json_agg(json_build_object(
    'estudiante_id', s.id, 'nombre', s.apellidos || ' ' || s.nombres,
    'acceso_est', (select max(m.ultimo_acceso) from miembros m where m.estudiante_id = s.id and m.rol = 'estudiante'),
    'acceso_acu', (select max(m.ultimo_acceso) from miembros m where m.estudiante_id = s.id and m.rol = 'acudiente'),
    'cuenta_est', exists (select 1 from miembros m where m.estudiante_id = s.id and m.rol = 'estudiante' and m.user_id is not null),
    'vistos', (select count(*) from campus_vistos v join campus_items i on i.id = v.item_id join campus_unidades u on u.id = i.unidad_id where v.estudiante_id = s.id and u.grupo_id = p_grupo and u.asignatura_id = p_asig),
    'entregas', (select count(*) from campus_entregas e join campus_items i on i.id = e.item_id join campus_unidades u on u.id = i.unidad_id where e.estudiante_id = s.id and u.grupo_id = p_grupo and u.asignatura_id = p_asig),
    'ultima_entrega', (select max(e.entregado_en) from campus_entregas e join campus_items i on i.id = e.item_id join campus_unidades u on u.id = i.unidad_id where e.estudiante_id = s.id and u.grupo_id = p_grupo and u.asignatura_id = p_asig)
  ) order by s.apellidos, s.nombres), '[]'::json) end
  from estudiantes s where s.grupo_id = p_grupo and s.estado = 'Activo'
$$;
revoke execute on function public.campus_participantes(uuid, uuid) from public, anonymous;
grant execute on function public.campus_participantes(uuid, uuid) to authenticated;

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
notify pgrst, 'reload schema';
