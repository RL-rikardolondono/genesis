alter table public.colegios add column if not exists web text;
alter table public.colegios add column if not exists lema text;
grant update (web, lema) on public.colegios to authenticated;
