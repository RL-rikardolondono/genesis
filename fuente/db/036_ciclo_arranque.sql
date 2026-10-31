-- 036 · Colegio-IA v0.22 (31 oct 2026): hallazgos de la simulación del ciclo completo de un colegio nuevo
-- 1) Registro propio para colegios de más de 1.000 estudiantes (planes de 1.100 a 3.000, de 100 en 100)
-- 2) "Debes iniciar sesión" → "Debe iniciar sesión"
-- 3) Ampliar el plan: plan_cambio() (en prueba o sin meses pagados por delante, de inmediato; con meses pagados, pagando la diferencia con Bold)
-- 4) El pago de la diferencia llega por el mismo bold_pago_aprobado (empresa = <colegio>__s<plan>, plan genesis:paq_dif-xN):
--    la función original pasa a priv.bold_pago_base sin cambios y bold_pago_aprobado queda como entrada que reparte
-- Se puede ejecutar más de una vez.

-- 1) Registro propio
do $$
declare d text := pg_get_functiondef('public.registrar_colegio(text, text, integer, integer[], text)'::regprocedure);
begin
  if position('p_plan not in (100, 250, 500, 1000)' in d) > 0 then
    d := replace(d, 'if p_plan not in (100, 250, 500, 1000) then',
      'if not (p_plan in (100, 250, 500, 1000) or (p_plan between 1100 and 3000 and p_plan % 100 = 0)) then');
    execute d;
  end if;
end $$;

-- 2) Trato de usted
do $$
declare d text := pg_get_functiondef('public.activar_cuenta(text)'::regprocedure);
begin
  if position('Debes iniciar sesión' in d) > 0 then execute replace(d, 'Debes iniciar sesión', 'Debe iniciar sesión'); end if;
end $$;

-- 2b) Al llegar al tope, el mensaje dice cómo ampliar el plan sin escribir a nadie
do $$
declare d text := pg_get_functiondef('priv.tg_bloqueo()'::regprocedure);
begin
  if position('solicite la ampliación del plan' in d) > 0 then
    execute replace(d, 'Para matricular más, solicite la ampliación del plan.', 'Para matricular más, la rectoría puede ampliar el plan en Inicio › Su suscripción › Ampliar el plan.');
  end if;
end $$;

-- 3) Ampliar el plan
create table if not exists public.plataforma_cambios_plan (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references colegios(id) on delete cascade,
  plan_antes int not null, plan_nuevo int not null,
  meses int not null default 0, valor int not null default 0,
  estado text not null default 'aplicado' check (estado in ('aplicado', 'revisar')),
  origen text not null, pago_id text unique, referencia text, quien text,
  creado_en timestamptz not null default now());
alter table public.plataforma_cambios_plan enable row level security;
revoke all on public.plataforma_cambios_plan from public, anonymous, authenticated;
grant select on public.plataforma_cambios_plan to authenticated;
drop policy if exists cambios_plan_ver on public.plataforma_cambios_plan;
create policy cambios_plan_ver on public.plataforma_cambios_plan for select to authenticated
  using (priv.es_superadmin() or priv.es_directivo(colegio_id));

create or replace function priv.plan_valido(n int) returns boolean language sql immutable as $$
  select n in (100, 250, 500, 1000) or (n between 1100 and 3000 and n % 100 = 0) $$;

-- Cuánto cuesta pasar al plan p hoy: diferencia mensual × meses ya pagados desde el mes en curso
create or replace function priv.plan_dif(c uuid, p int) returns json
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare k colegios; hoy date := priv.hoy_co(); m int := 0; pr boolean;
begin
  select * into k from colegios where id = c;
  pr := priv.en_prueba(c);
  if not pr and k.pagado_hasta >= hoy then
    m := (extract(year from k.pagado_hasta) * 12 + extract(month from k.pagado_hasta))::int - (extract(year from hoy) * 12 + extract(month from hoy))::int + 1;
  end if;
  return json_build_object('plan_actual', k.plan_max, 'plan', p, 'en_prueba', pr, 'meses', m,
    'dif_mes', greatest(0, precio_plan(p) - precio_plan(k.plan_max)), 'total', greatest(0, precio_plan(p) - precio_plan(k.plan_max)) * m);
end $$;

create or replace function public.plan_cambio(p_colegio uuid, p_plan int, p_aplicar boolean default false) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare k colegios; d json;
begin
  if not priv.es_rector(p_colegio) then raise exception 'Solo la rectoría puede cambiar el plan'; end if;
  select * into k from colegios where id = p_colegio;
  if k.demo then raise exception 'En la demostración no se cambia el plan'; end if;
  if k.interna then raise exception 'Esta institución es interna: no tiene límite de estudiantes'; end if;
  if not priv.plan_valido(p_plan) then raise exception 'Plan no válido. Para más de 3.000 estudiantes escríbanos por WhatsApp al 304 437 5758.'; end if;
  if p_plan <= k.plan_max then raise exception 'Elija un plan mayor que el actual. Para bajar de plan escríbanos por WhatsApp al 304 437 5758.'; end if;
  d := priv.plan_dif(p_colegio, p_plan);
  if not p_aplicar then return d; end if;
  if (d->>'total')::int > 0 then raise exception 'Para este cambio hay que pagar la diferencia con Bold'; end if;
  perform set_config('micolegia.sistema', 'on', true);
  update colegios set plan_max = p_plan where id = p_colegio;
  perform set_config('micolegia.sistema', '', true);
  insert into plataforma_cambios_plan (colegio_id, plan_antes, plan_nuevo, meses, valor, origen, quien)
  values (p_colegio, k.plan_max, p_plan, 0, 0, case when (d->>'en_prueba')::boolean then 'prueba' else 'sin meses pagados' end, priv.email_actual());
  return d;
