-- Colegio-IA 025: las familias pagan en línea con el Bold PROPIO de cada colegio (sus llaves), sin enviar comprobantes.
--  - El rector conecta las llaves del Bold del colegio (llave de identidad y llave secreta). La llave secreta queda guardada
--    en la base de datos y nunca vuelve a la pantalla.
--  - La familia marca las cuotas; la base de datos calcula el valor con el estado de cuenta, crea la orden y la firma de Bold.
--  - El pago se registra solo: cuando alguien de tesorería, secretaría o rectoría tiene Colegio-IA abierto, la app consulta
--    a Bold el estado de cada orden y, si está aprobada y cubre el valor, la base de datos registra el pago y su recibo.
-- (Esto es lo que la familia le paga al colegio; la suscripción del colegio a SkyNet Genesis sigue con el Bold de SkyNet.)

alter table public.colegios add column if not exists pago_bold_auto boolean not null default false;
alter table public.colegios add column if not exists bold_llave_id text;

create table if not exists public.colegio_bold (
  colegio_id uuid primary key references public.colegios(id) on delete cascade,
  llave_id text not null,
  secreto text not null,
  actualizado_en timestamptz not null default now(),
  actualizado_nombre text
);
alter table public.colegio_bold enable row level security;
revoke all on public.colegio_bold from authenticated, anonymous;

create table if not exists public.bold_ordenes (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  orden text not null unique,
  valor numeric(12,0) not null check (valor > 0),
  items jsonb not null,
  estado text not null default 'Pendiente' check (estado in ('Pendiente','Aprobada','Rechazada','Sin completar','Duplicado')),
  creado_nombre text,
  creado_en timestamptz not null default now(),
  aplicado_en timestamptz,
  aplicado_nombre text,
  bold_ref text,
  recibo int
);
alter table public.bold_ordenes drop constraint if exists bold_ordenes_estado_check;
alter table public.bold_ordenes add constraint bold_ordenes_estado_check check (estado in ('Pendiente','Aprobada','Rechazada','Sin completar','Duplicado'));
create index if not exists bold_ordenes_col on public.bold_ordenes (colegio_id, estado, creado_en desc);
create index if not exists bold_ordenes_est on public.bold_ordenes (estudiante_id, creado_en desc);
alter table public.bold_ordenes enable row level security;
revoke all on public.bold_ordenes from authenticated, anonymous;
grant select on public.bold_ordenes to authenticated;
drop policy if exists bo_ver on public.bold_ordenes;
create policy bo_ver on public.bold_ordenes for select to authenticated using (priv.maneja_pagos(colegio_id) or priv.es_familia_de(estudiante_id));

