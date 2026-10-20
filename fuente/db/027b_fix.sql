-- Colegio-IA 027b: corrección urgente (la demostración se renueva borrando el colegio completo)
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
-- prueba: renovar la demostración dentro de una transacción que se deshace
begin;
select priv.crear_demo();
rollback;
