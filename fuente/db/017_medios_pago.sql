-- Genesis-IA 017: cada colegio elige cómo le pagan las familias (efectivo, llave, Bold).
alter table public.colegios add column if not exists pago_efectivo boolean not null default true;
alter table public.colegios add column if not exists pago_efectivo_texto text;
alter table public.colegios add column if not exists pago_llave boolean not null default false;
alter table public.colegios add column if not exists pago_llave_valor text;
alter table public.colegios add column if not exists pago_llave_titular text;
alter table public.colegios add column if not exists pago_bold boolean not null default false;
alter table public.colegios add column if not exists pago_bold_url text;
notify pgrst, 'reload schema';
grant update (pago_efectivo, pago_efectivo_texto, pago_llave, pago_llave_valor, pago_llave_titular, pago_bold, pago_bold_url, restringir_morosos) on public.colegios to authenticated;
notify pgrst, 'reload schema';
