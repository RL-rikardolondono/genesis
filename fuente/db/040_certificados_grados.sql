-- 040 · Colegio-IA v0.25 (6 nov 2026): certificados verificables, grados y actas
-- 1) Cada certificado, constancia, informe final, acta de grado y diploma que se imprime queda registrado con un código
--    de verificación. Quien lo recibe lo verifica en colegio-ia.skynetgenesis.com/?verificar=CODIGO (con una cuenta gratis).
-- 2) Grados: la secretaría asigna a cada graduando número de acta, libro y folio; se imprimen el acta individual, el diploma
--    y el libro de actas de grado.
-- 3) Actas de la comisión de evaluación y promoción por curso y periodo (Decreto 1290 de 2009).
-- Se puede ejecutar más de una vez.

-- ---------- Documentos emitidos (verificables) ----------
create table if not exists public.documentos_emitidos (
  id uuid primary key default gen_random_uuid(),
  codigo text not null unique,
  colegio_id uuid not null references colegios(id) on delete cascade,
  estudiante_id uuid references estudiantes(id) on delete set null,
  tipo text not null,
  anio int,
  titulo text not null,
  resumen jsonb not null default '{}',     -- lo que el verificador ve: estudiante, documento, grado, resultado…
  huella text not null,                    -- para no repetir el mismo documento el mismo día
  emitido_por text,
  emitido_en timestamptz not null default now(),
  anulado_en timestamptz, anulado_por text, motivo_anulacion text);
create index if not exists docemit_colegio on public.documentos_emitidos (colegio_id, emitido_en desc);
create index if not exists docemit_huella on public.documentos_emitidos (colegio_id, huella);
alter table public.documentos_emitidos enable row level security;
revoke all on public.documentos_emitidos from public, anonymous, authenticated;
grant select on public.documentos_emitidos to authenticated;
drop policy if exists docemit_ver on public.documentos_emitidos;
create policy docemit_ver on public.documentos_emitidos for select to authenticated using (priv.es_directivo(colegio_id));

-- Registra el documento y devuelve su código (XXXX-XXXX). El mismo documento el mismo día conserva el código.
create or replace function public.emitir_documento(p_colegio uuid, p_est uuid, p_tipo text, p_anio int, p_titulo text, p_resumen jsonb) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare h text; c text; r jsonb := coalesce(p_resumen, '{}');
begin
  if not (priv.es_directivo(p_colegio) or priv.ve_pagos(p_colegio) or (p_est is not null and priv.es_acudiente_de(p_est))) then
    raise exception 'No tiene permiso para emitir documentos';
  end if;
  if p_est is not null and not exists (select 1 from estudiantes s where s.id = p_est and s.colegio_id = p_colegio) then raise exception 'Estudiante no válido'; end if;
  if p_tipo not in ('constancia', 'certificado', 'certificado_anio', 'informe_final', 'acta_grado', 'diploma', 'paz_salvo', 'retiro') then raise exception 'Tipo de documento no válido'; end if;
  h := md5(coalesce(p_est::text, '') || '|' || p_tipo || '|' || coalesce(p_anio, 0) || '|' || r::text || '|' || priv.hoy_co());
  select codigo into c from documentos_emitidos where colegio_id = p_colegio and huella = h and anulado_en is null limit 1;
  if c is not null then return c; end if;
  loop
    c := upper(substr(translate(replace(gen_random_uuid()::text, '-', ''), '01', ''), 1, 8));
    c := substr(c, 1, 4) || '-' || substr(c, 5, 4);
    exit when length(c) = 9 and not exists (select 1 from documentos_emitidos where codigo = c);
  end loop;
  insert into documentos_emitidos (codigo, colegio_id, estudiante_id, tipo, anio, titulo, resumen, huella, emitido_por)
  values (c, p_colegio, p_est, p_tipo, p_anio, left(coalesce(p_titulo, p_tipo), 120), r, h, priv.nombre_actual(p_colegio));
  return c;
end $$;

