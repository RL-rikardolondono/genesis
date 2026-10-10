-- Corrección: la regla de lectura de estudiantes no debe consultar la propia tabla
-- (en INSERT ... RETURNING la fila nueva aún no es visible para esa consulta).
create or replace function priv.es_familia_de(e uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from miembros m join colegios k on k.id = m.colegio_id
    where m.estudiante_id = e and m.user_id = priv.uid() and m.activo and k.activo)
$$;
grant execute on function priv.es_familia_de(uuid) to authenticated;
drop policy if exists est_ver on public.estudiantes;
create policy est_ver on public.estudiantes for select to authenticated
  using (priv.es_directivo(colegio_id) or priv.docente_de_grupo(grupo_id) or priv.es_familia_de(id));
