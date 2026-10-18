-- Colegio-IA 020 (etapa 2B): mensajes privados familia–colegio, autorizaciones, citas,
-- y regla de cobro vigente de SkyNet Genesis (sin mora: si no paga, el acceso se cierra el día 5).

-- 0) Regla de cobro (17 oct 2026): "Pagado hasta" = fin de mes; el día 5 del mes siguiente sin pago se cierra. Sin período de aviso.
create or replace function priv.estado_cobro(p_activo boolean, p_demo boolean, p_hasta date) returns text language sql stable as $$
  select case when not p_activo then 'suspendido'
              when p_demo or p_hasta is null or current_date - p_hasta < 5 then 'activa'
              else 'cerrada' end $$;
create or replace function priv.acceso_ok(p_activo boolean, p_demo boolean, p_hasta date) returns boolean language sql stable as $$
  select p_activo and (p_demo or p_hasta is null or current_date - p_hasta < 5) $$;

-- Ayudas
create or replace function priv.es_mi_miembro(mid uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from miembros m join colegios k on k.id = m.colegio_id
                 where m.id = mid and m.user_id = priv.uid() and m.activo and priv.acceso_ok(k.activo, k.demo, k.pagado_hasta))
$$;
-- ¿Ese miembro del personal atiende a ese estudiante? (rector, coordinación, director de grupo o docente del curso)
create or replace function priv.atiende_estudiante(mid uuid, e uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from miembros m join estudiantes s on s.colegio_id = m.colegio_id
    where m.id = mid and s.id = e and m.activo and m.user_id is not null and (
      m.rol in ('rector', 'coordinador')
      or exists (select 1 from grupos g where g.id = s.grupo_id and g.director_miembro_id = m.id)
      or (m.rol = 'docente' and exists (select 1 from docente_grupos dg where dg.miembro_id = m.id and dg.grupo_id = s.grupo_id))))
$$;
-- Personas del colegio a las que la familia puede escribir o pedir cita
create or replace function public.contactos_colegio(p_estudiante uuid) returns json
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(json_agg(x order by x.orden, x.nombre), '[]'::json) from (
    select m.id, m.nombre, m.rol,
           exists (select 1 from grupos g join estudiantes s on s.grupo_id = g.id where s.id = p_estudiante and g.director_miembro_id = m.id) as director,
           case m.rol when 'docente' then 2 when 'coordinador' then 3 else 4 end
             - case when exists (select 1 from grupos g join estudiantes s on s.grupo_id = g.id where s.id = p_estudiante and g.director_miembro_id = m.id) then 2 else 0 end as orden,
           (select string_agg(distinct a.nombre, ', ') from docente_grupos dg join asignaturas a on a.id = dg.asignatura_id
              join estudiantes s on s.grupo_id = dg.grupo_id where dg.miembro_id = m.id and s.id = p_estudiante) as asignaturas
    from miembros m where m.colegio_id = (select colegio_id from estudiantes where id = p_estudiante)
      and m.rol in ('rector', 'coordinador', 'docente') and priv.atiende_estudiante(m.id, p_estudiante)) x
  where p_estudiante in (select priv.mis_estudiantes())
$$;
revoke execute on function public.contactos_colegio(uuid) from anonymous;

-- 1) Mensajes privados entre la familia de un estudiante y una persona del colegio.
--    Cada conversación = (estudiante, miembro del personal). Solo la ven sus participantes.
create table if not exists public.mensajes (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  personal_id uuid not null references public.miembros(id) on delete cascade,
  de_familia boolean not null,
  texto text not null check (length(btrim(texto)) between 1 and 2000),
  autor_nombre text,
  creado_por text,
  leido_en timestamptz,
  creado_en timestamptz not null default now()
);
create index if not exists mensajes_hilo on public.mensajes (estudiante_id, personal_id, creado_en);
create index if not exists mensajes_personal on public.mensajes (personal_id, creado_en);
create or replace function priv.tg_mensajes() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  select colegio_id into new.colegio_id from estudiantes where id = new.estudiante_id;
  new.de_familia := not priv.es_mi_miembro(new.personal_id);
  new.creado_por := priv.uid(); new.leido_en := null; new.creado_en := now();
  new.autor_nombre := case when new.de_familia
    then coalesce((select max(m.nombre) from miembros m where m.user_id = priv.uid() and m.estudiante_id = new.estudiante_id and m.activo), 'Familia')
    else (select nombre from miembros where id = new.personal_id) end;
  if (select count(*) from mensajes where creado_por = priv.uid() and creado_en > now() - interval '1 hour') >= 60 then
    raise exception 'Ha enviado muchos mensajes en poco tiempo. Intente más tarde.';
  end if;
  return new;
end $$;
drop trigger if exists tg_mensajes on public.mensajes;
create trigger tg_mensajes before insert on public.mensajes for each row execute function priv.tg_mensajes();
alter table public.mensajes enable row level security;
grant select, insert on public.mensajes to authenticated;
drop policy if exists msj_ver on public.mensajes;
create policy msj_ver on public.mensajes for select to authenticated
  using (priv.es_mi_miembro(personal_id) or estudiante_id in (select priv.mis_estudiantes()));