-- Verificación: cualquier persona con sesión iniciada
create or replace function public.verificar_documento(p_codigo text) returns json
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare d documentos_emitidos; k colegios; c text := upper(regexp_replace(coalesce(p_codigo, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  if priv.uid() is null then raise exception 'Debe iniciar sesión'; end if;
  if length(c) = 8 then c := substr(c, 1, 4) || '-' || substr(c, 5, 4); end if;
  select * into d from documentos_emitidos where codigo = c;
  if d.id is null then return json_build_object('valido', false); end if;
  select * into k from colegios where id = d.colegio_id;
  return json_build_object('valido', d.anulado_en is null, 'anulado', d.anulado_en is not null, 'motivo', d.motivo_anulacion, 'codigo', d.codigo,
    'colegio', k.nombre, 'ciudad', k.ciudad, 'dane', k.dane, 'titulo', d.titulo, 'anio', d.anio, 'emitido_en', d.emitido_en, 'resumen', d.resumen);
end $$;

create or replace function public.anular_documento(p_id uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare d documentos_emitidos;
begin
  select * into d from documentos_emitidos where id = p_id;
  if d.id is null or not priv.es_directivo(d.colegio_id) then raise exception 'No tiene permiso'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 4 then raise exception 'Escriba el motivo de la anulación'; end if;
  update documentos_emitidos set anulado_en = now(), anulado_por = priv.nombre_actual(d.colegio_id), motivo_anulacion = btrim(p_motivo) where id = p_id and anulado_en is null;
end $$;

-- ---------- Grados ----------
alter table public.colegios add column if not exists grados_cfg jsonb not null default '{}';   -- titulo, fecha, libro, resolución
grant update (grados_cfg) on public.colegios to authenticated;
create table if not exists public.grados (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references colegios(id) on delete cascade,
  estudiante_id uuid not null references estudiantes(id) on delete cascade,
  anio int not null,
  titulo text not null,
  fecha date not null,
  acta int not null,
  libro text, folio text, diploma text,
  creado_por text, creado_en timestamptz not null default now(),
  unique (estudiante_id, titulo),
  unique (colegio_id, acta));
alter table public.grados enable row level security;
revoke all on public.grados from public, anonymous, authenticated;
grant select on public.grados to authenticated;
drop policy if exists grados_ver on public.grados;
create policy grados_ver on public.grados for select to authenticated using (priv.es_directivo(colegio_id) or priv.es_acudiente_de(estudiante_id));

-- Asigna acta, libro y folio consecutivos a los graduandos elegidos
create or replace function public.registrar_grados(p_colegio uuid, p_ests uuid[], p_titulo text, p_fecha date, p_libro text, p_acta_desde int, p_folio_desde int) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare k colegios; e uuid; n int := 0; a int; f int;
begin
  if not (priv.es_rector(p_colegio) or priv.puede(p_colegio, 'matricula')) then raise exception 'Solo la rectoría o la secretaría registran grados'; end if;
  if length(btrim(coalesce(p_titulo, ''))) < 5 then raise exception 'Escriba el título que se otorga'; end if;
  if p_fecha is null then raise exception 'Escriba la fecha de la ceremonia de grado'; end if;
  select * into k from colegios where id = p_colegio;
  a := greatest(coalesce(p_acta_desde, 1), coalesce((select max(acta) + 1 from grados where colegio_id = p_colegio), 1));
  f := coalesce(p_folio_desde, 1);
  foreach e in array coalesce(p_ests, '{}') loop
    if not exists (select 1 from estudiantes s where s.id = e and s.colegio_id = p_colegio) then continue; end if;
    if exists (select 1 from grados g where g.estudiante_id = e and g.titulo = upper(btrim(p_titulo))) then continue; end if;
    insert into grados (colegio_id, estudiante_id, anio, titulo, fecha, acta, libro, folio, diploma, creado_por)
    values (p_colegio, e, k.anio, upper(btrim(p_titulo)), p_fecha, a, nullif(btrim(coalesce(p_libro, '')), ''), f::text, k.anio || '-' || lpad(a::text, 4, '0'), priv.nombre_actual(p_colegio));
    a := a + 1; f := f + 1; n := n + 1;
  end loop;
  update colegios set grados_cfg = coalesce(grados_cfg, '{}') || jsonb_build_object('titulo', upper(btrim(p_titulo)), 'fecha', p_fecha, 'libro', p_libro) where id = p_colegio;
  return n;
end $$;

create or replace function public.quitar_grado(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare g grados;
begin
  select * into g from grados where id = p_id;
  if g.id is null or not priv.es_rector(g.colegio_id) then raise exception 'Solo la rectoría puede quitar un registro de grado'; end if;
  delete from grados where id = p_id;
end $$;

-- ---------- Actas de la comisión de evaluación y promoción ----------
create table if not exists public.actas_comision (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references colegios(id) on delete cascade,
  anio int not null,
  periodo int not null,          -- 0 = comisión de promoción (fin de año)
  grupo_id uuid references grupos(id) on delete cascade,
  numero int,
  fecha date not null default current_date,
  asistentes text,
  casos jsonb not null default '[]',   -- estudiantes con desempeño bajo y la decisión de cada uno
  conclusiones text,
  creado_por text, actualizado_en timestamptz not null default now(),
  unique (colegio_id, anio, periodo, grupo_id));
alter table public.actas_comision enable row level security;
revoke all on public.actas_comision from public, anonymous, authenticated;
grant select, insert, update, delete on public.actas_comision to authenticated;
drop policy if exists actas_dir on public.actas_comision;
create policy actas_dir on public.actas_comision for all to authenticated using (priv.es_directivo(colegio_id)) with check (priv.es_directivo(colegio_id));
create or replace function priv.tg_actas() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' and new.numero is null then
    select coalesce(max(numero), 0) + 1 into new.numero from actas_comision where colegio_id = new.colegio_id and anio = new.anio;
  end if;
  if tg_op = 'UPDATE' then new.colegio_id := old.colegio_id; new.numero := old.numero; end if;
  new.creado_por := coalesce(new.creado_por, priv.nombre_actual(new.colegio_id)); new.actualizado_en := now();
  return new;
end $$;
drop trigger if exists tg_actas on public.actas_comision;
create trigger tg_actas before insert or update on public.actas_comision for each row execute function priv.tg_actas();

revoke all on function public.emitir_documento(uuid, uuid, text, int, text, jsonb), public.verificar_documento(text), public.anular_documento(uuid, text),
  public.registrar_grados(uuid, uuid[], text, date, text, int, int), public.quitar_grado(uuid) from public, anonymous;
grant execute on function public.emitir_documento(uuid, uuid, text, int, text, jsonb), public.verificar_documento(text), public.anular_documento(uuid, text),
  public.registrar_grados(uuid, uuid[], text, date, text, int, int), public.quitar_grado(uuid) to authenticated;

notify pgrst, 'reload schema';
