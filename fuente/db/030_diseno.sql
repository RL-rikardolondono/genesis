-- Colegio-IA 030 (entrega 7 de la revisión del 19-20 oct 2026): diseño, documentos y demostración completa.
--  1) Jornada del horario por colegio (hora de entrada, duración de las clases y descanso).
--  2) Demostración más completa: escudo, contactos de emergencia, un curso por grado, PIAR, secretaría y tesorería.
--  3) Fotos de la semana: se puede corregir el texto de cada foto.
--  4) Logros: se ve quién los guardó por última vez.

-- 1) Jornada del horario: la definen los directivos (coordinación arma los horarios)
alter table public.colegios add column if not exists horario_cfg jsonb;
create or replace function public.colegio_horario_cfg(p_colegio uuid, p_cfg jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not priv.es_directivo(p_colegio) then raise exception 'Solo los directivos definen la jornada'; end if;
  if not coalesce((p_cfg ->> 'min')::int between 30 and 120 and coalesce((p_cfg ->> 'desc_min')::int, 0) between 0 and 90
     and coalesce((p_cfg ->> 'desc_despues')::int, 0) between 0 and 12 and (p_cfg ->> 'inicio') ~ '^\d{2}:\d{2}$', false)
  then raise exception 'Datos de jornada no válidos'; end if;
  update colegios set horario_cfg = jsonb_build_object('inicio', p_cfg ->> 'inicio', 'min', (p_cfg ->> 'min')::int,
    'desc_despues', coalesce((p_cfg ->> 'desc_despues')::int, 0), 'desc_min', coalesce((p_cfg ->> 'desc_min')::int, 0)) where id = p_colegio;
end $$;
revoke execute on function public.colegio_horario_cfg(uuid, jsonb) from public, anonymous;
grant execute on function public.colegio_horario_cfg(uuid, jsonb) to authenticated;

-- 2) Demostración completa (revisión 20 oct): escudo, un curso por cada grado, contactos de emergencia,
--    estudiantes con PIAR en los cursos del docente y perfiles de secretaría y tesorería.
create or replace function priv.demo_revision7(c uuid, a int) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  g record; e uuid; n int := 500; i int; s record; m int; rec int; adm uuid;
  nombres text[] := array['Alejandro','Camila','David','Elena','Felipe','Juliana','Gabriel','Manuela','Hugo','Renata','Iván','Sofía'];
  apellidos text[] := array['Acosta Lara','Benítez Roa','Cabrera Nieto','Delgado Ibarra','Escobar Mena','Franco Silva','Galindo Rey','Henao Paredes','Ibáñez Toro','Lozano Vera','Mendoza Gil','Nieto Parra'];
  madres text[] := array['Adriana','Beatriz','Catalina','Eliana','Gloria','Johana'];
  ajustes jsonb := '{}';
