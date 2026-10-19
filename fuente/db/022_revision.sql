-- Colegio-IA 022: cambios de la revisión del 18 oct 2026 (entrega 1).
-- 1) Escala de 0 a 100 sin decimales  2) actividades sin porcentajes  3) contactos con historial
-- 4) solo el rector maneja directivos  5) plan de estudios por grado  6) horario de atención para citas
-- 7) la demostración se renueva a medianoche de Colombia y queda completa.

-- 1) Escala 0 a 100. Las calificaciones de 1,0 a 5,0 se convierten multiplicando por 20 (3,0 → 60; 4,6 → 92).
do $$
begin
  if exists (select 1 from information_schema.columns where table_name = 'notas' and column_name = 'valor' and numeric_precision = 2) then
    alter table public.notas disable trigger user;
    alter table public.notas_act disable trigger user;
    alter table public.recuperaciones disable trigger user;
    alter table public.notas drop constraint if exists notas_valor_check;
    alter table public.notas_act drop constraint if exists notas_act_valor_check;
    alter table public.recuperaciones drop constraint if exists recuperaciones_nota_check;
    alter table public.notas alter column valor type numeric(4,1);
    alter table public.notas_act alter column valor type numeric(4,1);
    alter table public.recuperaciones alter column nota type numeric(4,1);
    alter table public.notas_log alter column antes type numeric(4,1), alter column despues type numeric(4,1);
    update public.notas set valor = round(valor * 20);
    update public.notas_act set valor = round(valor * 20);
    update public.recuperaciones set nota = round(nota * 20) where nota is not null;
    update public.notas_log set antes = round(antes * 20), despues = round(despues * 20);
    alter table public.notas enable trigger user;
    alter table public.notas_act enable trigger user;
    alter table public.recuperaciones enable trigger user;
    -- escalas guardadas (colegios y años cerrados)
    update public.colegios set escala = (select jsonb_agg(jsonb_build_object('d', e->>'d', 'min', round((e->>'min')::numeric * 20) - case when e->>'d' = 'Bajo' then round((e->>'min')::numeric * 20) else 0 end,
                                                                         'max', case when (e->>'max')::numeric >= 5 then 100 else round((e->>'max')::numeric * 20) + 1 end) order by (e->>'min')::numeric)
                                         from jsonb_array_elements(escala) e)
     where (select max((e->>'max')::numeric) from jsonb_array_elements(escala) e) <= 5;
    update public.anios_cerrados set escala = (select jsonb_agg(jsonb_build_object('d', e->>'d', 'min', round((e->>'min')::numeric * 20) - case when e->>'d' = 'Bajo' then round((e->>'min')::numeric * 20) else 0 end,
                                                                         'max', case when (e->>'max')::numeric >= 5 then 100 else round((e->>'max')::numeric * 20) + 1 end) order by (e->>'min')::numeric)
                                         from jsonb_array_elements(escala) e)
     where escala is not null and (select max((e->>'max')::numeric) from jsonb_array_elements(escala) e) <= 5;
  end if;
end $$;
alter table public.notas drop constraint if exists notas_valor_0_100;
alter table public.notas add constraint notas_valor_0_100 check (valor between 0 and 100);
alter table public.notas_act drop constraint if exists notas_act_valor_0_100;
alter table public.notas_act add constraint notas_act_valor_0_100 check (valor between 0 and 100);
alter table public.recuperaciones drop constraint if exists recuperaciones_nota_0_100;
alter table public.recuperaciones add constraint recuperaciones_nota_0_100 check (nota is null or nota between 0 and 100);
alter table public.colegios alter column escala set default
  '[{"d":"Bajo","min":0,"max":59},{"d":"Básico","min":60,"max":79},{"d":"Alto","min":80,"max":91},{"d":"Superior","min":92,"max":100}]'::jsonb;

-- 2) Actividades sin porcentajes: la calificación del periodo es el promedio simple (lo calcula la app); el peso queda en 0
update public.actividades set peso = 0 where peso <> 0;

