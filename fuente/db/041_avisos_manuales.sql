-- 041 · Colegio-IA v0.26 (7 nov 2026): avisos al celular y manuales del usuario
-- 1) Avisos al celular (notificaciones push): cada persona activa los avisos en su celular o computador; la base de datos
--    deja en cola los avisos (comunicados, mensajes, citas, solicitudes de admisión) y un proceso programado de GitHub
--    (Actions, cada 10 minutos) los envía. Si la persona no activó avisos y es una solicitud de admisión, va por correo (Brevo).
-- 2) Manuales del usuario en PDF guardados en la base: cada persona solo descarga el manual de su cargo.
-- Se puede ejecutar más de una vez.

-- ---------- Suscripciones de avisos ----------
create table if not exists public.push_subs (
  id uuid primary key default gen_random_uuid(),
  user_id text not null,
  endpoint text not null unique,
  p256dh text not null, auth text not null,
  equipo text,
  creado_en timestamptz not null default now(),
  fallos int not null default 0);
create index if not exists push_subs_user on public.push_subs (user_id);
alter table public.push_subs enable row level security;
revoke all on public.push_subs from public, anonymous, authenticated;

create or replace function public.avisos_activar(p_endpoint text, p_p256dh text, p_auth text, p_equipo text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if priv.uid() is null then raise exception 'Debe iniciar sesión'; end if;
  if coalesce(p_endpoint, '') !~ '^https://' or length(p_endpoint) > 1000 or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then raise exception 'Suscripción no válida'; end if;
  insert into push_subs (user_id, endpoint, p256dh, auth, equipo) values (priv.uid(), p_endpoint, p_p256dh, p_auth, left(p_equipo, 120))
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, equipo = excluded.equipo, fallos = 0;
  if (select count(*) from push_subs where user_id = priv.uid()) > 8 then
    delete from push_subs where id in (select id from push_subs where user_id = priv.uid() order by creado_en limit 1);
  end if;
end $$;
create or replace function public.avisos_quitar(p_endpoint text) returns void
language sql security definer set search_path = public, pg_temp as $$ delete from push_subs where endpoint = p_endpoint and user_id = priv.uid() $$;
create or replace function public.avisos_estado() returns int
language sql stable security definer set search_path = public, pg_temp as $$ select count(*)::int from push_subs where user_id = priv.uid() $$;

-- ---------- Cola de avisos ----------
create table if not exists public.avisos_cola (
  id bigserial primary key,
  user_id text not null,
  colegio_id uuid references colegios(id) on delete cascade,
  titulo text not null, cuerpo text, url text,
  por_correo boolean not null default false,
  creado_en timestamptz not null default now(),
  enviado_en timestamptz, intentos int not null default 0);
create index if not exists avisos_cola_pend on public.avisos_cola (enviado_en, creado_en);
alter table public.avisos_cola enable row level security;
revoke all on public.avisos_cola from public, anonymous, authenticated;

create or replace function priv.avisar(us text[], c uuid, t text, b text, u text default '/', correo boolean default false) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into avisos_cola (user_id, colegio_id, titulo, cuerpo, url, por_correo)
  select distinct x, c, left(t, 120), left(b, 240), u, correo from unnest(us) x
  where x is not null and x <> coalesce(priv.uid(), '') and not exists (select 1 from colegios k where k.id = c and k.demo)
$$;
-- personas (cuentas) de la familia de un estudiante
create or replace function priv.cuentas_familia(e uuid) returns text[]
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(array_agg(distinct m.user_id), '{}') from miembros m where m.estudiante_id = e and m.rol in ('acudiente', 'estudiante') and m.activo and m.user_id is not null
$$;

create or replace function priv.tg_aviso_comunicado() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare us text[];
begin
  select coalesce(array_agg(distinct m.user_id), '{}') into us from miembros m
  where m.colegio_id = new.colegio_id and m.activo and m.user_id is not null and m.rol in ('acudiente', 'estudiante')
    and (new.destino = 'todos'
      or (new.destino = 'grupo' and m.estudiante_id in (select s.id from estudiantes s where s.grupo_id = new.grupo_id))
      or (new.destino = 'estudiante' and m.estudiante_id = new.estudiante_id));
  perform priv.avisar(us, new.colegio_id, coalesce(new.tipo, 'Comunicado') || ': ' || new.titulo, left(coalesce(new.cuerpo, ''), 200), '/?ir=comunicados');
  return new;
end $$;
drop trigger if exists zz_aviso on public.comunicados;
create trigger zz_aviso after insert on public.comunicados for each row execute function priv.tg_aviso_comunicado();

create or replace function priv.tg_aviso_mensaje() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare us text[];
begin
  if new.de_familia then select array_agg(m.user_id) into us from miembros m where m.id = new.personal_id and m.activo;
  else us := priv.cuentas_familia(new.estudiante_id); end if;
  perform priv.avisar(us, new.colegio_id, 'Mensaje de ' || coalesce(new.autor_nombre, 'Colegio-IA'), left(coalesce(new.texto, ''), 200), '/?ir=mensajes');
  return new;
end $$;
drop trigger if exists zz_aviso on public.mensajes;
create trigger zz_aviso after insert on public.mensajes for each row execute function priv.tg_aviso_mensaje();

create or replace function priv.tg_aviso_cita() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare us text[];
begin
  if tg_op = 'INSERT' then
    if new.pedida_por = 'familia' then select array_agg(m.user_id) into us from miembros m where m.id = new.personal_id and m.activo;
    else us := priv.cuentas_familia(new.estudiante_id); end if;
    perform priv.avisar(us, new.colegio_id, 'Nueva cita', left(coalesce(new.motivo, ''), 200), '/?ir=citas');
  elsif new.estado is distinct from old.estado then
    perform priv.avisar(priv.cuentas_familia(new.estudiante_id) || coalesce((select array_agg(m.user_id) from miembros m where m.id = new.personal_id), '{}'),
      new.colegio_id, 'Cita: ' || coalesce(new.estado, ''), left(coalesce(new.respuesta, new.motivo, ''), 200), '/?ir=citas');
  end if;
  return new;
end $$;
drop trigger if exists zz_aviso on public.citas;
create trigger zz_aviso after insert or update on public.citas for each row execute function priv.tg_aviso_cita();

create or replace function priv.tg_aviso_admision() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.estado is distinct from old.estado or new.entrevista is distinct from old.entrevista or new.mensaje is distinct from old.mensaje then
    perform priv.avisar(array[new.user_id], new.colegio_id, 'Solicitud de admisión: ' || new.estado,
      (new.datos->>'nombres') || case when new.estado = 'Entrevista' and new.entrevista is not null then '. Entrevista: ' || to_char(new.entrevista at time zone 'America/Bogota', 'DD/MM/YYYY HH12:MI am') else '' end
      || case when new.mensaje is not null then '. ' || new.mensaje else '' end, '/', true);
  end if;
  return new;
end $$;
drop trigger if exists zz_aviso on public.admisiones;
create trigger zz_aviso after update on public.admisiones for each row execute function priv.tg_aviso_admision();

-- Para el proceso programado (usuario limitado correo_pruebas): avisos pendientes con sus suscripciones
create or replace function public.avisos_pendientes() returns table (id bigint, titulo text, cuerpo text, url text, subs jsonb, correo text, nombre text, colegio text, por_correo boolean)
language sql stable security definer set search_path = public, pg_temp as $$
  select a.id, a.titulo, a.cuerpo, a.url,
    coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'keys', jsonb_build_object('p256dh', s.p256dh, 'auth', s.auth))) from push_subs s where s.user_id = a.user_id), '[]'),
    (select u.email from neon_auth."user" u where u.id::text = a.user_id), (select u.name from neon_auth."user" u where u.id::text = a.user_id),
    (select k.nombre from colegios k where k.id = a.colegio_id), a.por_correo
  from avisos_cola a where a.enviado_en is null and a.intentos < 3 and a.creado_en > now() - interval '2 days'
  order by a.id limit 500
