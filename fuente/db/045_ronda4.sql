-- 045 · Colegio-IA v0.31 (20 nov 2026): correcciones de la 4.ª vuelta de la Prueba Ácida
-- 1) Paz y salvo: el servidor no lo expide (ni para tesorería por la API) si hay saldo vencido a hoy, de este año o de años anteriores
-- 2) Acuerdo de pago: la cuota inicial se cuenta solo con pagos registrados DESPUÉS de crear el acuerdo (no con abonos del mismo día anteriores)
-- 3) Un graduado (con grado registrado) no genera cobros de los años siguientes
-- 4) Al cambiar de año (cierre), la matrícula en línea queda cerrada hasta que el colegio la abra de nuevo
begin;

-- ---------- 1) Paz y salvo ----------
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
declare d text := pg_get_functiondef('public.emitir_documento(uuid, uuid, text, integer, text, jsonb)'::regprocedure);
begin
  if position('debe_a_hoy' in d) = 0 then
    d := replace(d, $q$then raise exception 'Tipo de documento no válido'; end if;$q$,
      $q$then raise exception 'Tipo de documento no válido'; end if;
  if p_tipo = 'paz_salvo' and p_est is not null and priv.debe_a_hoy(p_est) then raise exception 'Tiene saldo vencido: el paz y salvo se expide cuando esté al día'; end if;$q$);
    if position('debe_a_hoy' in d) = 0 then raise exception 'No se pudo ajustar emitir_documento'; end if;
    execute d;
  end if;
end $$;

-- ---------- 2) Acuerdo de pago: cuota inicial ----------
do $$
declare d text := pg_get_functiondef('priv.acuerdo_al_dia(uuid)'::regprocedure);
begin
  if position($q$a.creado_en - interval '1 day'$q$ in d) > 0 then
    d := replace(d, $q$a.creado_en - interval '1 day'$q$, $q$a.creado_en - interval '2 minutes'$q$);
    execute d;
  end if;
end $$;

-- ---------- 3) Graduados sin cobros de años siguientes ----------
do $$
declare d text := pg_get_functiondef('priv.cuenta_base(uuid,int)'::regprocedure);
begin
  if position('from grados gr' in d) = 0 then
    d := replace(d, $q$and not exists (select 1 from historial hg where hg.estudiante_id = s.id and hg.resultado = 'Graduado' and hg.anio < p_anio)$q$,
      $q$and not exists (select 1 from historial hg where hg.estudiante_id = s.id and hg.resultado = 'Graduado' and hg.anio < p_anio)
      and not exists (select 1 from grados gr where gr.estudiante_id = s.id and gr.anio < p_anio)$q$);
    if position('from grados gr' in d) = 0 then raise exception 'No se pudo ajustar cuenta_base'; end if;
    execute d;
  end if;
end $$;

-- ---------- 4) Cambio de año: se cierra la matrícula en línea ----------
create or replace function priv.tg_colegio_anio_ml() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if new.anio is distinct from old.anio and new.matricula_linea then
    new.matricula_linea := false;
  end if;
  return new;
end $$;
drop trigger if exists tg_colegio_anio_ml on public.colegios;
create trigger tg_colegio_anio_ml before update on public.colegios for each row execute function priv.tg_colegio_anio_ml();

commit;
notify pgrst, 'reload schema';
