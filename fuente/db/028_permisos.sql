-- Colegio-IA 028 (entrega 5 de la revisión del 19-20 oct 2026): permisos por funcionario, familias y accesos.
--  1) Permisos por cargo que cada colegio marca en Parametrización (colegio pequeño: el rector hace todo; colegio
--     grande: funciones separadas). La base de datos aplica los permisos, no solo la pantalla.
--  2) Autorizaciones: la familia responde una sola vez; para cambiar pide el cambio y coordinación lo aprueba.
--  3) Citas: rectoría y coordinación también pueden confirmar, cambiar o reasignar citas pedidas a otra persona.
--  4) Último acceso de cada usuario; un solo código activa a todos los hijos con el mismo correo.
--  5) Familia: aviso de la cuota del mes antes del día límite; solo el estudiante responde el campus.

-- 1) Permisos -------------------------------------------------------------------------------------------
alter table public.colegios add column if not exists permisos jsonb not null default '{}'::jsonb;

-- Cargos que tienen cada permiso por defecto (si el colegio no lo ha cambiado)
create or replace function priv.permiso_defecto(clave text) returns text[]
language sql immutable as $$
  select case clave
    when 'pagos'          then array['rector','secretaria','tesoreria']   -- registrar y anular pagos, confirmar comprobantes, tienda
    when 'pagos_ver'      then array['rector','secretaria','tesoreria']   -- ver cartera y estados de cuenta
    when 'costos'         then array['rector','tesoreria']                -- costos del año, conceptos, día límite, medios de pago
    when 'matricula'      then array['rector','coordinador','secretaria'] -- matricular, editar fichas, retiros
    when 'contactos'      then array['rector','coordinador','secretaria'] -- contactos de emergencia y quién recoge
    when 'citas'          then array['rector','coordinador']              -- confirmar o reasignar citas de otros
    when 'autorizaciones' then array['rector','coordinador']              -- aprobar cambios de respuesta de las familias
    else array[]::text[] end
$$;
create or replace function priv.permiso_roles(c uuid, clave text) returns text[]
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select array(select jsonb_array_elements_text(k.permisos -> clave)) from colegios k where k.id = c and k.permisos ? clave),
                  priv.permiso_defecto(clave))
$$;
create or replace function priv.puede(c uuid, clave text) returns boolean
language sql stable as $$ select priv.roles_en(c) && priv.permiso_roles(c, clave) $$;
-- Quien registra pagos; y quien solo los ve
create or replace function priv.maneja_pagos(c uuid) returns boolean
language sql stable as $$ select priv.puede(c, 'pagos') $$;
create or replace function priv.ve_pagos(c uuid) returns boolean
language sql stable as $$ select priv.puede(c, 'pagos') or priv.puede(c, 'pagos_ver') $$;

-- Lecturas de cartera: ver basta
drop policy if exists pagos_ver on public.pagos;
create policy pagos_ver on public.pagos for select using (priv.ve_pagos(colegio_id) or priv.es_familia_de(estudiante_id));
drop policy if exists cmp_ver on public.comprobantes;
create policy cmp_ver on public.comprobantes for select using (priv.ve_pagos(colegio_id) or estudiante_id in (select priv.mis_estudiantes()));
drop policy if exists bo_ver on public.bold_ordenes;
create policy bo_ver on public.bold_ordenes for select using (priv.ve_pagos(colegio_id) or priv.es_familia_de(estudiante_id));
drop policy if exists acud_ver on public.acudientes;
create policy acud_ver on public.acudientes for select using (priv.puede_ver_estudiante(estudiante_id) or priv.ve_pagos(colegio_id));
drop policy if exists est_ver on public.estudiantes;
create policy est_ver on public.estudiantes for select using (priv.es_directivo(colegio_id) or priv.ve_pagos(colegio_id) or priv.docente_de_grupo(grupo_id) or priv.es_familia_de(id));
drop policy if exists pe_ver on public.pedidos;
create policy pe_ver on public.pedidos for select using (priv.ve_pagos(colegio_id) or priv.es_familia_de(estudiante_id));
drop policy if exists pi_ver on public.pedido_items;
create policy pi_ver on public.pedido_items for select using (priv.ve_pagos(colegio_id) or exists (select 1 from pedidos p where p.id = pedido_items.pedido_id and priv.es_familia_de(p.estudiante_id)));
drop policy if exists pr_ver on public.productos;
create policy pr_ver on public.productos for select using (priv.ve_pagos(colegio_id) or (activo and priv.es_miembro(colegio_id)));