$$;
create or replace function public.avisos_marcar(p_ids bigint[], p_ok boolean, p_malos text[]) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update avisos_cola set enviado_en = case when p_ok then now() end, intentos = intentos + 1 where id = any(p_ids);
  delete from push_subs where endpoint = any(coalesce(p_malos, '{}'));
  delete from avisos_cola where creado_en < now() - interval '30 days';
end $$;
revoke all on function public.avisos_pendientes(), public.avisos_marcar(bigint[], boolean, text[]) from public, anonymous, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'correo_pruebas') then
    grant execute on function public.avisos_pendientes(), public.avisos_marcar(bigint[], boolean, text[]) to correo_pruebas;
  end if;
end $$;
revoke all on function public.avisos_activar(text, text, text, text), public.avisos_quitar(text), public.avisos_estado() from public, anonymous;
grant execute on function public.avisos_activar(text, text, text, text), public.avisos_quitar(text), public.avisos_estado() to authenticated;
revoke all on function priv.avisar(text[], uuid, text, text, text, boolean), priv.cuentas_familia(uuid) from public, anonymous, authenticated;

-- ---------- Manuales del usuario (PDF) ----------
create table if not exists public.manuales (
  rol text primary key check (rol in ('general', 'rector', 'coordinador', 'secretaria', 'tesoreria', 'docente', 'acudiente', 'estudiante')),
  titulo text not null, version text not null, pdf bytea not null, actualizado timestamptz not null default now());