begin
  perform set_config('micolegia.sistema', 'on', true);
  -- Escudo de ejemplo (dibujo propio)
  update colegios set logo = 'data:image/svg+xml;base64,' || encode(convert_to(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 120"><path d="M50 4 92 18v38c0 30-20 50-42 60C28 106 8 86 8 56V18z" fill="#0B4F8A" stroke="#F2B705" stroke-width="5"/>'
    || '<path d="M26 52c8-4 16-4 24 2 8-6 16-6 24-2v30c-8-4-16-4-24 2-8-6-16-6-24-2z" fill="#fff"/><path d="M50 54v30" stroke="#0B4F8A" stroke-width="2"/>'
    || '<circle cx="50" cy="34" r="9" fill="#F2B705"/><text x="50" y="104" font-family="Arial" font-size="11" font-weight="700" fill="#fff" text-anchor="middle">CD</text></svg>', 'UTF8'), 'base64')
  where id = c and logo is null;
  update colegios set logo = replace(logo, chr(10), '') where id = c;

  -- Un curso por cada grado que falte, con 3 estudiantes al día en pagos y con calificaciones
  insert into grupos (colegio_id, nombre, grado, nivel, director_nombre)
  select c, x.nom, x.gr, x.niv, 'Docente de ' || x.nom
  from (values ('Prejardín A', -2, 'preescolar'), ('Jardín A', -1, 'preescolar'), ('Segundo A', 2, 'primaria'), ('Cuarto A', 4, 'primaria'),
               ('Séptimo A', 7, 'secundaria'), ('Octavo A', 8, 'secundaria'), ('Noveno A', 9, 'secundaria'), ('Décimo A', 10, 'media'), ('Once A', 11, 'media')) x(nom, gr, niv)
  where not exists (select 1 from grupos g0 where g0.colegio_id = c and g0.grado = x.gr);
  select coalesce(max(recibo), 0) into rec from pagos where colegio_id = c;
  alter table pagos disable trigger tg_pagos;
  for g in select * from grupos gg where gg.colegio_id = c and not exists (select 1 from estudiantes x where x.grupo_id = gg.id) order by grado loop
    for i in 1..3 loop
      n := n + 1;
      insert into estudiantes (colegio_id, grupo_id, nombres, apellidos, tipo_doc, doc, fnac, lugar_nacimiento, lugar_expedicion, sexo, eps, rh, sisben,
                               direccion, barrio, municipio, zona, estrato, telefono, jornada, situacion, fecha_matricula,
                               acudiente_nombre, acudiente_tel, autoriza_datos, autoriza_imagen, autoriza_fecha, autoriza_por, pais_origen)
      values (c, g.id, nombres[1 + n % 12], apellidos[1 + (n * 5) % 12], case when g.grado < 1 then 'RC' when g.grado >= 10 then 'TI' else 'TI' end,
              (1100000000 + n * 7919)::text, make_date(a - 6 - g.grado, 1 + n % 12, 1 + n % 27), 'Santa Marta', 'Santa Marta',
              case when n % 2 = 0 then 'Femenino' else 'Masculino' end, (array['Sanitas','Sura','Nueva EPS','Salud Total'])[1 + n % 4],
              (array['O+','A+','B+','O-'])[1 + n % 4], (array['A3','B2','C1','No tiene'])[1 + n % 4], 'Carrera ' || (n % 40 + 2) || ' No. ' || (n % 30 + 5) || '-' || (n % 50 + 10),
              'El Prado', 'Santa Marta', 'Urbana', (1 + n % 4)::text, '300' || lpad((4600000 + n * 37)::text, 7, '0'),
              'Mañana', 'Antiguo', make_date(a, 1, 20), madres[1 + n % 6] || ' ' || split_part(apellidos[1 + (n * 5) % 12], ' ', 2),
              '311' || lpad((2300000 + n * 53)::text, 7, '0'), true, n % 3 <> 0, make_date(a, 1, 20),
              madres[1 + n % 6] || ' ' || split_part(apellidos[1 + (n * 5) % 12], ' ', 2), 'Colombia')
      returning id into e;
      insert into acudientes (colegio_id, estudiante_id, orden, parentesco, nombres, tipo_doc, doc, telefono, email, direccion, ocupacion, responsable_pago) values
        (c, e, 1, 'Madre', madres[1 + n % 6] || ' ' || split_part(apellidos[1 + (n * 5) % 12], ' ', 2), 'CC', (52000000 + n * 311)::text,
         '311' || lpad((2300000 + n * 53)::text, 7, '0'), lower(madres[1 + n % 6]) || n || '@correo.com', 'Carrera ' || (n % 40 + 2), 'Independiente', true);
      insert into notas (colegio_id, estudiante_id, asignatura_id, anio, periodo, valor)
      select c, e, s2.id, a, p, case when g.nivel = 'preescolar' then (array[96,85,85,70])[1 + floor(random() * 4)::int]
                                     else round(least(100, greatest(45, 80 + (random() - 0.5) * 32))) end
      from asignaturas s2, generate_series(1, 3) p where s2.colegio_id = c and s2.nivel = g.nivel and (coalesce(cardinality(s2.grados), 0) = 0 or g.grado = any(s2.grados));
      for s in select * from conceptos where colegio_id = c and anio = a and valor > 0 loop
        for m in select unnest(case when s.periodicidad = 'mensual' then s.meses else array[s.mes_cobro] end) loop
          if m <= extract(month from current_date)::int then
            rec := rec + 1;
            insert into pagos (colegio_id, estudiante_id, concepto_id, anio, mes, valor, fecha, medio, recibo, registrado_nombre, lote)
            values (c, e, s.id, a, case when s.periodicidad = 'unico' then s.mes_cobro else m end, s.valor, make_date(a, m, 3), 'Transferencia', rec, 'Luz Ángela Restrepo Gil', gen_random_uuid());
          end if;
        end loop;
      end loop;
    end loop;
  end loop;
  alter table pagos enable trigger tg_pagos;

  -- Horario y lista de útiles de los cursos nuevos: se toman del curso de ejemplo más parecido
  insert into horario (colegio_id, grupo_id, dia, bloque, hora, asignatura_id, docente)
  select c, gn.id, h.dia, h.bloque, h.hora, an.id, h.docente
  from grupos gn
  cross join lateral (select gt.id from grupos gt where gt.colegio_id = c and exists (select 1 from horario hx where hx.grupo_id = gt.id)
                      order by (gt.nivel = gn.nivel) desc, abs(gt.grado - gn.grado) limit 1) t
  join horario h on h.grupo_id = t.id
  join asignaturas ao on ao.id = h.asignatura_id
  join asignaturas an on an.colegio_id = c and an.nivel = gn.nivel and an.nombre = ao.nombre
  where gn.colegio_id = c and not exists (select 1 from horario hy where hy.grupo_id = gn.id);
  insert into utiles (colegio_id, anio, grado, lista, nota)
  select c, a, gn.grado, u.lista, u.nota
  from grupos gn
  cross join lateral (select u2.* from utiles u2 where u2.colegio_id = c and u2.anio = a order by abs(u2.grado - gn.grado) limit 1) u
  where gn.colegio_id = c and not exists (select 1 from utiles u3 where u3.colegio_id = c and u3.anio = a and u3.grado = gn.grado);

  -- Contactos de emergencia y personas autorizadas para recoger a cada estudiante
  insert into contactos_est (colegio_id, estudiante_id, tipo, nombre, parentesco, telefono, doc, creado_nombre)
  select c, x.id, 'emergencia', (array['Rosa','Gilberto','Martha','Hernando'])[1 + abs(hashtext(x.id::text)) % 4] || ' ' || split_part(x.apellidos, ' ', 1),
         (array['Abuela','Abuelo','Tía','Tío'])[1 + abs(hashtext(x.id::text)) % 4], '320' || lpad((abs(hashtext(x.id::text)) % 9000000 + 1000000)::text, 7, '0'), null, 'Secretaría'
  from estudiantes x where x.colegio_id = c and not exists (select 1 from contactos_est k where k.estudiante_id = x.id and k.tipo = 'emergencia');
  insert into contactos_est (colegio_id, estudiante_id, tipo, nombre, parentesco, telefono, doc, creado_nombre)
  select c, x.id, 'recoger', a2.nombres, a2.parentesco, a2.telefono, a2.doc, 'Secretaría'
  from estudiantes x join acudientes a2 on a2.estudiante_id = x.id and a2.orden = 1
  where x.colegio_id = c and not exists (select 1 from contactos_est k where k.estudiante_id = x.id and k.tipo = 'recoger');

  -- Un estudiante con PIAR en Tercero A y otro en Quinto A (cursos del docente de la demostración)
  select coalesce(jsonb_object_agg(id, case when nombre ilike 'Matem%' then 'Problemas con apoyo de material concreto y tiempo adicional en las evaluaciones.'
                                          else 'Lecturas cortas con imágenes; evaluación oral cuando la escritura sea una barrera.' end), '{}')
    into ajustes from asignaturas where colegio_id = c and (nombre ilike 'Matem%' or nombre ilike 'Lengua%');
  for e in select (select s3.id from estudiantes s3 where s3.grupo_id = g2.id order by s3.apellidos offset 2 limit 1)
           from grupos g2 where g2.colegio_id = c and g2.nombre in ('Tercero A', 'Quinto A') loop
    update estudiantes set piar = true, discapacidad = coalesce(discapacidad, 'Discapacidad intelectual'),
      condicion_especial = coalesce(condicion_especial, 'Dificultad en la comprensión lectora y en el cálculo. Diagnóstico aportado por la familia.') where id = e;
    insert into piar (colegio_id, estudiante_id, anio, datos, actualizado_por) values (c, e, a, jsonb_build_object(
      'fecha', make_date(a, 2, 20), 'elabora', 'Óscar Iván Torres (director de curso) y orientación escolar',
      'fortalezas', 'Es colaborador(a), le gusta el dibujo y trabaja bien en grupo.', 'intereses', 'Los animales, la música y el fútbol.',
      'barreras', 'Textos largos sin imágenes y evaluaciones escritas con tiempo limitado.',
      'apoyos', 'Acompañamiento de orientación escolar una vez por semana.', 'familia', 'Leer 20 minutos diarios en casa y revisar la agenda.',
      'ajustes', ajustes, 'seguimiento', jsonb_build_object('1', 'Avanza en lectura de textos cortos.', '2', 'Mejora en la resolución de problemas con material concreto.'),
      'acta', 'Firmada el ' || to_char(make_date(a, 2, 27), 'DD/MM/YYYY')), 'Orientación escolar')
    on conflict do nothing;
  end loop;
  -- (no se apaga micolegia.sistema: entrar_demo lo necesita encendido después de crear la demostración)
