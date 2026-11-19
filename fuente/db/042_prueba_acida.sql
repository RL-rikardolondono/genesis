-- 042 · Colegio-IA v0.27 (18 nov 2026): correcciones de la Prueba Ácida (5 colegios × 7 perfiles)
-- 1) Documentos verificables: la familia solo obtiene código para lo que pidió y pagó; retiro solo de retirados
-- 2) Cobro de la suscripción (regla de SkyNet Genesis del 18 nov): aviso del día 1 al 5 y cierre al terminar el día 5,
--    con la hora de Colombia; la prueba gratis llega completa hasta su último día
-- 3) Nadie cambia su propio cargo y el colegio nunca queda sin rector; «último acceso» de todo el personal
-- 4) Un acudiente que ya tiene cuenta recibe a sus otros hijos sin código nuevo
-- 5) Periodos: pesos mayores que 0 y asignaturas en bajo ≥ 1 (lo revisa la base)
-- 6) Pagos: un doble clic no registra dos veces; anular un recibo es un permiso aparte (por defecto la rectoría)
-- 7) Acuerdos de pago: quedan registrados; mientras se cumplan, la familia tiene acceso completo
-- 8) Calificaciones: lectura rápida en colegios grandes; la nota de un cuestionario oculto no se deja ver en el promedio;
--    la calificación que el docente ya había puesto no se pierde al crear la primera actividad
-- 9) Contrato de la matrícula en línea con el año que se matricula; paz y salvo cuenta lo de meses anteriores
-- Se puede ejecutar más de una vez.
begin;

-- ---------- 1) Documentos verificables ----------
do $$
declare d text := pg_get_functiondef('public.emitir_documento(uuid, uuid, text, integer, text, jsonb)'::regprocedure);
begin
  if position('Primero pida y pague este documento' in d) = 0 then
    d := replace(d, $q$  select * into s from estudiantes where id = p_est and colegio_id = p_colegio;
  if p_est is not null and s.id is null then raise exception 'Estudiante no válido'; end if;$q$,
      $q$  select * into s from estudiantes where id = p_est and colegio_id = p_colegio;
  if p_est is not null and s.id is null then raise exception 'Estudiante no válido'; end if;
  if p_tipo = 'retiro' and s.estado = 'Activo' then raise exception 'La constancia de retiro solo se expide para estudiantes retirados'; end if;
  if not dir and not priv.ve_pagos(p_colegio) then   -- la familia: solo lo que pidió y ya está pagado (la pantalla lo cobra; la base lo exige)
    if p_tipo = 'informe_final' then raise exception 'El informe final lo expide la secretaría del colegio'; end if;
    if not exists (select 1 from doc_solicitudes ds where ds.estudiante_id = p_est and ds.estado = 'Pagado'
        and ds.tipo = case p_tipo when 'certificado_anio' then 'anteriores' when 'paz_salvo' then 'pazysalvo' else p_tipo end
        and case when p_tipo = 'certificado_anio' then ds.anio = p_anio else ds.pagado_en > now() - interval '30 days' end) then
      raise exception 'Primero pida y pague este documento en «Documentos»';
    end if;
    if p_tipo = 'paz_salvo' and exists (select 1 from colegios kk cross join lateral estado_cuenta(p_est, kk.anio) ec
        where kk.id = p_colegio and ec.saldo > 0 and (ec.vencido or ec.mes < extract(month from priv.hoy_co()))) then
      raise exception 'Tiene saldo pendiente. El paz y salvo se expide cuando esté al día (vea Estado de cuenta)';
    end if;
  end if;$q$);
    if position('Primero pida y pague este documento' in d) = 0 then raise exception 'No se pudo ajustar emitir_documento'; end if;
    execute d;
  end if;
end $$;