alter table public.manuales enable row level security;
revoke all on public.manuales from public, anonymous, authenticated;

-- Manuales que puede abrir la persona en ese colegio (su cargo; la rectoría también el general)
create or replace function public.mis_manuales(p_colegio uuid) returns json
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(json_agg(json_build_object('rol', x.rol, 'titulo', x.titulo, 'version', x.version) order by x.rol = 'general' desc, x.rol), '[]')
  from manuales x
  where priv.es_superadmin() or x.rol = any(priv.roles_en(p_colegio)) or (x.rol = 'general' and priv.roles_en(p_colegio) && array['rector', 'coordinador', 'secretaria'])
$$;
create or replace function public.manual_pdf(p_colegio uuid, p_rol text) returns json
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare m manuales;
begin
  if not (priv.es_superadmin() or p_rol = any(priv.roles_en(p_colegio)) or (p_rol = 'general' and priv.roles_en(p_colegio) && array['rector', 'coordinador', 'secretaria'])) then
    raise exception 'Ese manual no corresponde a su cargo';
  end if;
  select * into m from manuales where rol = p_rol;
  if m.rol is null then raise exception 'El manual aún no está disponible'; end if;
  return json_build_object('titulo', m.titulo, 'version', m.version, 'pdf', encode(m.pdf, 'base64'));
