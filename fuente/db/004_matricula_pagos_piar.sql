-- =====================================================================
-- Genesis · 004: matrícula completa (SIMAT), acudientes, logo, notas por año,
-- costos por año, pagos con autor, PIAR, historial y cierre de año, perfil Tesorería
-- (idempotente: se puede ejecutar más de una vez)
-- =====================================================================

-- ---------- Perfil Tesorería ----------
alter table public.miembros drop constraint if exists miembros_rol_check;
alter table public.miembros add constraint miembros_rol_check
  check (rol in ('rector','coordinador','secretaria','tesoreria','docente','acudiente','estudiante'));

create or replace function priv.maneja_pagos(c uuid) returns boolean
language sql stable as $$ select priv.roles_en(c) && array['rector','secretaria','tesoreria'] $$;
grant execute on function priv.maneja_pagos(uuid) to authenticated;

-- ---------- Colegio: logo ----------
alter table public.colegios add column if not exists logo text;
alter table public.colegios drop constraint if exists colegios_logo_tam;
alter table public.colegios add constraint colegios_logo_tam check (logo is null or length(logo) < 400000);
grant update (logo) on public.colegios to authenticated;

-- ---------- Estudiante: datos de matrícula (SIMAT) ----------
alter table public.estudiantes
  add column if not exists sexo text,
  add column if not exists lugar_nacimiento text,
  add column if not exists lugar_expedicion text,
  add column if not exists rh text,
  add column if not exists eps text,
  add column if not exists sisben text,
  add column if not exists estrato text,
  add column if not exists direccion text,
  add column if not exists barrio text,
  add column if not exists municipio text,
  add column if not exists zona text,
  add column if not exists telefono text,
  add column if not exists email text,
  add column if not exists etnia text,
  add column if not exists discapacidad text,
  add column if not exists capacidades_excepcionales text,
  add column if not exists victima_conflicto boolean not null default false,
  add column if not exists pais_origen text default 'Colombia',
  add column if not exists institucion_procedencia text,
  add column if not exists jornada text default 'Mañana',
  add column if not exists situacion text default 'Nuevo',
  add column if not exists condicion_especial text,
  add column if not exists recomendaciones_medicas text,
  add column if not exists fecha_matricula date default current_date,
  add column if not exists fecha_retiro date,
  add column if not exists motivo_retiro text;
alter table public.estudiantes drop constraint if exists estudiantes_estado_check;
alter table public.estudiantes add constraint estudiantes_estado_check check (estado in ('Activo','Retirado','Graduado'));
update public.estudiantes set fecha_matricula = coalesce(fecha_matricula, creado_en::date);

-- Tesorería necesita ver la lista de estudiantes (no sus notas)
drop policy if exists est_ver on public.estudiantes;
create policy est_ver on public.estudiantes for select to authenticated
  using (priv.es_directivo(colegio_id) or priv.maneja_pagos(colegio_id)
         or priv.docente_de_grupo(grupo_id) or priv.es_familia_de(id));

-- ---------- Acudientes (dos o más por estudiante) ----------
create table if not exists public.acudientes (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  orden int not null default 1,
  parentesco text,
  nombres text not null,
  tipo_doc text default 'CC',
  doc text,
  telefono text,
  email text,
  direccion text,
  ocupacion text,
  responsable_pago boolean not null default false
);
create index if not exists acud_est on public.acudientes (estudiante_id);

-- ---------- Notas y observaciones por año lectivo ----------
alter table public.notas add column if not exists anio int;
update public.notas n set anio = k.anio from public.colegios k where k.id = n.colegio_id and n.anio is null;
alter table public.notas alter column anio set not null;
alter table public.notas drop constraint if exists notas_pkey;
alter table public.notas add primary key (estudiante_id, asignatura_id, anio, periodo);

alter table public.observaciones add column if not exists anio int;
update public.observaciones o set anio = k.anio from public.colegios k where k.id = o.colegio_id and o.anio is null;
alter table public.observaciones alter column anio set not null;
alter table public.observaciones drop constraint if exists observaciones_pkey;
alter table public.observaciones add primary key (estudiante_id, anio, periodo);