end $$;
do $$
declare d text;
begin
  d := pg_get_functiondef('priv.crear_demo'::regproc);
  if position('demo_revision7' in d) = 0 then
    d := replace(d, '  perform priv.demo_revision4(c, a);', '  perform priv.demo_revision4(c, a);' || chr(10) || '  perform priv.demo_revision7(c, a);');
    if position('demo_revision7' in d) = 0 then raise exception 'No se encontró dónde agregar los ajustes a la demostración'; end if;
    execute d;
  end if;
  -- Perfiles de secretaría y tesorería en la demostración
  d := pg_get_functiondef('public.entrar_demo'::regproc);
  if position('''tesoreria''' in d) = 0 then
    d := replace(d, $q$p_rol not in ('rector', 'coordinador', 'docente', 'acudiente', 'estudiante')$q$, $q$p_rol not in ('rector', 'coordinador', 'secretaria', 'tesoreria', 'docente', 'acudiente', 'estudiante')$q$);
    if position('''tesoreria''' in d) = 0 then raise exception 'No se encontró la lista de perfiles de la demostración'; end if;
    execute d;
  end if;
end $$;
-- La demostración de hoy también queda completa
select priv.demo_revision7(id, anio) from colegios where demo;

-- 3) Fotos de la semana: quien la subió (o un directivo) puede corregir el texto de la foto
grant update (pie) on public.fotos_clase to authenticated;
drop policy if exists fc_mod on public.fotos_clase;
create policy fc_mod on public.fotos_clase for update to authenticated
  using (creado_por = priv.uid() or priv.es_directivo(colegio_id)) with check (creado_por = priv.uid() or priv.es_directivo(colegio_id));

-- 4) Logros: queda registrado quién los guardó por última vez (docentes y directivos comparten el texto)
alter table public.logros add column if not exists actualizado_nombre text, add column if not exists actualizado_en timestamptz;
create or replace function priv.tg_logros_quien() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if current_setting('micolegia.sistema', true) = 'on' or priv.uid() is null then return new; end if;
  new.actualizado_nombre := priv.nombre_actual(new.colegio_id); new.actualizado_en := now();
  return new;
end $$;
drop trigger if exists tg_logros_quien on public.logros;
create trigger tg_logros_quien before insert or update on public.logros for each row execute function priv.tg_logros_quien();

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
notify pgrst, 'reload schema';
