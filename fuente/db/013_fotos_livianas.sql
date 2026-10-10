-- Genesis 013: fotos livianas y borrado automático de las fotos ya revisadas.
-- Al aprobar una excusa o confirmar un comprobante se borra la foto (quedan los datos: fechas, valor, referencia, quién revisó).
-- Las fotos de excusas o comprobantes rechazados se borran a los 30 días.

create or replace function priv.tg_excusas() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    select colegio_id into new.colegio_id from estudiantes where id = new.estudiante_id;
    new.enviada_por := (select coalesce(max(m.nombre), '') from miembros m where m.user_id = priv.uid() and m.estudiante_id = new.estudiante_id);
    new.estado := 'Pendiente'; new.revisada_por := null; new.respuesta := null;
    update excusas set soporte = null
     where colegio_id = new.colegio_id and estado = 'Rechazada' and soporte is not null and creado_en < now() - interval '30 days';
    return new;
  end if;
  if pg_trigger_depth() > 1 then  -- limpieza automática: solo se permite quitar la foto
    new := old; new.soporte := null; return new;
  end if;
  if not priv.puede_calificar(old.estudiante_id) then raise exception 'Sin permiso'; end if;
  new.colegio_id := old.colegio_id; new.estudiante_id := old.estudiante_id; new.desde := old.desde; new.hasta := old.hasta;
  new.motivo := old.motivo; new.enviada_por := old.enviada_por;
  if new.estado = 'Aprobada' then new.soporte := null; else new.soporte := old.soporte; end if;
  new.revisada_por := priv.nombre_actual(old.colegio_id);
  return new;
end $$;

create or replace function priv.tg_comprobantes() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    select colegio_id into new.colegio_id from estudiantes where id = new.estudiante_id;
    new.enviado_por := (select coalesce(max(m.nombre), '') from miembros m where m.user_id = priv.uid() and m.estudiante_id = new.estudiante_id);
    new.estado := 'Pendiente'; new.revisado_por := null; new.respuesta := null;
    update comprobantes set imagen = null
     where colegio_id = new.colegio_id and estado = 'Rechazado' and imagen is not null and creado_en < now() - interval '30 days';
    return new;
  end if;
  if pg_trigger_depth() > 1 then
    new := old; new.imagen := null; return new;
  end if;
  if not priv.maneja_pagos(old.colegio_id) then raise exception 'Sin permiso'; end if;
  new.colegio_id := old.colegio_id; new.estudiante_id := old.estudiante_id; new.valor := old.valor;
  new.fecha := old.fecha; new.medio := old.medio; new.referencia := old.referencia; new.enviado_por := old.enviado_por;
  if new.estado = 'Confirmado' then new.imagen := null; else new.imagen := old.imagen; end if;
  new.revisado_por := priv.nombre_actual(old.colegio_id);
  return new;
end $$;

-- Fotos nuevas: máximo ~180 KB (antes ~420 KB). Las ya guardadas no se validan.
alter table public.excusas drop constraint if exists excusas_soporte_liviana;
alter table public.excusas add constraint excusas_soporte_liviana check (soporte is null or length(soporte) < 250000) not valid;
alter table public.comprobantes drop constraint if exists comprobantes_imagen_liviana;
alter table public.comprobantes add constraint comprobantes_imagen_liviana check (imagen is null or length(imagen) < 250000) not valid;

-- Limpieza inicial de lo ya revisado
alter table public.excusas disable trigger user;
update public.excusas set soporte = null where soporte is not null
  and (estado = 'Aprobada' or (estado = 'Rechazada' and creado_en < now() - interval '30 days'));
alter table public.excusas enable trigger user;
alter table public.comprobantes disable trigger user;
update public.comprobantes set imagen = null where imagen is not null
  and (estado = 'Confirmado' or (estado = 'Rechazado' and creado_en < now() - interval '30 days'));
alter table public.comprobantes enable trigger user;

revoke execute on all functions in schema priv from public;
grant execute on all functions in schema priv to authenticated;
notify pgrst, 'reload schema';

select (select count(*) from excusas where soporte is not null) excusas_con_foto,
       (select count(*) from comprobantes where imagen is not null) comprobantes_con_foto,
       pg_size_pretty(pg_database_size(current_database())) tamano_bd;