end $$;
-- Solo el Superadministrador sube o reemplaza los manuales
create or replace function public.subir_manual(p_rol text, p_titulo text, p_version text, p_b64 text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not priv.es_superadmin() then raise exception 'Solo el Superadministrador sube manuales'; end if;
  insert into manuales (rol, titulo, version, pdf) values (p_rol, p_titulo, p_version, decode(p_b64, 'base64'))
  on conflict (rol) do update set titulo = excluded.titulo, version = excluded.version, pdf = excluded.pdf, actualizado = now();
end $$;
revoke all on function public.mis_manuales(uuid), public.manual_pdf(uuid, text), public.subir_manual(text, text, text, text) from public, anonymous;
grant execute on function public.mis_manuales(uuid), public.manual_pdf(uuid, text), public.subir_manual(text, text, text, text) to authenticated;

-- ---------- Ajustes de la revisión triple (v0.26) ----------
-- a) Cierre de calificaciones con la fecha de Colombia (no la del servidor)
create or replace function priv.notas_abiertas(c uuid, p int, g uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select priv.es_directivo(c) or coalesce((
    select priv.hoy_co() <= (x->>'cierre')::date
    from jsonb_array_elements(coalesce(priv.cal_grupo(c, g), '[]')) x
    where (x->>'n')::int = p and coalesce(x->>'cierre', '') <> ''), true)
$$;

-- b) Documentos verificables: el título y el resumen los arma la base de datos (no se aceptan los que mande el navegador)
--    y los diplomas, actas de grado, informes finales y certificados de años anteriores solo los emiten directivos
--    (la familia solo obtiene el código de lo que ya puede descargar). Códigos más largos (XXXX-XXXX-XXXX).
create or replace function public.emitir_documento(p_colegio uuid, p_est uuid, p_tipo text, p_anio int, p_titulo text, p_resumen jsonb) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare h text; c text; s estudiantes; g grupos; r jsonb := '{}'; dir boolean := priv.es_directivo(p_colegio); t text; x jsonb := coalesce(p_resumen, '{}'); k text;
begin
  if not (dir or priv.ve_pagos(p_colegio) or (p_est is not null and priv.es_acudiente_de(p_est))) then raise exception 'No tiene permiso para emitir documentos'; end if;
  t := case p_tipo when 'constancia' then 'Constancia de estudio' when 'certificado' then 'Constancia de estudio con calificaciones' when 'certificado_anio' then 'Certificado de estudios'
    when 'informe_final' then 'Informe final' when 'acta_grado' then 'Acta de grado' when 'diploma' then 'Diploma' when 'paz_salvo' then 'Paz y salvo' when 'retiro' then 'Constancia de retiro' end;
  if t is null then raise exception 'Tipo de documento no válido'; end if;
  if p_tipo in ('acta_grado', 'diploma') and not dir then raise exception 'Solo la rectoría o la secretaría expiden actas de grado y diplomas'; end if;
  select * into s from estudiantes where id = p_est and colegio_id = p_colegio;
  if p_est is not null and s.id is null then raise exception 'Estudiante no válido'; end if;
  if s.id is not null then
    select * into g from grupos where id = s.grupo_id;
    r := jsonb_build_object('estudiante', s.nombres || ' ' || s.apellidos,
      'documento', s.tipo_doc || ' ' || repeat('•', greatest(length(s.doc) - 4, 0)) || right(s.doc, 4), 'grado', coalesce(g.nombre, ''), 'estado', s.estado);
  end if;
  if p_tipo in ('acta_grado', 'diploma') then
    x := (select jsonb_build_object('titulo_otorgado', gr.titulo, 'acta', gr.acta::text, 'diploma', gr.diploma, 'fecha_de_grado', to_char(gr.fecha, 'DD/MM/YYYY'))
          from grados gr where gr.estudiante_id = p_est order by gr.fecha desc limit 1);
    if x is null then raise exception 'El estudiante no tiene grado registrado'; end if;
    r := r || x;
  elsif p_tipo = 'certificado_anio' then
    r := r || coalesce((select jsonb_build_object('grado', coalesce(h.grupo_nombre, ''), 'resultado', coalesce(h.resultado, ''))
                        from historial h where h.estudiante_id = p_est and h.anio = p_anio order by h.grado desc nulls last limit 1), '{}');
  elsif p_tipo = 'informe_final' and dir then
    -- el resultado lo calcula el colegio en pantalla; solo se acepta uno de los textos conocidos
    if x->>'resultado' in ('Cumple', 'Parcial', 'Promovido(a)') or x->>'resultado' like 'No cumple (%' then r := r || jsonb_build_object('resultado', x->>'resultado'); end if;
  end if;
  h := md5(coalesce(p_est::text, '') || '|' || p_tipo || '|' || coalesce(p_anio, 0) || '|' || r::text || '|' || priv.hoy_co());
  select codigo into c from documentos_emitidos where colegio_id = p_colegio and huella = h and anulado_en is null limit 1;
  if c is not null then return c; end if;
  loop
    c := upper(substr(translate(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), '01', ''), 1, 12));
    c := substr(c, 1, 4) || '-' || substr(c, 5, 4) || '-' || substr(c, 9, 4);
    exit when length(c) = 14 and not exists (select 1 from documentos_emitidos where codigo = c);
  end loop;
  insert into documentos_emitidos (codigo, colegio_id, estudiante_id, tipo, anio, titulo, resumen, huella, emitido_por)
  values (c, p_colegio, p_est, p_tipo, p_anio, t, r, h, priv.nombre_actual(p_colegio));
  return c;
