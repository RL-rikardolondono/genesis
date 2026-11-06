-- 037 · Colegio-IA v0.23 (6 nov 2026): bachillerato por ciclos (CLEI), pedido para el Colegio Anglocolombiano.
-- Educación de adultos (Decreto 3011 de 1997, hoy en el Decreto 1075 de 2015):
--   CLEI 3 = grados 6.º y 7.º, CLEI 4 = 8.º y 9.º: anuales, con los 4 periodos del colegio.
--   CLEI 5 = 10.º y CLEI 6 = 11.º: semestrales, con 2 periodos cada uno (primer semestre = periodos 1 y 2; segundo = 3 y 4).
-- Un curso por ciclo es un grupo con nivel 'ciclos', grado 20 + ciclo (21 a 26, como los códigos de ciclos del SIMAT), su ciclo y los periodos que usa.
-- Así los costos, la lista de útiles y el plan de estudios por grado de los ciclos no se mezclan con los grados regulares.
-- A mitad de año la rectoría cierra el semestre de los cursos que usan los periodos 1 y 2 (CLEI 5 pasa a CLEI 6; CLEI 6 se gradúa).
-- Se puede ejecutar más de una vez.

-- 1) Nivel "ciclos" en cursos y plan de estudios
alter table public.grupos drop constraint if exists grupos_nivel_check;
alter table public.grupos add constraint grupos_nivel_check check (nivel in ('preescolar', 'primaria', 'secundaria', 'media', 'ciclos'));
alter table public.asignaturas drop constraint if exists asignaturas_nivel_check;
alter table public.asignaturas add constraint asignaturas_nivel_check check (nivel in ('preescolar', 'primaria', 'secundaria', 'media', 'ciclos'));
alter table public.grupos drop constraint if exists grupos_grado_check;
alter table public.grupos add constraint grupos_grado_check check ((grado between -2 and 11) or (grado between 21 and 26));
alter table public.grupos add column if not exists ciclo int;
alter table public.grupos add column if not exists periodos int[];
alter table public.grupos drop constraint if exists grupos_ciclo_chk;
alter table public.grupos add constraint grupos_ciclo_chk check (
  (nivel = 'ciclos') = (ciclo is not null) and (ciclo is null or (ciclo between 1 and 6 and grado = 20 + ciclo))
  and (periodos is null or (cardinality(periodos) between 1 and 6 and 0 < all(periodos) and 7 > all(periodos))));

-- 2) Historial: un estudiante de ciclos puede terminar dos ciclos en el mismo año (CLEI 5 y CLEI 6)
alter table public.historial add column if not exists periodos int[];
alter table public.historial add column if not exists ciclo int;
do $$
begin
  if exists (select 1 from pg_constraint where conname = 'historial_pkey' and conrelid = 'public.historial'::regclass) then
    alter table public.historial drop constraint historial_pkey;
  end if;
end $$;
create unique index if not exists historial_uk on public.historial (estudiante_id, anio, (coalesce(grado, -99)));
-- el cierre de año usa la nueva llave
do $$
declare d text := pg_get_functiondef('public.cerrar_anio(uuid, jsonb)'::regprocedure);
begin
  if position('on conflict (estudiante_id, anio) do update' in d) > 0 then
    execute replace(d, 'on conflict (estudiante_id, anio) do update', 'on conflict (estudiante_id, anio, (coalesce(grado, -99))) do update');
  end if;
end $$;
-- cada fila del historial guarda el ciclo y los periodos que contaron (los toma del curso del estudiante)
create or replace function priv.tg_historial_ciclo() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare g grupos;
begin
  if new.ciclo is null or new.periodos is null then
    select x.* into g from estudiantes s join grupos x on x.id = s.grupo_id where s.id = new.estudiante_id;
    if g.nivel = 'ciclos' and new.nivel = 'ciclos' then
      new.ciclo := coalesce(new.ciclo, g.ciclo); new.periodos := coalesce(new.periodos, g.periodos);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists tg_historial_ciclo on public.historial;
create trigger tg_historial_ciclo before insert or update on public.historial for each row execute function priv.tg_historial_ciclo();

