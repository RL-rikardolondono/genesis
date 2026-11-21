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
- Publicada: versión 0.32.0 (5.ª vuelta de la Prueba Ácida, 20 nov 2026: una sola regla de «debe a la fecha» para el paz y salvo, también después del cierre de año y para graduados con deuda; la cuota inicial del acuerdo solo con pagos posteriores; actas de comisión sin casos ya no dejan la pantalla en blanco; asistencia sin fechas futuras; aviso antes de registrar un pago cuando hay deuda anterior; carga grande muestra su resultado). Antes: 0.31.0 (4.ª vuelta de la Prueba Ácida, 20 nov 2026: paz y salvo solo sin deuda, también en el servidor y sin documento sin código; con deuda de años anteriores el pago se aplica primero a lo más antiguo; la cuota inicial del acuerdo se cuenta solo con pagos posteriores; graduados sin cobros del año siguiente; al cambiar de año se cierra la matrícula en línea; una sola regla de «vencido a hoy» en todas las pantallas; botón «Volver al estado de cuenta»; textos y avisos).
- SQL aplicados en Neon: 001 a 046 (y 027b, 032b). El 036 deja la función original de Bold como priv.bold_pago_base y bold_pago_aprobado como entrada que reparte (pagos normales → la original; empresa terminada en __s<plan> → ampliación de plan); el respaldo de la original está en db/015b_bold_produccion.sql. Nota: priv.cuenta_base, priv.demo_contrato y priv.demo_cumple no deben quedar ejecutables por authenticated; si un SQL nuevo hace "grant execute on all functions in schema priv to authenticated", repetir al final el revoke de esas dos funciones.
- Correo diario a los colegios en prueba gratis: GitHub Actions (.github/workflows/correos-prueba.yml, 7:05 a. m. de Colombia) ejecuta fuente/correos/pruebas.mjs con los secretos NEON_CLAVE (contraseña del usuario limitado correo_pruebas de la base; se cambia en Neon › Roles) y BREVO_API_KEY; remitente opcional en la variable BREVO_REMITENTE (por defecto contacto@skynetgenesis.com). Los nombres internos (proyecto Neon "genesis", planes "genesis:" del firmador Bold, repositorio genesis) no cambiaron. Lo de Bold (`plataforma_bold`, `bold_pago_aprobado`, usuario `bold_pagos`) se hizo en la conversación "Pagos automáticos Bold" y no está en `db/`.
- Para publicar: `cd web && npm install && node build.mjs`. Eso genera `../docs/`, y los tres archivos de esa carpeta se suben a la raíz del repositorio.
- No borrar `pagarBoldSusc()` ni volver al enlace fijo `bold_url`. La suscripción de los colegios se paga solo con Bold automático.