create or replace function priv.tg_hijo_de_estudiante() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  select colegio_id into new.colegio_id from estudiantes where id = new.estudiante_id;
  if new.colegio_id is null then raise exception 'Estudiante no encontrado'; end if;
  if tg_table_name = 'notas' then
    if not exists (select 1 from asignaturas a where a.id = new.asignatura_id and a.colegio_id = new.colegio_id) then
      raise exception 'La asignatura no pertenece al colegio del estudiante';
    end if;
  end if;
  if tg_table_name in ('notas','observaciones','piar') and new.anio is null then
    select anio into new.anio from colegios where id = new.colegio_id;
  end if;
  if tg_table_name in ('notas','asistencia','observaciones','piar') and priv.es_cliente() then
    new.actualizado_por := priv.uid();
  end if;
  if tg_table_name in ('notas','piar') then new.actualizado_en := now(); end if;
  return new;
end $$;

-- acudientes usan el mismo disparador de colegio (sin columnas de auditoría)
create or replace function priv.tg_colegio_de_estudiante() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  select colegio_id into new.colegio_id from estudiantes where id = new.estudiante_id;
  if new.colegio_id is null then raise exception 'Estudiante no encontrado'; end if;
  return new;
end $$;
drop trigger if exists tg_acudientes on public.acudientes;
create trigger tg_acudientes before insert or update on public.acudientes for each row execute function priv.tg_colegio_de_estudiante();

-- ---------- PIAR ----------
create table if not exists public.piar (
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  anio int not null,
  datos jsonb not null default '{}',
  actualizado_por text,
  actualizado_en timestamptz not null default now(),
  primary key (estudiante_id, anio)
);
drop trigger if exists tg_piar on public.piar;
create trigger tg_piar before insert or update on public.piar for each row execute function priv.tg_hijo_de_estudiante();

-- ---------- Historial académico (cierre de año) ----------
create table if not exists public.historial (
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  anio int not null,
  grupo_nombre text,
  grado int,
  nivel text,
  resultado text not null check (resultado in ('Promovido','No promovido','Graduado','Retirado')),
  registrado_en timestamptz not null default now(),
  primary key (estudiante_id, anio)
);

-- ---------- Costos por año ----------
create table if not exists public.costos_anio (
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  anio int not null,
  resolucion text,
  fecha_resolucion date,
  entidad text default 'Secretaría de Educación',
  observaciones text,
  primary key (colegio_id, anio)
);

create table if not exists public.conceptos (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  anio int not null,
  nombre text not null,
  tipo text not null default 'otro' check (tipo in ('matricula','pension','seguro','carnet','otro')),
  periodicidad text not null default 'unico' check (periodicidad in ('unico','mensual')),
  valor numeric(12,0) not null default 0 check (valor >= 0),
  valores_grado jsonb not null default '{}',   -- {"3": 250000, "11": 300000}: valor distinto por grado
  mes_cobro int not null default 2 check (mes_cobro between 1 and 12),
  meses int[] not null default '{2,3,4,5,6,7,8,9,10,11}',
  orden int not null default 0,
  activo boolean not null default true
);
create index if not exists conc_col on public.conceptos (colegio_id, anio);

-- ---------- Pagos (con autor) ----------
create table if not exists public.pagos (
  id uuid primary key default gen_random_uuid(),
  colegio_id uuid not null references public.colegios(id) on delete cascade,
  estudiante_id uuid not null references public.estudiantes(id) on delete cascade,
  concepto_id uuid references public.conceptos(id) on delete set null,
  anio int not null,
  mes int check (mes between 1 and 12),
  valor numeric(12,0) not null check (valor > 0),
  fecha date not null default current_date,
  medio text default 'Efectivo',
  referencia text,
  observacion text,
  recibo int,
  registrado_por text,
  registrado_nombre text,
  registrado_en timestamptz not null default now(),
  anulado boolean not null default false,
  anulado_por text,
  anulado_motivo text
);
create index if not exists pagos_est on public.pagos (estudiante_id, anio);

create or replace function priv.tg_pagos() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare motivo text;
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
    select coalesce(max(recibo), 0) + 1 into new.recibo from pagos where colegio_id = new.colegio_id;
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
drop trigger if exists tg_pagos on public.pagos;
create trigger tg_pagos before insert or update on public.pagos for each row execute function priv.tg_pagos();

-- colegio fijo en conceptos / costos
drop trigger if exists tg_conc_fijo on public.conceptos;
create trigger tg_conc_fijo before update on public.conceptos for each row execute function priv.tg_colegio_fijo();

-- ---------- Permisos y RLS de las tablas nuevas ----------
grant select, insert, update, delete on public.acudientes, public.piar, public.costos_anio, public.conceptos to authenticated;
grant select, insert, update on public.pagos to authenticated;
revoke delete on public.pagos from authenticated;
grant select on public.historial to authenticated;
revoke insert, update, delete on public.historial from authenticated;