-- 3) Definitivas: en un curso de ciclos solo cuentan sus periodos
create or replace function public.definitivas(p_colegio uuid, p_hasta integer default 99)
returns table(estudiante_id uuid, asignatura_id uuid, definitiva numeric)
language sql stable as $$
  select n.estudiante_id, n.asignatura_id, round(sum(n.valor * p.peso) / nullif(sum(p.peso), 0), 1)
  from notas n join colegios k on k.id = n.colegio_id
  join estudiantes s on s.id = n.estudiante_id left join grupos g on g.id = s.grupo_id
  cross join lateral jsonb_to_recordset(k.periodos) as p(n int, peso numeric)
  where n.colegio_id = p_colegio and n.anio = k.anio and p.n = n.periodo and n.periodo <= p_hasta
    and (g.periodos is null or p.n = any(g.periodos))
  group by 1, 2
$$;

-- 4) Crear un curso de ciclos (el plan de estudios del nivel se crea la primera vez con las áreas obligatorias de la media)
create or replace function public.crear_ciclo(p_colegio uuid, p_ciclo int, p_semestre int, p_nombre text) returns grupos
language plpgsql security definer set search_path = public, pg_temp as $$
declare g grupos; eq int; ps int[]; nm text := upper(btrim(coalesce(p_nombre, ''))); i int := 0; a text;
begin
  if not priv.es_directivo(p_colegio) then raise exception 'Solo los directivos crean cursos'; end if;
  if p_ciclo not between 3 and 6 then raise exception 'Elija el ciclo (CLEI 3 a 6)'; end if;
  eq := 20 + p_ciclo;
  ps := case when p_ciclo >= 5 then case when p_semestre = 2 then array[3, 4] else array[1, 2] end end;
  if p_ciclo >= 5 and jsonb_array_length(coalesce((select periodos from colegios where id = p_colegio), '[]')) < 4 then
    raise exception 'Los ciclos semestrales usan los periodos 1-2 (primer semestre) y 3-4 (segundo). Defina 4 periodos en Parametrización › Periodos y escala';
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

-- 5) Cierre de semestre de los cursos de ciclos que usan los periodos 1 y 2
create or replace function public.cerrar_semestre(p_colegio uuid, p_grupo uuid, p_decisiones jsonb) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare k colegios; g grupos; d jsonb; e estudiantes; n int := 0; dest uuid;
begin
  if not priv.es_rector(p_colegio) then raise exception 'Solo el rector o la rectora pueden cerrar el semestre'; end if;
  select * into k from colegios where id = p_colegio;
  select * into g from grupos where id = p_grupo and colegio_id = p_colegio;
  if g.id is null or g.nivel <> 'ciclos' or g.periodos is null or not (g.periodos <@ array[1, 2]) then
    raise exception 'El cierre de semestre es para los cursos de ciclos del primer semestre (periodos 1 y 2)';
  end if;
  for d in select * from jsonb_array_elements(p_decisiones) loop
    select * into e from estudiantes where id = (d->>'estudiante_id')::uuid and grupo_id = g.id and estado = 'Activo';
    if e.id is null then continue; end if;
    if d->>'resultado' not in ('Promovido', 'No promovido', 'Graduado') then raise exception 'Resultado inválido'; end if;
    insert into historial (colegio_id, estudiante_id, anio, grupo_nombre, grado, nivel, resultado, fecha_matricula, periodos, ciclo)
    values (p_colegio, e.id, k.anio, g.nombre, g.grado, g.nivel, d->>'resultado', e.fecha_matricula, g.periodos, g.ciclo)
    on conflict (estudiante_id, anio, (coalesce(grado, -99))) do update set resultado = excluded.resultado, grupo_nombre = excluded.grupo_nombre,
      periodos = excluded.periodos, ciclo = excluded.ciclo;
    if d->>'resultado' = 'Graduado' then
      update estudiantes set estado = 'Graduado' where id = e.id;
    else
      dest := nullif(d->>'grupo_destino', '')::uuid;
      if dest is not null and not exists (select 1 from grupos x where x.id = dest and x.colegio_id = p_colegio) then raise exception 'Curso de destino inválido'; end if;
      update estudiantes set grupo_id = coalesce(dest, grupo_id),
        situacion = case when d->>'resultado' = 'No promovido' then 'Repitente' else 'Promovido' end
      where id = e.id;
    end if;
    n := n + 1;
  end loop;
  return json_build_object('procesados', n);
end $$;
revoke all on function public.cerrar_semestre(uuid, uuid, jsonb) from public, anonymous;
grant execute on function public.cerrar_semestre(uuid, uuid, jsonb) to authenticated;

notify pgrst, 'reload schema';
