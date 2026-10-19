-- Colegio-IA 023 (entrega 2 de la revisión del 18 oct 2026):
--  1) Campus virtual dentro de Colegio-IA (como el de AcademIA): por curso y asignatura, unidades por periodo con
--     recursos (enlaces), videos, clases en vivo, tareas y cuestionarios. Las calificaciones de tareas y cuestionarios
--     pasan solas a las actividades del periodo (la calificación del periodo es el promedio simple de las actividades).
--     Cada colegio enciende el campus y elige en qué grados funciona.
--  2) Perfil Estudiante con su propio campus (también en la demostración). Con pagos pendientes queda bloqueado.
--  3) Gemas: el estudiante las gana al entrar, abrir recursos, entregar tareas, responder cuestionarios, sacar
--     calificaciones altas y recibir felicitaciones; hay rangos y el top del curso.
-- Las respuestas correctas de los cuestionarios nunca llegan a la pantalla del estudiante: la base de datos califica.

-- 1) Campus encendido por colegio y grados donde funciona (vacío = todos); gemas encendidas
alter table public.colegios add column if not exists campus_activo boolean not null default false;
alter table public.colegios add column if not exists campus_grados int[] not null default '{}';
alter table public.colegios add column if not exists gemas_activas boolean not null default true;
grant update (campus_activo, campus_grados, gemas_activas) on public.colegios to authenticated;

-- ¿El campus funciona para este curso?
create or replace function priv.campus_grupo_ok(g uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from grupos gr join colegios k on k.id = gr.colegio_id
                 where gr.id = g and k.campus_activo and (cardinality(k.campus_grados) = 0 or gr.grado = any(k.campus_grados)))
