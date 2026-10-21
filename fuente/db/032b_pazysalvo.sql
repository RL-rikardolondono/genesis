-- Colegio-IA 032b (21 oct 2026): el paz y salvo pagado solo se pide estando al día (lo revisa la base, no solo la pantalla)
begin;
do $$
declare d text;
begin
  d := pg_get_functiondef('public.pedir_documento(uuid,text,integer,integer,text)'::regprocedure);
  if position('saldo vencido' in d) = 0 then
    d := replace(d, $q$  if p_tipo = 'retiro' and s.estado = 'Activo' then$q$,
      $q$  if p_tipo = 'pazysalvo' and exists (select 1 from estado_cuenta(p_est, k.anio) e where e.vencido and e.saldo > 0) then
    raise exception 'Tiene saldo vencido. El paz y salvo se expide cuando esté al día (vea Estado de cuenta)';
  end if;
  if p_tipo = 'retiro' and s.estado = 'Activo' then$q$);
    if position('saldo vencido' in d) = 0 then raise exception 'No se encontró dónde agregar la revisión del paz y salvo'; end if;
    execute d;
  end if;
end $$;
commit;
notify pgrst, 'reload schema';
