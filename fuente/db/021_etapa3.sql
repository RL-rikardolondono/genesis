-- Colegio-IA 021 (etapa 3): tienda del colegio con pedidos, lista de útiles por grado.
-- Los gráficos que cruzan variables se calculan en la app con los datos que ya existen (no necesitan tablas).
-- Pagos de la tienda: familia -> colegio, con los medios que el colegio eligió (efectivo, llave Bre-B, Bold propio).
-- El precio y el total los fija la base de datos al crear el pedido (la app no puede cambiarlos).

-- 1) Tienda activa y texto de entrega, por colegio
alter table public.colegios add column if not exists tienda_activa boolean not null default false;
alter table public.colegios add column if not exists tienda_texto text;
grant update (tienda_activa, tienda_texto) on public.colegios to authenticated;

-- 2) Productos
create table if not exists public.productos (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  categoria text not null default 'Otros' check (categoria in ('Uniformes','Libros y textos','Agendas y útiles','Stickers y marcación','Ruta escolar','Alimentación','Refuerzos y cursos','Derechos de grado','Eventos y salidas','Otros')),
  nombre text not null check (length(btrim(nombre)) between 3 and 120),
  descripcion text check (descripcion is null or length(descripcion) <= 500),
  precio numeric(12,0) not null check (precio > 0 and precio <= 20000000),
  opciones text check (opciones is null or length(opciones) <= 300),   -- tallas o variantes separadas por coma
  grados int[] not null default '{}',                                  -- vacío = todos los grados
  imagen text check (imagen is null or (length(imagen) < 120000 and imagen ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$')),
  con_imagen boolean generated always as (imagen is not null) stored,
  activo boolean not null default true,
  orden int not null default 0,
  creado_en timestamptz not null default now()
);
create index if not exists productos_col on public.productos (colegio_id, activo);
alter table public.productos enable row level security;
grant select, insert, update, delete on public.productos to authenticated;
drop policy if exists pr_ver on public.productos;
create policy pr_ver on public.productos for select to authenticated using (priv.maneja_pagos(colegio_id) or (activo and priv.es_miembro(colegio_id)));
drop policy if exists pr_esc on public.productos;
create policy pr_esc on public.productos for all to authenticated using (priv.maneja_pagos(colegio_id)) with check (priv.maneja_pagos(colegio_id));

-- 3) Pedidos y sus artículos (se crean y cambian solo con las funciones de abajo)
create table if not exists public.pedidos (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  numero int not null,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  estado text not null default 'Por pagar' check (estado in ('Por pagar','Por confirmar','Pagado','Listo para entregar','Entregado','Cancelado')),
  medio text not null check (medio in ('efectivo','llave','bold')),
  total numeric(12,0) not null check (total > 0),
  nota text check (nota is null or length(nota) <= 300),
  referencia text check (referencia is null or length(referencia) <= 60),
  comprobante text check (comprobante is null or (length(comprobante) < 250000 and comprobante ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$')),
  con_comprobante boolean generated always as (comprobante is not null) stored,
  respuesta text check (respuesta is null or length(respuesta) <= 300),
  visto_familia boolean not null default true,
  creado_por text,
  creado_nombre text,
  atendido_nombre text,
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  pagado_en timestamptz,
  entregado_en timestamptz,
  unique (colegio_id, numero)
);
create index if not exists pedidos_est on public.pedidos (estudiante_id, creado_en desc);
create index if not exists pedidos_col on public.pedidos (colegio_id, estado);
create table if not exists public.pedido_items (
  id uuid primary key default gen_random_uuid(),
  pedido_id uuid not null references public.pedidos(id) on delete cascade,
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  producto_id uuid references public.productos(id) on delete set null,
  nombre text not null,
  categoria text,
  opcion text,
  cantidad int not null check (cantidad between 1 and 20),
  precio numeric(12,0) not null check (precio > 0),
  subtotal numeric(12,0) not null
);
create index if not exists pedido_items_p on public.pedido_items (pedido_id);
alter table public.pedidos enable row level security;
alter table public.pedido_items enable row level security;
revoke all on public.pedidos, public.pedido_items from authenticated;
grant select on public.pedidos, public.pedido_items to authenticated;
drop policy if exists pe_ver on public.pedidos;
create policy pe_ver on public.pedidos for select to authenticated using (priv.maneja_pagos(colegio_id) or priv.es_familia_de(estudiante_id));
drop policy if exists pi_ver on public.pedido_items;
create policy pi_ver on public.pedido_items for select to authenticated
  using (priv.maneja_pagos(colegio_id) or exists (select 1 from pedidos p where p.id = pedido_id and priv.es_familia_de(p.estudiante_id)));

-- Acudiente activo del estudiante (los estudiantes no compran)
create or replace function priv.es_acudiente_de(e uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from miembros m join colegios k on k.id = m.colegio_id
    where m.estudiante_id = e and m.user_id = priv.uid() and m.rol = 'acudiente' and m.activo and k.activo)
$$;

create or replace function public.crear_pedido(p_estudiante uuid, p_items jsonb, p_medio text, p_nota text default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare s estudiantes; k colegios; g int; it jsonb; pr productos; op text; cant int; tot numeric := 0; n int; pid uuid; lineas int := 0;
begin
  if not priv.es_acudiente_de(p_estudiante) then raise exception 'Solo el acudiente del estudiante puede hacer pedidos'; end if;
  select * into s from estudiantes where id = p_estudiante;
  select * into k from colegios where id = s.colegio_id;
  if not k.tienda_activa then raise exception 'La tienda del colegio no está disponible en este momento'; end if;
  if p_medio not in ('efectivo','llave','bold')
     or (p_medio = 'efectivo' and not k.pago_efectivo)
     or (p_medio = 'llave' and not (k.pago_llave and k.pago_llave_valor is not null))
     or (p_medio = 'bold' and not (k.pago_bold and k.pago_bold_url is not null)) then
    raise exception 'Elija un medio de pago que el colegio reciba';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Su pedido está vacío'; end if;
  if jsonb_array_length(p_items) > 15 then raise exception 'Un pedido puede tener hasta 15 artículos distintos'; end if;
  if (select count(*) from pedidos where estudiante_id = p_estudiante and estado in ('Por pagar','Por confirmar')) >= 3 then
    raise exception 'Tiene 3 pedidos sin pagar. Pague o cancele alguno antes de hacer otro.';
  end if;
  if length(coalesce(p_nota, '')) > 300 then raise exception 'La nota es muy larga'; end if;
  select gr.grado into g from grupos gr where gr.id = s.grupo_id;
  perform pg_advisory_xact_lock(hashtext('pedidos:' || k.id::text));
  select coalesce(max(numero), 0) + 1 into n from pedidos where colegio_id = k.id;
  insert into pedidos (colegio_id, numero, estudiante_id, medio, total, nota, creado_por, creado_nombre)
  values (k.id, n, p_estudiante, p_medio, 1, nullif(btrim(coalesce(p_nota, '')), ''), priv.uid(),
          (select max(m.nombre) from miembros m where m.user_id = priv.uid() and m.estudiante_id = p_estudiante and m.activo)) returning id into pid;
  for it in select * from jsonb_array_elements(p_items) loop
    select * into pr from productos where id = (it ->> 'producto')::uuid and colegio_id = k.id and activo;
    if pr.id is null then raise exception 'Uno de los artículos ya no está disponible. Revise su pedido.'; end if;
    if cardinality(pr.grados) > 0 and (g is null or not g = any(pr.grados)) then raise exception '"%" no está disponible para el grado del estudiante', pr.nombre; end if;
    cant := coalesce((it ->> 'cantidad')::int, 1);
    if cant < 1 or cant > 20 then raise exception 'La cantidad debe estar entre 1 y 20'; end if;
    op := nullif(btrim(coalesce(it ->> 'opcion', '')), '');
    if coalesce(btrim(pr.opciones), '') <> '' then
      if op is null or not op = any(select btrim(x) from unnest(string_to_array(pr.opciones, ',')) x) then
        raise exception 'Elija la talla u opción de "%"', pr.nombre;
      end if;
    else op := null;
    end if;
    insert into pedido_items (pedido_id, colegio_id, producto_id, nombre, categoria, opcion, cantidad, precio, subtotal)
    values (pid, k.id, pr.id, pr.nombre, pr.categoria, op, cant, pr.precio, pr.precio * cant);
    tot := tot + pr.precio * cant; lineas := lineas + 1;
  end loop;
  update pedidos set total = tot where id = pid;
  return pid;
end $$;

-- La familia envía el comprobante (llave Bre-B o Bold del colegio)
create or replace function public.comprobante_pedido(p_pedido uuid, p_imagen text, p_referencia text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare p pedidos;
begin
  select * into p from pedidos where id = p_pedido;
  if p.id is null or not priv.es_acudiente_de(p.estudiante_id) then raise exception 'No tiene permiso para esta acción'; end if;
  if p.estado not in ('Por pagar','Por confirmar') then raise exception 'Este pedido ya no espera comprobante'; end if;
  if p_imagen is null and coalesce(btrim(p_referencia), '') = '' then raise exception 'Adjunte la foto del comprobante o escriba la referencia'; end if;
  update pedidos set comprobante = p_imagen, referencia = nullif(btrim(coalesce(p_referencia, '')), ''), estado = 'Por confirmar', respuesta = null, actualizado_en = now()
   where id = p_pedido;
end $$;

-- Cambio de estado: la familia solo cancela si aún no ha pagado; el colegio confirma, prepara, entrega, rechaza o cancela
create or replace function public.estado_pedido(p_pedido uuid, p_estado text, p_respuesta text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare p pedidos; staff boolean;
begin
  select * into p from pedidos where id = p_pedido;
  if p.id is null then raise exception 'Pedido no encontrado'; end if;
  staff := priv.maneja_pagos(p.colegio_id);
  if not staff then
    if not (priv.es_acudiente_de(p.estudiante_id) and p_estado = 'Cancelado' and p.estado in ('Por pagar','Por confirmar')) then
      raise exception 'Solo puede cancelar un pedido que aún no se ha pagado';
    end if;
    update pedidos set estado = 'Cancelado', comprobante = null, actualizado_en = now() where id = p_pedido;
    return;
  end if;
  if length(coalesce(p_respuesta, '')) > 300 then raise exception 'La respuesta es muy larga'; end if;
  if p.estado = 'Entregado' then raise exception 'El pedido ya fue entregado'; end if;
  if p.estado = 'Cancelado' then raise exception 'El pedido está cancelado'; end if;
  if p_estado = 'Por pagar' then          -- rechazo del comprobante
    if p.estado <> 'Por confirmar' then raise exception 'Solo se puede rechazar un comprobante por confirmar'; end if;
    if coalesce(btrim(p_respuesta), '') = '' then raise exception 'Escriba el motivo para la familia'; end if;
  elsif p_estado = 'Cancelado' then
    if p.estado in ('Pagado','Listo para entregar') and coalesce(btrim(p_respuesta), '') = '' then
      raise exception 'El pedido ya está pagado: escriba el motivo de la cancelación (y acuerde la devolución con la familia)';
    end if;
  elsif p_estado not in ('Pagado','Listo para entregar','Entregado') then raise exception 'Estado no válido';
  end if;
  update pedidos set estado = p_estado, respuesta = nullif(btrim(coalesce(p_respuesta, '')), ''),
         comprobante = case when p_estado in ('Pagado','Por pagar','Cancelado') then null else comprobante end,
         pagado_en = case when p_estado in ('Pagado','Listo para entregar','Entregado') then coalesce(pagado_en, now()) else pagado_en end,
         entregado_en = case when p_estado = 'Entregado' then now() else entregado_en end,
         atendido_nombre = priv.nombre_actual(p.colegio_id), visto_familia = false, actualizado_en = now()
   where id = p_pedido;
end $$;

create or replace function public.pedidos_vistos(p_estudiante uuid)
returns void language sql security definer set search_path = public, pg_temp as $$
  update pedidos set visto_familia = true where estudiante_id = p_estudiante and not visto_familia and priv.es_familia_de(p_estudiante)
$$;

-- 4) Lista de útiles por grado y año
create table if not exists public.utiles (
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  anio int not null,
  grado int not null check (grado between -2 and 11),
  lista text not null default '' check (length(lista) <= 6000),
  nota text check (nota is null or length(nota) <= 600),
  actualizado_nombre text,
  actualizado_en timestamptz not null default now(),
  primary key (colegio_id, anio, grado)
);
create or replace function priv.tg_utiles() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin new.actualizado_en := now(); new.actualizado_nombre := priv.nombre_actual(new.colegio_id); return new; end $$;
drop trigger if exists tg_utiles on public.utiles;
create trigger tg_utiles before insert or update on public.utiles for each row execute function priv.tg_utiles();
alter table public.utiles enable row level security;
grant select, insert, update, delete on public.utiles to authenticated;
drop policy if exists ut_ver on public.utiles;
create policy ut_ver on public.utiles for select to authenticated using (priv.es_miembro(colegio_id));
drop policy if exists ut_esc on public.utiles;
create policy ut_esc on public.utiles for all to authenticated using (priv.es_directivo(colegio_id)) with check (priv.es_directivo(colegio_id));

-- 5) Bloqueo por suscripción vencida también en las tablas nuevas
do $$
declare t text;
begin
  foreach t in array array['productos', 'pedidos', 'pedido_items', 'utiles'] loop
    execute format('drop trigger if exists zz_bloqueo on public.%I', t);
    execute format('create trigger zz_bloqueo before insert or update or delete on public.%I for each row execute function priv.tg_bloqueo()', t);
  end loop;
end $$;

-- 6) Datos de ejemplo en el colegio de demostración (se restauran cada día con crear_demo)
create or replace function priv.demo_tienda(c uuid, a int) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update colegios set tienda_activa = true, tienda_texto = 'Los pedidos pagados se entregan en la secretaría, de lunes a viernes de 7:00 a. m. a 12:00 m., o se envían con el estudiante.' where id = c;
  insert into productos (colegio_id, categoria, nombre, descripcion, precio, opciones, orden) values
    (c, 'Uniformes', 'Camiseta de diario', 'Camiseta blanca tipo polo con el escudo bordado.', 45000, '4, 6, 8, 10, 12, 14, S, M', 1),
    (c, 'Uniformes', 'Sudadera de educación física', 'Pantalón y chaqueta en algodón perchado.', 98000, '4, 6, 8, 10, 12, 14, S, M', 2),
    (c, 'Agendas y útiles', 'Agenda escolar ' || a, 'Agenda oficial del colegio con el manual de convivencia.', 28000, null, 3),
    (c, 'Stickers y marcación', 'Stickers marcadores (paquete de 60)', 'Con el nombre del estudiante, para cuadernos y útiles.', 18000, null, 4),
    (c, 'Libros y textos', 'Plan lector del año', 'Dos libros del plan lector del grado.', 76000, null, 5),
    (c, 'Refuerzos y cursos', 'Curso de refuerzo de matemáticas', 'Ocho sesiones los sábados de 8:00 a 10:00 a. m.', 120000, null, 6),
    (c, 'Eventos y salidas', 'Salida pedagógica al acuario', 'Incluye transporte, entrada y refrigerio.', 65000, null, 7);
  insert into productos (colegio_id, categoria, nombre, descripcion, precio, grados, orden)
  values (c, 'Derechos de grado', 'Derechos de grado de Transición', 'Toga, birrete, diploma y ceremonia.', 150000, '{0}', 8);
  insert into utiles (colegio_id, anio, grado, lista, nota)
  select c, a, gr.grado,
    case when gr.grado <= 0 then '1 cuaderno ferrocarril grande' || chr(10) || '1 caja de colores triangulares' || chr(10) || '1 caja de plastilina' || chr(10) || '2 lápices negros triangulares' || chr(10) || '1 tijeras punta roma' || chr(10) || '1 pegante en barra' || chr(10) || '1 block iris' || chr(10) || '1 delantal plástico'
         else '5 cuadernos cuadriculados de 100 hojas' || chr(10) || '3 cuadernos rayados de 100 hojas' || chr(10) || '1 caja de colores' || chr(10) || '2 lápices negros n.º 2' || chr(10) || '1 borrador y 1 sacapuntas' || chr(10) || '1 regla de 30 cm' || chr(10) || '1 diccionario de español' || chr(10) || '1 block cuadriculado' end,
    'Marque todos los útiles con el nombre del estudiante. Se reciben en la primera semana de clases.'
  from (select distinct grado from grupos where colegio_id = c) gr;
end $$;
do $$
declare d text;
begin
  d := pg_get_functiondef('priv.crear_demo'::regproc);
  if position('demo_tienda' in d) = 0 then
    d := replace(d, '  delete from notas_log where colegio_id = c;', '  perform priv.demo_tienda(c, a);' || chr(10) || '  delete from notas_log where colegio_id = c;');
    if position('demo_tienda' in d) = 0 then raise notice 'No se encontró dónde agregar la tienda a la demostración'; return; end if;
    execute d;
  end if;
end $$;
-- Llenar ya el colegio de demostración actual (sin esperar a la restauración del día)
do $$
declare c uuid; a int;
begin
  select id, anio into c, a from colegios where demo order by creado_en desc nulls last limit 1;
  if c is not null and not exists (select 1 from productos where colegio_id = c) then perform priv.demo_tienda(c, a); end if;
end $$;

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
revoke execute on function public.crear_pedido(uuid, jsonb, text, text), public.comprobante_pedido(uuid, text, text), public.estado_pedido(uuid, text, text), public.pedidos_vistos(uuid) from public;
grant execute on function public.crear_pedido(uuid, jsonb, text, text), public.comprobante_pedido(uuid, text, text), public.estado_pedido(uuid, text, text), public.pedidos_vistos(uuid) to authenticated;
notify pgrst, 'reload schema';