-- 3) Contactos de emergencia y personas autorizadas: no se borran, se retiran con fecha y quién lo hizo
alter table public.contactos_est add column if not exists activo boolean not null default true;
alter table public.contactos_est add column if not exists creado_nombre text;
alter table public.contactos_est add column if not exists retirado_en timestamptz;
alter table public.contactos_est add column if not exists retirado_nombre text;
create or replace function priv.tg_contactos_est() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  select colegio_id into new.colegio_id from estudiantes where id = new.estudiante_id;
  new.creado_por := priv.uid(); new.activo := true; new.retirado_en := null; new.retirado_nombre := null;
  new.creado_nombre := coalesce((select max(m.nombre) from miembros m where m.user_id = priv.uid() and m.colegio_id = new.colegio_id and m.activo), 'Colegio');
  if (select count(*) from contactos_est where estudiante_id = new.estudiante_id and tipo = new.tipo and activo) >= 6 then
    raise exception 'Puede registrar hasta 6 personas de cada tipo';
  end if;
  return new;
end $$;
revoke delete on public.contactos_est from authenticated;
drop policy if exists ce_del on public.contactos_est;
create or replace function public.retirar_contacto(p_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare c contactos_est;
begin
  select * into c from contactos_est where id = p_id;
  if c.id is null or not (priv.es_familia_de(c.estudiante_id) or priv.es_directivo(c.colegio_id)) then raise exception 'No tiene permiso para esta acción'; end if;
  if not c.activo then return; end if;
  update contactos_est set activo = false, retirado_en = now(),
         retirado_nombre = coalesce((select max(m.nombre) from miembros m where m.user_id = priv.uid() and m.colegio_id = c.colegio_id and m.activo), 'Colegio')
   where id = p_id;
end $$;

-- 4) Usuarios: solo el rector (o la plataforma) crea, cambia o desactiva rector, coordinación, secretaría y tesorería;
--    nadie se desactiva a sí mismo
create or replace function priv.tg_miembros_permiso() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare dir text[] := array['rector','coordinador','secretaria','tesoreria'];
begin
  if not priv.es_cliente() or priv.es_superadmin() then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then
    if old.rol = any(dir) and not priv.es_rector(old.colegio_id) then raise exception 'Solo el rector o la rectora pueden quitar usuarios directivos'; end if;
    return old;
  end if;
  if (new.rol = any(dir) or (tg_op = 'UPDATE' and old.rol = any(dir))) and not priv.es_rector(new.colegio_id) then
    raise exception 'Solo el rector o la rectora pueden crear o cambiar usuarios directivos (rectoría, coordinación, secretaría y tesorería)';
  end if;
  if tg_op = 'UPDATE' and old.user_id = priv.uid() and old.activo and not new.activo then
    raise exception 'No puede desactivar su propio usuario';
  end if;
  return new;
end $$;
drop trigger if exists tg_miembros_permiso on public.miembros;
do $$
declare d text;
begin
  d := pg_get_functiondef('public.regenerar_codigo'::regproc);
  if position('Solo el rector o la rectora pueden cambiar el acceso' in d) = 0 then
    d := replace(d, $q$if c is null or not priv.es_directivo(c) then raise exception 'Sin permiso'; end if;$q$,
      $q$if c is null or not priv.es_directivo(c) then raise exception 'Sin permiso'; end if;
  if (select rol from miembros where id = p_miembro) in ('rector','coordinador','secretaria','tesoreria') and not priv.es_rector(c) and not priv.es_superadmin() then
    raise exception 'Solo el rector o la rectora pueden cambiar el acceso de usuarios directivos';
  end if;$q$);
    execute d;
  end if;
end $$;
create trigger tg_miembros_permiso before insert or update or delete on public.miembros for each row execute function priv.tg_miembros_permiso();