drop policy if exists msj_ins on public.mensajes;
create policy msj_ins on public.mensajes for insert to authenticated with check (
  priv.atiende_estudiante(personal_id, estudiante_id) and (
    priv.es_mi_miembro(personal_id)
    or estudiante_id in (select m.estudiante_id from miembros m where m.user_id = priv.uid() and m.activo and m.rol = 'acudiente')));
-- Marcar como leídos los mensajes que recibió quien llama
create or replace function public.leer_mensajes(p_estudiante uuid, p_personal uuid) returns void
language sql security definer set search_path = public, pg_temp as $$
  update mensajes set leido_en = now()
   where estudiante_id = p_estudiante and personal_id = p_personal and leido_en is null
     and ((de_familia and priv.es_mi_miembro(p_personal))
       or (not de_familia and p_estudiante in (select priv.mis_estudiantes())))
$$;
revoke execute on function public.leer_mensajes(uuid, uuid) from anonymous;

-- 2) Autorizaciones: el colegio pide permiso a las familias (salida pedagógica, evento, uso de imagen…) y cada familia responde Sí o No
create table if not exists public.autorizaciones (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  titulo text not null check (length(titulo) between 3 and 150),
  detalle text not null check (length(detalle) <= 3000),
  fecha_evento date,
  fecha_limite date,
  destino text not null default 'todos' check (destino in ('todos', 'grupo')),
  grupo_id uuid references public.grupos(id) on delete cascade,
  creado_por text,
  autor_nombre text,
  creado_en timestamptz not null default now(),
  check (destino = 'todos' or grupo_id is not null)
);
create table if not exists public.respuestas_aut (
  autorizacion_id uuid not null references public.autorizaciones(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  autoriza boolean not null,
  nota text check (nota is null or length(nota) <= 300),
  nombre text,
  user_id text,
  respondido_en timestamptz not null default now(),
  primary key (autorizacion_id, estudiante_id)
);
create or replace function priv.tg_autorizaciones() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then new.creado_por := priv.uid(); new.autor_nombre := priv.nombre_actual(new.colegio_id); new.creado_en := now(); end if;
  return new;
end $$;
drop trigger if exists tg_autorizaciones on public.autorizaciones;
create trigger tg_autorizaciones before insert on public.autorizaciones for each row execute function priv.tg_autorizaciones();
create or replace function priv.tg_respuestas_aut() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare a autorizaciones;
begin
  select * into a from autorizaciones where id = new.autorizacion_id;
  if a.fecha_limite is not null and (now() at time zone 'America/Bogota')::date > a.fecha_limite then
    raise exception 'El plazo para responder esta autorización ya venció. Comuníquese con el colegio.';
  end if;
  new.user_id := priv.uid(); new.respondido_en := now();
  new.nombre := coalesce((select max(m.nombre) from miembros m where m.user_id = priv.uid() and m.estudiante_id = new.estudiante_id and m.activo), 'Acudiente');
  return new;
end $$;
drop trigger if exists tg_respuestas_aut on public.respuestas_aut;
create trigger tg_respuestas_aut before insert or update on public.respuestas_aut for each row execute function priv.tg_respuestas_aut();
create or replace function priv.ve_autorizacion(a public.autorizaciones) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select priv.es_personal(a.colegio_id) or (priv.es_miembro(a.colegio_id) and (
    a.destino = 'todos' or exists (select 1 from estudiantes s where s.grupo_id = a.grupo_id and s.id in (select priv.mis_estudiantes()))))
$$;
alter table public.autorizaciones enable row level security;
alter table public.respuestas_aut enable row level security;
grant select, insert, delete on public.autorizaciones to authenticated;
grant select, insert, update on public.respuestas_aut to authenticated;
drop policy if exists aut_ver on public.autorizaciones;
create policy aut_ver on public.autorizaciones for select to authenticated using (priv.ve_autorizacion(autorizaciones));
drop policy if exists aut_ins on public.autorizaciones;
create policy aut_ins on public.autorizaciones for insert to authenticated
  with check (priv.es_directivo(colegio_id) or (destino = 'grupo' and priv.docente_de_grupo(grupo_id)));
drop policy if exists aut_del on public.autorizaciones;
create policy aut_del on public.autorizaciones for delete to authenticated using (priv.es_directivo(colegio_id) or creado_por = priv.uid());
drop policy if exists raut_ver on public.respuestas_aut;
create policy raut_ver on public.respuestas_aut for select to authenticated
  using (priv.puede_ver_estudiante(estudiante_id));
drop policy if exists raut_esc on public.respuestas_aut;
create policy raut_esc on public.respuestas_aut for insert to authenticated
  with check (estudiante_id in (select m.estudiante_id from miembros m where m.user_id = priv.uid() and m.activo and m.rol = 'acudiente')
              and exists (select 1 from autorizaciones a join estudiantes s on s.id = estudiante_id
                          where a.id = autorizacion_id and a.colegio_id = s.colegio_id and (a.destino = 'todos' or a.grupo_id = s.grupo_id)));
drop policy if exists raut_mod on public.respuestas_aut;
create policy raut_mod on public.respuestas_aut for update to authenticated
  using (estudiante_id in (select m.estudiante_id from miembros m where m.user_id = priv.uid() and m.activo and m.rol = 'acudiente'))
  with check (estudiante_id in (select m.estudiante_id from miembros m where m.user_id = priv.uid() and m.activo and m.rol = 'acudiente'));

-- 3) Citas entre la familia y una persona del colegio (la pide la familia o la programa el colegio)
create table if not exists public.citas (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  personal_id uuid not null references public.miembros(id) on delete cascade,
  pedida_por text not null check (pedida_por in ('familia', 'colegio')),
  motivo text not null check (length(motivo) between 3 and 500),
  preferencia text check (preferencia is null or length(preferencia) <= 200),
  fecha timestamptz,
  modalidad text not null default 'Presencial' check (modalidad in ('Presencial', 'Virtual', 'Llamada')),
  estado text not null default 'Solicitada' check (estado in ('Solicitada', 'Confirmada', 'Cancelada', 'Realizada')),
  respuesta text check (respuesta is null or length(respuesta) <= 500),
  creado_por text,
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);
create index if not exists citas_personal on public.citas (personal_id, fecha);
create index if not exists citas_est on public.citas (estudiante_id, fecha);
create or replace function priv.tg_citas() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare personal boolean;
begin
  if tg_op = 'INSERT' then
    select colegio_id into new.colegio_id from estudiantes where id = new.estudiante_id;
    personal := priv.es_mi_miembro(new.personal_id);
    new.pedida_por := case when personal then 'colegio' else 'familia' end;
    new.creado_por := priv.uid(); new.creado_en := now();
    if personal then
      if new.fecha is null then raise exception 'Escriba la fecha y hora de la cita'; end if;
      new.estado := 'Confirmada';
    else
      new.estado := 'Solicitada'; new.fecha := null; new.respuesta := null;
      if (select count(*) from citas where estudiante_id = new.estudiante_id and estado = 'Solicitada') >= 3 then
        raise exception 'Ya tiene 3 solicitudes de cita pendientes. Espere la respuesta del colegio.';
      end if;
    end if;
  else
    personal := priv.es_mi_miembro(old.personal_id);
    -- nadie cambia a quién ni a qué estudiante corresponde la cita
    new.colegio_id := old.colegio_id; new.estudiante_id := old.estudiante_id; new.personal_id := old.personal_id;
    new.pedida_por := old.pedida_por; new.creado_por := old.creado_por; new.creado_en := old.creado_en; new.motivo := old.motivo;
    if not personal then  -- la familia solo puede cancelar
      if new.estado <> 'Cancelada' then raise exception 'Solo el colegio confirma o cambia la cita'; end if;
      new.fecha := old.fecha; new.modalidad := old.modalidad; new.respuesta := old.respuesta; new.preferencia := old.preferencia;
    elsif new.estado = 'Confirmada' and new.fecha is null then
      raise exception 'Escriba la fecha y hora de la cita';
    end if;
  end if;
  new.actualizado_en := now();
  return new;