-- Paz y salvo pedido por la familia: también cuenta lo de meses anteriores aunque haya entrado hoy (matrícula a mitad de año)
do $$
declare d text := pg_get_functiondef('public.pedir_documento(uuid, text, integer, integer, text)'::regprocedure);
begin
  if position('e.mes < extract(month from priv.hoy_co())' in d) = 0 then
    d := replace(d, 'from estado_cuenta(p_est, k.anio) e where e.vencido and e.saldo > 0)',
                    'from estado_cuenta(p_est, k.anio) e where e.saldo > 0 and (e.vencido or e.mes < extract(month from priv.hoy_co())))');
    if position('e.mes < extract(month from priv.hoy_co())' in d) = 0 then raise exception 'No se pudo ajustar pedir_documento'; end if;
    execute d;
  end if;
end $$;

-- ---------- 2) Cobro de la suscripción ----------
-- activa: hasta la fecha pagada · aviso: días 1 a 5 después · cerrada: desde el día 6 (al terminar el día 5)
create or replace function priv.estado_cobro(p_activo boolean, p_demo boolean, p_hasta date) returns text language sql stable as $$
  select case when not p_activo then 'suspendido'
              when p_demo or p_hasta is null or priv.hoy_co() <= p_hasta then 'activa'
              when priv.hoy_co() - p_hasta <= 5 then 'aviso'
              else 'cerrada' end $$;
create or replace function priv.acceso_ok(p_activo boolean, p_demo boolean, p_hasta date) returns boolean language sql stable as $$
  select p_activo and (p_demo or p_hasta is null or priv.hoy_co() - p_hasta <= 5) $$;
-- Compatibilidad: las funciones existentes calculan los días que quedan como «10 − dias_sin_pago»; así dan 5, 4, 3, 2, 1
create or replace function priv.dias_sin_pago(p_hasta date) returns int language sql stable as $$
  select greatest(priv.hoy_co() - p_hasta, 0) + 4 $$;
create or replace function priv.meses_debe(p_hasta date) returns int language sql stable as $$
  select greatest(1, ((extract(year from priv.hoy_co()) * 12 + extract(month from priv.hoy_co())) - (extract(year from p_hasta) * 12 + extract(month from p_hasta)))::int) $$;

-- El superadministrador ve también la prueba gratis
drop function if exists public.plataforma_resumen();
create function public.plataforma_resumen()
 returns table(colegio_id uuid, nombre text, ciudad text, activo boolean, estudiantes_activos integer, valor_mensual integer, creado_en timestamptz,
               anio integer, pagado_hasta date, meses_pendientes integer, plan_max integer, demo boolean, en_mora boolean, cobro text, dias integer,
               comprobante_id uuid, interna boolean, interna_motivo text, prueba_hasta date)
 language plpgsql stable security definer set search_path = public, pg_temp as $function$
begin
  if not priv.es_superadmin() then raise exception 'Sin permiso'; end if;
  return query
    select k.id, k.nombre, k.ciudad, k.activo,
           (select count(*)::int from estudiantes s where s.colegio_id = k.id and s.estado = 'Activo'),
           case when k.demo or k.interna then 0 else precio_plan(k.plan_max) end,
           k.creado_en, k.anio, k.pagado_hasta,
           case when k.demo or k.interna or priv.hoy_co() <= k.pagado_hasta then 0 else priv.meses_debe(k.pagado_hasta) end,
           k.plan_max, k.demo, priv.en_mora(k.id),
           priv.estado_cobro(k.activo, k.demo, k.pagado_hasta),
           case when priv.estado_cobro(k.activo, k.demo, k.pagado_hasta) = 'aviso' then 10 - priv.dias_sin_pago(k.pagado_hasta) end,
           (select pc.id from plataforma_comprobantes pc where pc.colegio_id = k.id and pc.estado = 'Pendiente'),
           k.interna, k.interna_motivo,
           case when not k.interna and k.prueba_hasta >= priv.hoy_co()
                 and not exists (select 1 from plataforma_pagos pp where pp.colegio_id = k.id) then k.prueba_hasta end
    from colegios k order by k.creado_en;
