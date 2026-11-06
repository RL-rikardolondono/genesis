-- 038 · Colegio-IA v0.23.1 (6 nov 2026): calendario de periodos propio para los ciclos (CLEI)
-- El colegio regular conserva su calendario (colegios.periodos, periodo_actual) y los cursos de ciclos usan
-- colegios.periodos_ciclos y periodo_actual_ciclos (4 periodos: CLEI 5 y 6 semestrales = 1-2 y 3-4).
-- Si periodos_ciclos está vacío, los ciclos usan el calendario del colegio (como en v0.23).
-- Se puede ejecutar más de una vez.

alter table public.colegios add column if not exists periodos_ciclos jsonb;
alter table public.colegios add column if not exists periodo_actual_ciclos int;
grant update (periodos_ciclos, periodo_actual_ciclos) on public.colegios to authenticated;
alter table public.anios_cerrados add column if not exists periodos_ciclos jsonb;

-- Calendario que usa un curso
create or replace function priv.cal_grupo(c uuid, g uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select case when x.nivel = 'ciclos' and jsonb_array_length(coalesce(k.periodos_ciclos, '[]')) > 0 then k.periodos_ciclos else k.periodos end
  from colegios k left join grupos x on x.id = g and x.colegio_id = k.id where k.id = c
$$;

-- Fecha de cierre de calificaciones según el calendario del curso
create or replace function priv.notas_abiertas(c uuid, p int, g uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select priv.es_directivo(c) or coalesce((
    select current_date <= (x->>'cierre')::date
    from jsonb_array_elements(coalesce(priv.cal_grupo(c, g), '[]')) x
    where (x->>'n')::int = p and coalesce(x->>'cierre', '') <> ''), true)
$$;

drop policy if exists notas_ins on public.notas;
create policy notas_ins on public.notas for insert to authenticated
  with check (priv.puede_calificar_asig(estudiante_id, asignatura_id)
    and priv.notas_abiertas(colegio_id, periodo, (select s.grupo_id from estudiantes s where s.id = estudiante_id)));
drop policy if exists notas_upd on public.notas;
create policy notas_upd on public.notas for update to authenticated
  using (priv.puede_calificar_asig(estudiante_id, asignatura_id)
    and priv.notas_abiertas(colegio_id, periodo, (select s.grupo_id from estudiantes s where s.id = estudiante_id)))
  with check (priv.puede_calificar_asig(estudiante_id, asignatura_id)
    and priv.notas_abiertas(colegio_id, periodo, (select s.grupo_id from estudiantes s where s.id = estudiante_id)));
drop policy if exists notas_del on public.notas;
create policy notas_del on public.notas for delete to authenticated
  using (priv.puede_calificar_asig(estudiante_id, asignatura_id)
    and priv.notas_abiertas(colegio_id, periodo, (select s.grupo_id from estudiantes s where s.id = estudiante_id)));

create or replace function priv.puede_actividad(a uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from actividades x where x.id = a
    and (priv.es_directivo(x.colegio_id) or priv.docente_de_asig(x.grupo_id, x.asignatura_id))
    and priv.notas_abiertas(x.colegio_id, x.periodo, x.grupo_id))
$$;

-- Campus: las calificaciones que pasan al cuaderno respetan el calendario del curso
do $$
declare f text; d text;
begin
  foreach f in array array['priv.campus_a_calificaciones(campus_items, uuid, numeric)', 'public.campus_calificar(uuid, uuid, numeric, text)'] loop
    if to_regprocedure(f) is null then continue; end if;
    d := pg_get_functiondef(f::regprocedure);
    if position('priv.notas_abiertas(u.colegio_id, u.periodo)' in d) > 0 then
      execute replace(d, 'priv.notas_abiertas(u.colegio_id, u.periodo)', 'priv.notas_abiertas(u.colegio_id, u.periodo, u.grupo_id)');
    end if;
  end loop;
end $$;

-- Definitivas con el calendario de cada curso
create or replace function public.definitivas(p_colegio uuid, p_hasta integer default 99)
returns table(estudiante_id uuid, asignatura_id uuid, definitiva numeric)
language sql stable as $$
  select n.estudiante_id, n.asignatura_id, round(sum(n.valor * p.peso) / nullif(sum(p.peso), 0), 1)
  from notas n join colegios k on k.id = n.colegio_id
  join estudiantes s on s.id = n.estudiante_id left join grupos g on g.id = s.grupo_id
  cross join lateral jsonb_to_recordset(case when g.nivel = 'ciclos' and jsonb_array_length(coalesce(k.periodos_ciclos, '[]')) > 0
                                             then k.periodos_ciclos else k.periodos end) as p(n int, peso numeric)
  where n.colegio_id = p_colegio and n.anio = k.anio and p.n = n.periodo and n.periodo <= p_hasta
    and (g.periodos is null or p.n = any(g.periodos))
  group by 1, 2
$$;

-- Boletín pedido por el acudiente: el periodo se valida con el calendario del curso
do $$
declare d text := pg_get_functiondef('public.pedir_documento(uuid, text, integer, integer, text)'::regprocedure);
begin
  if position('jsonb_array_length(coalesce(k.periodos, ''[]''))' in d) > 0 then
    execute replace(d, 'jsonb_array_length(coalesce(k.periodos, ''[]''))', 'jsonb_array_length(coalesce(priv.cal_grupo(k.id, s.grupo_id), ''[]''))');
  end if;
end $$;

-- Cierre de año: guarda el calendario de los ciclos y lo pasa al año nuevo
create or replace function priv.rodar_periodos(ps jsonb) returns jsonb language sql immutable as $$
  select case when ps is null then null else coalesce((select jsonb_agg(p || jsonb_strip_nulls(jsonb_build_object(
    'inicio', case when coalesce(p->>'inicio', '') <> '' then to_char((p->>'inicio')::date + interval '1 year', 'YYYY-MM-DD') end,
    'fin', case when coalesce(p->>'fin', '') <> '' then to_char((p->>'fin')::date + interval '1 year', 'YYYY-MM-DD') end,
    'cierre', case when coalesce(p->>'cierre', '') <> '' then to_char((p->>'cierre')::date + interval '1 year', 'YYYY-MM-DD') end))
    order by (p->>'n')::int) from jsonb_array_elements(ps) p), ps) end $$;
do $$
declare d text := pg_get_functiondef('public.cerrar_anio(uuid, jsonb)'::regprocedure);
begin
  if position('periodos_ciclos' in d) = 0 then
    d := replace(d, 'insert into anios_cerrados (colegio_id, anio, periodos, escala, max_perdidas)
    values (p_colegio, v_k.anio, v_k.periodos, v_k.escala, v_k.max_perdidas)
    on conflict (colegio_id, anio) do update set periodos = excluded.periodos, escala = excluded.escala, max_perdidas = excluded.max_perdidas;',
      'insert into anios_cerrados (colegio_id, anio, periodos, escala, max_perdidas, periodos_ciclos)
    values (p_colegio, v_k.anio, v_k.periodos, v_k.escala, v_k.max_perdidas, v_k.periodos_ciclos)
    on conflict (colegio_id, anio) do update set periodos = excluded.periodos, escala = excluded.escala, max_perdidas = excluded.max_perdidas, periodos_ciclos = excluded.periodos_ciclos;');
    d := replace(d, 'update colegios set anio = v_k.anio + 1, periodo_actual = 1,',
      'update colegios set anio = v_k.anio + 1, periodo_actual = 1, periodos_ciclos = priv.rodar_periodos(v_k.periodos_ciclos),
    periodo_actual_ciclos = case when v_k.periodos_ciclos is null then null else 1 end,');
    if position('v_k.periodos_ciclos)' in d) = 0 or position('periodo_actual_ciclos' in d) = 0 then
      raise exception 'No se encontró dónde guardar el calendario de los ciclos en el cierre de año';
    end if;
    execute d;
  end if;
end $$;

-- Crear un curso de ciclos: la primera vez se crea el calendario de los ciclos (4 periodos de 25 %)
create or replace function public.crear_ciclo(p_colegio uuid, p_ciclo int, p_semestre int, p_nombre text) returns grupos
language plpgsql security definer set search_path = public, pg_temp as $$
declare g grupos; k colegios; eq int; ps int[]; nm text := upper(btrim(coalesce(p_nombre, ''))); i int := 0; a text;
begin
  if not priv.es_directivo(p_colegio) then raise exception 'Solo los directivos crean cursos'; end if;
  if p_ciclo not between 3 and 6 then raise exception 'Elija el ciclo (CLEI 3 a 6)'; end if;
  select * into k from colegios where id = p_colegio for update;
  if jsonb_array_length(coalesce(k.periodos_ciclos, '[]')) = 0 then
    update colegios set periodos_ciclos = '[{"n":1,"peso":25},{"n":2,"peso":25},{"n":3,"peso":25},{"n":4,"peso":25}]'::jsonb,
      periodo_actual_ciclos = least(greatest(coalesce(k.periodo_actual, 1), 1), 4)
    where id = p_colegio returning * into k;
  end if;
  eq := 20 + p_ciclo;
  ps := case when p_ciclo >= 5 then case when p_semestre = 2 then array[3, 4] else array[1, 2] end end;
  if p_ciclo >= 5 and jsonb_array_length(k.periodos_ciclos) < 4 then
    raise exception 'Los ciclos semestrales usan los periodos 1-2 (primer semestre) y 3-4 (segundo). Defina 4 periodos de los ciclos en Parametrización › Periodos y escala';
  end if;
  if length(nm) < 3 then nm := 'CLEI ' || p_ciclo || case when p_ciclo >= 5 then ' SEMESTRE ' || coalesce(p_semestre, 1) else '' end; end if;
  insert into grupos (colegio_id, nombre, grado, nivel, ciclo, periodos) values (p_colegio, nm, eq, 'ciclos', p_ciclo, ps) returning * into g;
  if not exists (select 1 from asignaturas where colegio_id = p_colegio and nivel = 'ciclos') then
    foreach a in array array['Ciencias naturales y educación ambiental', 'Ciencias sociales', 'Educación artística y cultural', 'Educación ética y en valores humanos',
      'Educación física, recreación y deportes', 'Educación religiosa', 'Lengua castellana', 'Inglés', 'Matemáticas', 'Tecnología e informática',
      'Química', 'Física', 'Filosofía', 'Ciencias económicas y políticas'] loop
      i := i + 1;
      insert into asignaturas (colegio_id, nivel, codigo, nombre, ih, orden, grados)
      values (p_colegio, 'ciclos', 'CLEI' || i, a, case when i <= 10 then 2 else 1 end, i,
              case when i > 10 then array[25, 26] else '{}'::int[] end);
    end loop;
  end if;
  return g;
end $$;
revoke all on function public.crear_ciclo(uuid, int, int, text) from public, anonymous;
grant execute on function public.crear_ciclo(uuid, int, int, text) to authenticated;
revoke all on function priv.cal_grupo(uuid, uuid) from public, anonymous;

notify pgrst, 'reload schema';