-- 5) Plan de estudios por grado: cada asignatura puede limitarse a algunos grados de su nivel (vacío = todos)
alter table public.asignaturas add column if not exists grados int[] not null default '{}';
alter table public.asignaturas drop constraint if exists asignaturas_ih_check;
alter table public.asignaturas add constraint asignaturas_ih_check check (ih between 0 and 40);

-- 6) Citas: horario de atención a padres por colegio y fecha propuesta por la familia dentro de ese horario
alter table public.colegios add column if not exists atencion jsonb not null default '{"dias":[1,2,3,4,5],"desde":"07:00","hasta":"12:00"}';
grant update (atencion) on public.colegios to authenticated;
alter table public.citas add column if not exists fecha_propuesta timestamptz;
create or replace function priv.en_atencion(c uuid, f timestamptz) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select f is not null
     and extract(isodow from f at time zone 'America/Bogota')::int in (select jsonb_array_elements_text(k.atencion -> 'dias')::int)
     and (f at time zone 'America/Bogota')::time >= (k.atencion ->> 'desde')::time
     and (f at time zone 'America/Bogota')::time < (k.atencion ->> 'hasta')::time
  from colegios k where k.id = c
$$;
create or replace function priv.tg_citas() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare personal boolean;
begin
  if tg_op = 'INSERT' then
    select colegio_id into new.colegio_id from estudiantes where id = new.estudiante_id;
    personal := priv.es_mi_miembro(new.personal_id);
    new.pedida_por := case when personal then 'colegio' else 'familia' end;
    new.creado_por := priv.uid(); new.creado_en := now();
    if personal then
      if new.fecha is null then raise exception 'Escriba la fecha y hora de la cita'; end if;
      new.estado := 'Confirmada';
    else
      new.estado := 'Solicitada'; new.fecha := null; new.respuesta := null;
      if new.fecha_propuesta is not null then
        if new.fecha_propuesta < now() + interval '12 hours' then raise exception 'Elija una fecha a partir de mañana'; end if;
        if not priv.en_atencion(new.colegio_id, new.fecha_propuesta) then
          raise exception 'Esa fecha y hora están fuera del horario de atención a padres del colegio';
        end if;
      end if;
      if (select count(*) from citas where estudiante_id = new.estudiante_id and estado = 'Solicitada') >= 3 then
        raise exception 'Ya tiene 3 solicitudes de cita pendientes. Espere la respuesta del colegio.';
      end if;
    end if;
  else
    personal := priv.es_mi_miembro(old.personal_id);
    new.colegio_id := old.colegio_id; new.estudiante_id := old.estudiante_id; new.personal_id := old.personal_id;
    new.pedida_por := old.pedida_por; new.creado_por := old.creado_por; new.creado_en := old.creado_en; new.motivo := old.motivo;
    new.fecha_propuesta := old.fecha_propuesta;
    if not personal then
      if new.estado <> 'Cancelada' then raise exception 'Solo el colegio confirma o cambia la cita'; end if;
      new.fecha := old.fecha; new.modalidad := old.modalidad; new.respuesta := old.respuesta; new.preferencia := old.preferencia;
    elsif new.estado = 'Confirmada' and new.fecha is null then
      raise exception 'Escriba la fecha y hora de la cita';
    end if;
  end if;
  new.actualizado_en := now();
  return new;
end $$;

-- 6b) Observador: tipo "Felicitación" para estimular lo positivo
alter table public.observador drop constraint if exists observador_tipo_check;
alter table public.observador add constraint observador_tipo_check check (tipo in ('Felicitación','Positiva','Convivencia','Académica','Compromiso','Citación a acudiente'));

-- 6c) Boletines retenidos: estudiantes con pagos pendientes de un curso (solo para directivos)
create or replace function public.retenidos_grupo(p_grupo uuid) returns setof uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select s.id from estudiantes s join colegios k on k.id = s.colegio_id
  where s.grupo_id = p_grupo and s.estado = 'Activo' and k.restringir_morosos and priv.es_directivo(k.id) and priv.debe_vencido(s.id)
$$;
grant execute on function public.retenidos_grupo(uuid) to authenticated;

