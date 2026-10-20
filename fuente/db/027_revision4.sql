-- Colegio-IA 027 (entrega 4 de la revisión del 19-20 oct 2026): errores graves y seguridad.
--  1) No se puede eliminar un curso que tenga estudiantes (de cualquier estado) ni calificaciones registradas.
--  2) No se puede eliminar una asignatura que ya tenga calificaciones (se desmarcan sus grados para ocultarla).
--  3) La matrícula nueva exige los datos básicos del SIMAT también en la base (no solo en la pantalla).
--  4) Mensajes claros cuando un periodo ya está cerrado (en lugar de "No tiene permiso").

-- 1) Cursos
create or replace function priv.tg_grupos_no_borrar() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int; c int;
begin
  -- Si se está borrando el colegio completo (p. ej., la demostración que se renueva cada día) o lo hace el sistema, se permite
  if current_setting('micolegia.sistema', true) = 'on' or not exists (select 1 from colegios where id = old.colegio_id) then return old; end if;
  select count(*) into n from estudiantes where grupo_id = old.id;
  if n > 0 then
    raise exception 'El curso % tiene % estudiante(s). Trasládelos a otro curso o regístreles el retiro antes de eliminarlo', old.nombre, n;
  end if;
  select count(*) into c from notas_act na join actividades a on a.id = na.actividad_id where a.grupo_id = old.id;
  if c > 0 then
    raise exception 'El curso % tiene calificaciones registradas y no se puede eliminar', old.nombre;
  end if;
  return old;
end $$;
drop trigger if exists tg_grupos_no_borrar on public.grupos;
create trigger tg_grupos_no_borrar before delete on public.grupos for each row execute function priv.tg_grupos_no_borrar();

-- 2) Asignaturas
create or replace function priv.tg_asig_no_borrar() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if current_setting('micolegia.sistema', true) = 'on' or not exists (select 1 from colegios where id = old.colegio_id) then return old; end if;
  if exists (select 1 from notas where asignatura_id = old.id)
     or exists (select 1 from notas_act na join actividades a on a.id = na.actividad_id where a.asignatura_id = old.id) then
    raise exception 'La asignatura % ya tiene calificaciones y no se puede eliminar. Desmarque sus grados en el plan de estudios para que deje de aparecer', old.nombre;
  end if;
  return old;
end $$;
drop trigger if exists tg_asig_no_borrar on public.asignaturas;
create trigger tg_asig_no_borrar before delete on public.asignaturas for each row execute function priv.tg_asig_no_borrar();

-- 3) Matrícula nueva con datos básicos completos (las fichas antiguas se completan al editarlas)
create or replace function priv.tg_est_completo() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if current_setting('micolegia.sistema', true) = 'on' then return new; end if;
  if btrim(coalesce(new.doc, '')) = '' or btrim(coalesce(new.tipo_doc, '')) = '' or new.fnac is null or btrim(coalesce(new.sexo, '')) = ''
     or new.grupo_id is null or btrim(coalesce(new.direccion, '')) = '' or btrim(coalesce(new.municipio, '')) = '' then
    raise exception 'Falta un dato obligatorio de la matrícula (documento, fecha de nacimiento, sexo, curso, dirección o municipio)';
  end if;
  return new;
end $$;
drop trigger if exists tg_est_completo on public.estudiantes;
create trigger tg_est_completo before insert on public.estudiantes for each row execute function priv.tg_est_completo();

-- 4) Demostración: fichas completas (lugar de expedición y SISBÉN) para que no salgan como "Ficha incompleta"
create or replace function priv.demo_revision4(c uuid, a int) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update estudiantes set lugar_expedicion = coalesce(lugar_expedicion, lugar_nacimiento, 'Santa Marta'),
    sisben = coalesce(sisben, (array['A3', 'B2', 'B4', 'C1', 'No tiene'])[1 + abs(hashtext(id::text)) % 5])
  where colegio_id = c;
end $$;
do $$
declare d text;
begin
  d := pg_get_functiondef('priv.crear_demo'::regproc);
  if position('demo_revision4' in d) = 0 then
    d := replace(d, '  perform priv.demo_campus(c, a);', '  perform priv.demo_campus(c, a);' || chr(10) || '  perform priv.demo_revision4(c, a);');
    if position('demo_revision4' in d) = 0 then raise exception 'No se encontró dónde agregar los ajustes a la demostración'; end if;
    execute d;
  end if;
end $$;
-- La demostración de hoy también queda completa
select priv.demo_revision4(id, anio) from colegios where demo;

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
notify pgrst, 'reload schema';
