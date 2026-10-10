-- Genesis 005: día límite de pago, un recibo por pago (lote) y cobros ocasionales según fecha de matrícula

-- 1) Día límite de pago de cada mes
alter table public.colegios add column if not exists dia_limite_pago int not null default 5;
alter table public.colegios drop constraint if exists colegios_dia_limite_chk;
alter table public.colegios add constraint colegios_dia_limite_chk check (dia_limite_pago between 1 and 28);
grant update (dia_limite_pago) on public.colegios to authenticated;

-- 2) Varios conceptos pagados juntos comparten un mismo recibo
alter table public.pagos add column if not exists lote uuid;
create index if not exists pagos_recibo on public.pagos (colegio_id, recibo);

create or replace function priv.tg_pagos() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare motivo text; r int;
begin
  if tg_op = 'INSERT' then
    select colegio_id into new.colegio_id from estudiantes where id = new.estudiante_id;
    if new.colegio_id is null then raise exception 'Estudiante no encontrado'; end if;
    if new.concepto_id is not null and not exists (select 1 from conceptos c where c.id = new.concepto_id and c.colegio_id = new.colegio_id) then
      raise exception 'El concepto no pertenece al colegio';
    end if;
    new.registrado_por := priv.uid();
    select coalesce(max(m.nombre), 'Sistema') into new.registrado_nombre
      from miembros m where m.colegio_id = new.colegio_id and m.user_id = priv.uid();
    perform pg_advisory_xact_lock(hashtext('recibo' || new.colegio_id::text));
    r := null;
    if new.lote is not null then
      select p.recibo into r from pagos p
       where p.colegio_id = new.colegio_id and p.lote = new.lote and p.estudiante_id = new.estudiante_id limit 1;
    end if;
    if r is null then
      select coalesce(max(recibo), 0) + 1 into r from pagos where colegio_id = new.colegio_id;
    end if;
    new.recibo := r;
    new.anulado := false; new.anulado_por := null; new.anulado_motivo := null;
    return new;
  end if;
  if old.anulado then raise exception 'El pago ya está anulado'; end if;
  if not new.anulado then raise exception 'Los pagos no se modifican; anúlelo y regístrelo de nuevo'; end if;
  motivo := new.anulado_motivo;
  new := old;
  new.anulado := true;
  new.anulado_motivo := motivo;
  new.anulado_por := (select coalesce(max(m.nombre), 'Sistema') from miembros m where m.colegio_id = old.colegio_id and m.user_id = priv.uid());
  return new;
end $$;

-- 3) Estado de cuenta:
--    - matrícula, seguro y carné se cobran siempre en el año de matrícula;
--    - pensiones y demás cobros, solo desde el mes en que el estudiante ya estaba matriculado;
--    - una cuota se vence después del día límite de su mes (o de la fecha de matrícula, si fue posterior).
create or replace function public.estado_cuenta(p_estudiante uuid, p_anio int)
returns table (concepto_id uuid, concepto text, tipo text, mes int, valor numeric, pagado numeric, saldo numeric, vencido boolean)
language sql stable set search_path = public, pg_temp as $$
  with s as (
    select e.*, g.grado, k.dia_limite_pago as dia
    from estudiantes e
    join colegios k on k.id = e.colegio_id
    left join grupos g on g.id = e.grupo_id
    where e.id = p_estudiante
  ),
  cobros as (
    select c.id, c.nombre, c.tipo, c.orden, m.mes, s.fecha_matricula, s.dia,
           coalesce((c.valores_grado ->> (s.grado)::text)::numeric, c.valor) as valor
    from s
    join conceptos c on c.colegio_id = s.colegio_id and c.anio = p_anio and c.activo
    cross join lateral (
      select unnest(case when c.periodicidad = 'mensual' then c.meses else array[c.mes_cobro] end) as mes
    ) m
    where
      ((c.periodicidad = 'unico' and c.tipo in ('matricula', 'seguro', 'carnet'))
        or s.fecha_matricula is null
        or s.fecha_matricula < (make_date(p_anio, m.mes, 1) + interval '1 month'))
      and (s.fecha_retiro is null or make_date(p_anio, m.mes, 1) <= s.fecha_retiro)
  ),
  pag as (
    select p.concepto_id, p.mes, sum(p.valor) as pagado
    from pagos p where p.estudiante_id = p_estudiante and p.anio = p_anio and not p.anulado
    group by 1, 2
  )
  select c.id, c.nombre, c.tipo, c.mes, c.valor,
         coalesce(pg.pagado, 0), greatest(c.valor - coalesce(pg.pagado, 0), 0),
         current_date > greatest(make_date(p_anio, c.mes, c.dia), coalesce(c.fecha_matricula, make_date(p_anio, c.mes, c.dia)))
  from cobros c
  left join pag pg on pg.concepto_id = c.id and pg.mes is not distinct from c.mes
  where c.valor > 0
  order by c.mes, c.orden, c.nombre
$$;