-- Costos del año y conceptos de cobro
drop policy if exists costos_admin on public.costos_anio;
create policy costos_admin on public.costos_anio for all using (priv.puede(colegio_id, 'costos')) with check (priv.puede(colegio_id, 'costos'));
drop policy if exists conc_admin on public.conceptos;
create policy conc_admin on public.conceptos for all using (priv.puede(colegio_id, 'costos')) with check (priv.puede(colegio_id, 'costos'));

-- Matrícula y fichas
drop policy if exists est_insertar on public.estudiantes;
create policy est_insertar on public.estudiantes for insert with check (priv.puede(colegio_id, 'matricula'));
drop policy if exists est_editar on public.estudiantes;
create policy est_editar on public.estudiantes for update using (priv.puede(colegio_id, 'matricula')) with check (priv.puede(colegio_id, 'matricula'));

-- Contactos de emergencia y personas que recogen: la familia o quien tenga el permiso
drop policy if exists ce_ins on public.contactos_est;
create policy ce_ins on public.contactos_est for insert with check (priv.es_familia_de(estudiante_id)
  or priv.puede((select s.colegio_id from estudiantes s where s.id = contactos_est.estudiante_id), 'contactos'));

-- Cambios del día límite y de los medios de pago (columnas de colegios) por quien tenga el permiso "costos"
create or replace function public.colegio_cobros(p_colegio uuid, p_datos jsonb) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare k colegios; extra text[];
begin
  if not priv.puede(p_colegio, 'costos') then raise exception 'No tiene permiso para cambiar los costos y medios de pago'; end if;
  select array_agg(x) into extra from jsonb_object_keys(p_datos) x
  where x not in ('dia_limite_pago','pago_efectivo','pago_efectivo_texto','pago_llave','pago_llave_valor','pago_llave_titular','pago_bold','pago_bold_url','restringir_morosos');
  if extra is not null then raise exception 'Dato no permitido: %', array_to_string(extra, ', '); end if;
  if p_datos ? 'dia_limite_pago' and (p_datos ->> 'dia_limite_pago')::int not between 1 and 28 then raise exception 'El día límite va de 1 a 28'; end if;
  update colegios set
    dia_limite_pago     = coalesce((p_datos ->> 'dia_limite_pago')::int, dia_limite_pago),
    pago_efectivo       = case when p_datos ? 'pago_efectivo' then (p_datos ->> 'pago_efectivo')::boolean else pago_efectivo end,
    pago_efectivo_texto = case when p_datos ? 'pago_efectivo_texto' then p_datos ->> 'pago_efectivo_texto' else pago_efectivo_texto end,
    pago_llave          = case when p_datos ? 'pago_llave' then (p_datos ->> 'pago_llave')::boolean else pago_llave end,
    pago_llave_valor    = case when p_datos ? 'pago_llave_valor' then p_datos ->> 'pago_llave_valor' else pago_llave_valor end,
    pago_llave_titular  = case when p_datos ? 'pago_llave_titular' then p_datos ->> 'pago_llave_titular' else pago_llave_titular end,
    pago_bold           = case when p_datos ? 'pago_bold' then (p_datos ->> 'pago_bold')::boolean else pago_bold end,
    pago_bold_url       = case when p_datos ? 'pago_bold_url' then p_datos ->> 'pago_bold_url' else pago_bold_url end,
    restringir_morosos  = case when p_datos ? 'restringir_morosos' then (p_datos ->> 'restringir_morosos')::boolean else restringir_morosos end
  where id = p_colegio returning * into k;
  return row_to_json(k);
end $$;
revoke execute on function public.colegio_cobros(uuid, jsonb) from public, anonymous;
grant execute on function public.colegio_cobros(uuid, jsonb) to authenticated;