-- 1) El rector conecta o desconecta el Bold del colegio
create or replace function public.bold_colegio_guardar(p_colegio uuid, p_llave_id text, p_secreto text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare l text := btrim(coalesce(p_llave_id, '')); s text := btrim(coalesce(p_secreto, ''));
begin
  if not priv.es_rector(p_colegio) then raise exception 'Solo el rector o la rectora pueden conectar el Bold del colegio'; end if;
  if (select demo from colegios where id = p_colegio) then raise exception 'En el colegio de demostración no se conectan llaves de Bold'; end if;
  if l !~ '^[A-Za-z0-9_-]{20,120}$' then raise exception 'La llave de identidad no parece válida. Cópiela completa desde el panel de Bold'; end if;
  if s !~ '^[A-Za-z0-9_-]{16,120}$' then raise exception 'La llave secreta no parece válida. Cópiela completa desde el panel de Bold'; end if;
  if l = s then raise exception 'La llave de identidad y la llave secreta deben ser distintas'; end if;
  insert into colegio_bold (colegio_id, llave_id, secreto, actualizado_nombre) values (p_colegio, l, s, priv.nombre_actual(p_colegio))
  on conflict (colegio_id) do update set llave_id = excluded.llave_id, secreto = excluded.secreto, actualizado_en = now(), actualizado_nombre = excluded.actualizado_nombre;
  perform set_config('micolegia.sistema', 'on', true);
  update colegios set pago_bold_auto = true, bold_llave_id = l, pago_bold = true where id = p_colegio;
  perform set_config('micolegia.sistema', '', true);
end $$;
create or replace function public.bold_colegio_quitar(p_colegio uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not priv.es_rector(p_colegio) then raise exception 'Solo el rector o la rectora pueden desconectar el Bold del colegio'; end if;
  delete from colegio_bold where colegio_id = p_colegio;
  perform set_config('micolegia.sistema', 'on', true);
  update colegios set pago_bold_auto = false, bold_llave_id = null where id = p_colegio;
  perform set_config('micolegia.sistema', '', true);
end $$;
-- La app nunca escribe estas dos columnas directamente
create or replace function priv.tg_colegios_bold() returns trigger
language plpgsql as $$
begin
  if priv.es_cliente() and current_setting('micolegia.sistema', true) is distinct from 'on' then
    new.pago_bold_auto := old.pago_bold_auto; new.bold_llave_id := old.bold_llave_id;
  end if;
  return new;
end $$;
drop trigger if exists tg_colegios_bold on public.colegios;
create trigger tg_colegios_bold before update on public.colegios for each row execute function priv.tg_colegios_bold();

-- 2) La familia crea la orden: el valor sale del estado de cuenta (la pantalla no puede cambiarlo)
create or replace function public.bold_familia_orden(p_est uuid, p_items jsonb) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare s estudiantes; k colegios; b colegio_bold; it jsonb; x record; tot numeric := 0; lista jsonb := '[]'; o text; y int; n int := 0;
begin
  select * into s from estudiantes where id = p_est;
  if s.id is null or not priv.es_familia_de(p_est) then raise exception 'No tiene permiso para esta acción'; end if;
  select * into k from colegios where id = s.colegio_id;
  select * into b from colegio_bold where colegio_id = s.colegio_id;
  if not k.pago_bold_auto or b.colegio_id is null then raise exception 'El colegio no tiene activo el pago en línea con Bold'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Marque las cuotas que va a pagar'; end if;
  if jsonb_array_length(p_items) > 30 then raise exception 'Puede pagar hasta 30 cuotas en un solo pago'; end if;
  if exists (select 1 from bold_ordenes where estudiante_id = p_est and estado = 'Pendiente' and creado_en > now() - interval '10 minutes') then
    raise exception 'Tiene un pago en línea en proceso. Si no lo terminó, espere 10 minutos e inténtelo de nuevo.';
  end if;
  if (select count(*) from bold_ordenes where estudiante_id = p_est and creado_en > now() - interval '1 hour') >= 10 then
    raise exception 'Ya intentó varios pagos en la última hora. Espere un momento o comuníquese con la tesorería del colegio.';
  end if;
  for it in select value from jsonb_array_elements(p_items) loop
    n := n + 1;
    y := coalesce((it ->> 'anio')::int, k.anio);
    if y < k.anio - 5 or y > k.anio then raise exception 'Año no válido en la cuota %', n; end if;
    select * into x from estado_cuenta(p_est, y) e
     where e.concepto_id = (it ->> 'concepto_id')::uuid and e.mes is not distinct from (it ->> 'mes')::int and e.saldo > 0 limit 1;
    if x.concepto_id is null then raise exception 'Una de las cuotas marcadas ya no tiene saldo pendiente. Actualice la pantalla.'; end if;
    if lista @> jsonb_build_array(jsonb_build_object('concepto_id', x.concepto_id, 'anio', y, 'mes', x.mes)) then continue; end if;
    lista := lista || jsonb_build_array(jsonb_build_object('concepto_id', x.concepto_id, 'anio', y, 'mes', x.mes, 'valor', x.saldo, 'concepto', x.concepto));
    tot := tot + x.saldo;
  end loop;
  if tot < 1000 then raise exception 'El valor mínimo para pagar en línea es $1.000'; end if;
  o := 'CIA-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16));
  insert into bold_ordenes (colegio_id, estudiante_id, orden, valor, items, creado_nombre)
  values (s.colegio_id, p_est, o, tot, lista, coalesce((select max(m.nombre) from miembros m where m.colegio_id = s.colegio_id and m.user_id = priv.uid()), 'Familia'));
  return json_build_object('orderId', o, 'amount', tot::bigint, 'currency', 'COP', 'apiKey', b.llave_id,
    'signature', encode(digest(o || tot::bigint::text || 'COP' || b.secreto, 'sha256'), 'hex'),
    'description', left(k.nombre || ' - ' || s.nombres || ' ' || s.apellidos, 100));
end $$;

-- 3) Tesorería, secretaría o rectoría (desde su pantalla, tras consultar a Bold) registra la orden aprobada
create or replace function public.bold_familia_aplicar(p_orden text, p_estado text, p_valor numeric, p_ref text) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare o bold_ordenes; it jsonb; x record; v numeric; rec int; lote uuid := gen_random_uuid(); n int := 0; quien text;
begin
  select * into o from bold_ordenes where orden = p_orden for update;
  if o.id is null or not priv.maneja_pagos(o.colegio_id) then raise exception 'No tiene permiso para esta acción'; end if;
  if o.estado in ('Aprobada', 'Duplicado') then return json_build_object('ok', true, 'repetido', true, 'recibo', o.recibo); end if;
  quien := priv.nombre_actual(o.colegio_id);
  if p_estado in ('REJECTED', 'FAILED', 'VOIDED') then
    update bold_ordenes set estado = 'Rechazada', aplicado_en = now(), aplicado_nombre = quien, bold_ref = left(p_ref, 80) where id = o.id;
    return json_build_object('ok', true, 'estado', 'Rechazada');
  end if;
  if p_estado = 'NO_ENCONTRADA' then
    if o.creado_en < now() - interval '2 hours' then update bold_ordenes set estado = 'Sin completar' where id = o.id; end if;
    return json_build_object('ok', true, 'estado', 'Sin completar');
  end if;
  if p_estado not in ('APPROVED', 'MANUAL') then return json_build_object('ok', false, 'estado', 'Pendiente'); end if;
  if p_estado = 'APPROVED' and coalesce(p_valor, 0) < o.valor then
    raise exception 'Bold aprobó un valor menor al de la orden (% de %). Revíselo en el panel de Bold y regístrelo a mano.', p_valor, o.valor;
  end if;
  for it in select value from jsonb_array_elements(o.items) loop
    select * into x from estado_cuenta(o.estudiante_id, (it ->> 'anio')::int) e
     where e.concepto_id = (it ->> 'concepto_id')::uuid and e.mes is not distinct from (it ->> 'mes')::int limit 1;
    v := least((it ->> 'valor')::numeric, coalesce(x.saldo, 0));
    if v > 0 then
      insert into pagos (colegio_id, estudiante_id, concepto_id, anio, mes, valor, fecha, medio, referencia, observacion, lote)
      values (o.colegio_id, o.estudiante_id, (it ->> 'concepto_id')::uuid, (it ->> 'anio')::int, (it ->> 'mes')::int, v, priv.hoy_co(), 'Bold',
              'Bold ' || o.orden || coalesce(' · ' || left(p_ref, 60), ''), 'Pago en línea de la familia', lote)
      returning recibo into rec;
      n := n + 1;
    end if;
  end loop;
  -- si las cuotas ya estaban pagadas por otro medio, el pago queda como duplicado para que el colegio lo devuelva desde Bold
  update bold_ordenes set estado = case when n = 0 then 'Duplicado' else 'Aprobada' end, aplicado_en = now(), aplicado_nombre = quien, bold_ref = left(p_ref, 80), recibo = rec where id = o.id;
  return json_build_object('ok', true, 'estado', case when n = 0 then 'Duplicado' else 'Aprobada' end, 'recibo', rec, 'cuotas', n);
end $$;

-- 4) Permisos
revoke execute on function public.bold_colegio_guardar(uuid, text, text), public.bold_colegio_quitar(uuid), public.bold_familia_orden(uuid, jsonb), public.bold_familia_aplicar(text, text, numeric, text) from public, anonymous;
grant execute on function public.bold_colegio_guardar(uuid, text, text), public.bold_colegio_quitar(uuid), public.bold_familia_orden(uuid, jsonb), public.bold_familia_aplicar(text, text, numeric, text) to authenticated;

do $$
declare t text;
begin
  foreach t in array array['bold_ordenes', 'colegio_bold'] loop
    execute format('drop trigger if exists zz_bloqueo on public.%I', t);
    execute format('create trigger zz_bloqueo before insert or update or delete on public.%I for each row execute function priv.tg_bloqueo()', t);
  end loop;
end $$;

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
notify pgrst, 'reload schema';
