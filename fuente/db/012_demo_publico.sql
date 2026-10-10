-- Corrección del bloqueo (evaluaba new.estado en tablas sin esa columna)
create or replace function priv.tg_bloqueo() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare r jsonb := to_jsonb(case when tg_op = 'DELETE' then old else new end); c uuid; k colegios;
begin
  if priv.uid() is null or priv.es_superadmin() then return case when tg_op = 'DELETE' then old else new end; end if;
  c := (r ->> 'colegio_id')::uuid;
  if c is not null and priv.en_mora(c) then
    raise exception 'El colegio está en modo de solo consulta porque la suscripción de Genesis tiene un pago vencido. Al registrarse el pago se desbloquea de inmediato.';
  end if;
  if tg_table_name = 'estudiantes' and tg_op <> 'DELETE' then
    if r ->> 'estado' = 'Activo' and (tg_op = 'INSERT' or to_jsonb(old) ->> 'estado' <> 'Activo') then
      select * into k from colegios where id = c;
      if (select count(*) from estudiantes s where s.colegio_id = c and s.estado = 'Activo' and s.id <> (r ->> 'id')::uuid) >= k.plan_max then
        raise exception 'Su plan permite hasta % estudiantes activos. Para matricular más, solicite la ampliación del plan.', k.plan_max;
      end if;
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

-- Genesis 012: demostración pública (los clientes entran con su cuenta) y se restaura cada día.
create table if not exists public.demo_visitas (
  id bigserial primary key,
  user_id text, email text, nombre text, rol text,
  fecha timestamptz not null default now()
);
alter table public.demo_visitas enable row level security;
grant select on public.demo_visitas to authenticated;
drop policy if exists dv_admin on public.demo_visitas;
create policy dv_admin on public.demo_visitas for select to authenticated using (priv.es_superadmin());

create or replace function priv.crear_demo() returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$

declare
  c uuid; a int := extract(year from current_date)::int; g record; e uuid; i int; n int := 0; m int; rec int := 0; s record;
  nombres text[] := array['Valentina','Santiago','Isabella','Matías','Mariana','Samuel','Gabriela','Sebastián','Luciana','Nicolás','Sara','Emiliano','Antonella','Juan José','Salomé','Tomás','Daniela','Martín','Victoria','Jerónimo'];
  apellidos text[] := array['Gómez Ríos','Martínez Pava','Rodríguez Luna','Hernández Cano','Díaz Mejía','Pérez Solano','Castro Vega','Moreno Ortiz','Rojas Peña','Vargas Duque','Torres Arias','Ramírez Gil','Suárez Mora','Jiménez Cruz','Navarro Polo','Cárdenas Ruiz','Ospina León','Quintero Paz','Restrepo Mesa','Salazar Ochoa'];
  madres text[] := array['Carolina','Paola','Diana','Natalia','Andrea','Claudia','Liliana','Marcela','Juliana','Sandra'];
  padres text[] := array['Andrés','Carlos','Jorge','Luis','Felipe','Mauricio','Ricardo','Alejandro','Diego','Javier'];
  barrios text[] := array['Bavaria','El Prado','Los Almendros','Bastidas','Gaira','Rodadero','Pescaíto','Mamatoco','Santa Lucía','Jardín'];
  directores text[] := array['Ana Milena Castaño','Laura Patricia Vélez','Óscar Iván Torres','Paula Andrea Montoya','Héctor Fabio Lozano'];
  frases text[] := array['Muestra interés y participa activamente en las actividades propuestas.','Es respetuoso(a) con sus compañeros y docentes; contribuye a la sana convivencia.','Debe mejorar la puntualidad en la entrega de trabajos.','Ha mostrado avances significativos con respecto al periodo anterior.','Se destaca por su liderazgo, creatividad y trabajo en equipo.','Se recomienda reforzar en casa los hábitos de estudio y la lectura diaria.'];
  admin text := (select user_id from plataforma_admins order by creado_en limit 1);
  fecha date;