alter table public.acudientes  enable row level security;
alter table public.piar        enable row level security;
alter table public.historial   enable row level security;
alter table public.costos_anio enable row level security;
alter table public.conceptos   enable row level security;
alter table public.pagos       enable row level security;

drop policy if exists acud_ver on public.acudientes;
create policy acud_ver on public.acudientes for select to authenticated
  using (priv.puede_ver_estudiante(estudiante_id) or priv.maneja_pagos(colegio_id));
drop policy if exists acud_admin on public.acudientes;
create policy acud_admin on public.acudientes for all to authenticated
  using (priv.es_directivo(colegio_id)) with check (priv.es_directivo(colegio_id));

drop policy if exists piar_ver on public.piar;
create policy piar_ver on public.piar for select to authenticated using (priv.puede_ver_estudiante(estudiante_id));
drop policy if exists piar_escribir on public.piar;
create policy piar_escribir on public.piar for all to authenticated
  using (priv.puede_calificar(estudiante_id)) with check (priv.puede_calificar(estudiante_id));

drop policy if exists hist_ver on public.historial;
create policy hist_ver on public.historial for select to authenticated using (priv.puede_ver_estudiante(estudiante_id));

drop policy if exists costos_ver on public.costos_anio;
create policy costos_ver on public.costos_anio for select to authenticated using (priv.es_miembro(colegio_id));
drop policy if exists costos_admin on public.costos_anio;
create policy costos_admin on public.costos_anio for all to authenticated
  using (priv.es_rector(colegio_id) or 'tesoreria' = any(priv.roles_en(colegio_id)) or 'secretaria' = any(priv.roles_en(colegio_id)))
  with check (priv.es_rector(colegio_id) or 'tesoreria' = any(priv.roles_en(colegio_id)) or 'secretaria' = any(priv.roles_en(colegio_id)));

drop policy if exists conc_ver on public.conceptos;
create policy conc_ver on public.conceptos for select to authenticated using (priv.es_miembro(colegio_id));
drop policy if exists conc_admin on public.conceptos;
create policy conc_admin on public.conceptos for all to authenticated
  using (priv.maneja_pagos(colegio_id)) with check (priv.maneja_pagos(colegio_id));

drop policy if exists pagos_ver on public.pagos;
create policy pagos_ver on public.pagos for select to authenticated
  using (priv.maneja_pagos(colegio_id) or priv.es_familia_de(estudiante_id));
drop policy if exists pagos_ins on public.pagos;
create policy pagos_ins on public.pagos for insert to authenticated with check (priv.maneja_pagos(colegio_id));
drop policy if exists pagos_anular on public.pagos;
create policy pagos_anular on public.pagos for update to authenticated
  using (priv.maneja_pagos(colegio_id)) with check (priv.maneja_pagos(colegio_id));

-- ---------- Estado de cuenta ----------
-- Cobros de un estudiante en un año: cuotas desde el mes de matrícula hasta el retiro
create or replace function public.estado_cuenta(p_estudiante uuid, p_anio int)
returns table (concepto_id uuid, concepto text, tipo text, mes int, valor numeric, pagado numeric, saldo numeric, vencido boolean)
language sql stable set search_path = public, pg_temp as $$
  with s as (
    select e.*, g.grado from estudiantes e left join grupos g on g.id = e.grupo_id where e.id = p_estudiante
  ),
  cobros as (
    select c.id, c.nombre, c.tipo, c.orden, m.mes,
           coalesce((c.valores_grado ->> (s.grado)::text)::numeric, c.valor) as valor
    from s
    join conceptos c on c.colegio_id = s.colegio_id and c.anio = p_anio and c.activo
    cross join lateral (
      select unnest(case when c.periodicidad = 'mensual' then c.meses else array[c.mes_cobro] end) as mes
    ) m
    where
      -- matriculado a más tardar ese mes (los cobros únicos se cobran siempre en el año de matrícula)
      (c.periodicidad = 'unico' or s.fecha_matricula is null
        or s.fecha_matricula < (make_date(p_anio, m.mes, 1) + interval '1 month'))
      -- retirado: no se cobra desde el mes siguiente al retiro
      and (s.fecha_retiro is null or make_date(p_anio, m.mes, 1) <= s.fecha_retiro)
  ),
  pag as (
    select p.concepto_id, p.mes, sum(p.valor) as pagado
    from pagos p where p.estudiante_id = p_estudiante and p.anio = p_anio and not p.anulado
    group by 1, 2
  )
  select c.id, c.nombre, c.tipo, c.mes, c.valor,
         coalesce(pg.pagado, 0), greatest(c.valor - coalesce(pg.pagado, 0), 0),
         make_date(p_anio, c.mes, 1) <= current_date
  from cobros c
  left join pag pg on pg.concepto_id = c.id and pg.mes is not distinct from c.mes
  where c.valor > 0
  order by c.mes, c.orden, c.nombre
