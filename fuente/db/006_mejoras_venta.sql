-- Genesis 006: datos personales (Ley 1581), docente por asignatura, cobro de suscripciones,
-- año lectivo al crear colegio, observador del estudiante y logros del boletín.

-- 1) Autorización de tratamiento de datos personales (Ley 1581 de 2012, Decreto 1377 de 2013)
alter table public.estudiantes add column if not exists autoriza_datos boolean not null default false;
alter table public.estudiantes add column if not exists autoriza_imagen boolean not null default false;
alter table public.estudiantes add column if not exists autoriza_fecha date;
alter table public.estudiantes add column if not exists autoriza_por text;
alter table public.colegios add column if not exists politica_datos text;
grant update (politica_datos) on public.colegios to authenticated;

-- 2) Docente por asignatura: asignatura_id nulo = todas las asignaturas del grupo
alter table public.docente_grupos add column if not exists asignatura_id uuid references public.asignaturas(id) on delete cascade;
alter table public.docente_grupos drop constraint if exists docente_grupos_pkey;
alter table public.docente_grupos add column if not exists id uuid not null default gen_random_uuid();
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'docente_grupos_id_pk') then
    alter table public.docente_grupos add constraint docente_grupos_id_pk primary key (id);
  end if;
end $$;
create unique index if not exists docente_grupos_unico
  on public.docente_grupos (miembro_id, grupo_id, coalesce(asignatura_id, '00000000-0000-0000-0000-000000000000'::uuid));

create or replace function priv.tg_docente_grupos() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare niv text;
begin
  select colegio_id, nivel into new.colegio_id, niv from grupos where id = new.grupo_id;
  if not exists (select 1 from miembros m where m.id = new.miembro_id and m.colegio_id = new.colegio_id and m.rol = 'docente') then
    raise exception 'El docente no pertenece al colegio del grupo';
  end if;
  if new.asignatura_id is not null and not exists (
       select 1 from asignaturas a where a.id = new.asignatura_id and a.colegio_id = new.colegio_id and a.nivel = niv) then
    raise exception 'La asignatura no corresponde al nivel del grupo';
  end if;
  return new;
end $$;

create or replace function priv.docente_de_asig(g uuid, a uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from docente_grupos dg
    join miembros m on m.id = dg.miembro_id
    join colegios k on k.id = m.colegio_id
    where dg.grupo_id = g and (dg.asignatura_id is null or dg.asignatura_id = a)
      and m.user_id = priv.uid() and m.activo and m.rol = 'docente' and k.activo)
$$;

create or replace function priv.puede_calificar_asig(e uuid, a uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from estudiantes s where s.id = e
                 and (priv.es_directivo(s.colegio_id) or priv.docente_de_asig(s.grupo_id, a)))
$$;

drop policy if exists notas_ins on public.notas;
create policy notas_ins on public.notas for insert to authenticated with check (priv.puede_calificar_asig(estudiante_id, asignatura_id));
drop policy if exists notas_upd on public.notas;
create policy notas_upd on public.notas for update to authenticated
  using (priv.puede_calificar_asig(estudiante_id, asignatura_id)) with check (priv.puede_calificar_asig(estudiante_id, asignatura_id));
drop policy if exists notas_del on public.notas;
create policy notas_del on public.notas for delete to authenticated using (priv.puede_calificar_asig(estudiante_id, asignatura_id));

-- 3) Pagos de la suscripción de cada colegio (solo administración de Genesis)
create table if not exists public.plataforma_pagos (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  mes date not null,
  valor int not null check (valor > 0),
  fecha date not null default current_date,
  medio text,
  referencia text,
  registrado_en timestamptz not null default now(),
  unique (colegio_id, mes)
);
alter table public.plataforma_pagos enable row level security;
grant select, insert, delete on public.plataforma_pagos to authenticated;
drop policy if exists pp_admin on public.plataforma_pagos;
create policy pp_admin on public.plataforma_pagos for all to authenticated
  using (priv.es_superadmin()) with check (priv.es_superadmin());

-- Meses de suscripción: desde el mes de creación hasta el mes actual
create or replace function priv.meses_pendientes(c uuid) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select count(*)::int
  from colegios k
  cross join lateral generate_series(date_trunc('month', k.creado_en)::date, date_trunc('month', current_date)::date, interval '1 month') g(m)
  where k.id = c and not exists (select 1 from plataforma_pagos p where p.colegio_id = c and p.mes = g.m::date)
$$;

