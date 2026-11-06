-- 039 · Colegio-IA v0.24 (6 nov 2026): admisiones y matrícula en línea
-- 1) Admisiones: el colegio abre las admisiones y comparte un enlace (colegio-ia.skynetgenesis.com/?admision=CODIGO).
--    La familia crea su cuenta, llena la solicitud y ve el estado. La secretaría/rectoría revisa, cita a entrevista,
--    admite o no admite y, cuando el año de la solicitud ya está abierto, matricula: se crea el estudiante, sus acudientes
--    y el acceso de la familia (sin código de activación).
-- 2) Matrícula en línea (renovación): el colegio la abre para el año siguiente; la familia de cada estudiante activo
--    actualiza los datos, revisa y acepta el contrato de matrícula, y la secretaría confirma.
-- Se puede ejecutar más de una vez.

-- ---------- Configuración en colegios ----------
alter table public.colegios add column if not exists admisiones_abiertas boolean not null default false;
alter table public.colegios add column if not exists admision_codigo text;
alter table public.colegios add column if not exists admision_anio int;
alter table public.colegios add column if not exists admision_grados int[];
alter table public.colegios add column if not exists admision_texto text;
alter table public.colegios add column if not exists matricula_linea boolean not null default false;
alter table public.colegios add column if not exists matricula_anio int;
alter table public.colegios add column if not exists matricula_hasta date;
create unique index if not exists colegios_admision_codigo on public.colegios (admision_codigo) where admision_codigo is not null;
grant update (admisiones_abiertas, admision_anio, admision_grados, admision_texto, matricula_linea, matricula_anio, matricula_hasta) on public.colegios to authenticated;

-- Código corto del enlace de admisiones (el colegio no lo escribe: se crea solo)
create or replace function priv.tg_admision_codigo() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare c text;
begin
  if tg_op = 'UPDATE' and old.admision_codigo is not null then new.admision_codigo := old.admision_codigo; end if;
  if new.admision_codigo is null then
    loop
      c := upper(substr(translate(replace(gen_random_uuid()::text, '-', ''), '01', ''), 1, 7));
      exit when length(c) = 7 and not exists (select 1 from colegios where admision_codigo = c);
    end loop;
    new.admision_codigo := c;
  end if;
  return new;
end $$;
drop trigger if exists tg_admision_codigo on public.colegios;
create trigger tg_admision_codigo before insert or update on public.colegios for each row execute function priv.tg_admision_codigo();

-- ---------- Solicitudes de admisión ----------
create table if not exists public.admisiones (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references colegios(id) on delete cascade,
  anio int not null,
  user_id text not null,
  email text not null,
  estado text not null default 'Recibida' check (estado in ('Recibida', 'Entrevista', 'Admitida', 'No admitida', 'Matriculada', 'Retirada')),
  grado int not null,
  datos jsonb not null default '{}',          -- datos del aspirante (como la ficha de matrícula)
  acudientes jsonb not null default '[]',     -- uno o dos acudientes
  comentarios text,                           -- lo que escribe la familia
  entrevista timestamptz,                     -- cita de entrevista (la ve la familia)
  mensaje text,                               -- mensaje del colegio para la familia
  notas text,                                 -- notas internas (la familia no las ve)
  estudiante_id uuid references estudiantes(id) on delete set null,
  actualizado_por text,
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now());
create index if not exists admisiones_colegio on public.admisiones (colegio_id, anio);
create index if not exists admisiones_user on public.admisiones (user_id);
alter table public.admisiones enable row level security;
revoke all on public.admisiones from public, anonymous, authenticated;
grant select on public.admisiones to authenticated;
grant update (estado, entrevista, mensaje, notas, grado) on public.admisiones to authenticated;
drop policy if exists adm_ver on public.admisiones;
create policy adm_ver on public.admisiones for select to authenticated
  using (priv.puede(colegio_id, 'matricula') or priv.es_directivo(colegio_id));
drop policy if exists adm_editar on public.admisiones;
create policy adm_editar on public.admisiones for update to authenticated
  using (priv.puede(colegio_id, 'matricula') or priv.es_directivo(colegio_id))
  with check (priv.puede(colegio_id, 'matricula') or priv.es_directivo(colegio_id));