-- Guardar los permisos (solo el rector o la rectora; el rector siempre conserva Parametrización y Usuarios)
create or replace function public.guardar_permisos(p_colegio uuid, p_permisos jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare clave text; r text; limpio jsonb := '{}';
begin
  if not priv.es_rector(p_colegio) then raise exception 'Solo el rector o la rectora pueden cambiar los permisos'; end if;
  for clave in select jsonb_object_keys(p_permisos) loop
    if clave not in ('pagos','pagos_ver','costos','matricula','contactos','citas','autorizaciones') then raise exception 'Permiso desconocido: %', clave; end if;
    for r in select jsonb_array_elements_text(p_permisos -> clave) loop
      if r not in ('rector','coordinador','secretaria','tesoreria','docente') then raise exception 'Cargo no válido: %', r; end if;
    end loop;
    limpio := limpio || jsonb_build_object(clave, (select coalesce(jsonb_agg(distinct x), '[]') from jsonb_array_elements_text(p_permisos -> clave) x));
  end loop;
  if jsonb_array_length(coalesce(limpio -> 'pagos', to_jsonb(priv.permiso_defecto('pagos')))) = 0 then
    raise exception 'Al menos un cargo debe poder registrar pagos';
  end if;
  update colegios set permisos = limpio where id = p_colegio;
  return limpio;
end $$;
revoke execute on function public.guardar_permisos(uuid, jsonb) from public, anonymous;
grant execute on function public.guardar_permisos(uuid, jsonb) to authenticated;

-- 2) Autorizaciones: respuesta única; el cambio se pide y lo aprueba quien tenga el permiso -----------------
alter table public.respuestas_aut add column if not exists cambio_pedido_en timestamptz;
alter table public.respuestas_aut add column if not exists cambio_motivo text;
alter table public.respuestas_aut add column if not exists cambio_por text;
alter table public.respuestas_aut add column if not exists historial jsonb not null default '[]'::jsonb;
drop policy if exists raut_mod on public.respuestas_aut;   -- la familia ya no cambia su respuesta directamente

create or replace function public.pedir_cambio_aut(p_aut uuid, p_est uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare n text;
begin
  if not exists (select 1 from miembros m where m.user_id = priv.uid() and m.activo and m.rol = 'acudiente' and m.estudiante_id = p_est) then
    raise exception 'Solo el acudiente puede pedir el cambio';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 5 then raise exception 'Escriba por qué necesita cambiar la respuesta'; end if;
  select nombre into n from miembros m where m.user_id = priv.uid() and m.estudiante_id = p_est limit 1;
  update respuestas_aut set cambio_pedido_en = now(), cambio_motivo = left(btrim(p_motivo), 500), cambio_por = n
  where autorizacion_id = p_aut and estudiante_id = p_est;
  if not found then raise exception 'Primero responda la autorización'; end if;
end $$;
create or replace function public.resolver_cambio_aut(p_aut uuid, p_est uuid, p_aprobar boolean, p_nota text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare a autorizaciones; r respuestas_aut; quien text;
begin
  select * into a from autorizaciones where id = p_aut;
  if a.id is null or not priv.puede(a.colegio_id, 'autorizaciones') then raise exception 'No tiene permiso para resolver cambios de autorizaciones'; end if;
  select * into r from respuestas_aut where autorizacion_id = p_aut and estudiante_id = p_est;
  if r.cambio_pedido_en is null then raise exception 'No hay una solicitud de cambio pendiente'; end if;
  quien := coalesce((select nombre from miembros where user_id = priv.uid() and colegio_id = a.colegio_id and activo order by creado_en limit 1), 'Colegio');
  update respuestas_aut set
    historial = historial || jsonb_build_object('fecha', now(), 'antes', r.autoriza, 'motivo', r.cambio_motivo, 'pidio', r.cambio_por,
                                                'resuelto_por', quien, 'aprobado', p_aprobar, 'nota', nullif(btrim(coalesce(p_nota, '')), '')),
    autoriza = case when p_aprobar then not r.autoriza else r.autoriza end,
    respondido_en = case when p_aprobar then now() else respondido_en end,
    cambio_pedido_en = null, cambio_motivo = null, cambio_por = null
  where autorizacion_id = p_aut and estudiante_id = p_est;
end $$;
revoke execute on function public.pedir_cambio_aut(uuid, uuid, text), public.resolver_cambio_aut(uuid, uuid, boolean, text) from public, anonymous;
grant execute on function public.pedir_cambio_aut(uuid, uuid, text), public.resolver_cambio_aut(uuid, uuid, boolean, text) to authenticated;

-- 3) Citas: quien tenga el permiso también confirma, cambia o reasigna ---------------------------------------
drop policy if exists cit_mod on public.citas;
create policy cit_mod on public.citas for update
  using (priv.es_mi_miembro(personal_id) or priv.puede(colegio_id, 'citas')
         or estudiante_id in (select m.estudiante_id from miembros m where m.user_id = priv.uid() and m.activo and m.rol = 'acudiente'))
  with check (priv.es_mi_miembro(personal_id) or priv.puede(colegio_id, 'citas')
         or estudiante_id in (select m.estudiante_id from miembros m where m.user_id = priv.uid() and m.activo and m.rol = 'acudiente'));

do $$
declare d text;
begin
  d := pg_get_functiondef('priv.tg_citas'::regproc);
  if position('''citas'')' in d) = 0 then
    d := replace(d, 'personal := priv.es_mi_miembro(old.personal_id);', 'personal := priv.es_mi_miembro(old.personal_id) or priv.puede(old.colegio_id, ''citas'');');
    if position('''citas'')' in d) = 0 then raise exception 'No se pudo actualizar tg_citas'; end if;
    execute d;
  end if;
end $$;

-- 4) Último acceso y un solo código para varios hijos -----------------------------------------------------
alter table public.miembros add column if not exists ultimo_acceso timestamptz;
create or replace function public.marcar_acceso(p_miembro uuid) returns void
language sql security definer set search_path = public, pg_temp as $$
  update miembros set ultimo_acceso = now()
  where id = p_miembro and user_id = priv.uid() and (ultimo_acceso is null or ultimo_acceso < now() - interval '5 minutes')
