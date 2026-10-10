-- Genesis-IA 016: acceso de las familias según el pago, varios hijos, perfil Rector en la demostración.

-- 1) Familias con pagos pendientes: ven horario, comunicados, excusas y estado de cuenta,
--    pero no calificaciones, boletines, observador, PIAR, asistencia ni certificados hasta ponerse al día.
alter table public.colegios add column if not exists restringir_morosos boolean not null default true;

-- ¿El estudiante tiene cuotas vencidas sin pagar (este año o años anteriores)?
create or replace function priv.debe_vencido(e uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from estudiantes s join colegios k on k.id = s.colegio_id
    cross join lateral generate_series(greatest(extract(year from k.creado_en)::int, k.anio - 5), k.anio) y
    cross join lateral estado_cuenta(s.id, y) x
    where s.id = e and x.vencido and x.saldo > 0)
$$;
-- Estudiantes del usuario (como acudiente o estudiante) cuya información académica puede ver
create or replace function priv.mis_estudiantes_al_dia() returns setof uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select m.estudiante_id from miembros m join colegios k on k.id = m.colegio_id
  where m.user_id = priv.uid() and m.activo and m.estudiante_id is not null
    and priv.acceso_ok(k.activo, k.demo, k.pagado_hasta)
    and (not k.restringir_morosos or not priv.debe_vencido(m.estudiante_id))
$$;
do $$
declare t text; p text;
begin
  foreach t in array array['notas','asistencia','observaciones','piar','historial','observador','notas_act','recuperaciones','asistencia_clase'] loop
    select polname into p from pg_policy where polrelid = ('public.' || t)::regclass and polcmd = 'r' limit 1;
    if p is not null then
      execute format('drop policy %I on public.%I', p, t);
      execute format('create policy %I on public.%I for select to authenticated using (priv.puede_calificar(estudiante_id) or estudiante_id in (select priv.mis_estudiantes_al_dia()))', p, t);
    end if;
  end loop;
end $$;

-- Situación de cada hijo para la familia (lo usa la pantalla)
create or replace function public.mi_situacion_familia(p_colegio uuid) returns json
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(json_agg(json_build_object('estudiante_id', m.estudiante_id, 'al_dia', not (k.restringir_morosos and priv.debe_vencido(m.estudiante_id)),
           'debe', priv.debe_vencido(m.estudiante_id))), '[]'::json)
  from miembros m join colegios k on k.id = m.colegio_id
  where m.colegio_id = p_colegio and m.user_id = priv.uid() and m.activo and m.estudiante_id is not null
$$;
revoke execute on function public.mi_situacion_familia(uuid) from anonymous;

-- 2) "Carnet" en lugar de "Carné"
update public.conceptos set nombre = 'Carnet' where nombre = 'Carné';
create or replace function priv.conceptos_base(c uuid, a integer) returns void
language sql as $$
  insert into conceptos (colegio_id, anio, nombre, tipo, periodicidad, valor, mes_cobro, meses, orden)
  select c, a, x.nombre, x.tipo, x.per, 0, 2, '{2,3,4,5,6,7,8,9,10,11}', x.orden from (values
    ('Matrícula','matricula','unico',1),('Pensión','pension','mensual',2),
    ('Seguro estudiantil','seguro','unico',3),('Carnet','carnet','unico',4)) as x(nombre, tipo, per, orden)
  where not exists (select 1 from conceptos where colegio_id = c and anio = a)
$$;

-- 3) Demostración: perfil Rector y acudiente con dos hijos (uno al día y otro con pagos pendientes)
create or replace function public.entrar_demo(p_rol text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare u text := priv.uid(); k colegios; mid uuid; e uuid; e2 uuid; em text; nm text;
begin
  if u is null then raise exception 'Inicie sesión para entrar a la demostración'; end if;
  if p_rol not in ('rector', 'coordinador', 'docente', 'acudiente') then raise exception 'Perfil no válido'; end if;
  perform set_config('micolegia.sistema', 'on', true);
  select * into k from colegios where demo order by creado_en desc limit 1;
  if k.id is null or k.creado_en::date < current_date then
    perform priv.crear_demo();
    select * into k from colegios where demo order by creado_en desc limit 1;
  end if;
  em := coalesce(priv.email_actual(), u || '@visitante');
  nm := coalesce((select nullif(btrim(to_jsonb(x) ->> 'name'), '') from neon_auth."user" x where x.id::text = u), split_part(em, '@', 1));
  select id into mid from miembros where colegio_id = k.id and user_id = u and rol = p_rol order by creado_en limit 1;
  if mid is null then
    if p_rol = 'acudiente' then
      select s.id into e from estudiantes s join grupos g on g.id = s.grupo_id where s.colegio_id = k.id and g.nombre = 'Tercero A' order by s.apellidos limit 1;
      select s.id into e2 from estudiantes s join grupos g on g.id = s.grupo_id where s.colegio_id = k.id and g.nombre = 'Quinto A' order by s.apellidos limit 1;
      -- el primer hijo queda al día para mostrar el acceso completo
      alter table pagos disable trigger tg_pagos;
      insert into pagos (colegio_id, estudiante_id, concepto_id, anio, mes, valor, fecha, medio, recibo, registrado_nombre, lote)
      select k.id, e, c.id, k.anio, case when c.periodicidad = 'unico' then c.mes_cobro else m end, c.valor, current_date, 'Transferencia',
             (select coalesce(max(recibo), 0) from pagos where colegio_id = k.id) + row_number() over (), k.secretaria_nombre, gen_random_uuid()
      from conceptos c cross join lateral unnest(case when c.periodicidad = 'mensual' then c.meses else array[c.mes_cobro] end) m
      where c.colegio_id = k.id and c.anio = k.anio and c.valor > 0 and m <= extract(month from current_date)::int
        and not exists (select 1 from pagos p where p.estudiante_id = e and p.concepto_id = c.id and p.anio = k.anio
                        and p.mes is not distinct from case when c.periodicidad = 'unico' then c.mes_cobro else m end and not p.anulado);
      alter table pagos enable trigger tg_pagos;
      insert into miembros (colegio_id, email, nombre, rol, user_id, estudiante_id) values (k.id, em, nm, p_rol, u, e2)
        on conflict do nothing;
    end if;
    insert into miembros (colegio_id, email, nombre, rol, user_id, estudiante_id) values (k.id, em, nm, p_rol, u, e) returning id into mid;
    if p_rol = 'docente' then
      insert into docente_grupos (colegio_id, miembro_id, grupo_id)
      select k.id, mid, g.id from grupos g where g.colegio_id = k.id and g.nombre in ('Tercero A', 'Quinto A');
      update grupos set director_miembro_id = mid where colegio_id = k.id and nombre = 'Tercero A' and director_miembro_id is null;
    end if;
  end if;
  insert into demo_visitas (user_id, email, nombre, rol) values (u, em, nm, p_rol);
  perform set_config('micolegia.sistema', '', true);
  return mid;
end $$;
revoke execute on function public.entrar_demo(text) from anonymous;

-- En la demostración, nadie (salvo el administrador) puede cerrar el año
create or replace function priv.tg_demo_cierre() returns trigger
language plpgsql as $$
begin
  if old.demo and new.anio <> old.anio and not priv.es_superadmin() and priv.uid() is not null then
    raise exception 'En el colegio de demostración no se puede cerrar el año';
  end if;
  return new;
end $$;
drop trigger if exists tg_demo_cierre on public.colegios;
create trigger tg_demo_cierre before update on public.colegios for each row execute function priv.tg_demo_cierre();

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
notify pgrst, 'reload schema';
