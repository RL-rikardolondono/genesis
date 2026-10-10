-- =====================================================================
-- Genesis · Esquema multicolegio (fase 1)
-- Postgres en Neon + Neon Auth + Data API con seguridad por fila (RLS)
-- Cada fila pertenece a un colegio; la base de datos decide quién ve qué.
-- =====================================================================

create extension if not exists pgcrypto;

create schema if not exists priv;          -- funciones internas (no expuestas por la Data API)
grant usage on schema priv to authenticated;

-- ---------------------------------------------------------------------
-- Tablas
-- ---------------------------------------------------------------------
create table if not exists public.plataforma_admins (
  user_id text primary key,
  creado_en timestamptz not null default now()
);

create table if not exists public.colegios (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  nit text, dane text, resolucion text, ciudad text, direccion text, telefono text,
  rector_nombre text, secretaria_nombre text,
  anio int not null default extract(year from now())::int,
  periodo_actual int not null default 1,
  max_perdidas int not null default 2,
  periodos jsonb not null default '[{"n":1,"peso":25},{"n":2,"peso":25},{"n":3,"peso":25},{"n":4,"peso":25}]',
  escala jsonb not null default '[{"d":"Bajo","min":1.0,"max":2.9},{"d":"Básico","min":3.0,"max":3.9},{"d":"Alto","min":4.0,"max":4.5},{"d":"Superior","min":4.6,"max":5.0}]',
  activo boolean not null default true,
  creado_en timestamptz not null default now()
);

create table if not exists public.grupos (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  nombre text not null,
  grado int not null check (grado between -2 and 11),
  nivel text not null check (nivel in ('preescolar','primaria','secundaria','media')),
  director_nombre text,
  creado_en timestamptz not null default now(),
  unique (colegio_id, nombre)
);

create table if not exists public.asignaturas (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  nivel text not null check (nivel in ('preescolar','primaria','secundaria','media')),
  codigo text not null,
  nombre text not null,
  ih int not null default 1 check (ih between 0 and 40),
  orden int not null default 0,
  unique (colegio_id, nivel, codigo)
);

create table if not exists public.estudiantes (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  grupo_id uuid references public.grupos(id) on delete set null,
  nombres text not null,
  apellidos text not null,
  tipo_doc text not null default 'TI' check (tipo_doc in ('RC','TI','CC','CE','PPT','NUIP')),
  doc text not null,
  fnac date,
  acudiente_nombre text,
  acudiente_tel text,
  folio int,
  matricula text,
  estado text not null default 'Activo' check (estado in ('Activo','Retirado')),
  piar boolean not null default false,
  creado_en timestamptz not null default now(),
  unique (colegio_id, doc)
);

create table if not exists public.miembros (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  user_id text,                                   -- se llena al activar la cuenta
  email text not null,
  nombre text not null,
  rol text not null check (rol in ('rector','coordinador','secretaria','docente','acudiente','estudiante')),
  estudiante_id uuid references public.estudiantes(id) on delete cascade,
  codigo text unique,                              -- código de activación
  activo boolean not null default true,
  creado_en timestamptz not null default now(),
  check ((rol in ('acudiente','estudiante')) = (estudiante_id is not null))
);
create unique index if not exists miembros_unicos
  on public.miembros (colegio_id, lower(email), rol, coalesce(estudiante_id, '00000000-0000-0000-0000-000000000000'::uuid));
create index if not exists miembros_user on public.miembros (user_id);

create table if not exists public.docente_grupos (
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  miembro_id uuid not null references public.miembros(id) on delete cascade,
  grupo_id uuid not null references public.grupos(id) on delete cascade,
  primary key (miembro_id, grupo_id)
);

create table if not exists public.notas (
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  asignatura_id uuid not null references public.asignaturas(id) on delete cascade,
  periodo int not null check (periodo between 1 and 6),
  valor numeric(2,1) not null check (valor between 1.0 and 5.0),
  actualizado_por text,
  actualizado_en timestamptz not null default now(),
  primary key (estudiante_id, asignatura_id, periodo)
);
create index if not exists notas_colegio on public.notas (colegio_id);

create table if not exists public.asistencia (
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  fecha date not null,
  estado char(1) not null check (estado in ('P','A','T','E')),
  actualizado_por text,
  primary key (estudiante_id, fecha)
);

create table if not exists public.observaciones (
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  periodo int not null check (periodo between 1 and 6),
  texto text not null default '',
  actualizado_por text,
  primary key (estudiante_id, periodo)
);