-- 6d) Fotos de la semana: se pueden subir de cualquier día de la semana en curso (no solo de hoy)
create or replace function priv.tg_fotos_clase() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  select colegio_id into new.colegio_id from grupos where id = new.grupo_id;
  if new.fecha is null or new.fecha > priv.hoy_co() or new.fecha < priv.lunes_co() then new.fecha := priv.hoy_co(); end if;
  new.creado_por := priv.uid(); new.autor_nombre := priv.nombre_actual(new.colegio_id);
  if (select count(*) from fotos_clase where grupo_id = new.grupo_id and fecha = new.fecha) >= 8 then
    raise exception 'Ya hay 8 fotos de este curso ese día. Borre alguna para subir otra.';
  end if;
  delete from fotos_clase where colegio_id = new.colegio_id and fecha < priv.lunes_co();
  update comunicados set imagen = null
   where colegio_id = new.colegio_id and imagen is not null and creado_en < now() - interval '15 days';
  return new;
end $$;

-- 6d2) Las fotos de ejemplo de la demostración son dibujos SVG (se muestran como imagen, sin ejecutar nada)
alter table public.fotos_clase drop constraint if exists fotos_clase_imagen_check;
alter table public.fotos_clase add constraint fotos_clase_imagen_check check (length(imagen) < 200000 and imagen ~ '^data:image/(jpeg|png|webp|svg\+xml);base64,[A-Za-z0-9+/=]+$');

