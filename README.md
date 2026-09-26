# MiColegIA

Software de gestión escolar para colegios de Colombia (preescolar a media): boletines, calificaciones, asistencia, matrícula y accesos por perfil (rector, coordinación, secretaría, docente, acudiente y estudiante).

## Arquitectura (sin servidor propio)

- **Base de datos:** Neon Postgres. Cada fila pertenece a un colegio y la seguridad por fila (RLS) decide quién ve qué.
- **Inicio de sesión:** Neon Auth (correo y contraseña). El colegio entrega a cada usuario un código de activación personal.
- **API:** Neon Data API (REST sobre Postgres), llamada directamente desde la página.
- **Página:** estática, publicada con GitHub Pages desde la carpeta `docs/`.

## Carpetas

- `db/` scripts SQL del esquema (aplicar en el editor SQL de Neon, en orden).
- `web/` código fuente de la página. `npm install && node build.mjs` genera `docs/`.
- `docs/` versión publicada.
