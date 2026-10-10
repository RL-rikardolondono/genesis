-- Genesis 008: notas por actividades, cierre de notas por fecha, comunicados con lectura,
-- recuperaciones, registro de cambios de notas, asistencia por clase, director de grupo,
-- excusas, comprobantes de pago, tareas y horario.

-- ---------- Utilidades ----------
-- Estudiantes de la familia del usuario actual
create or replace function priv.mis_estudiantes() returns setof uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select m.estudiante_id from miembros m join colegios k on k.id = m.colegio_id
  where m.user_id = priv.uid() and m.activo and k.activo and m.estudiante_id is not null
$$;
create or replace function priv.es_personal(c uuid) returns boolean
language sql stable as $$ select priv.roles_en(c) && array['rector','coordinador','secretaria','docente','tesoreria'] $$;
create or replace function priv.nombre_actual(c uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(max(m.nombre), 'Sistema') from miembros m
  where m.colegio_id = c and m.user_id = priv.uid() and m.rol not in ('acudiente','estudiante')
$$;

-- ---------- Director de grupo vinculado a un docente ----------
alter table public.grupos add column if not exists director_miembro_id uuid references public.miembros(id) on delete set null;
create or replace function priv.docente_de_grupo(g uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from docente_grupos dg
    join miembros m on m.id = dg.miembro_id
    join colegios k on k.id = m.colegio_id
    where dg.grupo_id = g and m.user_id = priv.uid() and m.activo and m.rol = 'docente' and k.activo)
  or exists (
    select 1 from grupos gr join miembros m on m.id = gr.director_miembro_id join colegios k on k.id = m.colegio_id
    where gr.id = g and m.user_id = priv.uid() and m.activo and k.activo)
$$;

-- ---------- Calendario: fechas por periodo dentro de colegios.periodos ----------
-- Cada periodo puede traer "cierre" (fecha límite para digitar notas, AAAA-MM-DD).
create or replace function priv.notas_abiertas(c uuid, p int) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select priv.es_directivo(c) or coalesce((
    select current_date <= (x->>'cierre')::date
    from colegios k, jsonb_array_elements(k.periodos) x
    where k.id = c and (x->>'n')::int = p and coalesce(x->>'cierre', '') <> ''), true)
$$;

drop policy if exists notas_ins on public.notas;
create policy notas_ins on public.notas for insert to authenticated
  with check (priv.puede_calificar_asig(estudiante_id, asignatura_id) and priv.notas_abiertas(colegio_id, periodo));
drop policy if exists notas_upd on public.notas;
create policy notas_upd on public.notas for update to authenticated
  using (priv.puede_calificar_asig(estudiante_id, asignatura_id) and priv.notas_abiertas(colegio_id, periodo))
  with check (priv.puede_calificar_asig(estudiante_id, asignatura_id) and priv.notas_abiertas(colegio_id, periodo));
drop policy if exists notas_del on public.notas;
create policy notas_del on public.notas for delete to authenticated
  using (priv.puede_calificar_asig(estudiante_id, asignatura_id) and priv.notas_abiertas(colegio_id, periodo));

-- ---------- Registro de cambios de notas ----------
create table if not exists public.notas_log (
  id bigserial primary key,
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null,
  asignatura_id uuid not null,
  anio int, periodo int,
  antes numeric(2,1), despues numeric(2,1),
  usuario text, nombre text,
  fecha timestamptz not null default now()
);
create index if not exists notas_log_est on public.notas_log (colegio_id, estudiante_id);
create or replace function priv.tg_notas_log() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record;
begin
  if tg_op = 'DELETE' then r := old; else r := new; end if;
  if tg_op = 'UPDATE' and old.valor = new.valor then return null; end if;
  if not exists (select 1 from colegios where id = r.colegio_id) then return null; end if; -- colegio eliminado
  insert into notas_log (colegio_id, estudiante_id, asignatura_id, anio, periodo, antes, despues, usuario, nombre)
  values (r.colegio_id, r.estudiante_id, r.asignatura_id, r.anio, r.periodo,
          case when tg_op = 'INSERT' then null else old.valor end,
          case when tg_op = 'DELETE' then null else new.valor end,
          priv.uid(), priv.nombre_actual(r.colegio_id));
  return null;
end $$;
drop trigger if exists tg_notas_log on public.notas;
create trigger tg_notas_log after insert or update or delete on public.notas for each row execute function priv.tg_notas_log();
alter table public.notas_log enable row level security;
grant select on public.notas_log to authenticated;
grant usage on sequence public.notas_log_id_seq to authenticated;
drop policy if exists nlog_ver on public.notas_log;
create policy nlog_ver on public.notas_log for select to authenticated using (priv.es_directivo(colegio_id));

-- ---------- Notas por actividades ----------
create table if not exists public.actividades (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  grupo_id uuid not null references public.grupos(id) on delete cascade,
  asignatura_id uuid not null references public.asignaturas(id) on delete cascade,
  anio int not null,
  periodo int not null check (periodo between 1 and 6),
  nombre text not null,
  peso numeric(5,2) not null default 0 check (peso >= 0 and peso <= 100),
  fecha date,
  orden int not null default 0,
  creado_en timestamptz not null default now()
);
create index if not exists actividades_gap on public.actividades (grupo_id, asignatura_id, anio, periodo);
create table if not exists public.notas_act (
  actividad_id uuid not null references public.actividades(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  valor numeric(2,1) not null check (valor between 1.0 and 5.0),
  primary key (actividad_id, estudiante_id)
);
create or replace function priv.tg_actividades() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin select colegio_id into new.colegio_id from grupos where id = new.grupo_id; return new; end $$;
drop trigger if exists tg_actividades on public.actividades;
create trigger tg_actividades before insert or update on public.actividades for each row execute function priv.tg_actividades();
create or replace function priv.tg_notas_act() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin select colegio_id into new.colegio_id from actividades where id = new.actividad_id; return new; end $$;
drop trigger if exists tg_notas_act on public.notas_act;
create trigger tg_notas_act before insert or update on public.notas_act for each row execute function priv.tg_notas_act();
create or replace function priv.puede_actividad(a uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from actividades x where x.id = a
    and (priv.es_directivo(x.colegio_id) or priv.docente_de_asig(x.grupo_id, x.asignatura_id))
    and priv.notas_abiertas(x.colegio_id, x.periodo))
$$;
alter table public.actividades enable row level security;
alter table public.notas_act enable row level security;
grant select, insert, update, delete on public.actividades, public.notas_act to authenticated;
drop policy if exists act_ver on public.actividades;
create policy act_ver on public.actividades for select to authenticated using (priv.es_miembro(colegio_id));
drop policy if exists act_esc on public.actividades;
create policy act_esc on public.actividades for all to authenticated
  using (priv.es_directivo(colegio_id) or priv.docente_de_asig(grupo_id, asignatura_id))
  with check (exists (select 1 from grupos g where g.id = grupo_id and (priv.es_directivo(g.colegio_id) or priv.docente_de_asig(grupo_id, asignatura_id))));
drop policy if exists nact_ver on public.notas_act;
create policy nact_ver on public.notas_act for select to authenticated using (priv.puede_ver_estudiante(estudiante_id));
drop policy if exists nact_esc on public.notas_act;
create policy nact_esc on public.notas_act for all to authenticated
  using (priv.puede_actividad(actividad_id)) with check (priv.puede_actividad(actividad_id));

-- ---------- Recuperaciones (Decreto 1290) ----------
create table if not exists public.recuperaciones (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  asignatura_id uuid not null references public.asignaturas(id) on delete cascade,
  anio int not null,
  periodo int not null check (periodo between 1 and 6),
  plan text not null,
  fecha date,
  nota numeric(2,1) check (nota between 1.0 and 5.0),
  registrado_por text,
  creado_en timestamptz not null default now(),
  unique (estudiante_id, asignatura_id, anio, periodo)
);
create or replace function priv.tg_recuperaciones() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  select colegio_id into new.colegio_id from estudiantes where id = new.estudiante_id;
  new.registrado_por := priv.nombre_actual(new.colegio_id);
  return new;
end $$;
drop trigger if exists tg_recuperaciones on public.recuperaciones;
create trigger tg_recuperaciones before insert or update on public.recuperaciones for each row execute function priv.tg_recuperaciones();
alter table public.recuperaciones enable row level security;
grant select, insert, update, delete on public.recuperaciones to authenticated;
drop policy if exists rec_ver on public.recuperaciones;
create policy rec_ver on public.recuperaciones for select to authenticated using (priv.puede_ver_estudiante(estudiante_id));
drop policy if exists rec_esc on public.recuperaciones;
create policy rec_esc on public.recuperaciones for all to authenticated
  using (priv.puede_calificar_asig(estudiante_id, asignatura_id)) with check (priv.puede_calificar_asig(estudiante_id, asignatura_id));

-- ---------- Asistencia por clase ----------
alter table public.colegios add column if not exists asistencia_por_clase boolean not null default false;
grant update (asistencia_por_clase) on public.colegios to authenticated;
create table if not exists public.asistencia_clase (
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  asignatura_id uuid not null references public.asignaturas(id) on delete cascade,
  fecha date not null,
  estado char(1) not null check (estado in ('A','T','E')),
  primary key (estudiante_id, asignatura_id, fecha)
);
create or replace function priv.tg_asis_clase() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin select colegio_id into new.colegio_id from estudiantes where id = new.estudiante_id; return new; end $$;
drop trigger if exists tg_asis_clase on public.asistencia_clase;
create trigger tg_asis_clase before insert or update on public.asistencia_clase for each row execute function priv.tg_asis_clase();
alter table public.asistencia_clase enable row level security;
grant select, insert, update, delete on public.asistencia_clase to authenticated;
drop policy if exists ac_ver on public.asistencia_clase;
create policy ac_ver on public.asistencia_clase for select to authenticated using (priv.puede_ver_estudiante(estudiante_id));
drop policy if exists ac_esc on public.asistencia_clase;
create policy ac_esc on public.asistencia_clase for all to authenticated
  using (priv.puede_calificar_asig(estudiante_id, asignatura_id)) with check (priv.puede_calificar_asig(estudiante_id, asignatura_id));

-- ---------- Comunicados y lecturas ----------
create table if not exists public.comunicados (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  tipo text not null default 'Circular' check (tipo in ('Circular','Citación','Recordatorio','Evento')),
  titulo text not null,
  cuerpo text not null,
  destino text not null default 'todos' check (destino in ('todos','grupo','estudiante')),
  grupo_id uuid references public.grupos(id) on delete cascade,
  estudiante_id uuid references public.estudiantes(id) on delete cascade,
  fecha_evento timestamptz,
  requiere_confirmacion boolean not null default true,
  creado_por text,
  autor_nombre text,
  creado_en timestamptz not null default now()
);
create index if not exists comunicados_col on public.comunicados (colegio_id, creado_en desc);
create table if not exists public.lecturas (
  comunicado_id uuid not null references public.comunicados(id) on delete cascade,
  user_id text not null,
  nombre text,
  leido_en timestamptz not null default now(),
  primary key (comunicado_id, user_id)
);
create or replace function priv.tg_comunicados() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then new.creado_por := priv.uid(); new.autor_nombre := priv.nombre_actual(new.colegio_id); end if;
  if new.destino = 'grupo' and new.grupo_id is null then raise exception 'Elija el curso'; end if;
  if new.destino = 'estudiante' and new.estudiante_id is null then raise exception 'Elija el estudiante'; end if;
  return new;
end $$;
drop trigger if exists tg_comunicados on public.comunicados;
create trigger tg_comunicados before insert or update on public.comunicados for each row execute function priv.tg_comunicados();
create or replace function priv.ve_comunicado(c public.comunicados) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select priv.es_personal(c.colegio_id) or (priv.es_miembro(c.colegio_id) and (
    c.destino = 'todos'
    or (c.destino = 'grupo' and exists (select 1 from estudiantes s where s.grupo_id = c.grupo_id and s.id in (select priv.mis_estudiantes())))
    or (c.destino = 'estudiante' and c.estudiante_id in (select priv.mis_estudiantes()))))
$$;
create or replace function priv.puede_comunicar(c uuid, g uuid, e uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select priv.es_directivo(c)
    or (g is not null and priv.docente_de_grupo(g))
    or (e is not null and priv.puede_calificar(e))
$$;
alter table public.comunicados enable row level security;
alter table public.lecturas enable row level security;
grant select, insert, update, delete on public.comunicados to authenticated;
grant select, insert on public.lecturas to authenticated;
drop policy if exists com_ver on public.comunicados;
create policy com_ver on public.comunicados for select to authenticated using (priv.ve_comunicado(comunicados));
drop policy if exists com_ins on public.comunicados;
create policy com_ins on public.comunicados for insert to authenticated with check (priv.puede_comunicar(colegio_id, grupo_id, estudiante_id));
drop policy if exists com_mod on public.comunicados;
create policy com_mod on public.comunicados for update to authenticated
  using (priv.es_directivo(colegio_id) or creado_por = priv.uid()) with check (priv.es_directivo(colegio_id) or creado_por = priv.uid());
drop policy if exists com_del on public.comunicados;
create policy com_del on public.comunicados for delete to authenticated using (priv.es_directivo(colegio_id) or creado_por = priv.uid());
drop policy if exists lec_ins on public.lecturas;
create policy lec_ins on public.lecturas for insert to authenticated
  with check (user_id = priv.uid() and exists (select 1 from comunicados c where c.id = comunicado_id and priv.ve_comunicado(c)));
drop policy if exists lec_ver on public.lecturas;
create policy lec_ver on public.lecturas for select to authenticated
  using (user_id = priv.uid() or exists (select 1 from comunicados c where c.id = comunicado_id and priv.es_personal(c.colegio_id)));

-- ---------- Excusas de inasistencia ----------
create table if not exists public.excusas (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  desde date not null,
  hasta date not null,
  motivo text not null,
  soporte text check (soporte is null or length(soporte) < 600000),
  estado text not null default 'Pendiente' check (estado in ('Pendiente','Aprobada','Rechazada')),
  respuesta text,
  enviada_por text,
  revisada_por text,
  creado_en timestamptz not null default now(),
  check (hasta >= desde)
);
create or replace function priv.tg_excusas() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    select colegio_id into new.colegio_id from estudiantes where id = new.estudiante_id;
    new.enviada_por := (select coalesce(max(m.nombre), '') from miembros m where m.user_id = priv.uid() and m.estudiante_id = new.estudiante_id);
    new.estado := 'Pendiente'; new.revisada_por := null; new.respuesta := null;
  else
    if not priv.puede_calificar(old.estudiante_id) then raise exception 'Sin permiso'; end if;
    new.colegio_id := old.colegio_id; new.estudiante_id := old.estudiante_id; new.desde := old.desde; new.hasta := old.hasta;
    new.motivo := old.motivo; new.soporte := old.soporte; new.enviada_por := old.enviada_por;
    new.revisada_por := priv.nombre_actual(old.colegio_id);
  end if;
  return new;
end $$;
drop trigger if exists tg_excusas on public.excusas;
create trigger tg_excusas before insert or update on public.excusas for each row execute function priv.tg_excusas();
alter table public.excusas enable row level security;
grant select, insert, update on public.excusas to authenticated;
drop policy if exists exc_ver on public.excusas;
create policy exc_ver on public.excusas for select to authenticated using (priv.puede_ver_estudiante(estudiante_id));
drop policy if exists exc_ins on public.excusas;
create policy exc_ins on public.excusas for insert to authenticated
  with check (estudiante_id in (select priv.mis_estudiantes()) or priv.puede_calificar(estudiante_id));
drop policy if exists exc_upd on public.excusas;
create policy exc_upd on public.excusas for update to authenticated
  using (priv.puede_calificar(estudiante_id)) with check (priv.puede_calificar(estudiante_id));

-- ---------- Comprobantes de pago enviados por la familia ----------
create table if not exists public.comprobantes (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  fecha date not null default current_date,
  valor numeric(12,0) not null check (valor > 0),
  medio text,
  referencia text,
  imagen text check (imagen is null or length(imagen) < 600000),
  nota text,
  estado text not null default 'Pendiente' check (estado in ('Pendiente','Confirmado','Rechazado')),
  respuesta text,
  enviado_por text,
  revisado_por text,
  creado_en timestamptz not null default now()
);
create or replace function priv.tg_comprobantes() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    select colegio_id into new.colegio_id from estudiantes where id = new.estudiante_id;
    new.enviado_por := (select coalesce(max(m.nombre), '') from miembros m where m.user_id = priv.uid() and m.estudiante_id = new.estudiante_id);
    new.estado := 'Pendiente'; new.revisado_por := null; new.respuesta := null;
  else
    if not priv.maneja_pagos(old.colegio_id) then raise exception 'Sin permiso'; end if;
    new.colegio_id := old.colegio_id; new.estudiante_id := old.estudiante_id; new.valor := old.valor; new.imagen := old.imagen;
    new.fecha := old.fecha; new.medio := old.medio; new.referencia := old.referencia; new.enviado_por := old.enviado_por;
    new.revisado_por := priv.nombre_actual(old.colegio_id);
  end if;
  return new;
end $$;
drop trigger if exists tg_comprobantes on public.comprobantes;
create trigger tg_comprobantes before insert or update on public.comprobantes for each row execute function priv.tg_comprobantes();
alter table public.comprobantes enable row level security;
grant select, insert, update on public.comprobantes to authenticated;
drop policy if exists cmp_ver on public.comprobantes;
create policy cmp_ver on public.comprobantes for select to authenticated
  using (priv.maneja_pagos(colegio_id) or estudiante_id in (select priv.mis_estudiantes()));
drop policy if exists cmp_ins on public.comprobantes;
create policy cmp_ins on public.comprobantes for insert to authenticated with check (estudiante_id in (select priv.mis_estudiantes()));
drop policy if exists cmp_upd on public.comprobantes;
create policy cmp_upd on public.comprobantes for update to authenticated
  using (priv.maneja_pagos(colegio_id)) with check (priv.maneja_pagos(colegio_id));

-- ---------- Tareas ----------
create table if not exists public.tareas (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  grupo_id uuid not null references public.grupos(id) on delete cascade,
  asignatura_id uuid not null references public.asignaturas(id) on delete cascade,
  titulo text not null,
  descripcion text,
  fecha_entrega date not null,
  creado_por text,
  autor_nombre text,
  creado_en timestamptz not null default now()
);
create index if not exists tareas_grupo on public.tareas (grupo_id, fecha_entrega);
create or replace function priv.tg_tareas() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  select colegio_id into new.colegio_id from grupos where id = new.grupo_id;
  if tg_op = 'INSERT' then new.creado_por := priv.uid(); new.autor_nombre := priv.nombre_actual(new.colegio_id); end if;
  return new;
end $$;
drop trigger if exists tg_tareas on public.tareas;
create trigger tg_tareas before insert or update on public.tareas for each row execute function priv.tg_tareas();
alter table public.tareas enable row level security;
grant select, insert, update, delete on public.tareas to authenticated;
drop policy if exists tar_ver on public.tareas;
create policy tar_ver on public.tareas for select to authenticated using (
  priv.es_personal(colegio_id) or exists (select 1 from estudiantes s where s.grupo_id = tareas.grupo_id and s.id in (select priv.mis_estudiantes())));
drop policy if exists tar_esc on public.tareas;
create policy tar_esc on public.tareas for all to authenticated
  using (priv.es_directivo(colegio_id) or priv.docente_de_asig(grupo_id, asignatura_id))
  with check (exists (select 1 from grupos g where g.id = grupo_id and (priv.es_directivo(g.colegio_id) or priv.docente_de_asig(grupo_id, asignatura_id))));

-- ---------- Horario de clases ----------
create table if not exists public.horario (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  grupo_id uuid not null references public.grupos(id) on delete cascade,
  dia int not null check (dia between 1 and 6),
  bloque int not null check (bloque between 1 and 12),
  hora text,
  asignatura_id uuid references public.asignaturas(id) on delete cascade,
  docente text,
  unique (grupo_id, dia, bloque)
);
create or replace function priv.tg_horario() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin select colegio_id into new.colegio_id from grupos where id = new.grupo_id; return new; end $$;
drop trigger if exists tg_horario on public.horario;
create trigger tg_horario before insert or update on public.horario for each row execute function priv.tg_horario();
alter table public.horario enable row level security;
grant select, insert, update, delete on public.horario to authenticated;
drop policy if exists hor_ver on public.horario;
create policy hor_ver on public.horario for select to authenticated using (priv.es_miembro(colegio_id));
drop policy if exists hor_esc on public.horario;
create policy hor_esc on public.horario for all to authenticated
  using (priv.es_directivo(colegio_id)) with check (exists (select 1 from grupos g where g.id = grupo_id and priv.es_directivo(g.colegio_id)));

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
