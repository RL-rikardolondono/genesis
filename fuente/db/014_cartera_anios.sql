-- Genesis 014: la deuda de años anteriores no desaparece al cerrar el año.
alter table public.historial add column if not exists fecha_matricula date;

-- ===== Revisión de 3 años =====
-- (a) Al reintegrar a un estudiante retirado se borraba su fecha de retiro y le volvían a aparecer
--     cobros del año en que se retiró. El historial ahora guarda la fecha de retiro.
alter table public.historial add column if not exists fecha_retiro date;
-- (b) Los certificados de años anteriores se calculaban con los periodos y la escala del año actual.
--     Al cerrar el año se guarda cómo estaba configurado ese año.
create table if not exists public.anios_cerrados (
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  anio int not null,
  periodos jsonb, escala jsonb, max_perdidas int,
  cerrado_en timestamptz not null default now(),
  primary key (colegio_id, anio)
);
alter table public.anios_cerrados enable row level security;
grant select on public.anios_cerrados to authenticated;
drop policy if exists anc_ver on public.anios_cerrados;
create policy anc_ver on public.anios_cerrados for select to authenticated using (priv.es_miembro(colegio_id));


-- Antes: el cierre cambia fecha_matricula al 1 de enero del año nuevo y el estado de cuenta del año
-- anterior dejaba de cobrar las pensiones; además la cartera ocultaba a los graduados.

create or replace function public.estado_cuenta(p_estudiante uuid, p_anio integer)
 returns table(concepto_id uuid, concepto text, tipo text, mes integer, valor numeric, pagado numeric, saldo numeric, vencido boolean)
 language sql stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  -- security definer: necesita leer el historial (año cursado), que tesorería no ve; el permiso se valida abajo
  with s as (
    select e.*, k.dia_limite_pago as dia,
           -- curso y fecha de matrícula que valen para el año consultado
           coalesce(case when h.estudiante_id is not null and coalesce(extract(year from e.fecha_matricula)::int, p_anio) <> p_anio then h.grado end, g.grado) as grado_anio,
           case when extract(year from e.fecha_matricula)::int = p_anio then e.fecha_matricula
                when extract(year from h.fecha_matricula)::int = p_anio then h.fecha_matricula end as matricula_anio,
           (h.estudiante_id is not null or e.fecha_matricula is null or extract(year from e.fecha_matricula)::int <= p_anio) as cursa,
           coalesce(h.fecha_retiro, e.fecha_retiro) as retiro_anio
    from estudiantes e
    join colegios k on k.id = e.colegio_id
    left join grupos g on g.id = e.grupo_id
    left join historial h on h.estudiante_id = e.id and h.anio = p_anio
    where e.id = p_estudiante and (priv.maneja_pagos(e.colegio_id) or priv.es_familia_de(e.id))
  ),
  cobros as (
    select c.id, c.nombre, c.tipo, c.orden, m.mes, s.matricula_anio, s.dia,
           coalesce((c.valores_grado ->> (s.grado_anio)::text)::numeric, c.valor) as valor
    from s
    join conceptos c on c.colegio_id = s.colegio_id and c.anio = p_anio and c.activo
    cross join lateral (
      select unnest(case when c.periodicidad = 'mensual' then c.meses else array[c.mes_cobro] end) as mes
    ) m
    where s.cursa
      and not exists (select 1 from historial hg where hg.estudiante_id = s.id and hg.resultado = 'Graduado' and hg.anio < p_anio)
      and ((c.periodicidad = 'unico' and c.tipo in ('matricula', 'seguro', 'carnet'))
        or s.matricula_anio is null
        or s.matricula_anio < (make_date(p_anio, m.mes, 1) + interval '1 month'))
      and (s.retiro_anio is null or make_date(p_anio, m.mes, 1) <= s.retiro_anio)
  ),
  pag as (
    select p.concepto_id, p.mes, sum(p.valor) as pagado
    from pagos p where p.estudiante_id = p_estudiante and p.anio = p_anio and not p.anulado
    group by 1, 2
  )
  select c.id, c.nombre, c.tipo, c.mes, c.valor,
         coalesce(pg.pagado, 0), greatest(c.valor - coalesce(pg.pagado, 0), 0),
         current_date > greatest(make_date(p_anio, c.mes, c.dia), coalesce(c.matricula_anio, make_date(p_anio, c.mes, c.dia)))
  from cobros c
  left join pag pg on pg.concepto_id = c.id and pg.mes is not distinct from c.mes
  where c.valor > 0
  order by c.mes, c.orden, c.nombre
$function$;

create or replace function public.cartera(p_colegio uuid, p_anio integer)
 returns table(estudiante_id uuid, nombre text, grupo text, estado text, cobrado numeric, pagado numeric, saldo_vencido numeric, saldo_total numeric)
 language plpgsql stable
 set search_path to 'public', 'pg_temp'
as $function$
declare v_actual int := (select anio from colegios where id = p_colegio);
begin
  if not priv.maneja_pagos(p_colegio) then raise exception 'Sin permiso'; end if;
  return query
    select e.id, e.apellidos || ' ' || e.nombres,
           case when p_anio < v_actual then coalesce((select h.grupo_nombre from historial h where h.estudiante_id = e.id and h.anio = p_anio), g.nombre) else g.nombre end,
           e.estado,
           coalesce(sum(x.valor), 0), coalesce(sum(x.pagado), 0),
           coalesce(sum(x.saldo) filter (where x.vencido), 0), coalesce(sum(x.saldo), 0)
    from estudiantes e
    left join grupos g on g.id = e.grupo_id
    left join lateral estado_cuenta(e.id, p_anio) x on true
    where e.colegio_id = p_colegio and (e.estado <> 'Graduado' or p_anio < v_actual)
    group by e.id, e.apellidos, e.nombres, g.nombre, e.estado
    having p_anio >= v_actual or coalesce(sum(x.valor), 0) > 0
    order by 3 nulls last, e.apellidos;
