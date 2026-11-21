-- 046 · Colegio-IA v0.32 (20 nov 2026): correcciones de la 5.ª vuelta de la Prueba Ácida
-- 1) Una sola regla de «debe a la fecha» (cuota vencida, de un mes anterior del año en curso, o de un año anterior)
--    para pedir y emitir el paz y salvo. Antes se comparaba solo el mes, y después del cierre de año (año 2027 con
--    calendario 2026) una familia al día no podía pedirlo; y un graduado con deuda de años anteriores sí podía pedirlo.
-- 2) Acuerdo de pago: la cuota inicial se cuenta solo con pagos registrados DESPUÉS de crear el acuerdo (sin margen)
begin;

create or replace function priv.debe_a_hoy(e uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from estudiantes s join colegios k on k.id = s.colegio_id
    cross join lateral generate_series(greatest(k.anio - 5, 2020), k.anio) y
    cross join lateral priv.cuenta_int(s.id, y) x
    where s.id = e and x.saldo > 0
      and (x.vencido or y < extract(year from priv.hoy_co())::int
           or (y = extract(year from priv.hoy_co())::int and x.mes < extract(month from priv.hoy_co())::int)))
$$;
revoke all on function priv.debe_a_hoy(uuid) from public, anonymous, authenticated;

do $$
declare d text;
begin
  -- pedir_documento (familia)
  d := pg_get_functiondef('public.pedir_documento(uuid,text,integer,integer,text)'::regprocedure);
  if position('debe_a_hoy' in d) = 0 then
    d := replace(d, $q$exists (select 1 from estado_cuenta(p_est, k.anio) e where e.saldo > 0 and (e.vencido or e.mes < extract(month from priv.hoy_co())))$q$, $q$priv.debe_a_hoy(p_est)$q$);
    if position('debe_a_hoy' in d) = 0 then raise exception 'No se pudo ajustar pedir_documento'; end if;
    execute d;
  end if;
  -- emitir_documento (familia): misma regla
  d := pg_get_functiondef('public.emitir_documento(uuid,uuid,text,integer,text,jsonb)'::regprocedure);
  if position('ec.mes < extract(month' in d) > 0 then
    d := replace(d, $q$exists (select 1 from colegios kk cross join lateral estado_cuenta(p_est, kk.anio) ec
        where kk.id = p_colegio and ec.saldo > 0 and (ec.vencido or ec.mes < extract(month from priv.hoy_co())))$q$, $q$priv.debe_a_hoy(p_est)$q$);
    if position('ec.mes < extract(month' in d) > 0 then raise exception 'No se pudo ajustar emitir_documento'; end if;
    execute d;
  end if;
  -- acuerdo: sin margen
  d := pg_get_functiondef('priv.acuerdo_al_dia(uuid)'::regprocedure);
  if position($q$a.creado_en - interval '2 minutes'$q$ in d) > 0 then
    d := replace(d, $q$p.registrado_en >= a.creado_en - interval '2 minutes'$q$, $q$p.registrado_en >= a.creado_en$q$);
    execute d;
  end if;
end $$;

commit;
notify pgrst, 'reload schema';
