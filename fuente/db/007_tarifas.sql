-- Genesis 007: nuevas tarifas mensuales (octubre 2026)
create or replace function public.precio_plan(n int) returns int
language sql immutable as $$
  select case when n <= 100 then 120000 when n <= 250 then 220000
              when n <= 500 then 350000 when n <= 1000 then 550000
              else 550000 + ceil((n - 1000) / 100.0)::int * 40000 end
$$;
