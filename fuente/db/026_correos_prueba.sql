-- Colegio-IA 026: correo diario a los colegios en prueba gratis con los días que les quedan (Brevo).
-- Lo envía cada mañana un proceso programado en GitHub (Actions) del repositorio, que se conecta a la base con un
-- usuario limitado (correo_pruebas) que SOLO puede leer esta lista y marcar el correo como enviado.

alter table public.colegios add column if not exists prueba_ultimo_correo date;

-- Colegios en prueba a los que hoy les toca correo (uno al día; el último cuando termina la prueba)
create or replace function public.pruebas_para_correo() returns table (
  colegio_id uuid, colegio text, email text, rector text, dias int, prueba_hasta date, plan_max int, valor_mes int)
language sql stable security definer set search_path = public, pg_temp as $$
  select k.id, k.nombre, k.registro_email, k.rector_nombre, (k.prueba_hasta - priv.hoy_co())::int, k.prueba_hasta, k.plan_max, precio_plan(k.plan_max)
  from colegios k
  where k.activo and not k.demo and k.prueba_hasta is not null and k.registro_email is not null
    and priv.en_prueba(k.id)
    and k.prueba_hasta - priv.hoy_co() between 0 and 15
    and k.prueba_ultimo_correo is distinct from priv.hoy_co()
  order by k.creado_en
$$;
-- Marca el correo de hoy como enviado (para no repetirlo)
create or replace function public.prueba_correo_enviado(p_colegio uuid) returns void
language sql security definer set search_path = public, pg_temp as $$
  update colegios set prueba_ultimo_correo = priv.hoy_co() where id = p_colegio and prueba_hasta is not null
$$;
revoke execute on function public.pruebas_para_correo(), public.prueba_correo_enviado(uuid) from public, anonymous, authenticated;

-- Usuario limitado para el proceso programado (la contraseña se genera aquí y se muestra UNA sola vez abajo)
create temp table if not exists tmp_conexion (copie_este_valor text);
do $$
declare pw text;
begin
  if not exists (select 1 from pg_roles where rolname = 'correo_pruebas') then
    pw := encode(gen_random_bytes(24), 'hex');
    execute format('create role correo_pruebas login password %L', pw);
    insert into tmp_conexion values ('postgresql://correo_pruebas:' || pw || '@ep-weathered-breeze-b4c82o4u.c-6.us-east-2.aws.neon.tech/neondb?sslmode=require');
  else
    insert into tmp_conexion values ('El usuario correo_pruebas ya existía: use el valor que guardó en GitHub la primera vez.');
  end if;
end $$;
grant usage on schema public to correo_pruebas;
grant execute on function public.pruebas_para_correo(), public.prueba_correo_enviado(uuid) to correo_pruebas;
select copie_este_valor from tmp_conexion;