create index if not exists est_grupo on public.estudiantes (grupo_id);
create index if not exists est_colegio on public.estudiantes (colegio_id);

-- ---------------------------------------------------------------------
-- Funciones internas de seguridad
-- ---------------------------------------------------------------------
create or replace function priv.uid() returns text
language plpgsql stable as $$
begin
  return auth.user_id();
exception when others then
  return null;   -- sin JWT (por ejemplo, desde el editor SQL)
end $$;

-- ¿La operación viene de un usuario por la Data API (y no de una función del sistema)?
create or replace function priv.es_cliente() returns boolean
language sql stable as $$
  select priv.uid() is not null and coalesce(current_setting('micolegia.sistema', true), '') <> 'on'
$$;

create or replace function priv.es_superadmin() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from plataforma_admins where user_id = priv.uid())
$$;

create or replace function priv.roles_en(c uuid) returns text[]
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(array_agg(distinct m.rol), '{}')
  from miembros m join colegios k on k.id = m.colegio_id
  where m.colegio_id = c and m.user_id = priv.uid() and m.activo and k.activo
$$;

create or replace function priv.es_miembro(c uuid) returns boolean
language sql stable as $$ select cardinality(priv.roles_en(c)) > 0 $$;

create or replace function priv.es_directivo(c uuid) returns boolean
language sql stable as $$ select priv.roles_en(c) && array['rector','coordinador','secretaria'] $$;

create or replace function priv.es_rector(c uuid) returns boolean
language sql stable as $$ select 'rector' = any(priv.roles_en(c)) $$;

create or replace function priv.docente_de_grupo(g uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from docente_grupos dg
    join miembros m on m.id = dg.miembro_id
    join colegios k on k.id = m.colegio_id
    where dg.grupo_id = g and m.user_id = priv.uid() and m.activo and m.rol = 'docente' and k.activo)
$$;

create or replace function priv.puede_calificar(e uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from estudiantes s where s.id = e
                 and (priv.es_directivo(s.colegio_id) or priv.docente_de_grupo(s.grupo_id)))
$$;

