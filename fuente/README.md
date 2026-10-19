# Colegio-IA (antes Genesis-IA)

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
- Publicada: versión 0.13.0 (pagos de las familias con el Bold propio de cada colegio: el rector conecta la llave de identidad y la llave secreta, la base de datos calcula el valor y firma la orden, y la app de tesorería/secretaría/rectoría consulta a Bold y registra sola los pagos aprobados con su recibo; antes 0.12.0 revisión del 18 oct 2026, entrega 3: registro del colegio por su cuenta con 15 días de prueba gratis (una vez por correo; al terminar se cierra si no paga; el primer pago Bold cubre el mes en que termina la prueba), planes y precios, invitación a contratar en la demostración y al salir de ella, panel del Superadministrador con los colegios registrados; antes 0.11.0 entrega 2: campus virtual por curso y asignatura con unidades, recursos, videos, clases en vivo, tareas y cuestionarios que califica la base de datos y pasan a Calificaciones; perfil Estudiante, bloqueado por completo con pagos pendientes; gemas con rangos y top del curso; Parametrización › Campus y gemas; antes 0.10.0 entrega 1: menú por secciones, escala 0-100, actividades sin porcentajes, docentes sin documentos, familias con pagos pendientes limitadas, plan de estudios por grado, citas con horario de atención, contactos con historial, demostración completa; antes 0.9.5 etapa 3: tienda del colegio con pedidos, lista de útiles por grado, gráficos que cruzan variables; antes 2B: avisos, Hoy, mensajes, autorizaciones, citas; cierre por pago el día 5), con el botón de pago Bold `pagarBoldSusc()` incluido.
- SQL aplicados en Neon: 001 a 025. Los nombres internos (proyecto Neon "genesis", planes "genesis:" del firmador Bold, repositorio genesis) no cambiaron. Lo de Bold (`plataforma_bold`, `bold_pago_aprobado`, usuario `bold_pagos`) se hizo en la conversación "Pagos automáticos Bold" y no está en `db/`.
- Para publicar: `cd web && npm install && node build.mjs`. Eso genera `../docs/`, y los tres archivos de esa carpeta se suben a la raíz del repositorio.
- No borrar `pagarBoldSusc()` ni volver al enlace fijo `bold_url`. La suscripción de los colegios se paga solo con Bold automático.