end $function$;
revoke all on function public.plataforma_resumen() from public, anonymous;
grant execute on function public.plataforma_resumen() to authenticated;

-- ---------- 3) Usuarios: cargo propio, último rector, último acceso ----------
create or replace function priv.tg_miembros_permiso() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare dir text[] := array['rector','coordinador','secretaria','tesoreria'];
begin
  if not priv.es_cliente() or priv.es_superadmin() then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then
    if old.bloqueo_motivo is not null then raise exception 'Esta cuenta está bloqueada por la administración de Colegio-IA y no se puede quitar'; end if;
    if old.rol = any(dir) and not priv.es_rector(old.colegio_id) then raise exception 'Solo el rector o la rectora pueden quitar usuarios directivos'; end if;
    if old.user_id = priv.uid() and old.rol = any(dir) then raise exception 'No puede quitar su propio usuario'; end if;
    if old.rol = 'rector' and old.activo and not exists (select 1 from miembros m where m.colegio_id = old.colegio_id and m.rol = 'rector' and m.activo and m.id <> old.id) then
      raise exception 'El colegio debe tener siempre un rector o una rectora activo';
    end if;
    return old;
  end if;
  if (new.rol = any(dir) or (tg_op = 'UPDATE' and old.rol = any(dir))) and not priv.es_rector(new.colegio_id) then
    raise exception 'Solo el rector o la rectora pueden crear o cambiar usuarios directivos (rectoría, coordinación, secretaría y tesorería)';
  end if;
  if tg_op = 'UPDATE' then
    if old.user_id = priv.uid() and new.rol <> old.rol then raise exception 'No puede cambiar su propio cargo'; end if;
    if old.user_id = priv.uid() and old.activo and not new.activo then raise exception 'No puede desactivar su propio usuario'; end if;
    if old.rol = 'rector' and old.activo and (new.rol <> 'rector' or not new.activo)
       and not exists (select 1 from miembros m where m.colegio_id = old.colegio_id and m.rol = 'rector' and m.activo and m.id <> old.id) then
      raise exception 'El colegio debe tener siempre un rector o una rectora activo';
    end if;
  end if;
  return new;
end $$;

-- «Último acceso»: lo marca el sistema (antes fallaba para coordinación, secretaría y tesorería por la regla de directivos)
create or replace function public.marcar_acceso(p_miembro uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform set_config('micolegia.sistema', 'on', true);
  update miembros set ultimo_acceso = now()
  where id = p_miembro and user_id = priv.uid() and (ultimo_acceso is null or ultimo_acceso < now() - interval '5 minutes');
  perform set_config('micolegia.sistema', '', true);
end $$;
revoke all on function public.marcar_acceso(uuid) from public, anonymous;
grant execute on function public.marcar_acceso(uuid) to authenticated;

-- ---------- 4) Otro hijo de un acudiente que ya tiene cuenta: queda vinculado sin código ----------
create or replace function priv.tg_miembros_hijo() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.rol = 'acudiente' and new.user_id is null and new.activo then
    select m.user_id into new.user_id from miembros m
    where m.colegio_id = new.colegio_id and m.rol = 'acudiente' and m.activo and m.user_id is not null and lower(m.email) = lower(new.email)
    limit 1;
  end if;
  return new;
end $$;
drop trigger if exists tg_miembros_zhijo on public.miembros;
create trigger tg_miembros_zhijo before insert on public.miembros for each row execute function priv.tg_miembros_hijo();