$$;

-- Cartera del colegio: saldo vencido y total por estudiante activo o retirado
create or replace function public.cartera(p_colegio uuid, p_anio int)
returns table (estudiante_id uuid, nombre text, grupo text, estado text, cobrado numeric, pagado numeric, saldo_vencido numeric, saldo_total numeric)
language plpgsql stable set search_path = public, pg_temp as $$
begin
  if not priv.maneja_pagos(p_colegio) then raise exception 'Sin permiso'; end if;
  return query
    select e.id, e.apellidos || ' ' || e.nombres, g.nombre, e.estado,
           coalesce(sum(x.valor), 0), coalesce(sum(x.pagado), 0),
           coalesce(sum(x.saldo) filter (where x.vencido), 0), coalesce(sum(x.saldo), 0)
    from estudiantes e
    left join grupos g on g.id = e.grupo_id
    left join lateral estado_cuenta(e.id, p_anio) x on true
    where e.colegio_id = p_colegio and e.estado <> 'Graduado'
    group by e.id, e.apellidos, e.nombres, g.nombre, e.estado
    order by g.nombre nulls last, e.apellidos;
end $$;

-- ---------- Cierre de año y promoción ----------
-- p_decisiones: [{"estudiante_id": "...", "resultado": "Promovido|No promovido|Graduado", "grupo_destino": "uuid|null"}]
create or replace function public.cerrar_anio(p_colegio uuid, p_decisiones jsonb) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_k colegios; v_d jsonb; v_e estudiantes; v_g grupos; v_n int := 0;
begin
  if not priv.es_rector(p_colegio) then raise exception 'Solo el rector o la rectora pueden cerrar el año'; end if;
  select * into v_k from colegios where id = p_colegio for update;
  for v_d in select * from jsonb_array_elements(p_decisiones) loop
    select * into v_e from estudiantes where id = (v_d->>'estudiante_id')::uuid and colegio_id = p_colegio and estado = 'Activo';
    if v_e.id is null then continue; end if;
    if v_d->>'resultado' not in ('Promovido','No promovido','Graduado') then raise exception 'Resultado inválido'; end if;
    select * into v_g from grupos where id = v_e.grupo_id;
    insert into historial (colegio_id, estudiante_id, anio, grupo_nombre, grado, nivel, resultado)
      values (p_colegio, v_e.id, v_k.anio, v_g.nombre, v_g.grado, v_g.nivel, v_d->>'resultado')
      on conflict (estudiante_id, anio) do update set resultado = excluded.resultado, grupo_nombre = excluded.grupo_nombre,
        grado = excluded.grado, nivel = excluded.nivel;
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
  insert into historial (colegio_id, estudiante_id, anio, grupo_nombre, grado, nivel, resultado)
    select p_colegio, s.id, v_k.anio, gg.nombre, gg.grado, gg.nivel, 'Retirado'
    from estudiantes s left join grupos gg on gg.id = s.grupo_id
    where s.colegio_id = p_colegio and s.estado = 'Retirado'
      and (s.fecha_retiro is null or extract(year from s.fecha_retiro) = v_k.anio)
    on conflict do nothing;
  perform set_config('micolegia.sistema', 'on', true);
  update colegios set anio = v_k.anio + 1, periodo_actual = 1 where id = p_colegio;
  perform set_config('micolegia.sistema', '', true);
  insert into conceptos (colegio_id, anio, nombre, tipo, periodicidad, valor, valores_grado, mes_cobro, meses, orden, activo)
    select c.colegio_id, c.anio + 1, c.nombre, c.tipo, c.periodicidad, c.valor, c.valores_grado, c.mes_cobro, c.meses, c.orden, c.activo
    from conceptos c where c.colegio_id = p_colegio and c.anio = v_k.anio
      and not exists (select 1 from conceptos c2 where c2.colegio_id = p_colegio and c2.anio = v_k.anio + 1);
  return json_build_object('procesados', v_n, 'nuevo_anio', v_k.anio + 1);