$$;
revoke execute on function public.marcar_acceso(uuid) from public, anonymous;
grant execute on function public.marcar_acceso(uuid) to authenticated;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.activar_cuenta'::regproc);
  if position('otros hijos' in d) = 0 then
    d := replace(d, $q$  update miembros set user_id = priv.uid() where id = m.id;$q$,
      $q$  update miembros set user_id = priv.uid() where id = m.id;
  -- otros hijos: con un solo código quedan vinculados todos los estudiantes del mismo acudiente (mismo correo, mismo colegio)
  if m.rol = 'acudiente' then
    update miembros set user_id = priv.uid() where colegio_id = m.colegio_id and rol = 'acudiente' and activo and user_id is null and lower(email) = lower(correo);
  end if;$q$);
    if position('otros hijos' in d) = 0 then raise exception 'No se pudo actualizar activar_cuenta'; end if;
    execute d;
  end if;
end $$;

-- 5) Familia: aviso de la cuota del mes antes del día límite --------------------------------------------
create or replace function public.mi_situacion_familia(p_colegio uuid) returns json
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(json_agg(json_build_object('estudiante_id', m.estudiante_id, 'al_dia', not (k.restringir_morosos and priv.debe_vencido(m.estudiante_id)),
           'debe', priv.debe_vencido(m.estudiante_id),
           'por_vencer', (select coalesce(sum(x.saldo), 0) from estado_cuenta(m.estudiante_id, k.anio) x where not x.vencido and x.saldo > 0
                          and x.mes is not null and x.mes <= extract(month from priv.hoy_co())::int),
           'dia_limite', k.dia_limite_pago)), '[]'::json)
  from miembros m join colegios k on k.id = m.colegio_id
  where m.colegio_id = p_colegio and m.user_id = priv.uid() and m.activo and m.estudiante_id is not null
$$;

-- 5b) Solo el estudiante (no el acudiente) abre y responde cuestionarios y entrega tareas del campus
create or replace function priv.soy_estudiante(p_est uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from miembros m where m.user_id = priv.uid() and m.activo and m.rol = 'estudiante' and m.estudiante_id = p_est)
$$;
do $$
declare f text; d text;
begin
  foreach f in array array['public.campus_cuestionario(uuid, uuid)', 'public.campus_responder(uuid, uuid, jsonb)', 'public.campus_entregar(uuid, uuid, text, text)'] loop
    d := pg_get_functiondef(f::regprocedure);
    if position('soy_estudiante' in d) = 0 then
      d := replace(d, '  i := priv.item_para(p_item, p_est);',
        '  if not priv.soy_estudiante(p_est) then raise exception ''Las evaluaciones y tareas las responde el estudiante desde su propia cuenta''; end if;' || chr(10) || '  i := priv.item_para(p_item, p_est);');
      if position('soy_estudiante' in d) = 0 then raise exception 'No se pudo actualizar %', f; end if;
      execute d;
    end if;
  end loop;
end $$;

-- 6) Cierre de sesión por inactividad (opcional, lo fija el rector; 0 = nunca)
alter table public.colegios add column if not exists cierre_inactividad int not null default 0;
alter table public.colegios drop constraint if exists colegios_inactividad_chk;
alter table public.colegios add constraint colegios_inactividad_chk check (cierre_inactividad in (0, 15, 30, 60, 120));
grant update (cierre_inactividad) on public.colegios to authenticated;

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
notify pgrst, 'reload schema';

-- Lecturas de cartera con el permiso "ver": cartera, estado de cuenta y resumen
do $$
declare f text; d text;
begin
  foreach f in array array['cartera', 'estado_cuenta', 'resumen_colegio'] loop
    for d in select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = f loop
      if position('priv.maneja_pagos(' in d) > 0 then execute replace(d, 'priv.maneja_pagos(', 'priv.ve_pagos('); end if;
    end loop;
  end loop;
end $$;
notify pgrst, 'reload schema';