begin
  delete from colegios where nombre = 'Colegio Demostración Genesis';
  insert into colegios (nombre, ciudad, direccion, telefono, rector_nombre, secretaria_nombre, anio, periodo_actual, lema, periodos, demo, plan_max, dia_limite_pago)
  values ('Colegio Demostración Genesis', 'Santa Marta', 'Carrera 5 No. 20-30', '6054200000', 'María Fernanda Ospina Rueda', 'Luz Ángela Restrepo Gil', a, 4,
          'Educamos con amor, disciplina y excelencia',
          jsonb_build_array(
            jsonb_build_object('n',1,'peso',25,'inicio',a||'-01-26','fin',a||'-04-03','cierre',a||'-04-10'),
            jsonb_build_object('n',2,'peso',25,'inicio',a||'-04-13','fin',a||'-06-19','cierre',a||'-06-26'),
            jsonb_build_object('n',3,'peso',25,'inicio',a||'-07-13','fin',a||'-09-18','cierre',a||'-09-25'),
            jsonb_build_object('n',4,'peso',25,'inicio',a||'-09-28','fin',a||'-11-27','cierre',a||'-12-04')), true, 100, 5)
  returning id into c;
  perform priv.plan_base(c);
  perform priv.conceptos_base(c, a);
  update conceptos set valor = case tipo when 'matricula' then 350000 when 'pension' then 280000 when 'seguro' then 25000 when 'carnet' then 12000 else valor end
  where colegio_id = c and anio = a;
  insert into grupos (colegio_id, nombre, grado, nivel, director_nombre) values
    (c, 'Transición A', 0, 'preescolar', directores[1]), (c, 'Primero A', 1, 'primaria', directores[2]),
    (c, 'Tercero A', 3, 'primaria', directores[3]), (c, 'Quinto A', 5, 'primaria', directores[4]),
    (c, 'Sexto A', 6, 'secundaria', directores[5]);

  alter table pagos disable trigger tg_pagos;
  for g in select * from grupos where colegio_id = c order by grado loop
    for i in 1..8 loop
      n := n + 1;
      insert into estudiantes (colegio_id, grupo_id, nombres, apellidos, tipo_doc, doc, fnac, lugar_nacimiento, sexo, eps, rh,
                               direccion, barrio, municipio, zona, estrato, telefono, jornada, situacion, fecha_matricula,
                               acudiente_nombre, acudiente_tel, autoriza_datos, autoriza_imagen, autoriza_fecha, autoriza_por, pais_origen)
      values (c, g.id, nombres[1 + (n * 7) % 20], apellidos[1 + (n * 3) % 20], case when g.grado < 1 then 'RC' else 'TI' end,
              (1100000000 + n * 7919)::text, make_date(a - 6 - greatest(g.grado, 0), 1 + n % 12, 1 + n % 27), 'Santa Marta',
              case when n % 2 = 0 then 'Femenino' else 'Masculino' end, (array['Sanitas','Sura','Nueva EPS','Salud Total'])[1 + n % 4],
              (array['O+','A+','B+','O-'])[1 + n % 4], 'Calle ' || (10 + n) || ' No. ' || (n % 30 + 2) || '-' || (n % 50 + 10),
              barrios[1 + n % 10], 'Santa Marta', 'Urbana', (1 + n % 4)::text, '300' || lpad((4500000 + n * 37)::text, 7, '0'),
              'Mañana', case when n % 5 = 0 then 'Nuevo' else 'Antiguo' end, make_date(a, 1, 20),
              madres[1 + n % 10] || ' ' || split_part(apellidos[1 + (n * 3) % 20], ' ', 2), '310' || lpad((2200000 + n * 53)::text, 7, '0'),
              true, true, make_date(a, 1, 20), madres[1 + n % 10] || ' ' || split_part(apellidos[1 + (n * 3) % 20], ' ', 2), 'Colombia')
      returning id into e;
      insert into acudientes (colegio_id, estudiante_id, orden, parentesco, nombres, tipo_doc, doc, telefono, email, direccion, ocupacion, responsable_pago) values
        (c, e, 1, 'Madre', madres[1 + n % 10] || ' ' || split_part(apellidos[1 + (n * 3) % 20], ' ', 2), 'CC', (52000000 + n * 311)::text,
         '310' || lpad((2200000 + n * 53)::text, 7, '0'), lower(madres[1 + n % 10]) || n || '@correo.com', 'Calle ' || (10 + n), 'Docente', true),
        (c, e, 2, 'Padre', padres[1 + n % 10] || ' ' || split_part(apellidos[1 + (n * 3) % 20], ' ', 1), 'CC', (79000000 + n * 457)::text,
         '315' || lpad((6100000 + n * 71)::text, 7, '0'), lower(padres[1 + n % 10]) || n || '@correo.com', 'Calle ' || (10 + n), 'Comerciante', false);
      -- calificaciones de los periodos 1 a 3
      insert into notas (colegio_id, estudiante_id, asignatura_id, anio, periodo, valor)
      select c, e, s2.id, a, p, case when g.nivel = 'preescolar' then (array[4.8,4.2,4.2,3.5])[1 + floor(random() * 4)::int]
                                     else round(least(5.0, greatest(1.5, 3.9 + (random() - 0.5) * 1.8 - case when random() < 0.12 then 1.2 else 0 end))::numeric, 1) end
      from asignaturas s2, generate_series(1, 3) p where s2.colegio_id = c and s2.nivel = g.nivel;
      insert into observaciones (colegio_id, estudiante_id, anio, periodo, texto)
      select c, e, a, p, frases[1 + (n + p) % 6] from generate_series(1, 3) p;
      -- asistencia: algunas fallas y llegadas tarde
      if n % 3 = 0 then insert into asistencia (colegio_id, estudiante_id, fecha, estado) values (c, e, make_date(a, 3, 10 + n % 10), 'A'), (c, e, make_date(a, 8, 4 + n % 10), 'T'); end if;
      if n % 7 = 0 then insert into asistencia (colegio_id, estudiante_id, fecha, estado) values (c, e, make_date(a, 5, 12), 'E'); end if;
      -- pagos: matrícula, seguro, carné y pensiones (algunas familias atrasadas)
      for s in select * from conceptos where colegio_id = c and anio = a loop
        if s.periodicidad = 'unico' then
          rec := rec + 1;
          insert into pagos (colegio_id, estudiante_id, concepto_id, anio, mes, valor, fecha, medio, recibo, registrado_nombre, lote)
          values (c, e, s.id, a, s.mes_cobro, s.valor, make_date(a, 1, 20), 'Transferencia', rec, 'Luz Ángela Restrepo Gil', gen_random_uuid());
        else
          for m in 2 .. (case when n % 6 = 0 then 6 when n % 4 = 0 then 8 else 9 end) loop
            rec := rec + 1;
            insert into pagos (colegio_id, estudiante_id, concepto_id, anio, mes, valor, fecha, medio, recibo, registrado_nombre, lote)
            values (c, e, s.id, a, m, s.valor, make_date(a, m, 3), (array['Efectivo','Transferencia','Nequi','PSE'])[1 + (n + m) % 4], rec, 'Luz Ángela Restrepo Gil', gen_random_uuid());
          end loop;
        end if;
      end loop;
    end loop;
  end loop;
  alter table pagos enable trigger tg_pagos;

  -- logros de primaria y secundaria
  insert into logros (colegio_id, grupo_id, asignatura_id, anio, periodo, texto)
  select c, g2.id, s3.id, a, p,
         case s3.nombre when 'Matemáticas' then 'Resuelve problemas cotidianos usando las operaciones básicas.' || chr(10) || 'Interpreta información en tablas y gráficos sencillos.'
                        when 'Lengua castellana' then 'Comprende e interpreta textos narrativos e informativos.' || chr(10) || 'Produce textos escritos con coherencia y buena ortografía.'
                        else 'Reconoce y aplica los conceptos fundamentales de ' || lower(s3.nombre) || ' trabajados en el periodo.' end
  from grupos g2 join asignaturas s3 on s3.colegio_id = c and s3.nivel = g2.nivel cross join generate_series(1, 3) p
  where g2.colegio_id = c and g2.nivel <> 'preescolar';

  -- observador
  insert into observador (colegio_id, estudiante_id, anio, fecha, tipo, descripcion, compromiso, autor_nombre)
  select c, x.id, a, make_date(a, 8, 20), case when row_number() over () % 2 = 0 then 'Positiva' else 'Convivencia' end,
         case when row_number() over () % 2 = 0 then 'Se destacó en la feria de ciencias con un proyecto sobre reciclaje.' else 'Llegó tarde en dos ocasiones durante la semana.' end,
         case when row_number() over () % 2 = 0 then null else 'Llegar puntualmente a la jornada.' end, 'Óscar Iván Torres'
  from (select id from estudiantes where colegio_id = c order by folio limit 10) x;

  insert into comunicados (colegio_id, tipo, titulo, cuerpo, destino, requiere_confirmacion, fecha_evento, autor_nombre)
  values (c, 'Circular', 'Inicio del cuarto periodo', 'Apreciadas familias: les recordamos que el cuarto periodo inició el 28 de septiembre. Las calificaciones se cierran el 4 de diciembre.', 'todos', true, null, 'María Fernanda Ospina Rueda'),
         (c, 'Evento', 'Entrega de boletines del tercer periodo', 'Los esperamos en el salón de cada curso. Se entregarán los boletines y se dialogará sobre el proceso de cada estudiante.', 'todos', true, (current_date + 10)::timestamptz + interval '19 hours', 'María Fernanda Ospina Rueda');

  update comunicados set autor_nombre = 'María Fernanda Ospina Rueda' where colegio_id = c;
  update observador set autor_nombre = 'Óscar Iván Torres' where colegio_id = c;
  delete from notas_log where colegio_id = c;
  if admin is not null then
    insert into miembros (colegio_id, email, nombre, rol, user_id) values (c, 'demo@skynetgenesis.com', 'María Fernanda Ospina Rueda', 'rector', admin);
  end if;
  return c;