-- ---------- 5) Periodos y escala ----------
create or replace function priv.tg_colegios_periodos() returns trigger
language plpgsql as $$
declare p jsonb;
begin
  for p in select jsonb_array_elements(coalesce(new.periodos, '[]') || coalesce(new.periodos_ciclos, '[]')) loop
    if coalesce((p ->> 'peso')::numeric, 0) <= 0 then raise exception 'Cada periodo debe pesar un porcentaje mayor que 0'; end if;
  end loop;
  if new.max_perdidas < 1 then raise exception 'Las asignaturas en bajo para no promover deben ser 1 o más'; end if;
  return new;
end $$;
drop trigger if exists tg_colegios_periodos on public.colegios;
create trigger tg_colegios_periodos before insert or update of periodos, periodos_ciclos, max_perdidas on public.colegios
  for each row execute function priv.tg_colegios_periodos();

-- ---------- 6) Pagos: doble registro y anulación ----------
create or replace function priv.tg_pagos_doble() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if priv.uid() is not null and exists (select 1 from pagos p where p.estudiante_id = new.estudiante_id and p.anio = new.anio
       and p.concepto_id is not distinct from new.concepto_id and p.mes is not distinct from new.mes and p.valor = new.valor and not p.anulado
       and p.registrado_por = priv.uid() and p.lote is distinct from new.lote and p.registrado_en > now() - interval '20 seconds') then
    raise exception 'Ese pago ya se registró hace unos segundos. Revise los recibos antes de registrarlo otra vez';
  end if;
  return new;
end $$;
drop trigger if exists tg_pagos_doble on public.pagos;
create trigger tg_pagos_doble before insert on public.pagos for each row execute function priv.tg_pagos_doble();

create or replace function priv.permiso_defecto(clave text) returns text[]
language sql immutable as $$
  select case clave
    when 'pagos'          then array['rector','secretaria','tesoreria']   -- registrar pagos, confirmar comprobantes, tienda
    when 'pagos_ver'      then array['rector','secretaria','tesoreria']   -- ver cartera y estados de cuenta
    when 'costos'         then array['rector','tesoreria']                -- costos del año, conceptos, día límite, medios de pago
    when 'matricula'      then array['rector','coordinador','secretaria'] -- matricular, editar fichas, retiros
    when 'contactos'      then array['rector','coordinador','secretaria'] -- contactos de emergencia y quién recoge
    when 'citas'          then array['rector','coordinador']              -- confirmar o reasignar citas de otros
    when 'autorizaciones' then array['rector','coordinador']              -- aprobar cambios de respuesta de las familias
    when 'becas'          then array['rector']                            -- asignar y anular becas, subsidios y descuentos
    when 'anular'         then array['rector']                            -- anular recibos ya registrados
    else array[]::text[] end