end $$;
drop trigger if exists tg_citas on public.citas;
create trigger tg_citas before insert or update on public.citas for each row execute function priv.tg_citas();
alter table public.citas enable row level security;
grant select, insert, update on public.citas to authenticated;
drop policy if exists cit_ver on public.citas;
create policy cit_ver on public.citas for select to authenticated
  using (priv.es_mi_miembro(personal_id) or priv.es_directivo(colegio_id) or estudiante_id in (select priv.mis_estudiantes()));
drop policy if exists cit_ins on public.citas;
create policy cit_ins on public.citas for insert to authenticated with check (
  priv.atiende_estudiante(personal_id, estudiante_id) and (
    priv.es_mi_miembro(personal_id)
    or estudiante_id in (select m.estudiante_id from miembros m where m.user_id = priv.uid() and m.activo and m.rol = 'acudiente')));
drop policy if exists cit_mod on public.citas;
create policy cit_mod on public.citas for update to authenticated
  using (priv.es_mi_miembro(personal_id) or estudiante_id in (select m.estudiante_id from miembros m where m.user_id = priv.uid() and m.activo and m.rol = 'acudiente'))
  with check (priv.es_mi_miembro(personal_id) or estudiante_id in (select m.estudiante_id from miembros m where m.user_id = priv.uid() and m.activo and m.rol = 'acudiente'));

-- 4) Bloqueo por suscripción vencida también en las tablas nuevas
do $$
declare t text;
begin
  foreach t in array array['mensajes', 'autorizaciones', 'respuestas_aut', 'citas'] loop
    execute format('drop trigger if exists zz_bloqueo on public.%I', t);
    execute format('create trigger zz_bloqueo before insert or update or delete on public.%I for each row execute function priv.tg_bloqueo()', t);
  end loop;
end $$;

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
notify pgrst, 'reload schema';