end $$;

create or replace function public.entrar_demo(p_rol text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare u text := priv.uid(); k colegios; mid uuid; e uuid; em text; nm text;
begin
  if u is null then raise exception 'Inicie sesión para entrar a la demostración'; end if;
  if p_rol not in ('coordinador', 'docente', 'acudiente') then raise exception 'Perfil no válido'; end if;
  perform set_config('micolegia.sistema', 'on', true);  -- inserta miembros con su cuenta ya vinculada
  select * into k from colegios where demo order by creado_en desc limit 1;
  if k.id is null or k.creado_en::date < current_date then
    perform priv.crear_demo();
    select * into k from colegios where demo order by creado_en desc limit 1;
  end if;
  em := coalesce(priv.email_actual(), u || '@visitante');
  nm := coalesce((select nullif(btrim(to_jsonb(x) ->> 'name'), '') from neon_auth."user" x where x.id::text = u), split_part(em, '@', 1));
  select id into mid from miembros where colegio_id = k.id and user_id = u and rol = p_rol;
  if mid is null then
    if p_rol = 'acudiente' then
      select s.id into e from estudiantes s join grupos g on g.id = s.grupo_id where s.colegio_id = k.id and g.nombre = 'Tercero A' order by s.apellidos limit 1;
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
revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;

-- Un solo colegio de demostración; se elimina el colegio de pruebas
delete from colegios where nombre = 'Colegio de Prueba Genesis';
select priv.crear_demo();
notify pgrst, 'reload schema';
