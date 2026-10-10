-- Genesis 009: colegio de demostración con datos ficticios (para mostrar la plataforma a clientes).
-- Se puede ejecutar de nuevo: borra y recrea el colegio de demostración.
do $$
declare
  c uuid; a int := extract(year from current_date)::int; g record; e uuid; i int; n int := 0;
  nombres text[] := array['Valentina','Santiago','Isabella','Matías','Mariana','Samuel','Gabriela','Sebastián','Luciana','Nicolás','Sara','Emiliano','Antonella','Juan José','Salomé','Tomás','Daniela','Martín','Victoria','Jerónimo'];
  apellidos text[] := array['Gómez Ríos','Martínez Pava','Rodríguez Luna','Hernández Cano','Díaz Mejía','Pérez Solano','Castro Vega','Moreno Ortiz','Rojas Peña','Vargas Duque','Torres Arias','Ramírez Gil','Suárez Mora','Jiménez Cruz','Navarro Polo','Cárdenas Ruiz','Ospina León','Quintero Paz','Restrepo Mesa','Salazar Ochoa'];
  admin text := (select user_id from plataforma_admins order by creado_en limit 1);
begin
  delete from colegios where nombre = 'Colegio Demostración Genesis';
  insert into colegios (nombre, ciudad, direccion, telefono, rector_nombre, secretaria_nombre, anio, periodo_actual, lema, periodos)
  values ('Colegio Demostración Genesis', 'Santa Marta', 'Calle 1 No. 2-3', '3000000000', 'Rector(a) de demostración', 'Secretaría de demostración', a, 4,
          'Datos ficticios para conocer Genesis',
          jsonb_build_array(
            jsonb_build_object('n',1,'peso',25,'inicio',a||'-01-26','fin',a||'-04-03','cierre',a||'-04-10'),
            jsonb_build_object('n',2,'peso',25,'inicio',a||'-04-13','fin',a||'-06-19','cierre',a||'-06-26'),
            jsonb_build_object('n',3,'peso',25,'inicio',a||'-07-13','fin',a||'-09-18','cierre',a||'-09-25'),
            jsonb_build_object('n',4,'peso',25,'inicio',a||'-09-28','fin',a||'-11-27','cierre',a||'-12-04')))
  returning id into c;
  perform priv.plan_base(c);
  perform priv.conceptos_base(c, a);
  insert into grupos (colegio_id, nombre, grado, nivel, director_nombre) values
    (c, 'Transición A', 0, 'preescolar', 'Docente de demostración'), (c, 'Primero A', 1, 'primaria', 'Docente de demostración'),
    (c, 'Tercero A', 3, 'primaria', 'Docente de demostración'), (c, 'Quinto A', 5, 'primaria', 'Docente de demostración'),
    (c, 'Sexto A', 6, 'secundaria', 'Docente de demostración');
  for g in select * from grupos where colegio_id = c order by grado loop
    for i in 1..8 loop
      n := n + 1;
      insert into estudiantes (colegio_id, grupo_id, nombres, apellidos, tipo_doc, doc, fnac, acudiente_nombre, acudiente_tel, autoriza_datos)
      values (c, g.id, nombres[1 + (n * 7) % 20], apellidos[1 + (n * 3) % 20], case when g.grado < 1 then 'RC' else 'TI' end,
              'DEMO' || lpad(n::text, 4, '0'), make_date(a - 6 - greatest(g.grado, 0), 1 + n % 12, 1 + n % 27),
              'Acudiente de demostración ' || n, '3000000' || lpad(n::text, 3, '0'), true)
      returning id into e;
      insert into notas (colegio_id, estudiante_id, asignatura_id, anio, periodo, valor)
      select c, e, s.id, a, p, case when g.nivel = 'preescolar' then (array[4.8,4.2,4.2,3.5])[1 + floor(random() * 4)::int]
                                    else round(least(5.0, greatest(1.5, 3.9 + (random() - 0.5) * 1.8 - case when random() < 0.12 then 1.2 else 0 end))::numeric, 1) end
      from asignaturas s, generate_series(1, 3) p where s.colegio_id = c and s.nivel = g.nivel;
    end loop;
  end loop;
  insert into comunicados (colegio_id, tipo, titulo, cuerpo, destino, requiere_confirmacion, fecha_evento)
  values (c, 'Circular', 'Bienvenidos a Genesis', 'Este es un colegio de demostración con datos ficticios. Explore los boletines, la planilla, las estadísticas y los comunicados.', 'todos', true, null),
         (c, 'Evento', 'Entrega de boletines del tercer periodo', 'Los esperamos en el salón de cada curso.', 'todos', true, (current_date + 10)::timestamptz + interval '19 hours');
  if admin is not null then
    insert into miembros (colegio_id, email, nombre, rol, user_id) values (c, 'demo@skynetgenesis.com', 'Rector(a) de demostración', 'rector', admin);
  end if;
end $$;