$$;
-- Personal que arma el campus del curso y asignatura (directivos o el docente de esa asignatura)
create or replace function priv.edita_campus(g uuid, a uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from grupos gr where gr.id = g and (priv.es_directivo(gr.colegio_id) or priv.docente_de_asig(g, a)))
$$;
-- Personal que puede ver el campus del curso (además, el director de grupo)
create or replace function priv.ve_campus(g uuid, a uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select priv.edita_campus(g, a) or priv.docente_de_grupo(g)
$$;
-- Estudiante del usuario (acudiente o estudiante, al día con los pagos) que está en el curso
create or replace function priv.mi_est_en_grupo(g uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select s.id from estudiantes s where s.grupo_id = g and s.estado = 'Activo' and s.id in (select priv.mis_estudiantes_al_dia()) order by s.id limit 1
$$;

-- 2) Unidades del campus (por curso, asignatura y periodo)
create table if not exists public.campus_unidades (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  grupo_id uuid not null references public.grupos(id) on delete cascade,
  asignatura_id uuid not null references public.asignaturas(id) on delete cascade,
  anio int not null,
  periodo int not null check (periodo between 1 and 6),
  titulo text not null check (length(btrim(titulo)) between 3 and 120),
  descripcion text check (descripcion is null or length(descripcion) <= 1000),
  orden int not null default 0,
  visible boolean not null default true,
  creado_nombre text,
  creado_en timestamptz not null default now()
);
create index if not exists campus_unidades_gap on public.campus_unidades (grupo_id, asignatura_id, anio, periodo);

-- Contenidos de cada unidad
create table if not exists public.campus_items (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  unidad_id uuid not null references public.campus_unidades(id) on delete cascade,
  tipo text not null check (tipo in ('recurso','video','clase','tarea','cuestionario')),
  titulo text not null check (length(btrim(titulo)) between 3 and 120),
  texto text check (texto is null or length(texto) <= 4000),
  url text check (url is null or (length(url) <= 500 and url ~ '^https?://[^\s<>"'']+$')),
  fecha timestamptz,                         -- clase en vivo: cuándo es; tarea y cuestionario: fecha límite
  calificable boolean not null default true, -- tarea y cuestionario: la calificación pasa a las actividades del periodo
  intentos int not null default 1 check (intentos between 1 and 3),
  n_preg int not null default 0,
  puntos int not null default 0,
  actividad_id uuid references public.actividades(id) on delete set null,
  visible boolean not null default true,
  orden int not null default 0,
  creado_en timestamptz not null default now()
);
create index if not exists campus_items_u on public.campus_items (unidad_id, orden);

-- Preguntas de los cuestionarios, con las respuestas correctas (solo las ve el personal)
create table if not exists public.campus_preguntas (
  item_id uuid primary key references public.campus_items(id) on delete cascade,
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  preguntas jsonb not null default '[]'
);

-- Entregas de tareas y respuestas de cuestionarios (se crean y cambian solo con las funciones de abajo)
create table if not exists public.campus_entregas (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  item_id uuid not null references public.campus_items(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  texto text check (texto is null or length(texto) <= 4000),
  url text check (url is null or (length(url) <= 500 and url ~ '^https?://[^\s<>"'']+$')),
  respuestas jsonb,
  intentos int not null default 0,
  nota numeric(4,1) check (nota is null or nota between 0 and 100),
  comentario text check (comentario is null or length(comentario) <= 1000),
  estado text not null default 'Entregada' check (estado in ('Entregada','Calificada')),
  entregado_en timestamptz,
  entregado_nombre text,
  calificado_en timestamptz,
  calificado_nombre text,
  unique (item_id, estudiante_id)
);
create index if not exists campus_entregas_est on public.campus_entregas (estudiante_id);

-- Qué recursos ha abierto cada estudiante (para el docente y para las gemas)
create table if not exists public.campus_vistos (
  item_id uuid not null references public.campus_items(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  veces int not null default 1,
  visto_en timestamptz not null default now(),
  primary key (item_id, estudiante_id)
);

-- Gemas ganadas (una fila por motivo; la base de datos evita que se repitan)
create table if not exists public.gemas (
  id bigserial primary key,
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  motivo text not null check (motivo in ('entrada','racha','recurso','tarea','cuestionario','excelente','felicitacion','positiva','participacion')),
  ref text not null,
  cantidad int not null check (cantidad between 1 and 50),
  creado_en timestamptz not null default now(),
  unique (estudiante_id, motivo, ref)
);
create index if not exists gemas_col on public.gemas (colegio_id, estudiante_id);

-- 3) Reglas automáticas
create or replace function priv.tg_campus_unidades() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  select gr.colegio_id into new.colegio_id from grupos gr where gr.id = new.grupo_id;
  if not exists (select 1 from asignaturas s where s.id = new.asignatura_id and s.colegio_id = new.colegio_id) then raise exception 'La asignatura no es de este colegio'; end if;
  if tg_op = 'INSERT' then
    select k.anio into new.anio from colegios k where k.id = new.colegio_id;
    new.creado_nombre := priv.nombre_actual(new.colegio_id); new.creado_en := now();
  else
    new.anio := old.anio; new.grupo_id := old.grupo_id; new.asignatura_id := old.asignatura_id; new.creado_nombre := old.creado_nombre;
  end if;
  new.titulo := btrim(new.titulo);
  return new;
end $$;
drop trigger if exists tg_campus_unidades on public.campus_unidades;
create trigger tg_campus_unidades before insert or update on public.campus_unidades for each row execute function priv.tg_campus_unidades();

-- Las actividades creadas por el campus quedan marcadas (en Calificaciones no se borran: se manejan desde el campus)
alter table public.actividades add column if not exists campus boolean not null default false;

-- Recalcula la calificación del periodo de un estudiante con el promedio simple de sus actividades calificadas
create or replace function priv.recalc_nota(e uuid, g uuid, a uuid, y int, p int) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v numeric; c uuid;
begin
  if not exists (select 1 from actividades x where x.grupo_id = g and x.asignatura_id = a and x.anio = y and x.periodo = p) then return; end if;
  select round(avg(na.valor)) into v from notas_act na join actividades x on x.id = na.actividad_id
   where na.estudiante_id = e and x.grupo_id = g and x.asignatura_id = a and x.anio = y and x.periodo = p;
  select colegio_id into c from estudiantes where id = e;
  if v is null then
    delete from notas where estudiante_id = e and asignatura_id = a and anio = y and periodo = p;
  else
    insert into notas (colegio_id, estudiante_id, asignatura_id, anio, periodo, valor, actualizado_por)
    values (c, e, a, y, p, v, priv.nombre_actual(c))
    on conflict (estudiante_id, asignatura_id, anio, periodo) do update set valor = excluded.valor, actualizado_por = excluded.actualizado_por, actualizado_en = now()
    where notas.valor is distinct from excluded.valor;
  end if;
end $$;

-- Quita la actividad de un contenido (al borrarlo o al dejar de ser calificable) y recalcula la calificación del periodo
create or replace function priv.quitar_actividad(aid uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare x actividades; ests uuid[]; e uuid;
begin
  select * into x from actividades where id = aid; if x.id is null then return; end if;
  ests := array(select estudiante_id from notas_act where actividad_id = aid);
  delete from actividades where id = aid;
  foreach e in array ests loop perform priv.recalc_nota(e, x.grupo_id, x.asignatura_id, x.anio, x.periodo); end loop;
end $$;

-- La tarea o el cuestionario calificable tiene su actividad en Calificaciones (se crea sola)
create or replace function priv.tg_campus_items() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare u campus_unidades; aid uuid;
begin
  select * into u from campus_unidades where id = new.unidad_id;
  new.colegio_id := u.colegio_id;
  new.titulo := btrim(new.titulo);
  if tg_op = 'INSERT' then
    new.actividad_id := null;
    if current_setting('micolegia.preg', true) is distinct from 'on' then new.n_preg := 0; new.puntos := 0; end if;
  else
    new.unidad_id := old.unidad_id; new.tipo := old.tipo;
    if current_setting('micolegia.preg', true) is distinct from 'on' then new.n_preg := old.n_preg; new.puntos := old.puntos; end if;
    if new.actividad_id is not null and new.actividad_id is distinct from old.actividad_id then new.actividad_id := old.actividad_id; end if;
  end if;
  if new.tipo not in ('tarea', 'cuestionario') then new.calificable := false; new.intentos := 1; end if;
  if new.tipo in ('recurso', 'video') and new.url is null and coalesce(btrim(new.texto), '') = '' then raise exception 'Escriba el enlace o el texto del recurso'; end if;
  if new.tipo = 'video' and new.url is null then raise exception 'Escriba el enlace del video'; end if;
  if new.tipo = 'clase' and new.fecha is null then raise exception 'Escriba la fecha y la hora de la clase en vivo'; end if;
  if new.calificable then
    if new.actividad_id is null or not exists (select 1 from actividades where id = new.actividad_id) then
      insert into actividades (colegio_id, grupo_id, asignatura_id, anio, periodo, nombre, fecha, orden, campus)
      values (u.colegio_id, u.grupo_id, u.asignatura_id, u.anio, u.periodo, left(new.titulo, 80), coalesce((new.fecha at time zone 'America/Bogota')::date, priv.hoy_co()), 100, true)
      returning id into aid;
      new.actividad_id := aid;
    elsif tg_op = 'UPDATE' and (new.titulo is distinct from old.titulo or new.fecha is distinct from old.fecha) then
      update actividades set nombre = left(new.titulo, 80), fecha = coalesce((new.fecha at time zone 'America/Bogota')::date, fecha) where id = new.actividad_id;
    end if;
  else
    new.actividad_id := null;   -- si tenía actividad, se quita después de guardar (ver abajo)
  end if;
  return new;
end $$;
drop trigger if exists tg_campus_items on public.campus_items;
create trigger tg_campus_items before insert or update on public.campus_items for each row execute function priv.tg_campus_items();
create or replace function priv.tg_campus_items_fin() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if old.actividad_id is not null and (tg_op = 'DELETE' or new.actividad_id is distinct from old.actividad_id) then
    perform priv.quitar_actividad(old.actividad_id);
  end if;
  return null;
end $$;
drop trigger if exists tg_campus_items_fin on public.campus_items;
create trigger tg_campus_items_fin after update or delete on public.campus_items for each row execute function priv.tg_campus_items_fin();

-- Gemas (solo las da la base de datos; si el colegio las apagó no se dan)
create or replace function priv.dar_gemas(e uuid, mot text, r text, n int) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare c uuid; ok int;
begin
  select s.colegio_id into c from estudiantes s join colegios k on k.id = s.colegio_id where s.id = e and k.gemas_activas;
  if c is null or n <= 0 then return 0; end if;
  insert into gemas (colegio_id, estudiante_id, motivo, ref, cantidad) values (c, e, mot, r, least(n, 50)) on conflict do nothing;
  get diagnostics ok = row_count;
  return case when ok > 0 then least(n, 50) else 0 end;
end $$;

-- Felicitaciones y anotaciones positivas del observador dan gemas
create or replace function priv.tg_observador_gemas() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.tipo = 'Felicitación' then perform priv.dar_gemas(new.estudiante_id, 'felicitacion', new.id::text, 15);
  elsif new.tipo = 'Positiva' then perform priv.dar_gemas(new.estudiante_id, 'positiva', new.id::text, 5); end if;
  return new;
end $$;
drop trigger if exists tg_observador_gemas on public.observador;
create trigger tg_observador_gemas after insert on public.observador for each row execute function priv.tg_observador_gemas();

-- 4) Seguridad por filas
alter table public.campus_unidades enable row level security;
alter table public.campus_items enable row level security;
alter table public.campus_preguntas enable row level security;
alter table public.campus_entregas enable row level security;
alter table public.campus_vistos enable row level security;
alter table public.gemas enable row level security;
revoke all on public.campus_preguntas, public.campus_entregas, public.campus_vistos, public.gemas from authenticated;
grant select, insert, update, delete on public.campus_unidades, public.campus_items to authenticated;
grant select on public.campus_preguntas, public.campus_entregas, public.campus_vistos, public.gemas to authenticated;
grant usage on sequence public.gemas_id_seq to authenticated;

drop policy if exists cu_ver on public.campus_unidades;
create policy cu_ver on public.campus_unidades for select to authenticated using (
  priv.ve_campus(grupo_id, asignatura_id)
  or (visible and priv.campus_grupo_ok(grupo_id) and priv.mi_est_en_grupo(grupo_id) is not null));
drop policy if exists cu_esc on public.campus_unidades;
create policy cu_esc on public.campus_unidades for all to authenticated
  using (priv.edita_campus(grupo_id, asignatura_id)) with check (priv.edita_campus(grupo_id, asignatura_id));

drop policy if exists ci_ver on public.campus_items;
create policy ci_ver on public.campus_items for select to authenticated using (exists (
  select 1 from campus_unidades u where u.id = unidad_id and (priv.ve_campus(u.grupo_id, u.asignatura_id)
    or (visible and u.visible and priv.campus_grupo_ok(u.grupo_id) and priv.mi_est_en_grupo(u.grupo_id) is not null))));
drop policy if exists ci_esc on public.campus_items;
create policy ci_esc on public.campus_items for all to authenticated
  using (exists (select 1 from campus_unidades u where u.id = unidad_id and priv.edita_campus(u.grupo_id, u.asignatura_id)))
  with check (exists (select 1 from campus_unidades u where u.id = unidad_id and priv.edita_campus(u.grupo_id, u.asignatura_id)));

drop policy if exists cp_ver on public.campus_preguntas;
create policy cp_ver on public.campus_preguntas for select to authenticated using (exists (
  select 1 from campus_items i join campus_unidades u on u.id = i.unidad_id where i.id = item_id and priv.ve_campus(u.grupo_id, u.asignatura_id)));

drop policy if exists ce2_ver on public.campus_entregas;
create policy ce2_ver on public.campus_entregas for select to authenticated using (
  estudiante_id in (select priv.mis_estudiantes_al_dia())
  or exists (select 1 from campus_items i join campus_unidades u on u.id = i.unidad_id where i.id = item_id and priv.ve_campus(u.grupo_id, u.asignatura_id)));

drop policy if exists cv_ver on public.campus_vistos;
create policy cv_ver on public.campus_vistos for select to authenticated using (
  estudiante_id in (select priv.mis_estudiantes_al_dia())
  or exists (select 1 from campus_items i join campus_unidades u on u.id = i.unidad_id where i.id = item_id and priv.ve_campus(u.grupo_id, u.asignatura_id)));

drop policy if exists ge_ver on public.gemas;
create policy ge_ver on public.gemas for select to authenticated using (priv.puede_calificar(estudiante_id) or estudiante_id in (select priv.mis_estudiantes_al_dia()));

-- 5) Funciones que usa la app
-- Contenido que la familia o el estudiante pueden abrir (visible, de su curso, campus encendido, al día con los pagos)
create or replace function priv.item_para(p_item uuid, p_est uuid) returns campus_items
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare i campus_items; u campus_unidades;
begin
  select * into i from campus_items where id = p_item;
  select * into u from campus_unidades where id = i.unidad_id;
  if i.id is null or not i.visible or not u.visible then raise exception 'Este contenido ya no está disponible'; end if;
  if p_est is null or p_est not in (select priv.mis_estudiantes_al_dia())
     or not exists (select 1 from estudiantes s where s.id = p_est and s.grupo_id = u.grupo_id and s.estado = 'Activo') then
    raise exception 'Esta sección no está disponible en este momento. Para más información, comuníquese con la secretaría del colegio.';
  end if;
  if not priv.campus_grupo_ok(u.grupo_id) then raise exception 'El campus virtual no está activo para este curso'; end if;
  return i;
end $$;
create or replace function priv.mi_nombre_familia(c uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(max(m.nombre), 'Familia') from miembros m where m.colegio_id = c and m.user_id = priv.uid() and m.activo
$$;

-- Abrir un recurso, video o clase (queda registrado y da gemas la primera vez)
create or replace function public.campus_abrir(p_item uuid, p_est uuid) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare i campus_items;
begin
  i := priv.item_para(p_item, p_est);
  insert into campus_vistos (item_id, estudiante_id, colegio_id) values (i.id, p_est, i.colegio_id)
  on conflict (item_id, estudiante_id) do update set veces = campus_vistos.veces + 1, visto_en = now();
  if i.tipo in ('recurso', 'video', 'clase') then return priv.dar_gemas(p_est, 'recurso', i.id::text, 2); end if;
  return 0;
end $$;

-- Gemas por entrar (una vez al día) y por entrar 5 días seguidos
create or replace function public.gemas_entrada(p_est uuid) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int := 0; d date := priv.hoy_co();
begin
  if p_est is null or p_est not in (select priv.mis_estudiantes_al_dia()) then return 0; end if;
  n := priv.dar_gemas(p_est, 'entrada', d::text, 3);
  if n > 0 and (select count(*) from gemas where estudiante_id = p_est and motivo = 'entrada' and ref::date between d - 4 and d) = 5
     and not exists (select 1 from gemas where estudiante_id = p_est and motivo = 'racha' and ref::date between d - 4 and d - 1) then
    n := n + priv.dar_gemas(p_est, 'racha', d::text, 10);
  end if;
  return n;
end $$;

-- Preguntas del cuestionario para responder (sin las respuestas correctas; el emparejamiento sale desordenado)
create or replace function public.campus_cuestionario(p_item uuid, p_est uuid) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare i campus_items; e campus_entregas; pr jsonb; out jsonb := '[]'; x jsonb;
begin
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
                           'nota', e.nota, 'preguntas', out);
end $$;

create or replace function priv.norm_txt(t text) returns text
language sql immutable as $$ select regexp_replace(translate(lower(btrim(coalesce(t, ''))), 'áéíóúüñ', 'aeiouun'), '\s+', ' ', 'g') $$;

-- Escribe la calificación en la actividad del periodo y recalcula (si el periodo sigue abierto)
create or replace function priv.campus_a_calificaciones(i campus_items, p_est uuid, v numeric) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
declare u campus_unidades; aid uuid;
begin
  if not i.calificable then return false; end if;
  select * into u from campus_unidades where id = i.unidad_id;
  if not priv.notas_abiertas(u.colegio_id, u.periodo) and not priv.es_directivo(u.colegio_id) then return false; end if;
  aid := i.actividad_id;
  if aid is null or not exists (select 1 from actividades where id = aid) then
    update campus_items set calificable = true, actividad_id = null where id = i.id;   -- el disparador vuelve a crear la actividad
    select actividad_id into aid from campus_items where id = i.id;
  end if;
  if v is null then delete from notas_act where actividad_id = aid and estudiante_id = p_est;
  else
    insert into notas_act (actividad_id, estudiante_id, colegio_id, valor) values (aid, p_est, u.colegio_id, v)
    on conflict (actividad_id, estudiante_id) do update set valor = excluded.valor;
  end if;
  perform priv.recalc_nota(p_est, u.grupo_id, u.asignatura_id, u.anio, u.periodo);
  return true;
end $$;

-- Responder un cuestionario: la base de datos califica (puntos de cada pregunta, nota sobre 100)
create or replace function public.campus_responder(p_item uuid, p_est uuid, p_resp jsonb) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare i campus_items; e campus_entregas; pr jsonb; x jsonb; r jsonb; k int := 0; tot numeric := 0; got numeric := 0; ok int := 0;
        pares int; bien int; v numeric; gm int := 0; detalle jsonb := '[]'; pasa boolean;
begin
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
  gm := priv.dar_gemas(p_est, 'cuestionario', i.id::text, 5 + (v / 10)::int);
  if v >= 92 then gm := gm + priv.dar_gemas(p_est, 'excelente', i.id::text, 10); end if;
  return json_build_object('nota', v, 'mejor', e.nota, 'correctas', ok, 'total', k, 'gemas', gm, 'detalle', detalle,
                           'quedan', greatest(0, i.intentos - e.intentos));
end $$;

-- Entregar (o corregir) una tarea mientras no esté calificada
create or replace function public.campus_entregar(p_item uuid, p_est uuid, p_texto text, p_url text) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare i campus_items; e campus_entregas; t text := nullif(btrim(coalesce(p_texto, '')), ''); l text := nullif(btrim(coalesce(p_url, '')), ''); gm int := 0;
begin
  i := priv.item_para(p_item, p_est);
  if i.tipo <> 'tarea' then raise exception 'Este contenido no es una tarea'; end if;
  if t is null and l is null then raise exception 'Escriba su respuesta o pegue el enlace de su trabajo'; end if;
  if l is not null and l !~ '^https?://' then l := 'https://' || l; end if;
  select * into e from campus_entregas where item_id = i.id and estudiante_id = p_est;
  if e.estado = 'Calificada' then raise exception 'La tarea ya fue calificada. Si necesita cambiar algo, escríbale al docente.'; end if;
  insert into campus_entregas (colegio_id, item_id, estudiante_id, texto, url, intentos, estado, entregado_en, entregado_nombre)
  values (i.colegio_id, i.id, p_est, t, l, 1, 'Entregada', now(), priv.mi_nombre_familia(i.colegio_id))
  on conflict (item_id, estudiante_id) do update set texto = excluded.texto, url = excluded.url, intentos = campus_entregas.intentos + 1,
    entregado_en = now(), entregado_nombre = excluded.entregado_nombre;
  if e.id is null then gm := priv.dar_gemas(p_est, 'tarea', i.id::text, case when i.fecha is not null and now() > i.fecha then 5 else 10 end); end if;
  return gm;
end $$;

-- El docente califica una tarea (o cualquier tarea/cuestionario, aunque el estudiante no haya entregado)
create or replace function public.campus_calificar(p_item uuid, p_est uuid, p_nota numeric, p_coment text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare i campus_items; u campus_unidades; e campus_entregas; v numeric := round(p_nota);
begin
  select * into i from campus_items where id = p_item;
  select * into u from campus_unidades where id = i.unidad_id;
  if i.id is null or not priv.edita_campus(u.grupo_id, u.asignatura_id) then raise exception 'No tiene permiso para esta acción'; end if;
  if i.tipo not in ('tarea', 'cuestionario') then raise exception 'Este contenido no se califica'; end if;
  if not exists (select 1 from estudiantes where id = p_est and grupo_id = u.grupo_id) then raise exception 'El estudiante no es de este curso'; end if;
  if v is not null and (v < 0 or v > 100) then raise exception 'Escriba un número entero de 0 a 100'; end if;
  if i.calificable and not priv.notas_abiertas(u.colegio_id, u.periodo) and not priv.es_directivo(u.colegio_id) then
    raise exception 'El periodo % ya está cerrado. Si necesita corregir una calificación, solicítelo a coordinación.', u.periodo;
  end if;
  select * into e from campus_entregas where item_id = i.id and estudiante_id = p_est;
  if v is null then
    if e.id is not null and (e.texto is not null or e.url is not null or e.respuestas is not null) then
      update campus_entregas set nota = null, estado = 'Entregada', comentario = nullif(btrim(p_coment), ''), calificado_en = null, calificado_nombre = null where id = e.id;
    elsif e.id is not null then delete from campus_entregas where id = e.id;
    end if;
  else
    insert into campus_entregas (colegio_id, item_id, estudiante_id, nota, comentario, estado, calificado_en, calificado_nombre)
    values (i.colegio_id, i.id, p_est, v, nullif(btrim(p_coment), ''), 'Calificada', now(), priv.nombre_actual(i.colegio_id))
    on conflict (item_id, estudiante_id) do update set nota = excluded.nota, comentario = excluded.comentario, estado = 'Calificada',
      calificado_en = now(), calificado_nombre = excluded.calificado_nombre;
    if v >= 92 and (e.texto is not null or e.url is not null or e.respuestas is not null) then perform priv.dar_gemas(p_est, 'excelente', i.id::text, 10); end if;
  end if;
  perform priv.campus_a_calificaciones(i, p_est, v);
end $$;

-- El docente guarda las preguntas del cuestionario (se revisan aquí para que nunca queden mal armadas)
create or replace function public.campus_guardar_preguntas(p_item uuid, p_preg jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare i campus_items; u campus_unidades; x jsonb; n int := 0; pts int := 0; limpio jsonb := '[]'; t text; o jsonb; c jsonb; p jsonb;
begin
  select * into i from campus_items where id = p_item;
  select * into u from campus_unidades where id = i.unidad_id;
  if i.id is null or not priv.edita_campus(u.grupo_id, u.asignatura_id) then raise exception 'No tiene permiso para esta acción'; end if;
  if i.tipo <> 'cuestionario' then raise exception 'Este contenido no es un cuestionario'; end if;
  if jsonb_typeof(p_preg) <> 'array' or jsonb_array_length(p_preg) > 40 then raise exception 'Puede tener hasta 40 preguntas'; end if;
  for x in select value from jsonb_array_elements(p_preg) loop
    n := n + 1; t := x ->> 't';
    if coalesce(btrim(x ->> 'q'), '') = '' or length(x ->> 'q') > 600 then raise exception 'Escriba el enunciado de la pregunta % (hasta 600 letras)', n; end if;
    if coalesce((x ->> 'pts')::int, 0) not between 1 and 100 then raise exception 'La pregunta % debe valer entre 1 y 100 puntos', n; end if;
    if t = 'om' then
      select coalesce(jsonb_agg(btrim(v)), '[]') into o from jsonb_array_elements_text(x -> 'o') v where btrim(v) <> '';
      if jsonb_array_length(o) < 2 or jsonb_array_length(o) > 6 then raise exception 'La pregunta % necesita entre 2 y 6 opciones', n; end if;
      if (x ->> 'c') is null or (x ->> 'c')::int not between 0 and jsonb_array_length(o) - 1 then raise exception 'Marque la opción correcta de la pregunta %', n; end if;
      limpio := limpio || jsonb_build_array(jsonb_build_object('t', t, 'q', btrim(x ->> 'q'), 'pts', (x ->> 'pts')::int, 'o', o, 'c', (x ->> 'c')::int));
    elsif t = 'vf' then
      if jsonb_typeof(x -> 'c') <> 'boolean' then raise exception 'Marque si la afirmación % es verdadera o falsa', n; end if;
      limpio := limpio || jsonb_build_array(jsonb_build_object('t', t, 'q', btrim(x ->> 'q'), 'pts', (x ->> 'pts')::int, 'c', x -> 'c'));
    elsif t = 'corta' then
      select coalesce(jsonb_agg(btrim(v)), '[]') into c from jsonb_array_elements_text(x -> 'c') v where btrim(v) <> '';
      if jsonb_array_length(c) = 0 then raise exception 'Escriba al menos una respuesta aceptada en la pregunta %', n; end if;
      limpio := limpio || jsonb_build_array(jsonb_build_object('t', t, 'q', btrim(x ->> 'q'), 'pts', (x ->> 'pts')::int, 'c', c));
    elsif t = 'emp' then
      select coalesce(jsonb_agg(jsonb_build_array(btrim(par ->> 0), btrim(par ->> 1))), '[]') into p from jsonb_array_elements(x -> 'p') par
       where btrim(coalesce(par ->> 0, '')) <> '' and btrim(coalesce(par ->> 1, '')) <> '';
      if jsonb_array_length(p) < 2 or jsonb_array_length(p) > 8 then raise exception 'La pregunta % necesita entre 2 y 8 parejas completas', n; end if;
      if (select count(distinct priv.norm_txt(par ->> 1)) from jsonb_array_elements(p) par) < jsonb_array_length(p) then raise exception 'En la pregunta % hay respuestas repetidas en la columna derecha', n; end if;
      limpio := limpio || jsonb_build_array(jsonb_build_object('t', t, 'q', btrim(x ->> 'q'), 'pts', (x ->> 'pts')::int, 'p', p));
    else raise exception 'Tipo de pregunta no válido en la pregunta %', n;
    end if;
    pts := pts + (x ->> 'pts')::int;
  end loop;
  insert into campus_preguntas (item_id, colegio_id, preguntas) values (i.id, i.colegio_id, limpio)
  on conflict (item_id) do update set preguntas = excluded.preguntas;
  perform set_config('micolegia.preg', 'on', true);
  update campus_items set n_preg = n, puntos = pts where id = i.id;
  perform set_config('micolegia.preg', '', true);
end $$;
-- Resumen de gemas del estudiante: total, de la semana, puesto en su curso y el top 10 del curso
create or replace function public.gemas_resumen(p_est uuid) returns json
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s estudiantes; tot int; sem int; pos int; de int; top json; lun date := priv.lunes_co();
begin
  select * into s from estudiantes where id = p_est;
  if s.id is null or not (p_est in (select priv.mis_estudiantes_al_dia()) or priv.puede_calificar(p_est)) then raise exception 'No tiene permiso para esta acción'; end if;
  select coalesce(sum(cantidad), 0) into tot from gemas where estudiante_id = p_est;
  select coalesce(sum(cantidad), 0) into sem from gemas where estudiante_id = p_est and (creado_en at time zone 'America/Bogota')::date >= lun;
  with r as (select x.id, coalesce((select sum(cantidad) from gemas g where g.estudiante_id = x.id), 0) t
             from estudiantes x where x.grupo_id = s.grupo_id and x.estado = 'Activo')
  select count(*) filter (where t > tot) + 1, count(*) into pos, de from r;
  select json_agg(json_build_object('n', z.n, 'g', z.t, 'yo', z.id = p_est) order by z.t desc, z.n) into top from (
    select x.id, x.nombres || ' ' || left(x.apellidos, 1) || '.' n, coalesce((select sum(cantidad) from gemas g where g.estudiante_id = x.id), 0) t
    from estudiantes x where x.grupo_id = s.grupo_id and x.estado = 'Activo' order by t desc, n limit 10) z;
  return json_build_object('total', tot, 'semana', sem, 'puesto', pos, 'de', de, 'top', coalesce(top, '[]'::json),
    'ultimas', (select coalesce(json_agg(json_build_object('m', motivo, 'c', cantidad, 'f', creado_en) order by creado_en desc), '[]'::json)
                from (select * from gemas where estudiante_id = p_est order by creado_en desc limit 12) w));
end $$;

-- Gemas del curso para el personal (docentes del curso y directivos)
create or replace function public.gemas_grupo(p_grupo uuid) returns json
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(json_agg(json_build_object('estudiante_id', x.id, 'total', coalesce(t.tot, 0), 'semana', coalesce(t.sem, 0)) order by coalesce(t.tot, 0) desc), '[]'::json)
  from estudiantes x
  left join lateral (select sum(cantidad) tot, sum(cantidad) filter (where (creado_en at time zone 'America/Bogota')::date >= priv.lunes_co()) sem
                     from gemas g where g.estudiante_id = x.id) t on true
  where x.grupo_id = p_grupo and x.estado = 'Activo'
    and (priv.es_directivo(x.colegio_id) or priv.docente_de_grupo(p_grupo))
$$;

-- El docente reconoce la participación en clase (5 gemas, una vez al día por docente y estudiante)
create or replace function public.gemas_participacion(p_est uuid) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare s estudiantes;
begin
  select * into s from estudiantes where id = p_est;
  if s.id is null or not (priv.es_directivo(s.colegio_id) or priv.docente_de_grupo(s.grupo_id)) then raise exception 'No tiene permiso para esta acción'; end if;
  return priv.dar_gemas(p_est, 'participacion', priv.hoy_co()::text || ':' || priv.uid(), 5);
end $$;

-- 6) Bloqueo por suscripción vencida también en las tablas nuevas
do $$
declare t text;
begin
  foreach t in array array['campus_unidades', 'campus_items', 'campus_preguntas', 'campus_entregas', 'campus_vistos', 'gemas'] loop
    execute format('drop trigger if exists zz_bloqueo on public.%I', t);
    execute format('create trigger zz_bloqueo before insert or update or delete on public.%I for each row execute function priv.tg_bloqueo()', t);
  end loop;
end $$;

-- 7) Demostración: perfil Estudiante (segundo estudiante de Quinto A, al día) y campus de ejemplo
do $$
declare d text;
begin
  d := pg_get_functiondef('public.entrar_demo'::regproc);
  if position('''estudiante''' in d) = 0 then
    d := replace(d, $q$if p_rol not in ('rector', 'coordinador', 'docente', 'acudiente') then$q$, $q$if p_rol not in ('rector', 'coordinador', 'docente', 'acudiente', 'estudiante') then$q$);
    d := replace(d, $q$    insert into miembros (colegio_id, email, nombre, rol, user_id, estudiante_id) values (k.id, em, nm, p_rol, u, e) returning id into mid;$q$,
      $q$    if p_rol = 'estudiante' then
      select s.id into e from estudiantes s join grupos g on g.id = s.grupo_id where s.colegio_id = k.id and g.nombre = 'Quinto A' order by s.apellidos offset 1 limit 1;
      alter table pagos disable trigger tg_pagos;
      insert into pagos (colegio_id, estudiante_id, concepto_id, anio, mes, valor, fecha, medio, recibo, registrado_nombre, lote)
      select k.id, e, c.id, k.anio, case when c.periodicidad = 'unico' then c.mes_cobro else m end, c.valor, current_date, 'Transferencia',
             (select coalesce(max(recibo), 0) from pagos where colegio_id = k.id) + row_number() over (), k.secretaria_nombre, gen_random_uuid()
      from conceptos c cross join lateral unnest(case when c.periodicidad = 'mensual' then c.meses else array[c.mes_cobro] end) m
      where c.colegio_id = k.id and c.anio = k.anio and c.valor > 0 and m <= extract(month from current_date)::int
        and not exists (select 1 from pagos p where p.estudiante_id = e and p.concepto_id = c.id and p.anio = k.anio
                        and p.mes is not distinct from case when c.periodicidad = 'unico' then c.mes_cobro else m end and not p.anulado);
      alter table pagos enable trigger tg_pagos;
    end if;
    insert into miembros (colegio_id, email, nombre, rol, user_id, estudiante_id) values (k.id, em, nm, p_rol, u, e) returning id into mid;$q$);
    if position('''estudiante''' in d) = 0 or position('offset 1 limit 1' in d) = 0 then raise exception 'No se pudo agregar el perfil Estudiante a la demostración'; end if;
    execute d;
  end if;
end $$;

create or replace function priv.demo_campus(c uuid, a int) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare g record; s record; un uuid; it uuid; tq uuid; cq uuid; pa int; es uuid[]; i int; v int; hoy date := priv.hoy_co(); pr jsonb; nm text;
begin
  update colegios set campus_activo = true, campus_grados = '{}', gemas_activas = true where id = c;
  select periodo_actual into pa from colegios where id = c;
  for g in select gr.* from grupos gr where gr.colegio_id = c and gr.nombre in ('Tercero A', 'Quinto A') loop
    select array_agg(x.id order by x.apellidos) into es from estudiantes x where x.grupo_id = g.id and x.estado = 'Activo';
    select m.nombre into nm from docente_grupos dg join miembros m on m.id = dg.miembro_id where dg.grupo_id = g.id and m.user_id like 'demo:%' limit 1;
    for s in select * from asignaturas where colegio_id = c and nivel = g.nivel and nombre in ('Matemáticas', 'Lengua castellana') loop
      -- unidad del periodo anterior (ya terminada) y unidad del periodo en curso
      insert into campus_unidades (colegio_id, grupo_id, asignatura_id, anio, periodo, titulo, descripcion, orden, creado_nombre)
      values (c, g.id, s.id, a, greatest(1, pa - 1), 'Unidad ' || greatest(1, pa - 1) || ': repaso general', 'Materiales de repaso del periodo anterior.', 1, nm);
      insert into campus_unidades (colegio_id, grupo_id, asignatura_id, anio, periodo, titulo, descripcion, orden, creado_nombre)
      values (c, g.id, s.id, a, pa, case when s.nombre = 'Matemáticas' then 'Unidad ' || pa || ': ' || case when g.grado <= 3 then 'sumas, restas y multiplicación' else 'fracciones y geometría' end
                                         else 'Unidad ' || pa || ': comprensión lectora y gramática' end,
              'Lea las instrucciones de cada actividad. Si tiene dudas, escríbale al docente desde Mensajes.', 2, nm)
      returning id into un;
      insert into campus_items (colegio_id, unidad_id, tipo, titulo, texto, url, orden) values
        (c, un, 'recurso', 'Lectura de la unidad', 'Lea con atención y tome apuntes en su cuaderno.', 'https://www.colombiaaprende.edu.co/', 1),
        (c, un, 'video', 'Video explicativo', 'Vea el video completo antes de hacer el taller.', 'https://www.youtube.com/results?search_query=' || replace(lower(s.nombre), ' ', '+') || '+grado+' || g.grado, 2);
      insert into campus_items (colegio_id, unidad_id, tipo, titulo, texto, url, fecha, orden)
      values (c, un, 'clase', 'Clase en vivo de refuerzo', 'Conéctese 5 minutos antes con su cuaderno.', 'https://meet.google.com/', ((hoy + 1)::text || ' 15:00')::timestamp at time zone 'America/Bogota', 3);
      insert into campus_items (colegio_id, unidad_id, tipo, titulo, texto, fecha, orden)
      values (c, un, 'tarea', case when s.nombre = 'Matemáticas' then 'Taller de ejercicios' else 'Resumen de la lectura' end,
              case when s.nombre = 'Matemáticas' then 'Resuelva los ejercicios de la página 45 y escriba aquí los resultados, o pegue el enlace de una foto de su cuaderno.'
                   else 'Escriba un resumen de 5 a 8 renglones de la lectura de la unidad.' end,
              ((hoy + 3)::text || ' 23:59')::timestamp at time zone 'America/Bogota', 4)
      returning id into tq;
      insert into campus_items (colegio_id, unidad_id, tipo, titulo, texto, fecha, intentos, orden)
      values (c, un, 'cuestionario', 'Evaluación corta', 'Tiene 2 intentos. Se guarda la mejor calificación.', ((hoy + 5)::text || ' 23:59')::timestamp at time zone 'America/Bogota', 2, 5)
      returning id into cq;
      pr := case when s.nombre = 'Matemáticas' and g.grado <= 3 then
        '[{"t":"om","q":"¿Cuánto es 25 + 17?","pts":25,"o":["32","42","52","41"],"c":1},
          {"t":"vf","q":"El número 305 tiene 3 centenas.","pts":25,"c":true},
          {"t":"emp","q":"Una cada palabra con su cantidad.","pts":25,"p":[["Decena","10"],["Docena","12"],["Centena","100"]]},
          {"t":"corta","q":"¿Cuánto es 9 × 3?","pts":25,"c":["27"]}]'
           when s.nombre = 'Matemáticas' then
        '[{"t":"om","q":"¿Cuánto son las 3/4 partes de 20?","pts":25,"o":["5","10","15","12"],"c":2},
          {"t":"vf","q":"Un número primo tiene exactamente dos divisores.","pts":25,"c":true},
          {"t":"emp","q":"Una cada figura con su número de lados.","pts":25,"p":[["Triángulo","3"],["Cuadrado","4"],["Pentágono","5"],["Hexágono","6"]]},
          {"t":"corta","q":"¿Cuánto es 0,5 + 0,25?","pts":25,"c":["0,75","0.75",",75"]}]'
           else
        '[{"t":"om","q":"¿Cuál es un sinónimo de «feliz»?","pts":25,"o":["Contento","Triste","Cansado","Enojado"],"c":0},
          {"t":"vf","q":"Los sustantivos nombran personas, animales, cosas o lugares.","pts":25,"c":true},
          {"t":"emp","q":"Una cada palabra con su clase.","pts":25,"p":[["Correr","Verbo"],["Casa","Sustantivo"],["Bonito","Adjetivo"]]},
          {"t":"corta","q":"Escriba el plural de «lápiz».","pts":25,"c":["lápices"]}]' end;
      insert into campus_preguntas (item_id, colegio_id, preguntas) values (cq, c, pr);
      perform set_config('micolegia.preg', 'on', true);
      update campus_items set n_preg = 4, puntos = 100 where id = cq;
      perform set_config('micolegia.preg', '', true);
      -- entregas y calificaciones de ejemplo (el segundo estudiante de Quinto A es el perfil Estudiante: queda sin entregar)
      for i in 1 .. coalesce(array_length(es, 1), 0) loop
        continue when g.nombre = 'Quinto A' and i = 2;
        if i % 3 <> 0 then
          insert into campus_entregas (colegio_id, item_id, estudiante_id, texto, intentos, estado, entregado_en, entregado_nombre)
          values (c, tq, es[i], 'Aquí está mi trabajo. Los resultados quedaron en el cuaderno.', 1, 'Entregada', now() - (i || ' hours')::interval, 'Familia');
          if i % 2 = 1 then
            v := (array[65, 78, 85, 92, 100, 58, 88])[1 + i % 7];
            update campus_entregas set nota = v, estado = 'Calificada', comentario = case when v >= 92 then '¡Excelente trabajo!' when v >= 80 then 'Muy bien.' else 'Revise los ejercicios 3 y 4.' end,
                   calificado_en = now(), calificado_nombre = nm where item_id = tq and estudiante_id = es[i];
            perform priv.campus_a_calificaciones((select x from campus_items x where x.id = tq), es[i], v);
          end if;
          perform priv.dar_gemas(es[i], 'tarea', tq::text, 10);
        end if;
        if i % 2 = 0 then
          v := (array[75, 100, 50, 88])[1 + (i / 2) % 4];
          insert into campus_entregas (colegio_id, item_id, estudiante_id, intentos, nota, estado, entregado_en, entregado_nombre, calificado_en, calificado_nombre)
          values (c, cq, es[i], 1, v, 'Calificada', now() - (i || ' hours')::interval, 'Familia', now(), 'Calificación automática');
          perform priv.campus_a_calificaciones((select x from campus_items x where x.id = cq), es[i], v);
          perform priv.dar_gemas(es[i], 'cuestionario', cq::text, 5 + v / 10);
        end if;
      end loop;
    end loop;
    -- gemas de los últimos días para que el top del curso tenga movimiento
    for i in 1 .. coalesce(array_length(es, 1), 0) loop
      insert into gemas (colegio_id, estudiante_id, motivo, ref, cantidad, creado_en)
      select c, es[i], 'entrada', (hoy - d)::text, 3, ((hoy - d)::text || ' 07:30')::timestamp at time zone 'America/Bogota'
      from generate_series(1, 12) d where (d + i) % 4 <> 0 on conflict do nothing;
      if i % 4 = 1 then perform priv.dar_gemas(es[i], 'felicitacion', 'demo' || i, 15); end if;
    end loop;
  end loop;
