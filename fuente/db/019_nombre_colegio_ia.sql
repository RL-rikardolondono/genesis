-- Colegio-IA 019: cambio de nombre de la app (antes Genesis-IA) en los textos de la base de datos.
-- Los nombres internos (proyecto Neon "genesis", planes "genesis:" del firmador Bold, repositorio) no cambian.
do $$
declare d text;
begin
  d := pg_get_functiondef('priv.crear_demo'::regproc);
  d := replace(d, $q$delete from colegios where nombre = 'Colegio Demostración Genesis';$q$,
                  $q$delete from colegios where demo or nombre = 'Colegio Demostración Genesis';$q$);
  d := replace(d, $q$values ('Colegio Demostración Genesis',$q$, $q$values ('Colegio de Demostración',$q$);
  execute d;
  d := pg_get_functiondef('public.crear_colegio'::regproc);
  execute replace(d, 'Solo la administración de Genesis puede crear colegios', 'Solo el Superadministrador de Colegio-IA puede crear colegios');
  d := pg_get_functiondef('priv.tg_bloqueo'::regproc);
  d := replace(d, 'la suscripción de Genesis tiene', 'la suscripción de Colegio-IA tiene');
  execute replace(d, 'la mensualidad de Genesis.', 'la mensualidad de Colegio-IA.');
end $$;
update public.colegios set nombre = 'Colegio de Demostración' where demo and nombre = 'Colegio Demostración Genesis';
notify pgrst, 'reload schema';