end $function$;

-- El cierre guarda la fecha de matrícula del año que termina (antes se perdía)
create or replace function public.cerrar_anio(p_colegio uuid, p_decisiones jsonb)
 returns json language plpgsql security definer set search_path to 'public', 'pg_temp'
as $function$
declare v_k colegios; v_d jsonb; v_e estudiantes; v_g grupos; v_n int := 0;
begin
  if not priv.es_rector(p_colegio) then raise exception 'Solo el rector o la rectora pueden cerrar el año'; end if;
  select * into v_k from colegios where id = p_colegio for update;
  for v_d in select * from jsonb_array_elements(p_decisiones) loop
    select * into v_e from estudiantes where id = (v_d->>'estudiante_id')::uuid and colegio_id = p_colegio and estado = 'Activo';
    if v_e.id is null then continue; end if;
    if v_d->>'resultado' not in ('Promovido','No promovido','Graduado') then raise exception 'Resultado inválido'; end if;
    select * into v_g from grupos where id = v_e.grupo_id;
    insert into historial (colegio_id, estudiante_id, anio, grupo_nombre, grado, nivel, resultado, fecha_matricula)
      values (p_colegio, v_e.id, v_k.anio, v_g.nombre, v_g.grado, v_g.nivel, v_d->>'resultado', v_e.fecha_matricula)
      on conflict (estudiante_id, anio) do update set resultado = excluded.resultado, grupo_nombre = excluded.grupo_nombre,
        grado = excluded.grado, nivel = excluded.nivel, fecha_matricula = excluded.fecha_matricula;
    if v_d->>'resultado' = 'Graduado' then
      update estudiantes set estado = 'Graduado' where id = v_e.id;
    else
      if nullif(v_d->>'grupo_destino', '') is not null
         and not exists (select 1 from grupos x where x.id = (v_d->>'grupo_destino')::uuid and x.colegio_id = p_colegio) then
        raise exception 'Grupo de destino inválido';
      end if;
      update estudiantes set
        grupo_id = coalesce(nullif(v_d->>'grupo_destino', '')::uuid, grupo_id),
        situacion = case when v_d->>'resultado' = 'No promovido' then 'Repitente' else 'Promovido' end,
        fecha_matricula = make_date(v_k.anio + 1, 1, 1)
      where id = v_e.id;
    end if;
    v_n := v_n + 1;
  end loop;
  insert into historial (colegio_id, estudiante_id, anio, grupo_nombre, grado, nivel, resultado, fecha_matricula, fecha_retiro)
    select p_colegio, s.id, v_k.anio, gg.nombre, gg.grado, gg.nivel, 'Retirado', s.fecha_matricula, s.fecha_retiro
    from estudiantes s left join grupos gg on gg.id = s.grupo_id
    where s.colegio_id = p_colegio and s.estado = 'Retirado'
      and (s.fecha_retiro is null or extract(year from s.fecha_retiro) = v_k.anio)
    on conflict do nothing;
  insert into anios_cerrados (colegio_id, anio, periodos, escala, max_perdidas)
    values (p_colegio, v_k.anio, v_k.periodos, v_k.escala, v_k.max_perdidas)
    on conflict (colegio_id, anio) do update set periodos = excluded.periodos, escala = excluded.escala, max_perdidas = excluded.max_perdidas;
  perform set_config('micolegia.sistema', 'on', true);
  -- las fechas de los periodos pasan al año nuevo (antes quedaban en el año anterior y los docentes no podían calificar)
  update colegios set anio = v_k.anio + 1, periodo_actual = 1,
    periodos = coalesce((select jsonb_agg(p || jsonb_strip_nulls(jsonb_build_object(
        'inicio', case when coalesce(p->>'inicio', '') <> '' then to_char((p->>'inicio')::date + interval '1 year', 'YYYY-MM-DD') end,
        'fin', case when coalesce(p->>'fin', '') <> '' then to_char((p->>'fin')::date + interval '1 year', 'YYYY-MM-DD') end,
        'cierre', case when coalesce(p->>'cierre', '') <> '' then to_char((p->>'cierre')::date + interval '1 year', 'YYYY-MM-DD') end))
        order by (p->>'n')::int) from jsonb_array_elements(v_k.periodos) p), v_k.periodos)
  where id = p_colegio;
  perform set_config('micolegia.sistema', '', true);
  insert into conceptos (colegio_id, anio, nombre, tipo, periodicidad, valor, valores_grado, mes_cobro, meses, orden, activo)
    select c.colegio_id, c.anio + 1, c.nombre, c.tipo, c.periodicidad, c.valor, c.valores_grado, c.mes_cobro, c.meses, c.orden, c.activo
    from conceptos c where c.colegio_id = p_colegio and c.anio = v_k.anio
      and not exists (select 1 from conceptos c2 where c2.colegio_id = p_colegio and c2.anio = v_k.anio + 1);
  return json_build_object('procesados', v_n, 'nuevo_anio', v_k.anio + 1);
end $function$;
revoke execute on function public.cerrar_anio(uuid, jsonb) from anonymous;

revoke execute on function public.estado_cuenta(uuid, integer) from anonymous;
revoke execute on function public.cartera(uuid, integer) from anonymous;
notify pgrst, 'reload schema';