create or replace function priv.tg_admisiones() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  new.colegio_id := old.colegio_id; new.user_id := old.user_id; new.email := old.email; new.anio := old.anio; new.creado_en := old.creado_en;
  if priv.es_cliente() then
    new.datos := old.datos; new.acudientes := old.acudientes; new.estudiante_id := old.estudiante_id;
    if new.estado = 'Matriculada' and old.estado <> 'Matriculada' then raise exception 'Use el botón Matricular'; end if;
    if old.estado = 'Matriculada' and new.estado <> 'Matriculada' then raise exception 'La solicitud ya está matriculada'; end if;
  end if;
  new.actualizado_en := now(); new.actualizado_por := coalesce(priv.nombre_actual(new.colegio_id), new.actualizado_por);
  return new;
end $$;
drop trigger if exists tg_admisiones on public.admisiones;
create trigger tg_admisiones before update on public.admisiones for each row execute function priv.tg_admisiones();

-- Lo que la familia ve del colegio al abrir el enlace
create or replace function public.admision_info(p_codigo text) returns json
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare k colegios;
begin
  if priv.uid() is null then raise exception 'Debe iniciar sesión'; end if;
  select * into k from colegios where admision_codigo = upper(btrim(coalesce(p_codigo, ''))) and activo;
  if k.id is null then raise exception 'El enlace de admisiones no es válido. Pídale al colegio el enlace correcto.'; end if;
  return json_build_object('colegio', k.nombre, 'ciudad', k.ciudad, 'logo', k.logo, 'abiertas', k.admisiones_abiertas and not k.demo,
    'anio', coalesce(k.admision_anio, k.anio), 'grados', coalesce(k.admision_grados, (select array_agg(distinct g.grado order by g.grado) from grupos g where g.colegio_id = k.id)),
    'texto', k.admision_texto, 'telefono', k.telefono,
    'mias', coalesce((select json_agg(json_build_object('id', a.id, 'estado', a.estado, 'grado', a.grado, 'anio', a.anio, 'nombre', (a.datos->>'nombres') || ' ' || (a.datos->>'apellidos'),
       'entrevista', a.entrevista, 'mensaje', a.mensaje, 'creado_en', a.creado_en) order by a.creado_en desc)
       from admisiones a where a.colegio_id = k.id and a.user_id = priv.uid()), '[]'));
end $$;

-- Solicitudes de la persona en todos los colegios (para la pantalla de quien aún no tiene acceso)
create or replace function public.mis_admisiones() returns json
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(json_agg(json_build_object('id', a.id, 'colegio', k.nombre, 'codigo', k.admision_codigo, 'estado', a.estado, 'grado', a.grado, 'anio', a.anio,
    'nombre', (a.datos->>'nombres') || ' ' || (a.datos->>'apellidos'), 'entrevista', a.entrevista, 'mensaje', a.mensaje, 'creado_en', a.creado_en) order by a.creado_en desc), '[]')
  from admisiones a join colegios k on k.id = a.colegio_id where a.user_id = priv.uid()
$$;