end $$;
do $$
declare d text;
begin
  d := pg_get_functiondef('priv.crear_demo'::regproc);
  if position('demo_campus' in d) = 0 then
    d := replace(d, '  perform priv.demo_ajustes(c, a);', '  perform priv.demo_ajustes(c, a);' || chr(10) || '  perform priv.demo_campus(c, a);');
    if position('demo_campus' in d) = 0 then raise exception 'No se encontró dónde agregar el campus a la demostración'; end if;
    execute d;
  end if;
end $$;
-- Rehacer ya la demostración con el campus
select priv.crear_demo();

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
revoke execute on function public.campus_abrir(uuid, uuid), public.gemas_entrada(uuid), public.campus_cuestionario(uuid, uuid), public.campus_responder(uuid, uuid, jsonb),
  public.campus_entregar(uuid, uuid, text, text), public.campus_calificar(uuid, uuid, numeric, text), public.campus_guardar_preguntas(uuid, jsonb),
  public.gemas_resumen(uuid), public.gemas_grupo(uuid), public.gemas_participacion(uuid) from public;
grant execute on function public.campus_abrir(uuid, uuid), public.gemas_entrada(uuid), public.campus_cuestionario(uuid, uuid), public.campus_responder(uuid, uuid, jsonb),
  public.campus_entregar(uuid, uuid, text, text), public.campus_calificar(uuid, uuid, numeric, text), public.campus_guardar_preguntas(uuid, jsonb),
  public.gemas_resumen(uuid), public.gemas_grupo(uuid), public.gemas_participacion(uuid) to authenticated;
notify pgrst, 'reload schema';