-- 6e) Firma escaneada del rector(a) para boletines y constancias
alter table public.colegios add column if not exists firma_rector text;
alter table public.colegios drop constraint if exists colegios_firma_liviana;
alter table public.colegios add constraint colegios_firma_liviana check (firma_rector is null or (length(firma_rector) < 80000 and firma_rector ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$'));
grant update (firma_rector) on public.colegios to authenticated;

-- 7) Demostración: se renueva a medianoche de Colombia (antes era a las 7 p. m.) y queda completa
do $$
declare d text;
begin
  d := pg_get_functiondef('public.entrar_demo'::regproc);
  d := replace(d, 'k.creado_en::date < current_date', '(k.creado_en at time zone ''America/Bogota'')::date < priv.hoy_co()');
  execute d;
end $$;

create or replace function priv.demo_ajustes(c uuid, a int) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare g record; i int; dm uuid; coord uuid; docs text[] := array['Ana Milena Castaño','Laura Patricia Vélez','Óscar Iván Torres','Paula Andrea Montoya','Héctor Fabio Lozano'];
begin
  -- calificaciones a la escala 0-100 (crear_demo las genera de 1 a 5)
  alter table notas disable trigger user;
  update notas set valor = round(valor * 20) where colegio_id = c and valor <= 5;
  -- periodo 4 en curso con algunas calificaciones ya registradas (tercera parte de las asignaturas)
  insert into notas (colegio_id, estudiante_id, asignatura_id, anio, periodo, valor)
  select n.colegio_id, n.estudiante_id, n.asignatura_id, a, 4, least(100, greatest(35, n.valor + (random() * 16 - 8)::int))
  from notas n join asignaturas s on s.id = n.asignatura_id
  where n.colegio_id = c and n.anio = a and n.periodo = 3 and s.orden % 3 = 1 and s.nivel <> 'preescolar';
  alter table notas enable trigger user;
  update colegios set escala = '[{"d":"Bajo","min":0,"max":59},{"d":"Básico","min":60,"max":79},{"d":"Alto","min":80,"max":91},{"d":"Superior","min":92,"max":100}]',
         resolucion = 'Licencia de funcionamiento No. 0123 de 2015, Secretaría de Educación Distrital de Santa Marta', dane = '347001000123', nit = '900123456-7',
         pago_efectivo = true, pago_efectivo_texto = 'Tesorería del colegio, lunes a viernes de 7:00 a. m. a 12:00 m.',
         pago_llave = true, pago_llave_valor = '@colegiodemo', pago_llave_titular = 'Colegio de Demostración',
         pago_bold = true, pago_bold_url = 'https://bold.co',
         atencion = '{"dias":[1,2,3,4,5],"desde":"07:00","hasta":"12:00"}'
   where id = c;
  -- docentes y coordinación del colegio de ejemplo (para que las familias vean a quién escribir)
  -- (con una cuenta ficticia "demo:..." para que aparezcan como destinatarios de mensajes y citas)
  insert into miembros (colegio_id, email, nombre, rol, user_id) values (c, 'coordinacion@colegiodemo.co', 'Jorge Eliécer Pabón', 'coordinador', 'demo:coordinacion') returning id into coord;
  i := 0;
  for g in select * from grupos where colegio_id = c order by grado loop
    i := i + 1;
    insert into miembros (colegio_id, email, nombre, rol, user_id) values (c, 'docente' || i || '@colegiodemo.co', docs[1 + (i - 1) % 5], 'docente', 'demo:docente' || i) returning id into dm;
    insert into docente_grupos (colegio_id, miembro_id, grupo_id) values (c, dm, g.id);
    -- el director de Tercero A lo asume quien entra como Docente en la demostración
    if g.nombre <> 'Tercero A' then update grupos set director_miembro_id = dm, director_nombre = docs[1 + (i - 1) % 5] where id = g.id; end if;
  end loop;
  -- horario de ejemplo de lunes a viernes
  insert into horario (colegio_id, grupo_id, dia, bloque, hora, asignatura_id)
  select c, g2.id, d, b, (array['7:00','8:00','9:30','10:30','11:30'])[b],
         (select s.id from asignaturas s where s.colegio_id = c and s.nivel = g2.nivel order by s.orden offset ((d * 5 + b) % greatest(1, (select count(*) from asignaturas s3 where s3.colegio_id = c and s3.nivel = g2.nivel)::int)) limit 1)
  from grupos g2, generate_series(1, 5) d, generate_series(1, 5) b where g2.colegio_id = c;
  -- fotos de la semana de ejemplo (dibujos SVG livianos: tablero, cuaderno y actividad)
  insert into fotos_clase (grupo_id, imagen, pie, fecha)
  select g2.id, 'data:image/svg+xml;base64,' || replace(encode(convert_to(x.svg, 'UTF8'), 'base64'), chr(10), ''), x.pie, greatest(priv.lunes_co(), priv.hoy_co() - x.d)
  from grupos g2, (values ('<svg xmlns=''http://www.w3.org/2000/svg'' width=''480'' height=''320''><rect width=''480'' height=''320'' fill=''#22553c''/><rect x=''8'' y=''8'' width=''464'' height=''304'' fill=''none'' stroke=''#96703c'' stroke-width=''10''/><text x=''40'' y=''80'' fill=''#f0f0e6'' font-size=''36'' font-family=''Arial''>Fracciones</text><text x=''40'' y=''150'' fill=''#f0f0e6'' font-size=''30'' font-family=''Arial''>1/2 + 1/4 = 3/4</text><text x=''40'' y=''210'' fill=''#f0f0e6'' font-size=''30'' font-family=''Arial''>3/5 - 1/5 = 2/5</text><circle cx=''390'' cy=''200'' r=''50'' fill=''none'' stroke=''#f0f0e6'' stroke-width=''4''/><line x1=''390'' y1=''150'' x2=''390'' y2=''250'' stroke=''#f0f0e6'' stroke-width=''3''/><line x1=''340'' y1=''200'' x2=''440'' y2=''200'' stroke=''#f0f0e6'' stroke-width=''3''/></svg>', 'Repaso de fracciones en el tablero', 2),
                          ('<svg xmlns=''http://www.w3.org/2000/svg'' width=''480'' height=''320''><rect width=''480'' height=''320'' fill=''#fafaf5''/><g stroke=''#aac8e6''><line x1=''0'' y1=''64'' x2=''480'' y2=''64''/><line x1=''0'' y1=''104'' x2=''480'' y2=''104''/><line x1=''0'' y1=''144'' x2=''480'' y2=''144''/><line x1=''0'' y1=''184'' x2=''480'' y2=''184''/><line x1=''0'' y1=''224'' x2=''480'' y2=''224''/><line x1=''0'' y1=''264'' x2=''480'' y2=''264''/></g><line x1=''60'' y1=''0'' x2=''60'' y2=''320'' stroke=''#e67878'' stroke-width=''2''/><text x=''75'' y=''50'' fill=''#1e3c8c'' font-size=''24'' font-family=''Arial''>Tarea: el ciclo del agua</text><text x=''80'' y=''95'' font-size=''22'' font-family=''Arial''>1. Evaporación</text><text x=''80'' y=''135'' font-size=''22'' font-family=''Arial''>2. Condensación</text><text x=''80'' y=''175'' font-size=''22'' font-family=''Arial''>3. Precipitación</text><text x=''80'' y=''215'' font-size=''22'' font-family=''Arial''>4. Escorrentía</text><circle cx=''400'' cy=''130'' r=''40'' fill=''#ffc828''/></svg>', 'Tarea: el ciclo del agua (para quien faltó)', 1),
                          ('<svg xmlns=''http://www.w3.org/2000/svg'' width=''480'' height=''320''><rect width=''480'' height=''320'' fill=''#e8f1fa''/><rect y=''240'' width=''480'' height=''80'' fill=''#78b45a''/><g><circle cx=''105'' cy=''145'' r=''25'' fill=''#f0c8a0''/><rect x=''85'' y=''170'' width=''40'' height=''80'' fill=''#14a38b''/><circle cx=''225'' cy=''145'' r=''25'' fill=''#f0c8a0''/><rect x=''205'' y=''170'' width=''40'' height=''80'' fill=''#0b4f8a''/><circle cx=''345'' cy=''145'' r=''25'' fill=''#f0c8a0''/><rect x=''325'' y=''170'' width=''40'' height=''80'' fill=''#e6783c''/></g><text x=''20'' y=''50'' fill=''#0b4f8a'' font-size=''32'' font-family=''Arial''>Feria de ciencias</text></svg>', 'Preparando la feria de ciencias', 0)) x(svg, pie, d)
  where g2.colegio_id = c and g2.nombre in ('Tercero A', 'Quinto A');
  -- el segundo hijo del acudiente de la demostración (primer estudiante de Quinto A) queda con pagos pendientes
  alter table pagos disable trigger user;
  delete from pagos where estudiante_id = (select s.id from estudiantes s join grupos g3 on g3.id = s.grupo_id where s.colegio_id = c and g3.nombre = 'Quinto A' order by s.apellidos limit 1);
  alter table pagos enable trigger user;
  -- autorización de ejemplo
  insert into autorizaciones (colegio_id, titulo, detalle, fecha_evento, fecha_limite, destino, autor_nombre)
  values (c, 'Salida pedagógica al Acuario de Santa Marta', 'Saldremos a las 8:00 a. m. en el bus del colegio y regresaremos a las 12:00 m. Incluye refrigerio.',
          priv.hoy_co() + 12, priv.hoy_co() + 8, 'todos', 'María Fernanda Ospina Rueda');
end $$;
do $$
declare d text;
begin
  d := pg_get_functiondef('priv.crear_demo'::regproc);
  if position('demo_ajustes' in d) = 0 then
    d := replace(d, '  perform priv.demo_tienda(c, a);', '  perform priv.demo_tienda(c, a);' || chr(10) || '  perform priv.demo_ajustes(c, a);');
    if position('demo_ajustes' in d) = 0 then raise notice 'No se encontró dónde agregar los ajustes a la demostración'; return; end if;
    execute d;
  end if;
end $$;
-- Rehacer ya la demostración con todo lo nuevo
select priv.crear_demo();

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
grant execute on function public.retirar_contacto(uuid) to authenticated;
notify pgrst, 'reload schema';