end $$;
revoke all on function public.plan_cambio(uuid, int, boolean) from public, anonymous;
grant execute on function public.plan_cambio(uuid, int, boolean) to authenticated;

-- 4) Entrada única de los pagos de Bold
create or replace function priv.bold_cambio_plan(e text, v int, r text, pid text) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
declare c uuid; p int; k colegios; d json;
begin
  c := nullif(split_part(e, '__s', 1), '')::uuid; p := nullif(split_part(e, '__s', 2), '')::int;
  if exists (select 1 from plataforma_cambios_plan where pago_id = pid) then return true; end if;
  select * into k from colegios where id = c for update;
  if k.id is null then raise exception 'Colegio no encontrado: %', c; end if;
  d := priv.plan_dif(c, p);
  if priv.plan_valido(p) and p > k.plan_max and v >= (d->>'total')::int then
    perform set_config('micolegia.sistema', 'on', true);
    update colegios set plan_max = p where id = c;
    perform set_config('micolegia.sistema', '', true);
    insert into plataforma_cambios_plan (colegio_id, plan_antes, plan_nuevo, meses, valor, origen, pago_id, referencia)
    values (c, k.plan_max, p, (d->>'meses')::int, v, 'bold', pid, r);
  else
    -- valor menor, plan ya aplicado o plan no válido: queda para que el Superadministrador lo revise (el dinero no se pierde)
    insert into plataforma_cambios_plan (colegio_id, plan_antes, plan_nuevo, meses, valor, estado, origen, pago_id, referencia)
    values (c, k.plan_max, coalesce(p, 0), (d->>'meses')::int, v, 'revisar', 'bold', pid, r);
  end if;
  return true;
end $$;

do $$
declare o oid; nombres text[]; tipos text; rt text; args text; llamada text; g record;
begin
  -- a) la función original pasa a priv.bold_pago_base (una sola vez)
  if to_regprocedure('priv.bold_pago_base(text, integer, integer, text, text)') is null then
    if to_regprocedure('public.bold_pago_aprobado(text, integer, integer, text, text)') is null then
      raise notice 'bold_pago_aprobado no existe en esta base: se omite la entrada de cambios de plan'; return;
    end if;
    create temp table if not exists _bold_grants as select grantee from information_schema.routine_privileges
      where routine_schema = 'public' and routine_name = 'bold_pago_aprobado' and privilege_type = 'EXECUTE';
    alter function public.bold_pago_aprobado(text, integer, integer, text, text) rename to bold_pago_base;
    alter function public.bold_pago_base(text, integer, integer, text, text) set schema priv;
  end if;
  o := 'priv.bold_pago_base(text, integer, integer, text, text)'::regprocedure;
  select coalesce(proargnames, array['p1','p2','p3','p4','p5']), pg_get_function_result(oid) into nombres, rt from pg_proc where oid = o;
  args := format('%I text, %I integer, %I integer, %I text, %I text', nombres[1], nombres[2], nombres[3], nombres[4], nombres[5]);
  llamada := format('%I, %I, %I, %I, %I', nombres[1], nombres[2], nombres[3], nombres[4], nombres[5]);
  -- b) nueva entrada con los mismos nombres de parámetros y el mismo tipo de respuesta
  execute format($f$create or replace function public.bold_pago_aprobado(%s) returns %s
    language plpgsql security definer set search_path = public, pg_temp as $b$
    begin
      if %I ~ '__s[0-9]+$' then
        begin
          perform priv.bold_cambio_plan(%I, %I, %I, %I);
        exception when others then
          return json_build_object('ok', false, 'error', 'cambio_de_plan: ' || sqlerrm)::%s;
        end;
        return json_build_object('ok', true, 'cambio_de_plan', true)::%s;
      end if;
      return priv.bold_pago_base(%s);
    end $b$ $f$, args, rt, nombres[1], nombres[1], nombres[3], nombres[4], nombres[5], rt, rt, llamada);
  revoke all on function public.bold_pago_aprobado(text, integer, integer, text, text) from public;
  for g in select grantee from information_schema.routine_privileges where routine_schema = 'priv' and routine_name = 'bold_pago_base' and privilege_type = 'EXECUTE' and grantee not in ('PUBLIC') loop
    execute format('grant execute on function public.bold_pago_aprobado(text, integer, integer, text, text) to %I', g.grantee);
  end loop;
  if to_regclass('pg_temp._bold_grants') is not null then
    for g in select grantee from _bold_grants where grantee <> 'PUBLIC' loop
      execute format('grant execute on function public.bold_pago_aprobado(text, integer, integer, text, text) to %I', g.grantee);
    end loop;
  end if;
end $$;

notify pgrst, 'reload schema';