create or replace function priv.puede_ver_estudiante(e uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select priv.puede_calificar(e) or exists (
    select 1 from miembros m join colegios k on k.id = m.colegio_id
    where m.estudiante_id = e and m.user_id = priv.uid() and m.activo and k.activo)
$$;

create or replace function priv.email_actual() returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select lower(email) from neon_auth."user" where id::text = priv.uid()
$$;

create or replace function priv.nuevo_codigo() returns text
language plpgsql volatile as $$
declare
  alfabeto constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  b bytea := gen_random_bytes(10);
  r text := '';
begin
  for i in 0..9 loop
    r := r || substr(alfabeto, (get_byte(b, i) % 32) + 1, 1);
  end loop;
  return r;
end $$;

grant execute on all functions in schema priv to authenticated;

-- ---------------------------------------------------------------------
-- Disparadores: el colegio de cada fila se deduce del padre (no del cliente)
-- ---------------------------------------------------------------------
create or replace function priv.tg_hijo_de_estudiante() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  select colegio_id into new.colegio_id from estudiantes where id = new.estudiante_id;
  if new.colegio_id is null then raise exception 'Estudiante no encontrado'; end if;
  if tg_table_name = 'notas' then
    if not exists (select 1 from asignaturas a where a.id = new.asignatura_id and a.colegio_id = new.colegio_id) then
      raise exception 'La asignatura no pertenece al colegio del estudiante';
    end if;
  end if;
  if priv.es_cliente() then new.actualizado_por := priv.uid(); end if;
  if tg_table_name = 'notas' then new.actualizado_en := now(); end if;
  return new;
end $$;

drop trigger if exists tg_notas on public.notas;
create trigger tg_notas before insert or update on public.notas for each row execute function priv.tg_hijo_de_estudiante();
drop trigger if exists tg_asistencia on public.asistencia;
create trigger tg_asistencia before insert or update on public.asistencia for each row execute function priv.tg_hijo_de_estudiante();
drop trigger if exists tg_observaciones on public.observaciones;
create trigger tg_observaciones before insert or update on public.observaciones for each row execute function priv.tg_hijo_de_estudiante();

create or replace function priv.tg_estudiantes() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare anio int;
begin
  if tg_op = 'UPDATE' then
    new.colegio_id := old.colegio_id; new.folio := old.folio; new.matricula := old.matricula;
  end if;
  if new.grupo_id is not null and not exists (select 1 from grupos g where g.id = new.grupo_id and g.colegio_id = new.colegio_id) then
    raise exception 'El grupo no pertenece al colegio';
  end if;
  if tg_op = 'INSERT' then
    perform pg_advisory_xact_lock(hashtext(new.colegio_id::text));
    select coalesce(max(folio), 0) + 1 into new.folio from estudiantes where colegio_id = new.colegio_id;
    select k.anio into anio from colegios k where k.id = new.colegio_id;
    new.matricula := anio || '-' || lpad(new.folio::text, 4, '0');
  end if;
  new.nombres := btrim(new.nombres); new.apellidos := btrim(new.apellidos); new.doc := btrim(new.doc);
  return new;
end $$;
drop trigger if exists tg_estudiantes on public.estudiantes;
create trigger tg_estudiantes before insert or update on public.estudiantes for each row execute function priv.tg_estudiantes();

create or replace function priv.tg_miembros() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  new.email := lower(btrim(new.email));
  if tg_op = 'INSERT' then
    if priv.es_cliente() then new.user_id := null; end if;
    new.codigo := priv.nuevo_codigo();
  else
    new.colegio_id := old.colegio_id;
    if priv.es_cliente() then new.user_id := old.user_id; new.codigo := old.codigo; end if;
    if new.email <> old.email then new.user_id := null; new.codigo := priv.nuevo_codigo(); end if;
  end if;
  if new.estudiante_id is not null and not exists (select 1 from estudiantes s where s.id = new.estudiante_id and s.colegio_id = new.colegio_id) then
    raise exception 'El estudiante no pertenece al colegio';
  end if;
  return new;
end $$;
drop trigger if exists tg_miembros on public.miembros;
create trigger tg_miembros before insert or update on public.miembros for each row execute function priv.tg_miembros();

create or replace function priv.tg_docente_grupos() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  select colegio_id into new.colegio_id from grupos where id = new.grupo_id;
  if not exists (select 1 from miembros m where m.id = new.miembro_id and m.colegio_id = new.colegio_id and m.rol = 'docente') then
    raise exception 'El docente no pertenece al colegio del grupo';
  end if;
  return new;
end $$;
drop trigger if exists tg_docente_grupos on public.docente_grupos;
create trigger tg_docente_grupos before insert or update on public.docente_grupos for each row execute function priv.tg_docente_grupos();

create or replace function priv.tg_colegio_fijo() returns trigger
language plpgsql as $$
begin new.colegio_id := old.colegio_id; return new; end $$;
drop trigger if exists tg_grupos_fijo on public.grupos;
create trigger tg_grupos_fijo before update on public.grupos for each row execute function priv.tg_colegio_fijo();
drop trigger if exists tg_asig_fijo on public.asignaturas;
create trigger tg_asig_fijo before update on public.asignaturas for each row execute function priv.tg_colegio_fijo();

create or replace function priv.tg_colegios() returns trigger
language plpgsql as $$
begin
  if priv.es_cliente() then new.activo := old.activo; new.id := old.id; end if;
  return new;
end $$;
drop trigger if exists tg_colegios on public.colegios;
create trigger tg_colegios before update on public.colegios for each row execute function priv.tg_colegios();

-- ---------------------------------------------------------------------
-- Permisos base y RLS
-- ---------------------------------------------------------------------
grant usage on schema public to authenticated;
revoke all on all tables in schema public from anonymous;
grant select, insert, update, delete on
  public.grupos, public.asignaturas, public.estudiantes, public.miembros,
  public.docente_grupos, public.notas, public.asistencia, public.observaciones
  to authenticated;
revoke all on public.colegios from authenticated;
grant select on public.colegios to authenticated;
grant update (nombre, nit, dane, resolucion, ciudad, direccion, telefono, rector_nombre, secretaria_nombre,
              anio, periodo_actual, max_perdidas, periodos, escala) on public.colegios to authenticated;
revoke all on public.plataforma_admins from authenticated;

alter table public.plataforma_admins enable row level security;
alter table public.colegios        enable row level security;
alter table public.grupos          enable row level security;
alter table public.asignaturas     enable row level security;
alter table public.estudiantes     enable row level security;
alter table public.miembros        enable row level security;
alter table public.docente_grupos  enable row level security;
alter table public.notas           enable row level security;
alter table public.asistencia      enable row level security;
alter table public.observaciones   enable row level security;

-- colegios
drop policy if exists colegios_ver on public.colegios;
create policy colegios_ver on public.colegios for select to authenticated
  using (priv.es_miembro(id) or priv.es_superadmin());
drop policy if exists colegios_editar on public.colegios;
create policy colegios_editar on public.colegios for update to authenticated
  using (priv.es_rector(id)) with check (priv.es_rector(id));

-- grupos y asignaturas: los ve cualquier miembro; los administran directivos
drop policy if exists grupos_ver on public.grupos;
create policy grupos_ver on public.grupos for select to authenticated using (priv.es_miembro(colegio_id));
drop policy if exists grupos_admin on public.grupos;
create policy grupos_admin on public.grupos for all to authenticated
  using (priv.es_directivo(colegio_id)) with check (priv.es_directivo(colegio_id));

drop policy if exists asig_ver on public.asignaturas;
create policy asig_ver on public.asignaturas for select to authenticated using (priv.es_miembro(colegio_id));
drop policy if exists asig_admin on public.asignaturas;
create policy asig_admin on public.asignaturas for all to authenticated
  using (priv.es_directivo(colegio_id)) with check (priv.es_directivo(colegio_id));

drop policy if exists dg_ver on public.docente_grupos;
create policy dg_ver on public.docente_grupos for select to authenticated using (priv.es_miembro(colegio_id));
drop policy if exists dg_admin on public.docente_grupos;
create policy dg_admin on public.docente_grupos for all to authenticated
  using (priv.es_directivo(colegio_id)) with check (priv.es_directivo(colegio_id));

-- miembros: cada quien ve su propia fila; directivos ven y administran las de su colegio
drop policy if exists miembros_ver on public.miembros;
create policy miembros_ver on public.miembros for select to authenticated
  using (user_id = priv.uid() or priv.es_directivo(colegio_id));
drop policy if exists miembros_admin on public.miembros;
create policy miembros_admin on public.miembros for all to authenticated
  using (priv.es_directivo(colegio_id)) with check (priv.es_directivo(colegio_id));
-- docentes necesitan ver nombres de docentes? No en fase 1.

-- estudiantes
drop policy if exists est_ver on public.estudiantes;
create policy est_ver on public.estudiantes for select to authenticated using (priv.puede_ver_estudiante(id));
drop policy if exists est_insertar on public.estudiantes;
create policy est_insertar on public.estudiantes for insert to authenticated with check (priv.es_directivo(colegio_id));
drop policy if exists est_editar on public.estudiantes;
create policy est_editar on public.estudiantes for update to authenticated
  using (priv.es_directivo(colegio_id)) with check (priv.es_directivo(colegio_id));
drop policy if exists est_borrar on public.estudiantes;
create policy est_borrar on public.estudiantes for delete to authenticated using (priv.es_rector(colegio_id));

-- notas, asistencia, observaciones
do $$
declare t text;
begin
  foreach t in array array['notas','asistencia','observaciones'] loop
    execute format('drop policy if exists %1$s_ver on public.%1$s', t);
    execute format('create policy %1$s_ver on public.%1$s for select to authenticated using (priv.puede_ver_estudiante(estudiante_id))', t);
    execute format('drop policy if exists %1$s_ins on public.%1$s', t);
    execute format('create policy %1$s_ins on public.%1$s for insert to authenticated with check (priv.puede_calificar(estudiante_id))', t);
    execute format('drop policy if exists %1$s_upd on public.%1$s', t);
    execute format('create policy %1$s_upd on public.%1$s for update to authenticated using (priv.puede_calificar(estudiante_id)) with check (priv.puede_calificar(estudiante_id))', t);
    execute format('drop policy if exists %1$s_del on public.%1$s', t);
    execute format('create policy %1$s_del on public.%1$s for delete to authenticated using (priv.puede_calificar(estudiante_id))', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Funciones RPC (expuestas en /rpc/...)
-- ---------------------------------------------------------------------
create or replace function public.precio_plan(n int) returns int
language sql immutable as $$
  select case when n <= 100 then 39000 when n <= 250 then 79000
              when n <= 500 then 139000 when n <= 1000 then 239000
              else 239000 + ceil((n - 1000) / 100.0)::int * 20000 end
$$;

create or replace function public.soy_superadmin() returns boolean
language sql stable as $$ select priv.es_superadmin() $$;

-- Activa la cuenta del usuario con el código que le entregó el colegio.
create or replace function public.activar_cuenta(p_codigo text) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare m miembros; correo text := priv.email_actual();
begin
  if priv.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  select * into m from miembros where codigo = upper(btrim(p_codigo)) and activo for update;
  if m.id is null then raise exception 'Código no válido'; end if;
  if m.user_id is not null and m.user_id <> priv.uid() then raise exception 'Este código ya fue usado'; end if;
  if m.email <> correo then raise exception 'Este código fue emitido para otro correo electrónico'; end if;
  perform set_config('micolegia.sistema', 'on', true);
  update miembros set user_id = priv.uid() where id = m.id;
  perform set_config('micolegia.sistema', '', true);
  return json_build_object('colegio', (select nombre from colegios where id = m.colegio_id), 'rol', m.rol);
end $$;

-- Vincula automáticamente invitaciones pendientes? No: se exige el código para evitar suplantación.

-- Regenera el código de activación de un miembro (lo pierde, cambia de correo, etc.)
create or replace function public.regenerar_codigo(p_miembro uuid) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare c uuid; nuevo text := priv.nuevo_codigo();
begin
  select colegio_id into c from miembros where id = p_miembro;
  if c is null or not priv.es_directivo(c) then raise exception 'Sin permiso'; end if;
  perform set_config('micolegia.sistema', 'on', true);
  update miembros set codigo = nuevo, user_id = null where id = p_miembro;
  perform set_config('micolegia.sistema', '', true);
  return nuevo;
end $$;

-- Plan de estudios base (del prototipo) para un colegio nuevo
create or replace function priv.plan_base(c uuid) returns void
language sql as $$
  insert into asignaturas (colegio_id, nivel, codigo, nombre, ih, orden)
  select c, x.nivel, x.codigo, x.nombre, x.ih, x.orden from (values
    ('preescolar','dco','Dimensión comunicativa',5,1),('preescolar','dcg','Dimensión cognitiva',5,2),
    ('preescolar','dcp','Dimensión corporal',4,3),('preescolar','des','Dimensión estética',3,4),
    ('preescolar','det','Dimensión ética',2,5),('preescolar','dsa','Dimensión socioafectiva',2,6),
    ('preescolar','dep','Dimensión espiritual',1,7),
    ('primaria','mat','Matemáticas',5,1),('primaria','len','Lengua castellana',5,2),('primaria','nat','Ciencias naturales',3,3),
    ('primaria','soc','Ciencias sociales',3,4),('primaria','ing','Inglés',2,5),('primaria','art','Educación artística',1,6),
    ('primaria','efi','Educación física',2,7),('primaria','eti','Ética y valores',1,8),('primaria','rel','Educación religiosa',1,9),
    ('primaria','tec','Tecnología e informática',2,10),
    ('secundaria','mat','Matemáticas',5,1),('secundaria','len','Lengua castellana',5,2),('secundaria','nat','Ciencias naturales',4,3),
    ('secundaria','soc','Ciencias sociales',4,4),('secundaria','ing','Inglés',3,5),('secundaria','art','Educación artística',1,6),
    ('secundaria','efi','Educación física',2,7),('secundaria','eti','Ética y valores',1,8),('secundaria','rel','Educación religiosa',1,9),
    ('secundaria','tec','Tecnología e informática',2,10),
    ('media','mat','Matemáticas',4,1),('media','len','Lengua castellana',4,2),('media','fis','Física',3,3),('media','qui','Química',3,4),
    ('media','fil','Filosofía',2,5),('media','soc','Ciencias sociales',2,6),('media','pol','Ciencias políticas y económicas',1,7),
    ('media','ing','Inglés',3,8),('media','efi','Educación física',2,9),('media','eti','Ética y valores',1,10),
    ('media','tec','Tecnología e informática',2,11)
  ) as x(nivel, codigo, nombre, ih, orden)
  on conflict do nothing
$$;

-- Alta de un colegio nuevo (solo administradores de la plataforma)
create or replace function public.crear_colegio(p_nombre text, p_ciudad text, p_rector_nombre text, p_rector_email text)
returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare c uuid; m miembros;
begin
  if not priv.es_superadmin() then raise exception 'Solo la administración de Genesis puede crear colegios'; end if;
  insert into colegios (nombre, ciudad, rector_nombre) values (btrim(p_nombre), p_ciudad, p_rector_nombre) returning id into c;
  perform priv.plan_base(c);
  insert into miembros (colegio_id, email, nombre, rol) values (c, p_rector_email, p_rector_nombre, 'rector') returning * into m;
  return json_build_object('colegio_id', c, 'codigo', m.codigo);
end $$;

-- Panel de la plataforma: colegios, estudiantes activos y valor mensual
create or replace function public.plataforma_resumen()
returns table (colegio_id uuid, nombre text, ciudad text, activo boolean, estudiantes_activos int, valor_mensual int, creado_en timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not priv.es_superadmin() then raise exception 'Sin permiso'; end if;
  return query
    select k.id, k.nombre, k.ciudad, k.activo,
           (select count(*)::int from estudiantes s where s.colegio_id = k.id and s.estado = 'Activo'),
           precio_plan((select count(*)::int from estudiantes s where s.colegio_id = k.id and s.estado = 'Activo')),
           k.creado_en
    from colegios k order by k.creado_en;
end $$;

create or replace function public.plataforma_activar_colegio(p_colegio uuid, p_activo boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not priv.es_superadmin() then raise exception 'Sin permiso'; end if;
  perform set_config('micolegia.sistema', 'on', true);
  update colegios set activo = p_activo where id = p_colegio;
  perform set_config('micolegia.sistema', '', true);
end $$;

-- Definitivas por estudiante y asignatura (respeta RLS: cada quien ve lo suyo)
create or replace function public.definitivas(p_colegio uuid, p_hasta int default 99)
returns table (estudiante_id uuid, asignatura_id uuid, definitiva numeric)
language sql stable as $$
  select n.estudiante_id, n.asignatura_id,
         round(sum(n.valor * p.peso) / nullif(sum(p.peso), 0), 1)
  from notas n
  join colegios k on k.id = n.colegio_id
  cross join lateral jsonb_to_recordset(k.periodos) as p(n int, peso numeric)
  where n.colegio_id = p_colegio and p.n = n.periodo and n.periodo <= p_hasta
  group by 1, 2
$$;

-- Resumen para el inicio de directivos
create or replace function public.resumen_colegio(p_colegio uuid) returns json
language plpgsql stable set search_path = public, pg_temp as $$
declare k colegios; bajo_hasta numeric; r json;
begin
  select * into k from colegios where id = p_colegio;
  if k.id is null or not priv.es_directivo(p_colegio) then raise exception 'Sin permiso'; end if;
  select min((e->>'min')::numeric) into bajo_hasta from jsonb_array_elements(k.escala) e where e->>'d' <> 'Bajo';
  with act as (select s.* from estudiantes s where s.colegio_id = p_colegio and s.estado = 'Activo'),
  gr as (select g.* from grupos g where g.colegio_id = p_colegio),
  esperadas as (select count(*) n from act join gr on gr.id = act.grupo_id join asignaturas a on a.colegio_id = p_colegio and a.nivel = gr.nivel),
  registradas as (select count(*) n from notas x join act on act.id = x.estudiante_id where x.periodo = k.periodo_actual),
  defs as (select d.* from definitivas(p_colegio) d join act on act.id = d.estudiante_id join gr on gr.id = act.grupo_id where gr.nivel <> 'preescolar'),
  riesgo as (
    select act.id, act.nombres || ' ' || act.apellidos as nombre, gr.nombre as grupo,
           array_agg(a.nombre order by a.orden) as asignaturas
    from defs d join act on act.id = d.estudiante_id join gr on gr.id = act.grupo_id join asignaturas a on a.id = d.asignatura_id
    where d.definitiva < bajo_hasta
    group by act.id, act.nombres, act.apellidos, gr.nombre
    having count(*) >= k.max_perdidas)
  select json_build_object(
    'activos', (select count(*) from act),
    'grupos', (select count(*) from gr),
    'piar', (select count(*) from act where piar),
    'esperadas', (select n from esperadas),
    'registradas', (select n from registradas),
    'valor_mensual', precio_plan((select count(*)::int from act)),
    'riesgo', coalesce((select json_agg(riesgo order by grupo, nombre) from riesgo), '[]'::json)
  ) into r;
  return r;
end $$;

revoke execute on function public.crear_colegio(text,text,text,text) from anonymous;
revoke execute on function public.activar_cuenta(text) from anonymous;
revoke execute on function public.plataforma_resumen() from anonymous;
revoke execute on function public.regenerar_codigo(uuid) from anonymous;
revoke execute on function public.plataforma_activar_colegio(uuid, boolean) from anonymous;
revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
