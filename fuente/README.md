# Genesis

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

## Estado (10 de octubre de 2026)

- Esta carpeta `fuente/` es el respaldo del código fuente. Lo que se ve en https://genesis.skynetgenesis.com son los archivos compilados de la raíz del repositorio (`app.js`, `app.css`, `index.html`).
- Publicada: versión 0.8.5 + botón de pago Bold (`app.js?v=bold1`). Este código fuente ya es la 0.8.6, que incluye `pagarBoldSusc()` y aún no se ha publicado.
- SQL aplicados en Neon: 001 a 017. Lo de Bold (`plataforma_bold`, `bold_pago_aprobado`, usuario `bold_pagos`) se hizo en la conversación "Pagos automáticos Bold" y no está en `db/`.
- Para publicar: `cd web && npm install && node build.mjs`. Eso genera `../docs/`, y los tres archivos de esa carpeta se suben a la raíz del repositorio.
- No borrar `pagarBoldSusc()` ni volver al enlace fijo `bold_url`. La suscripción de los colegios se paga solo con Bold automático.