$$;
create or replace function public.guardar_permisos(p_colegio uuid, p_permisos jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare clave text; r text; limpio jsonb := '{}';
begin
  if not priv.es_rector(p_colegio) then raise exception 'Solo el rector o la rectora pueden cambiar los permisos'; end if;
  for clave in select jsonb_object_keys(p_permisos) loop
    if clave not in ('pagos','pagos_ver','costos','matricula','contactos','citas','autorizaciones','becas','anular') then raise exception 'Permiso desconocido: %', clave; end if;
    for r in select jsonb_array_elements_text(p_permisos -> clave) loop
      if r not in ('rector','coordinador','secretaria','tesoreria','docente') then raise exception 'Cargo no válido: %', r; end if;
    end loop;
    limpio := limpio || jsonb_build_object(clave, (select coalesce(jsonb_agg(distinct x), '[]') from jsonb_array_elements_text(p_permisos -> clave) x));
  end loop;
  if jsonb_array_length(coalesce(limpio -> 'pagos', to_jsonb(priv.permiso_defecto('pagos')))) = 0 then
    raise exception 'Al menos un cargo debe poder registrar pagos';
  end if;
  if jsonb_array_length(coalesce(limpio -> 'anular', to_jsonb(priv.permiso_defecto('anular')))) = 0 then
    raise exception 'Al menos un cargo debe poder anular recibos';
  end if;
  update colegios set permisos = limpio where id = p_colegio;
  return limpio;
end $$;
revoke all on function public.guardar_permisos(uuid, jsonb) from public, anonymous;
grant execute on function public.guardar_permisos(uuid, jsonb) to authenticated;

create or replace function priv.tg_pagos_anular() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if priv.es_cliente() and new.anulado and not old.anulado then
    if not priv.puede(old.colegio_id, 'anular') then
      raise exception 'Anular un recibo lo hace quien tenga el permiso «Anular recibos» (por defecto, la rectoría)';
    end if;
    if old.registrado_por = priv.uid() and not priv.es_rector(old.colegio_id) then
      raise exception 'Quien registró el pago no puede anular su propio recibo: pídaselo a la rectoría';
    end if;
    if length(btrim(coalesce(new.anulado_motivo, ''))) < 4 then raise exception 'Escriba el motivo de la anulación'; end if;
  end if;
  return new;
end $$;
drop trigger if exists tg_pagos_anular on public.pagos;
create trigger tg_pagos_anular before update on public.pagos for each row execute function priv.tg_pagos_anular();

-- ---------- 7) Acuerdos de pago ----------
create table if not exists public.acuerdos_pago (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references colegios(id) on delete cascade,
  estudiante_id uuid not null references estudiantes(id) on delete cascade,
  numero text,
  total numeric(12,0) not null check (total > 0),
  inicial numeric(12,0) not null default 0 check (inicial >= 0),
  cuotas jsonb not null default '[]',          -- [{fecha, valor}]
  estado text not null default 'Vigente' check (estado in ('Vigente','Terminado')),
  motivo text,
  creado_por text, creado_nombre text, creado_en timestamptz not null default now(),
  terminado_nombre text, terminado_en timestamptz);
create index if not exists acuerdos_est on public.acuerdos_pago (estudiante_id, estado);
alter table public.acuerdos_pago enable row level security;
revoke all on public.acuerdos_pago from public, anonymous, authenticated;
grant select on public.acuerdos_pago to authenticated;
drop policy if exists acuerdos_ver on public.acuerdos_pago;
create policy acuerdos_ver on public.acuerdos_pago for select to authenticated using (priv.ve_pagos(colegio_id) or priv.es_familia_de(estudiante_id));

-- ¿Va al día con su acuerdo? Lo pagado desde la firma cubre la cuota inicial (5 días de gracia) y las cuotas vencidas hace más de 5 días
create or replace function priv.acuerdo_al_dia(e uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from acuerdos_pago a
    where a.estudiante_id = e and a.estado = 'Vigente'
      and priv.hoy_co() <= coalesce((select max((c ->> 'fecha')::date) from jsonb_array_elements(a.cuotas) c), (a.creado_en at time zone 'America/Bogota')::date) + 5
      and coalesce((select sum(p.valor) from pagos p where p.estudiante_id = e and not p.anulado and p.registrado_en >= a.creado_en), 0)
          >= case when priv.hoy_co() > (a.creado_en at time zone 'America/Bogota')::date + 5 then a.inicial else 0 end
             + coalesce((select sum((c ->> 'valor')::numeric) from jsonb_array_elements(a.cuotas) c where (c ->> 'fecha')::date < priv.hoy_co() - 5), 0))
