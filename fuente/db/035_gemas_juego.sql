-- 035 · Tablero de gemas como el de AcademIA (pedido del dueño, 21 oct 2026; hecho 30-31 oct 2026)
-- gemas_resumen devuelve además: gemas de hoy, racha actual de días seguidos entrando, la mejor racha
-- y cuántas gemas tiene por cada motivo (para calcular las insignias en la pantalla).
create or replace function public.gemas_resumen(p_est uuid) returns json
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s estudiantes; tot int; sem int; hoy int; pos int; de int; top json; cnt json; rac int; rmax int;
  lun date := priv.lunes_co(); d date := priv.hoy_co();
begin
  select * into s from estudiantes where id = p_est;
  if s.id is null or not (p_est in (select priv.mis_estudiantes_al_dia()) or priv.puede_calificar(p_est)) then raise exception 'No tiene permiso para esta acción'; end if;
  select coalesce(sum(cantidad), 0) into tot from gemas where estudiante_id = p_est;
  select coalesce(sum(cantidad), 0) into sem from gemas where estudiante_id = p_est and (creado_en at time zone 'America/Bogota')::date >= lun;
  select coalesce(sum(cantidad), 0) into hoy from gemas where estudiante_id = p_est and (creado_en at time zone 'America/Bogota')::date = d;
  with r as (select x.id, coalesce((select sum(cantidad) from gemas g where g.estudiante_id = x.id), 0) t
             from estudiantes x where x.grupo_id = s.grupo_id and x.estado = 'Activo')
  select count(*) filter (where t > tot) + 1, count(*) into pos, de from r;
  select json_agg(json_build_object('n', z.n, 'g', z.t, 'yo', z.id = p_est) order by z.t desc, z.n) into top from (
    select x.id, x.nombres || ' ' || left(x.apellidos, 1) || '.' n, coalesce((select sum(cantidad) from gemas g where g.estudiante_id = x.id), 0) t
    from estudiantes x where x.grupo_id = s.grupo_id and x.estado = 'Activo' order by t desc, n limit 10) z;
  select coalesce(json_object_agg(motivo, n), '{}'::json) into cnt from (select motivo, count(*) n from gemas where estudiante_id = p_est group by motivo) m;
  -- Rachas: días con gemas de entrada agrupados en tramos seguidos
  with dias as (select distinct ref::date f from gemas where estudiante_id = p_est and motivo = 'entrada' and ref ~ '^\d{4}-\d{2}-\d{2}$'),
       g as (select f, f - (row_number() over (order by f))::int grp from dias),
       t as (select max(f) fin, count(*) n from g group by grp)
  select coalesce(max(n), 0), coalesce(max(n) filter (where fin >= d - 1), 0) into rmax, rac from t;
  return json_build_object('total', tot, 'semana', sem, 'hoy', hoy, 'racha', rac, 'racha_max', rmax, 'cnt', cnt,
    'puesto', pos, 'de', de, 'top', coalesce(top, '[]'::json),
    'ultimas', (select coalesce(json_agg(json_build_object('m', motivo, 'c', cantidad, 'f', creado_en) order by creado_en desc), '[]'::json)
                from (select * from gemas where estudiante_id = p_est order by creado_en desc limit 12) w));
end $$;
revoke all on function public.gemas_resumen(uuid) from public;
grant execute on function public.gemas_resumen(uuid) to authenticated;