end $$;
create or replace function public.verificar_documento(p_codigo text) returns json
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare d documentos_emitidos; k colegios; c text := upper(regexp_replace(coalesce(p_codigo, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  if priv.uid() is null then raise exception 'Debe iniciar sesión'; end if;
  if length(c) = 8 then c := substr(c, 1, 4) || '-' || substr(c, 5, 4);
  elsif length(c) = 12 then c := substr(c, 1, 4) || '-' || substr(c, 5, 4) || '-' || substr(c, 9, 4); end if;
  select * into d from documentos_emitidos where codigo = c;
  if d.id is null then return json_build_object('valido', false); end if;
  select * into k from colegios where id = d.colegio_id;
  return json_build_object('valido', d.anulado_en is null, 'anulado', d.anulado_en is not null, 'motivo', d.motivo_anulacion, 'codigo', d.codigo,
    'colegio', k.nombre, 'ciudad', k.ciudad, 'dane', k.dane, 'titulo', d.titulo, 'anio', d.anio, 'emitido_en', d.emitido_en, 'resumen', d.resumen);
end $$;

-- c) Escudo del colegio: solo imágenes (evita que un texto malicioso se ejecute al mostrarlo)
alter table public.colegios drop constraint if exists colegios_logo_img;
alter table public.colegios add constraint colegios_logo_img check (logo is null or logo ~ '^data:image/(png|jpeg|jpg|webp|gif|svg\+xml);base64,[A-Za-z0-9+/=\s]+$') not valid;

-- d) Admisiones de ciclos (adultos): el acudiente es opcional y quien hace la solicitud entra como estudiante
do $$
declare d text := pg_get_functiondef('public.admision_enviar(text, integer, jsonb, jsonb, text)'::regprocedure);
begin
  if position('p_grado < 21 and (' in d) = 0 then
    d := replace(d, 'if jsonb_typeof(a) <> ''array'' or jsonb_array_length(a) = 0 or', 'if jsonb_typeof(a) <> ''array'' then raise exception ''Acudientes no válidos''; end if;
  if p_grado < 21 and (jsonb_array_length(a) = 0 or');
    d := replace(d, 'btrim(coalesce(a->0->>''telefono'', '''')) = '''' then
    raise exception ''Escriba los datos del acudiente', 'btrim(coalesce(a->0->>''telefono'', '''')) = '''') then
    raise exception ''Escriba los datos del acudiente');
    d := replace(d, 'a := (select jsonb_agg(jsonb_build_object(''parentesco''', 'a := coalesce((select jsonb_agg(jsonb_build_object(''parentesco''');
    d := replace(d, 'from jsonb_array_elements(a) with ordinality as e(x, o) where btrim(coalesce(x->>''nombres'', '''')) <> '''');',
                    'from jsonb_array_elements(a) with ordinality as e(x, o) where btrim(coalesce(x->>''nombres'', '''')) <> ''''), ''[]'');');
    if position('p_grado < 21 and (' in d) = 0 or position('a := coalesce((select jsonb_agg' in d) = 0 or position('''''), ''[]'');' in d) = 0 then
      raise exception 'No se pudo ajustar admision_enviar';
    end if;
    execute d;
  end if;
  d := pg_get_functiondef('public.admision_matricular(uuid, uuid)'::regprocedure);
  if position('when ad.grado >= 21 then ''estudiante''' in d) = 0 then
    d := replace(d, 'm.rol = ''acudiente'' and m.estudiante_id = e', 'm.rol = (case when ad.grado >= 21 then ''estudiante'' else ''acudiente'' end) and m.estudiante_id = e');
    d := replace(d, 'upper(nombre), ''acudiente'', e)', 'upper(nombre), case when ad.grado >= 21 then ''estudiante'' else ''acudiente'' end, e)');
    d := replace(d, 'rol = ''acudiente'' and estudiante_id = e and lower(email)', 'rol = (case when ad.grado >= 21 then ''estudiante'' else ''acudiente'' end) and estudiante_id = e and lower(email)');
    if (length(d) - length(replace(d, 'when ad.grado >= 21 then', ''))) / length('when ad.grado >= 21 then') <> 3 then raise exception 'No se pudo ajustar admision_matricular'; end if;
    execute d;
  end if;
end $$;

notify pgrst, 'reload schema';
