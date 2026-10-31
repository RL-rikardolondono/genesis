-- 015b · RESPALDO de lo de Bold que se hizo en la conversación "Pagos automáticos Bold" (10 oct 2026) y solo vivía en Neon.
-- Copiado de producción el 31 oct 2026 (antes de aplicar el 036). No hace falta ejecutarlo en producción:
-- sirve para reconstruir una base nueva. Después del 036, esta función queda como priv.bold_pago_base.
create table if not exists public.plataforma_bold (
  pago_id text primary key,
  colegio_id uuid not null,
  meses integer not null,
  valor integer not null,
  referencia text not null,
  respuesta json,
  creado_en timestamptz not null default now());

-- Usuario limitado que usa el receptor de skynetgenesis.com (bold-webhook.php): solo ejecuta esta función.
-- Se crea por SQL, no por el panel de Neon (allí queda administrador). La contraseña no va en este archivo.
-- create role bold_pagos login password '...';

CREATE OR REPLACE FUNCTION public.bold_pago_aprobado(p_colegio text, p_meses integer, p_valor integer, p_referencia text, p_pago_id text)
 RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $function$
declare k colegios; v_id uuid; m date; i int; previo json; res json;
begin
  if coalesce(p_pago_id, '') = '' or coalesce(p_referencia, '') = '' then return json_build_object('ok', false, 'error', 'datos_incompletos'); end if;
  if p_meses is null or p_meses < 1 or p_meses > 12 or p_valor is null or p_valor < p_meses then return json_build_object('ok', false, 'error', 'meses_o_valor_invalido'); end if;
  begin v_id := p_colegio::uuid; exception when others then return json_build_object('ok', false, 'error', 'colegio_invalido'); end;
  -- Un mismo pago de Bold se aplica una sola vez (aunque Bold avise varias veces).
  select respuesta into previo from plataforma_bold where pago_id = p_pago_id;
  if found then return (previo::jsonb || '{"repetido": true}'::jsonb)::json; end if;
  select * into k from colegios where id = v_id for update;
  if k.id is null then return json_build_object('ok', false, 'error', 'colegio_no_existe'); end if;
  insert into plataforma_bold (pago_id, colegio_id, meses, valor, referencia) values (p_pago_id, v_id, p_meses, p_valor, p_referencia);
  if k.prueba_hasta is not null and not exists (select 1 from plataforma_pagos x where x.colegio_id = v_id) then
    m := date_trunc('month', greatest(current_date, k.prueba_hasta - 1))::date;
  else
    m := (date_trunc('month', coalesce(k.pagado_hasta, current_date)) + interval '1 month')::date;
  end if;
  for i in 1 .. p_meses loop
    insert into plataforma_pagos (colegio_id, mes, valor, fecha, medio, referencia)
    values (v_id, m, greatest(1, round(p_valor::numeric / p_meses))::int, current_date, 'Bold', 'Bold ' || p_referencia)
    on conflict (colegio_id, mes) do nothing;
    m := (m + interval '1 month')::date;
  end loop;
  res := json_build_object('ok', true, 'colegio', v_id, 'meses', p_meses, 'pagado_hasta', (select pagado_hasta from colegios where id = v_id));
  update plataforma_bold set respuesta = res where pago_id = p_pago_id;
  return res;
end $function$;
revoke all on function public.bold_pago_aprobado(text, integer, integer, text, text) from public;
grant execute on function public.bold_pago_aprobado(text, integer, integer, text, text) to bold_pagos;