create or replace function public.admision_enviar(p_codigo text, p_grado int, p_datos jsonb, p_acudientes jsonb, p_comentarios text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare k colegios; id uuid; t text; d jsonb := coalesce(p_datos, '{}'); a jsonb := coalesce(p_acudientes, '[]'); c text; correo text := priv.email_actual();
begin
  if priv.uid() is null then raise exception 'Debe iniciar sesión'; end if;
  select * into k from colegios where admision_codigo = upper(btrim(coalesce(p_codigo, ''))) and activo;
  if k.id is null then raise exception 'El enlace de admisiones no es válido'; end if;
  if not k.admisiones_abiertas or k.demo then raise exception 'Las admisiones de este colegio están cerradas'; end if;
  if k.admision_grados is not null and not (p_grado = any(k.admision_grados)) then raise exception 'El colegio no recibe solicitudes para ese grado'; end if;
  if not exists (select 1 from grupos g where g.colegio_id = k.id and g.grado = p_grado) then raise exception 'Elija un grado que ofrezca el colegio'; end if;
  foreach c in array array['nombres', 'apellidos', 'tipo_doc', 'doc', 'fnac', 'sexo', 'direccion', 'municipio'] loop
    if btrim(coalesce(d->>c, '')) = '' then raise exception 'Falta un dato obligatorio del aspirante: %', replace(c, '_', ' '); end if;
  end loop;
  if not (d->>'tipo_doc' in ('RC', 'NUIP', 'TI', 'CC', 'CE', 'PPT')) then raise exception 'Tipo de documento no válido'; end if;
  if not (d->>'sexo' in ('Femenino', 'Masculino')) then raise exception 'Elija el sexo del aspirante'; end if;
  if (d->>'fnac')::date > current_date or (d->>'fnac')::date < current_date - interval '80 years' then raise exception 'Revise la fecha de nacimiento'; end if;
  if jsonb_typeof(a) <> 'array' or jsonb_array_length(a) = 0 or btrim(coalesce(a->0->>'nombres', '')) = '' or btrim(coalesce(a->0->>'doc', '')) = '' or btrim(coalesce(a->0->>'telefono', '')) = '' then
    raise exception 'Escriba los datos del acudiente: nombre, documento y teléfono';
  end if;
  if jsonb_array_length(a) > 2 then raise exception 'Máximo dos acudientes'; end if;
  if (select count(*) from admisiones x where x.user_id = priv.uid() and x.colegio_id = k.id and x.estado in ('Recibida', 'Entrevista')) >= 5 then
    raise exception 'Ya tiene 5 solicitudes en revisión en este colegio';
  end if;
  if exists (select 1 from admisiones x where x.colegio_id = k.id and x.anio = coalesce(k.admision_anio, k.anio) and x.estado not in ('No admitida', 'Retirada')
             and x.datos->>'doc' = regexp_replace(d->>'doc', '[\s.]', '', 'g')) then
    raise exception 'Ya hay una solicitud para ese número de documento';
  end if;
  -- solo los campos de la ficha, sin espacios de sobra y en mayúscula (como la ficha de matrícula)
  d := (select coalesce(jsonb_object_agg(x.key, case when x.key in ('fnac', 'email', 'tipo_doc', 'sexo', 'zona', 'estrato', 'rh', 'sisben', 'jornada') then to_jsonb(btrim(x.value))
                                             else to_jsonb(upper(btrim(x.value))) end), '{}')
        from jsonb_each_text(d) x
        where x.key in ('nombres', 'apellidos', 'tipo_doc', 'doc', 'lugar_expedicion', 'fnac', 'lugar_nacimiento', 'sexo', 'direccion', 'barrio', 'municipio', 'zona',
                        'estrato', 'telefono', 'email', 'eps', 'rh', 'sisben', 'institucion_procedencia', 'condicion_especial', 'recomendaciones_medicas', 'jornada')
          and btrim(x.value) <> '');
  d := jsonb_set(d, '{doc}', to_jsonb(regexp_replace(d->>'doc', '[\s.]', '', 'g')));
  d := jsonb_set(d, '{email}', to_jsonb(lower(coalesce(d->>'email', ''))));
  a := (select jsonb_agg(jsonb_build_object('parentesco', upper(btrim(coalesce(x->>'parentesco', ''))), 'nombres', upper(btrim(coalesce(x->>'nombres', ''))),
          'tipo_doc', coalesce(nullif(x->>'tipo_doc', ''), 'CC'), 'doc', regexp_replace(coalesce(x->>'doc', ''), '[\s.]', '', 'g'), 'telefono', btrim(coalesce(x->>'telefono', '')),
          'email', lower(btrim(coalesce(x->>'email', ''))), 'direccion', upper(btrim(coalesce(x->>'direccion', ''))), 'ocupacion', upper(btrim(coalesce(x->>'ocupacion', ''))),
          'responsable_pago', coalesce((x->>'responsable_pago')::boolean, false)) order by o)
        from jsonb_array_elements(a) with ordinality as e(x, o) where btrim(coalesce(x->>'nombres', '')) <> '');
  insert into admisiones (colegio_id, anio, user_id, email, grado, datos, acudientes, comentarios)
  values (k.id, coalesce(k.admision_anio, k.anio), priv.uid(), coalesce(correo, ''), p_grado, d, a, nullif(btrim(coalesce(p_comentarios, '')), ''))
  returning admisiones.id into id;
  return id;
end $$;

-- La familia retira su solicitud (antes de ser matriculada)
create or replace function public.admision_retirar(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform set_config('micolegia.sistema', 'on', true);
  update admisiones set estado = 'Retirada' where id = p_id and user_id = priv.uid() and estado in ('Recibida', 'Entrevista', 'Admitida');
  if not found then raise exception 'No se puede retirar esta solicitud'; end if;
  perform set_config('micolegia.sistema', '', true);
end $$;

-- Matricular una solicitud admitida: crea el estudiante, los acudientes y el acceso de la familia
create or replace function public.admision_matricular(p_id uuid, p_grupo uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare ad admisiones; k colegios; g grupos; d jsonb; e uuid; x jsonb; o int := 0; resp boolean; nombre text;
begin
  select * into ad from admisiones where id = p_id for update;
  if ad.id is null then raise exception 'Solicitud no encontrada'; end if;
  if not (priv.puede(ad.colegio_id, 'matricula') or priv.es_directivo(ad.colegio_id)) then raise exception 'No tiene permiso para matricular'; end if;
  if ad.estado <> 'Admitida' then raise exception 'Primero marque la solicitud como Admitida'; end if;
  select * into k from colegios where id = ad.colegio_id;
  if ad.anio > k.anio then raise exception 'La solicitud es para el año %. Se matricula cuando el colegio cierre el año % (Parametrización › Cierre de año)', ad.anio, k.anio; end if;
  select * into g from grupos where id = p_grupo and colegio_id = ad.colegio_id;
  if g.id is null then raise exception 'Elija el curso'; end if;
  if exists (select 1 from estudiantes s where s.colegio_id = ad.colegio_id and s.doc = ad.datos->>'doc') then
    raise exception 'Ya existe un estudiante con el documento %. Revíselo en Estudiantes y matrícula', ad.datos->>'doc';
  end if;
  d := ad.datos;
  insert into estudiantes (colegio_id, grupo_id, nombres, apellidos, tipo_doc, doc, lugar_expedicion, fnac, lugar_nacimiento, sexo, direccion, barrio, municipio, zona,
    estrato, telefono, email, eps, rh, sisben, institucion_procedencia, condicion_especial, recomendaciones_medicas, jornada, situacion, fecha_matricula,
    acudiente_nombre, acudiente_tel, estado)
  values (ad.colegio_id, g.id, d->>'nombres', d->>'apellidos', d->>'tipo_doc', d->>'doc', d->>'lugar_expedicion', (d->>'fnac')::date, d->>'lugar_nacimiento', d->>'sexo',
    d->>'direccion', d->>'barrio', d->>'municipio', d->>'zona', d->>'estrato', d->>'telefono', nullif(d->>'email', ''), d->>'eps', d->>'rh', d->>'sisben',
    d->>'institucion_procedencia', d->>'condicion_especial', d->>'recomendaciones_medicas', d->>'jornada', 'Nuevo', priv.hoy_co(),
    ad.acudientes->0->>'nombres', ad.acudientes->0->>'telefono', 'Activo')
  returning id into e;
  resp := not exists (select 1 from jsonb_array_elements(ad.acudientes) y where (y->>'responsable_pago')::boolean);
  for x in select * from jsonb_array_elements(ad.acudientes) loop
    o := o + 1;
    insert into acudientes (colegio_id, estudiante_id, orden, parentesco, nombres, tipo_doc, doc, telefono, email, direccion, ocupacion, responsable_pago)
    values (ad.colegio_id, e, o, nullif(x->>'parentesco', ''), x->>'nombres', coalesce(nullif(x->>'tipo_doc', ''), 'CC'), x->>'doc', x->>'telefono', nullif(x->>'email', ''),
            nullif(x->>'direccion', ''), nullif(x->>'ocupacion', ''), coalesce((x->>'responsable_pago')::boolean, false) or (resp and o = 1));
  end loop;
  -- acceso de la familia con la cuenta que hizo la solicitud
  nombre := coalesce((select name from neon_auth."user" where id::text = ad.user_id), ad.acudientes->0->>'nombres', ad.email);
  if not exists (select 1 from miembros m where m.colegio_id = ad.colegio_id and m.rol = 'acudiente' and m.estudiante_id = e and lower(m.email) = lower(ad.email)) then
    insert into miembros (colegio_id, email, nombre, rol, estudiante_id) values (ad.colegio_id, ad.email, upper(nombre), 'acudiente', e);
  end if;
  perform set_config('micolegia.sistema', 'on', true);
  update miembros set user_id = ad.user_id where colegio_id = ad.colegio_id and rol = 'acudiente' and estudiante_id = e and lower(email) = lower(ad.email) and user_id is null;
  update admisiones set estado = 'Matriculada', estudiante_id = e where id = ad.id;
  perform set_config('micolegia.sistema', '', true);
  return e;
end $$;

-- ---------- Matrícula en línea (renovación) ----------
create table if not exists public.matricula_linea (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references colegios(id) on delete cascade,
  estudiante_id uuid not null references estudiantes(id) on delete cascade,
  anio int not null,
  datos_en timestamptz, datos_por text,
  contrato_en timestamptz, firma_nombre text, firma_doc text,
  confirmada_en timestamptz, confirmada_por text,
  observacion text,
  unique (estudiante_id, anio));
alter table public.matricula_linea enable row level security;
revoke all on public.matricula_linea from public, anonymous, authenticated;
grant select on public.matricula_linea to authenticated;
drop policy if exists ml_ver on public.matricula_linea;
create policy ml_ver on public.matricula_linea for select to authenticated
  using (priv.puede(colegio_id, 'matricula') or priv.es_directivo(colegio_id) or priv.ve_pagos(colegio_id) or priv.es_acudiente_de(estudiante_id));

create or replace function priv.ml_abierta(s estudiantes) returns colegios
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare k colegios;
begin
  select * into k from colegios where id = s.colegio_id;
  if not k.matricula_linea or k.matricula_anio is null or (k.matricula_hasta is not null and priv.hoy_co() > k.matricula_hasta) then raise exception 'La matrícula en línea está cerrada'; end if;
  if s.estado <> 'Activo' then raise exception 'La matrícula en línea es para estudiantes activos'; end if;
  return k;
end $$;

-- Paso 1: la familia actualiza los datos del estudiante y de los acudientes
create or replace function public.ml_datos(p_est uuid, p_datos jsonb, p_acudientes jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s estudiantes; k colegios; d jsonb := coalesce(p_datos, '{}'); x jsonb;
begin
  select * into s from estudiantes where id = p_est;
  if s.id is null or not priv.es_acudiente_de(p_est) then raise exception 'Solo el acudiente del estudiante puede hacer la matrícula en línea'; end if;
  k := priv.ml_abierta(s);
  if btrim(coalesce(d->>'direccion', '')) = '' or btrim(coalesce(d->>'municipio', '')) = '' then raise exception 'Escriba la dirección y el municipio'; end if;
  perform set_config('micolegia.sistema', 'on', true);
  update estudiantes set direccion = upper(btrim(d->>'direccion')), barrio = upper(btrim(coalesce(d->>'barrio', ''))), municipio = upper(btrim(d->>'municipio')),
    telefono = btrim(coalesce(d->>'telefono', '')), email = nullif(lower(btrim(coalesce(d->>'email', ''))), ''), eps = upper(btrim(coalesce(d->>'eps', ''))),
    rh = btrim(coalesce(d->>'rh', '')), estrato = btrim(coalesce(d->>'estrato', '')), sisben = btrim(coalesce(d->>'sisben', '')),
    condicion_especial = upper(btrim(coalesce(d->>'condicion_especial', ''))), recomendaciones_medicas = upper(btrim(coalesce(d->>'recomendaciones_medicas', '')))
  where id = p_est;
  for x in select * from jsonb_array_elements(coalesce(p_acudientes, '[]')) loop
    update acudientes set telefono = btrim(coalesce(x->>'telefono', telefono)), email = nullif(lower(btrim(coalesce(x->>'email', ''))), ''),
      direccion = upper(btrim(coalesce(x->>'direccion', ''))), ocupacion = upper(btrim(coalesce(x->>'ocupacion', '')))
    where id = (x->>'id')::uuid and estudiante_id = p_est;
  end loop;
  update estudiantes set acudiente_tel = (select a.telefono from acudientes a where a.estudiante_id = p_est order by a.orden limit 1) where id = p_est;
  insert into matricula_linea (colegio_id, estudiante_id, anio, datos_en, datos_por) values (s.colegio_id, p_est, k.matricula_anio, now(), priv.nombre_actual(s.colegio_id))
  on conflict (estudiante_id, anio) do update set datos_en = now(), datos_por = excluded.datos_por;
  perform set_config('micolegia.sistema', '', true);
end $$;

-- Paso 2: la familia acepta el contrato de matrícula (el pagaré se firma en físico)
create or replace function public.ml_contrato(p_est uuid, p_nombre text, p_doc text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s estudiantes; k colegios; m matricula_linea;
begin
  select * into s from estudiantes where id = p_est;
  if s.id is null or not priv.es_acudiente_de(p_est) then raise exception 'Solo el acudiente del estudiante puede hacer la matrícula en línea'; end if;
  k := priv.ml_abierta(s);
  select * into m from matricula_linea where estudiante_id = p_est and anio = k.matricula_anio;
  if m.datos_en is null then raise exception 'Primero actualice los datos (paso 1)'; end if;
  if length(btrim(coalesce(p_nombre, ''))) < 5 or length(regexp_replace(coalesce(p_doc, ''), '\D', '', 'g')) < 5 then raise exception 'Escriba su nombre completo y su número de documento'; end if;
  if not exists (select 1 from acudientes a where a.estudiante_id = p_est and regexp_replace(coalesce(a.doc, ''), '\D', '', 'g') = regexp_replace(p_doc, '\D', '', 'g')) then
    raise exception 'El documento debe ser el de uno de los acudientes registrados del estudiante';
  end if;
  update matricula_linea set contrato_en = now(), firma_nombre = upper(btrim(p_nombre)), firma_doc = regexp_replace(p_doc, '\D', '', 'g') where id = m.id;
end $$;

-- Paso 3 (colegio): confirmar la matrícula (o quitar la confirmación)
create or replace function public.ml_confirmar(p_est uuid, p_ok boolean, p_obs text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s estudiantes; k colegios;
begin
  select * into s from estudiantes where id = p_est;
  if s.id is null or not (priv.puede(s.colegio_id, 'matricula') or priv.es_directivo(s.colegio_id)) then raise exception 'No tiene permiso para confirmar matrículas'; end if;
  select * into k from colegios where id = s.colegio_id;
  if k.matricula_anio is null then raise exception 'Abra primero la matrícula en línea'; end if;
  insert into matricula_linea (colegio_id, estudiante_id, anio) values (s.colegio_id, p_est, k.matricula_anio) on conflict (estudiante_id, anio) do nothing;
  update matricula_linea set confirmada_en = case when p_ok then now() end, confirmada_por = case when p_ok then priv.nombre_actual(s.colegio_id) end,
    observacion = nullif(btrim(coalesce(p_obs, '')), '')
  where estudiante_id = p_est and anio = k.matricula_anio;
end $$;

-- Contrato: la familia lo ve durante la matrícula en línea; con la matrícula en línea abierta para el año siguiente
-- y los costos de ese año ya puestos, el contrato sale con el año y los costos nuevos
do $$
declare d text := pg_get_functiondef('public.contrato_datos(uuid)'::regprocedure);
begin
  if position('y := case' in d) = 0 then
    d := replace(d, 'if not (priv.puede(s.colegio_id, ''matricula'') or priv.ve_pagos(s.colegio_id)) then',
      'if not (priv.puede(s.colegio_id, ''matricula'') or priv.ve_pagos(s.colegio_id) or (priv.es_acudiente_de(p_est) and exists (select 1 from colegios c where c.id = s.colegio_id and c.matricula_linea))) then');
    d := replace(d, 'declare s estudiantes; k colegios;', 'declare s estudiantes; k colegios; y int;');
    d := replace(d, '  select * into k from colegios where id = s.colegio_id;
  return jsonb_build_object(', '  select * into k from colegios where id = s.colegio_id;
  y := case when k.matricula_linea and k.matricula_anio > k.anio and exists (select 1 from conceptos c where c.colegio_id = k.id and c.anio = k.matricula_anio) then k.matricula_anio else k.anio end;
  return jsonb_build_object(');
    d := replace(d, '''anio'', k.anio,', '''anio'', y,');
    d := replace(d, 'priv.cuenta_base(p_est, k.anio)', 'priv.cuenta_base(p_est, y)');
    d := replace(d, 'bc.anio = k.anio', 'bc.anio = y');
    if position('y := case' in d) = 0 or position('''anio'', y,' in d) = 0 or position('cuenta_base(p_est, y)' in d) = 0 or position('priv.es_acudiente_de(p_est)' in d) = 0 then
      raise exception 'No se pudo ajustar contrato_datos';
    end if;
    execute d;
  end if;
end $$;

revoke all on function public.admision_info(text), public.mis_admisiones(), public.admision_enviar(text, int, jsonb, jsonb, text), public.admision_retirar(uuid),
  public.admision_matricular(uuid, uuid), public.ml_datos(uuid, jsonb, jsonb), public.ml_contrato(uuid, text, text), public.ml_confirmar(uuid, boolean, text) from public, anonymous;
grant execute on function public.admision_info(text), public.mis_admisiones(), public.admision_enviar(text, int, jsonb, jsonb, text), public.admision_retirar(uuid),
  public.admision_matricular(uuid, uuid), public.ml_datos(uuid, jsonb, jsonb), public.ml_contrato(uuid, text, text), public.ml_confirmar(uuid, boolean, text) to authenticated;
revoke all on function priv.ml_abierta(estudiantes) from public, anonymous, authenticated;

-- Colegios que ya existen: su código de enlace
update colegios set admision_codigo = admision_codigo where admision_codigo is null;

notify pgrst, 'reload schema';