$$;
-- Con un acuerdo al día, la familia no queda restringida por la deuda que reconoció
create or replace function priv.debe_vencido(e uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select not priv.acuerdo_al_dia(e) and exists (
    select 1 from estudiantes s join colegios k on k.id = s.colegio_id
    cross join lateral generate_series(greatest(extract(year from k.creado_en)::int, k.anio - 5), k.anio) y
    cross join lateral estado_cuenta(s.id, y) x
    where s.id = e and x.vencido and x.saldo > 0)
$$;

create or replace function public.acuerdo_guardar(p_est uuid, p_numero text, p_total numeric, p_inicial numeric, p_cuotas jsonb) returns acuerdos_pago
language plpgsql security definer set search_path = public, pg_temp as $$
declare s estudiantes; r acuerdos_pago; c jsonb;
begin
  select * into s from estudiantes where id = p_est;
  if s.id is null or not priv.maneja_pagos(s.colegio_id) then raise exception 'No tiene permiso para registrar acuerdos de pago'; end if;
  if coalesce(p_total, 0) <= 0 then raise exception 'El acuerdo necesita una deuda mayor que 0'; end if;
  if coalesce(p_inicial, 0) < 0 or coalesce(p_inicial, 0) > p_total then raise exception 'Revise la cuota inicial'; end if;
  for c in select jsonb_array_elements(coalesce(p_cuotas, '[]')) loop
    if (c ->> 'fecha') is null or coalesce((c ->> 'valor')::numeric, 0) <= 0 then raise exception 'Revise las cuotas del acuerdo'; end if;
  end loop;
  update acuerdos_pago set estado = 'Terminado', motivo = 'Reemplazado por un acuerdo nuevo', terminado_nombre = priv.nombre_actual(s.colegio_id), terminado_en = now()
   where estudiante_id = p_est and estado = 'Vigente';
  insert into acuerdos_pago (colegio_id, estudiante_id, numero, total, inicial, cuotas, creado_por, creado_nombre)
  values (s.colegio_id, p_est, left(p_numero, 30), round(p_total), round(coalesce(p_inicial, 0)), coalesce(p_cuotas, '[]'), priv.uid(), priv.nombre_actual(s.colegio_id))
  returning * into r;
  return r;
end $$;
create or replace function public.acuerdo_terminar(p_id uuid, p_motivo text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare a acuerdos_pago;
begin
  select * into a from acuerdos_pago where id = p_id;
  if a.id is null or not priv.maneja_pagos(a.colegio_id) then raise exception 'No tiene permiso'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 4 then raise exception 'Escriba el motivo'; end if;
  update acuerdos_pago set estado = 'Terminado', motivo = btrim(p_motivo), terminado_nombre = priv.nombre_actual(a.colegio_id), terminado_en = now() where id = p_id;
end $$;
revoke all on function public.acuerdo_guardar(uuid, text, numeric, numeric, jsonb), public.acuerdo_terminar(uuid, text) from public, anonymous;
grant execute on function public.acuerdo_guardar(uuid, text, numeric, numeric, jsonb), public.acuerdo_terminar(uuid, text) to authenticated;

-- ---------- 8) Calificaciones ----------
-- Lectura rápida: el conjunto de estudiantes que la persona puede ver se calcula una vez, no fila por fila
create or replace function priv.estudiantes_calificables() returns setof uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select s.id from estudiantes s
  where s.colegio_id in (select m.colegio_id from miembros m join colegios k on k.id = m.colegio_id
                         where m.user_id = priv.uid() and m.activo and m.rol in ('rector','coordinador','secretaria') and priv.acceso_ok(k.activo, k.demo, k.pagado_hasta))
  union
  select s.id from estudiantes s
  join docente_grupos dg on dg.grupo_id = s.grupo_id
  join miembros m on m.id = dg.miembro_id join colegios k on k.id = m.colegio_id
  where m.user_id = priv.uid() and m.activo and m.rol = 'docente' and priv.acceso_ok(k.activo, k.demo, k.pagado_hasta)
  union
  select s.id from estudiantes s
  join grupos g on g.id = s.grupo_id join miembros m on m.id = g.director_miembro_id join colegios k on k.id = m.colegio_id
  where m.user_id = priv.uid() and m.activo and priv.acceso_ok(k.activo, k.demo, k.pagado_hasta)
$$;
-- La familia no ve la definitiva del periodo mientras incluya un cuestionario cuya nota todavía está oculta
create or replace function priv.nota_con_oculto(e uuid, a uuid, y int, p int) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from notas_act na join actividades x on x.id = na.actividad_id
                 join campus_items ci on ci.actividad_id = x.id
                 where na.estudiante_id = e and x.asignatura_id = a and x.anio = y and x.periodo = p
                   and ci.tipo = 'cuestionario' and not priv.ver_ahora(ci.ver_nota, ci.fecha))
