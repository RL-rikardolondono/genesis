-- Genesis-IA 018 (etapa 2): fotos en comunicados, galería semanal de clase, carnet digital con foto,
-- contactos de emergencia y personas autorizadas para recoger, redes sociales del colegio.
-- El cronograma usa los comunicados con fecha de evento (no necesita tabla nueva).

-- 1) Comunicados con una foto (liviana). Las fotos de comunicados se borran solas a los 15 días.
alter table public.comunicados add column if not exists imagen text;
alter table public.comunicados drop constraint if exists comunicados_imagen_liviana;
alter table public.comunicados add constraint comunicados_imagen_liviana check (imagen is null or (length(imagen) < 250000 and imagen ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$'));
alter table public.comunicados add column if not exists con_imagen boolean generated always as (imagen is not null) stored;
create or replace function priv.tg_comunicados() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    new.creado_por := priv.uid(); new.autor_nombre := priv.nombre_actual(new.colegio_id);
    update comunicados set imagen = null
     where colegio_id = new.colegio_id and imagen is not null and creado_en < now() - interval '15 days';
  elsif pg_trigger_depth() > 1 then
    new := old; new.imagen := null; return new;
  end if;
  if new.destino = 'grupo' and new.grupo_id is null then raise exception 'Elija el curso'; end if;
  if new.destino = 'estudiante' and new.estudiante_id is null then raise exception 'Elija el estudiante'; end if;
  return new;
end $$;

-- 2) Galería de la semana: fotos de clase por curso y día. Se ven de lunes a domingo y se borran al empezar la semana siguiente.
create or replace function priv.hoy_co() returns date
language sql stable as $$ select (now() at time zone 'America/Bogota')::date $$;
create or replace function priv.lunes_co() returns date
language sql stable as $$ select (priv.hoy_co() - (extract(isodow from priv.hoy_co())::int - 1)) $$;

create table if not exists public.fotos_clase (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  grupo_id uuid not null references public.grupos(id) on delete cascade,
  fecha date not null default (now() at time zone 'America/Bogota')::date,
  pie text check (pie is null or length(pie) <= 200),
  imagen text not null check (length(imagen) < 200000 and imagen ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$'),
  creado_por text,
  autor_nombre text,
  creado_en timestamptz not null default now()
);
create index if not exists fotos_clase_grupo on public.fotos_clase (grupo_id, fecha);
create or replace function priv.tg_fotos_clase() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  select colegio_id into new.colegio_id from grupos where id = new.grupo_id;
  new.fecha := priv.hoy_co(); new.creado_por := priv.uid(); new.autor_nombre := priv.nombre_actual(new.colegio_id);
  if (select count(*) from fotos_clase where grupo_id = new.grupo_id and fecha = new.fecha) >= 8 then
    raise exception 'Ya hay 8 fotos de este curso hoy. Borre alguna para subir otra.';
  end if;
  delete from fotos_clase where colegio_id = new.colegio_id and fecha < priv.lunes_co();
  update comunicados set imagen = null
   where colegio_id = new.colegio_id and imagen is not null and creado_en < now() - interval '15 days';
  return new;
end $$;
drop trigger if exists tg_fotos_clase on public.fotos_clase;
create trigger tg_fotos_clase before insert on public.fotos_clase for each row execute function priv.tg_fotos_clase();
alter table public.fotos_clase enable row level security;
grant select, insert, delete on public.fotos_clase to authenticated;
drop policy if exists fc_ver on public.fotos_clase;
create policy fc_ver on public.fotos_clase for select to authenticated using (
  fecha >= priv.lunes_co() and (priv.es_personal(colegio_id)
    or exists (select 1 from estudiantes s where s.grupo_id = fotos_clase.grupo_id and s.id in (select priv.mis_estudiantes()))));
drop policy if exists fc_ins on public.fotos_clase;
create policy fc_ins on public.fotos_clase for insert to authenticated
  with check (priv.docente_de_grupo(grupo_id) or priv.es_directivo((select colegio_id from grupos g where g.id = grupo_id)));
drop policy if exists fc_del on public.fotos_clase;
create policy fc_del on public.fotos_clase for delete to authenticated using (creado_por = priv.uid() or priv.es_directivo(colegio_id));

-- 3) Foto del estudiante (la sube la familia; muy liviana porque se guarda a largo plazo). Se usa en el carnet,
--    la hoja y el libro de matrícula, los boletines y las constancias. Tabla aparte para no hacer pesadas las listas.
create table if not exists public.fotos_est (
  estudiante_id uuid primary key references public.estudiantes(id) on delete cascade,
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  foto text not null check (length(foto) < 60000 and foto ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$'),
  actualizado_en timestamptz not null default now()
);
create or replace function priv.tg_fotos_est() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  select colegio_id into new.colegio_id from estudiantes where id = new.estudiante_id;
  new.actualizado_en := now();
  return new;
end $$;
drop trigger if exists tg_fotos_est on public.fotos_est;
create trigger tg_fotos_est before insert or update on public.fotos_est for each row execute function priv.tg_fotos_est();
alter table public.fotos_est enable row level security;
grant select, insert, update, delete on public.fotos_est to authenticated;
drop policy if exists fe_ver on public.fotos_est;
create policy fe_ver on public.fotos_est for select to authenticated using (priv.puede_ver_estudiante(estudiante_id));
drop policy if exists fe_esc on public.fotos_est;
create policy fe_esc on public.fotos_est for all to authenticated
  using (priv.es_familia_de(estudiante_id) or priv.es_directivo(colegio_id) or 'secretaria' = any(priv.roles_en(colegio_id)))
  with check (priv.es_familia_de(estudiante_id) or priv.es_directivo((select colegio_id from estudiantes s where s.id = estudiante_id))
              or 'secretaria' = any(priv.roles_en((select colegio_id from estudiantes s where s.id = estudiante_id))));

-- 4) Contactos de emergencia y personas autorizadas para recoger al estudiante (los registra la familia)
create table if not exists public.contactos_est (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  tipo text not null check (tipo in ('emergencia', 'recoger')),
  nombre text not null check (length(nombre) between 3 and 120),
  parentesco text check (parentesco is null or length(parentesco) <= 60),
  telefono text check (telefono is null or length(telefono) <= 30),
  doc text check (doc is null or length(doc) <= 30),
  creado_por text,
  creado_en timestamptz not null default now()
);
create index if not exists contactos_est_e on public.contactos_est (estudiante_id);
create or replace function priv.tg_contactos_est() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  select colegio_id into new.colegio_id from estudiantes where id = new.estudiante_id;
  new.creado_por := priv.uid();
  if (select count(*) from contactos_est where estudiante_id = new.estudiante_id and tipo = new.tipo) >= 6 then
    raise exception 'Puede registrar hasta 6 personas de cada tipo';
  end if;
  return new;
end $$;
drop trigger if exists tg_contactos_est on public.contactos_est;
create trigger tg_contactos_est before insert on public.contactos_est for each row execute function priv.tg_contactos_est();
alter table public.contactos_est enable row level security;
grant select, insert, delete on public.contactos_est to authenticated;
drop policy if exists ce_ver on public.contactos_est;
create policy ce_ver on public.contactos_est for select to authenticated using (priv.puede_ver_estudiante(estudiante_id));
drop policy if exists ce_ins on public.contactos_est;
create policy ce_ins on public.contactos_est for insert to authenticated
  with check (priv.es_familia_de(estudiante_id) or priv.es_directivo((select colegio_id from estudiantes s where s.id = estudiante_id)));
drop policy if exists ce_del on public.contactos_est;
create policy ce_del on public.contactos_est for delete to authenticated
  using (priv.es_familia_de(estudiante_id) or priv.es_directivo(colegio_id));

-- 5) Redes sociales del colegio (la página web ya existe en colegios.web)
alter table public.colegios add column if not exists red_facebook text;
alter table public.colegios add column if not exists red_instagram text;
alter table public.colegios add column if not exists red_youtube text;
alter table public.colegios add column if not exists red_tiktok text;
grant update (red_facebook, red_instagram, red_youtube, red_tiktok) on public.colegios to authenticated;

-- 6) Bloqueo por suscripción vencida también en las tablas nuevas
do $$
declare t text;
begin
  foreach t in array array['fotos_clase', 'fotos_est', 'contactos_est'] loop
    execute format('drop trigger if exists zz_bloqueo on public.%I', t);
    execute format('create trigger zz_bloqueo before insert or update or delete on public.%I for each row execute function priv.tg_bloqueo()', t);
  end loop;
end $$;

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
notify pgrst, 'reload schema';
