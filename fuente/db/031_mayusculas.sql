-- Colegio-IA 031 (21 oct 2026): los datos y nombres siempre en MAYÚSCULA.
--  Lo pidió Ricardo: así la persona escriba en minúscula, en pantalla (y en los documentos) todo queda en mayúscula.
--  Se aplica a nombres y datos (estudiantes, acudientes, usuarios, cursos, asignaturas, contactos, colegio, conceptos,
--  artículos de la tienda y actividades). Quedan como se escriben: correos, contraseñas, enlaces, llaves, tipos de
--  documento y opciones de listas, y los textos largos (comunicados, mensajes, observaciones, logros, campus).
--  También se pasan a mayúscula los datos ya guardados.

begin;

-- 1) Función común: pone en mayúscula las columnas indicadas al crear o cambiar una fila
create or replace function priv.tg_mayus() returns trigger
language plpgsql set search_path = public, pg_temp as $$
declare j jsonb := to_jsonb(new); c text;
begin
  foreach c in array tg_argv loop
    if jsonb_typeof(j -> c) = 'string' and (j ->> c) <> upper(j ->> c) then
      j := jsonb_set(j, array[c], to_jsonb(upper(j ->> c)));
    end if;
  end loop;
  new := jsonb_populate_record(new, j);
  return new;
end $$;

-- 2) Disparadores (nombre "zz_mayus" para que corran de últimos, después de los demás)
drop trigger if exists zz_mayus on public.estudiantes;
create trigger zz_mayus before insert or update on public.estudiantes for each row execute function priv.tg_mayus(
  'nombres', 'apellidos', 'lugar_nacimiento', 'lugar_expedicion', 'eps', 'direccion', 'barrio', 'municipio', 'acudiente_nombre',
  'pais_origen', 'institucion_procedencia', 'sisben', 'autoriza_por');
drop trigger if exists zz_mayus on public.acudientes;
create trigger zz_mayus before insert or update on public.acudientes for each row execute function priv.tg_mayus('nombres', 'direccion', 'ocupacion');
drop trigger if exists zz_mayus on public.miembros;
create trigger zz_mayus before insert or update on public.miembros for each row execute function priv.tg_mayus('nombre');
drop trigger if exists zz_mayus on public.grupos;
create trigger zz_mayus before insert or update on public.grupos for each row execute function priv.tg_mayus('nombre', 'director_nombre');
drop trigger if exists zz_mayus on public.asignaturas;
create trigger zz_mayus before insert or update on public.asignaturas for each row execute function priv.tg_mayus('nombre');
drop trigger if exists zz_mayus on public.contactos_est;
create trigger zz_mayus before insert or update on public.contactos_est for each row execute function priv.tg_mayus('nombre', 'parentesco', 'creado_nombre', 'retirado_nombre');
drop trigger if exists zz_mayus on public.colegios;
create trigger zz_mayus before insert or update on public.colegios for each row execute function priv.tg_mayus(
  'nombre', 'ciudad', 'direccion', 'rector_nombre', 'secretaria_nombre', 'lema', 'resolucion');
drop trigger if exists zz_mayus on public.conceptos;
create trigger zz_mayus before insert or update on public.conceptos for each row execute function priv.tg_mayus('nombre');
drop trigger if exists zz_mayus on public.productos;
create trigger zz_mayus before insert or update on public.productos for each row execute function priv.tg_mayus('nombre');
drop trigger if exists zz_mayus on public.actividades;
create trigger zz_mayus before insert or update on public.actividades for each row execute function priv.tg_mayus('nombre');
-- nombres de quien registró algo (autor del comunicado o del observador, quien recibió el pago, quien leyó, quien guardó los logros)
drop trigger if exists zz_mayus on public.comunicados;
create trigger zz_mayus before insert or update on public.comunicados for each row execute function priv.tg_mayus('autor_nombre');
drop trigger if exists zz_mayus on public.observador;
create trigger zz_mayus before insert or update on public.observador for each row execute function priv.tg_mayus('autor_nombre');
drop trigger if exists zz_mayus on public.pagos;
create trigger zz_mayus before insert on public.pagos for each row execute function priv.tg_mayus('registrado_nombre');
drop trigger if exists zz_mayus on public.lecturas;
create trigger zz_mayus before insert or update on public.lecturas for each row execute function priv.tg_mayus('nombre');
drop trigger if exists zz_mayus on public.logros;
create trigger zz_mayus before insert or update on public.logros for each row execute function priv.tg_mayus('actualizado_nombre');

-- 3) La demostración compara nombres de cursos y asignaturas: se ajusta a los nombres en mayúscula
do $$
declare f text; d text;
begin
  foreach f in array array['priv.crear_demo()', 'public.entrar_demo(text)', 'priv.demo_campus(uuid,integer)', 'priv.demo_ajustes(uuid,integer)', 'priv.demo_revision7(uuid,integer)'] loop
    d := pg_get_functiondef(f::regprocedure);
    d := replace(replace(replace(replace(d, '''Tercero A''', '''TERCERO A'''), '''Quinto A''', '''QUINTO A'''),
                 '''Matemáticas''', '''MATEMÁTICAS'''), '''Lengua castellana''', '''LENGUA CASTELLANA''');
    execute d;
  end loop;
end $$;

-- 4) Datos ya guardados (todo el archivo va en una sola transacción: si algo falla, no queda nada a medias)
select set_config('micolegia.sistema', 'on', true);
update estudiantes set nombres = nombres where true;   -- el disparador hace el cambio
update acudientes set nombres = nombres where true;
update miembros set nombre = nombre where true;
-- cursos: si dos nombres quedan iguales en mayúscula, al segundo se le agrega una marca para no perderlo
update grupos g set nombre = upper(g.nombre) || ' (' || left(g.id::text, 4) || ')'
  where exists (select 1 from grupos o where o.colegio_id = g.colegio_id and o.id < g.id and upper(o.nombre) = upper(g.nombre));
update grupos set nombre = nombre where true;
update asignaturas set nombre = nombre where true;
update contactos_est set nombre = nombre where true;
update colegios set nombre = nombre where true;
update conceptos set nombre = nombre where true;
update productos set nombre = nombre where true;
update actividades set nombre = nombre where true;
-- nombres de quien registró algo (autores, quien recibió el pago, quien guardó los logros)
update comunicados set autor_nombre = upper(autor_nombre) where autor_nombre <> upper(autor_nombre);
alter table observador disable trigger tg_observador;
update observador set autor_nombre = upper(autor_nombre) where autor_nombre <> upper(autor_nombre);
alter table observador enable trigger tg_observador;
update lecturas set nombre = upper(nombre) where nombre <> upper(nombre);
alter table pagos disable trigger tg_pagos;
update pagos set registrado_nombre = upper(registrado_nombre) where registrado_nombre <> upper(registrado_nombre);
alter table pagos enable trigger tg_pagos;
update logros set actualizado_nombre = upper(actualizado_nombre) where actualizado_nombre <> upper(actualizado_nombre);
select set_config('micolegia.sistema', '', true);

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
commit;
notify pgrst, 'reload schema';