end $$;

-- ---------- Resumen del inicio: usa el año lectivo ----------
create or replace function public.definitivas(p_colegio uuid, p_hasta int default 99)
returns table (estudiante_id uuid, asignatura_id uuid, definitiva numeric)
language sql stable as $$
  select n.estudiante_id, n.asignatura_id, round(sum(n.valor * p.peso) / nullif(sum(p.peso), 0), 1)
  from notas n join colegios k on k.id = n.colegio_id
  cross join lateral jsonb_to_recordset(k.periodos) as p(n int, peso numeric)
  where n.colegio_id = p_colegio and n.anio = k.anio and p.n = n.periodo and n.periodo <= p_hasta
  group by 1, 2
$$;

create or replace function public.resumen_colegio(p_colegio uuid) returns json
language plpgsql stable set search_path = public, pg_temp as $$
declare k colegios; bajo_hasta numeric; r json;
begin
  select * into k from colegios where id = p_colegio;
  if k.id is null or not (priv.es_directivo(p_colegio) or priv.maneja_pagos(p_colegio)) then raise exception 'Sin permiso'; end if;
  select min((e->>'min')::numeric) into bajo_hasta from jsonb_array_elements(k.escala) e where e->>'d' <> 'Bajo';
  with act as (select s.* from estudiantes s where s.colegio_id = p_colegio and s.estado = 'Activo'),
  gr as (select g.* from grupos g where g.colegio_id = p_colegio),
  esperadas as (select count(*) n from act join gr on gr.id = act.grupo_id join asignaturas a on a.colegio_id = p_colegio and a.nivel = gr.nivel),
  registradas as (select count(*) n from notas x join act on act.id = x.estudiante_id where x.periodo = k.periodo_actual and x.anio = k.anio),
  defs as (select d.* from definitivas(p_colegio) d join act on act.id = d.estudiante_id join gr on gr.id = act.grupo_id where gr.nivel <> 'preescolar'),
  riesgo as (select act.id, act.nombres || ' ' || act.apellidos as nombre, gr.nombre as grupo, array_agg(a.nombre order by a.orden) as asignaturas
    from defs d join act on act.id = d.estudiante_id join gr on gr.id = act.grupo_id join asignaturas a on a.id = d.asignatura_id
    where d.definitiva < bajo_hasta group by act.id, act.nombres, act.apellidos, gr.nombre having count(*) >= k.max_perdidas)
  select json_build_object('activos', (select count(*) from act), 'grupos', (select count(*) from gr),
    'piar', (select count(*) from act where piar), 'esperadas', (select n from esperadas), 'registradas', (select n from registradas),
    'valor_mensual', precio_plan((select count(*)::int from act)),
    'riesgo', coalesce((select json_agg(riesgo order by grupo, nombre) from riesgo), '[]'::json)) into r;
  return r;
end $$;

-- ---------- Conceptos base al crear un colegio ----------
create or replace function priv.conceptos_base(c uuid, a int) returns void
language sql as $$
  insert into conceptos (colegio_id, anio, nombre, tipo, periodicidad, valor, mes_cobro, meses, orden)
  select c, a, x.nombre, x.tipo, x.per, 0, 2, '{2,3,4,5,6,7,8,9,10,11}', x.orden from (values
    ('Matrícula','matricula','unico',1),('Pensión','pension','mensual',2),
    ('Seguro estudiantil','seguro','unico',3),('Carné','carnet','unico',4)) as x(nombre, tipo, per, orden)
  where not exists (select 1 from conceptos where colegio_id = c and anio = a)
$$;
select priv.conceptos_base(id, anio) from public.colegios;

create or replace function public.crear_colegio(p_nombre text, p_ciudad text, p_rector_nombre text, p_rector_email text) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare c uuid; m miembros; a int;
begin
  if not priv.es_superadmin() then raise exception 'Solo la administración de Genesis puede crear colegios'; end if;
  insert into colegios (nombre, ciudad, rector_nombre) values (btrim(p_nombre), p_ciudad, p_rector_nombre) returning id, anio into c, a;
  perform priv.plan_base(c);
  perform priv.conceptos_base(c, a);
  insert into miembros (colegio_id, email, nombre, rol) values (c, p_rector_email, p_rector_nombre, 'rector') returning * into m;
  return json_build_object('colegio_id', c, 'codigo', m.codigo);
end $$;

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