drop function if exists public.plataforma_resumen();
create or replace function public.plataforma_resumen()
returns table (colegio_id uuid, nombre text, ciudad text, activo boolean, estudiantes_activos int, valor_mensual int,
               creado_en timestamptz, anio int, pagado_hasta date, meses_pendientes int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not priv.es_superadmin() then raise exception 'Sin permiso'; end if;
  return query
    select k.id, k.nombre, k.ciudad, k.activo,
           (select count(*)::int from estudiantes s where s.colegio_id = k.id and s.estado = 'Activo'),
           precio_plan((select count(*)::int from estudiantes s where s.colegio_id = k.id and s.estado = 'Activo')),
           k.creado_en, k.anio,
           (select max(p.mes) from plataforma_pagos p where p.colegio_id = k.id),
           priv.meses_pendientes(k.id)
    from colegios k order by k.creado_en;
end $$;
revoke execute on function public.plataforma_resumen() from anonymous;

-- El rector ve el estado de su suscripción
create or replace function public.mi_suscripcion(p_colegio uuid) returns json
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not priv.es_directivo(p_colegio) then raise exception 'Sin permiso'; end if;
  return json_build_object(
    'pagado_hasta', (select max(mes) from plataforma_pagos where colegio_id = p_colegio),
    'meses_pendientes', priv.meses_pendientes(p_colegio),
    'ultimos', coalesce((select json_agg(json_build_object('mes', mes, 'valor', valor, 'fecha', fecha) order by mes desc)
                         from (select * from plataforma_pagos where colegio_id = p_colegio order by mes desc limit 6) x), '[]'::json));
end $$;
revoke execute on function public.mi_suscripcion(uuid) from anonymous;

-- 4) Año lectivo al crear el colegio
drop function if exists public.crear_colegio(text, text, text, text);
create or replace function public.crear_colegio(p_nombre text, p_ciudad text, p_rector_nombre text, p_rector_email text, p_anio int default null)
returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare c uuid; m miembros; a int := coalesce(p_anio, extract(year from current_date)::int);
begin
  if not priv.es_superadmin() then raise exception 'Solo la administración de Genesis puede crear colegios'; end if;
  if a < 2020 or a > 2100 then raise exception 'Año lectivo no válido'; end if;
  insert into colegios (nombre, ciudad, rector_nombre, anio) values (btrim(p_nombre), p_ciudad, p_rector_nombre, a) returning id into c;
  perform priv.plan_base(c);
  perform priv.conceptos_base(c, a);
  insert into miembros (colegio_id, email, nombre, rol) values (c, p_rector_email, p_rector_nombre, 'rector') returning * into m;
  return json_build_object('colegio_id', c, 'codigo', m.codigo, 'anio', a);
end $$;
revoke execute on function public.crear_colegio(text, text, text, text, int) from anonymous;

-- 6) Observador del estudiante
create table if not exists public.observador (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  anio int not null,
  fecha date not null default current_date,
  tipo text not null default 'Convivencia' check (tipo in ('Positiva','Convivencia','Académica','Compromiso','Citación a acudiente')),
  descripcion text not null,
  compromiso text,
  seguimiento text,
  creado_por text,
  autor_nombre text,
  creado_en timestamptz not null default now()
);
create index if not exists observador_est on public.observador (estudiante_id, anio);

create or replace function priv.tg_observador() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    select s.colegio_id, k.anio into new.colegio_id, new.anio from estudiantes s join colegios k on k.id = s.colegio_id where s.id = new.estudiante_id;
    new.creado_por := priv.uid();
    select coalesce(max(m.nombre), 'Sistema') into new.autor_nombre
      from miembros m where m.colegio_id = new.colegio_id and m.user_id = priv.uid() and m.rol <> 'acudiente' and m.rol <> 'estudiante';
  else
    new.colegio_id := old.colegio_id; new.estudiante_id := old.estudiante_id; new.anio := old.anio;
    new.creado_por := old.creado_por; new.autor_nombre := old.autor_nombre; new.creado_en := old.creado_en;
  end if;
  return new;
end $$;
drop trigger if exists tg_observador on public.observador;
create trigger tg_observador before insert or update on public.observador for each row execute function priv.tg_observador();

alter table public.observador enable row level security;
grant select, insert, update, delete on public.observador to authenticated;
drop policy if exists obsv_ver on public.observador;
create policy obsv_ver on public.observador for select to authenticated using (priv.puede_ver_estudiante(estudiante_id));
drop policy if exists obsv_ins on public.observador;
create policy obsv_ins on public.observador for insert to authenticated with check (priv.puede_calificar(estudiante_id));
drop policy if exists obsv_upd on public.observador;
create policy obsv_upd on public.observador for update to authenticated
  using (priv.es_directivo(colegio_id) or creado_por = priv.uid()) with check (priv.es_directivo(colegio_id) or creado_por = priv.uid());
drop policy if exists obsv_del on public.observador;
create policy obsv_del on public.observador for delete to authenticated using (priv.es_directivo(colegio_id) or creado_por = priv.uid());

-- 7) Logros del periodo por grupo y asignatura (aparecen en el boletín)
create table if not exists public.logros (
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  grupo_id uuid not null references public.grupos(id) on delete cascade,
  asignatura_id uuid not null references public.asignaturas(id) on delete cascade,
  anio int not null,
  periodo int not null check (periodo between 1 and 6),
  texto text not null,
  primary key (grupo_id, asignatura_id, anio, periodo)
);
create or replace function priv.tg_logros() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  select colegio_id into new.colegio_id from grupos where id = new.grupo_id;
  return new;
end $$;
drop trigger if exists tg_logros on public.logros;
create trigger tg_logros before insert or update on public.logros for each row execute function priv.tg_logros();
alter table public.logros enable row level security;
grant select, insert, update, delete on public.logros to authenticated;
drop policy if exists logros_ver on public.logros;
create policy logros_ver on public.logros for select to authenticated using (priv.es_miembro(colegio_id));
drop policy if exists logros_esc on public.logros;
create policy logros_esc on public.logros for all to authenticated
  using (priv.es_directivo(colegio_id) or priv.docente_de_asig(grupo_id, asignatura_id))
  with check (priv.docente_de_asig(grupo_id, asignatura_id) or exists (select 1 from grupos g where g.id = grupo_id and priv.es_directivo(g.colegio_id)));

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