$$;
drop policy if exists notas_ver on public.notas;
create policy notas_ver on public.notas for select to authenticated using (
  estudiante_id in (select priv.estudiantes_calificables())
  or (estudiante_id in (select priv.mis_estudiantes_al_dia()) and not priv.nota_con_oculto(estudiante_id, asignatura_id, anio, periodo)));
drop policy if exists nact_ver on public.notas_act;
create policy nact_ver on public.notas_act for select using (estudiante_id in (select priv.estudiantes_calificables()) or (estudiante_id in (select priv.mis_estudiantes_al_dia())
  and not exists (select 1 from campus_items ci where ci.actividad_id = notas_act.actividad_id and ci.tipo = 'cuestionario' and not priv.ver_ahora(ci.ver_nota, ci.fecha))));
create index if not exists notas_col_est on public.notas (colegio_id, estudiante_id);
create index if not exists notas_act_est on public.notas_act (estudiante_id);

-- La primera actividad de un curso/asignatura/periodo conserva la calificación que el docente ya había puesto:
-- se guarda como una actividad más («Calificación anterior del periodo») y entra al promedio
create or replace function priv.tg_actividades_previas() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare aid uuid;
begin
  if exists (select 1 from actividades x where x.grupo_id = new.grupo_id and x.asignatura_id = new.asignatura_id and x.anio = new.anio and x.periodo = new.periodo and x.id <> new.id) then
    return null;
  end if;
  if not exists (select 1 from notas n join estudiantes s on s.id = n.estudiante_id
                 where s.grupo_id = new.grupo_id and n.asignatura_id = new.asignatura_id and n.anio = new.anio and n.periodo = new.periodo) then
    return null;
  end if;
  insert into actividades (colegio_id, grupo_id, asignatura_id, anio, periodo, nombre, orden)
  values (new.colegio_id, new.grupo_id, new.asignatura_id, new.anio, new.periodo, 'Calificación anterior del periodo', -1) returning id into aid;
  insert into notas_act (actividad_id, estudiante_id, colegio_id, valor)
  select aid, n.estudiante_id, new.colegio_id, n.valor from notas n join estudiantes s on s.id = n.estudiante_id
  where s.grupo_id = new.grupo_id and n.asignatura_id = new.asignatura_id and n.anio = new.anio and n.periodo = new.periodo and n.valor is not null
  on conflict do nothing;
  return null;
end $$;
drop trigger if exists tg_actividades_previas on public.actividades;
create trigger tg_actividades_previas after insert on public.actividades for each row execute function priv.tg_actividades_previas();

-- ---------- 9) Contrato de la matrícula en línea ----------
do $$
declare d text := pg_get_functiondef('public.contrato_datos(uuid)'::regprocedure);
begin
  if position('familia en la matrícula en línea' in d) = 0 then
    d := replace(d, '  y := case when k.matricula_linea and k.matricula_anio > k.anio and exists',
      '  -- la familia en la matrícula en línea siempre ve el contrato del año que se matricula (sin costos, quedan líneas para llenar)
  y := case when k.matricula_linea and k.matricula_anio > k.anio and not (priv.puede(s.colegio_id, ''matricula'') or priv.ve_pagos(s.colegio_id)) then k.matricula_anio
            when k.matricula_linea and k.matricula_anio > k.anio and exists');
    if position('familia en la matrícula en línea' in d) = 0 then raise exception 'No se pudo ajustar contrato_datos'; end if;
    execute d;
  end if;
end $$;

commit;
notify pgrst, 'reload schema';
