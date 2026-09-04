# Variables de entorno

Hay **cuatro orígenes distintos** de configuración en este sistema, y se
comportan de forma muy diferente. Confundirlos produce siempre el mismo síntoma:
*"cambié la variable, hice `apply`, y no pasó nada"*.

Este documento es el mapa. El detalle de cada servicio está en
[apps-y-servicios.md](apps-y-servicios.md); la vista de conjunto, en
[infraestructura.md](infraestructura.md).

---

## 1. Los cuatro orígenes

| Origen | Se fija en | Lo consume | Para cambiarlo |
|---|---|---|---|
| `terraform/secrets/postgres` | `terraform apply` | **Terraform**, no un servicio | Editar + `apply` |
| `terraform/secrets/backend` | `terraform apply` | Cloud Run del backend | Editar + `apply` |
| Valores derivados por Terraform | `terraform apply` | Cloud Run (backend, frontend, job) | Automático |
| `docker build --build-arg` | **Build de la imagen** | El bundle JS del navegador | Rebuild + push + `apply` |

Las tres primeras son variables de entorno de verdad: viven en el contenedor y
se cambian con un `apply`. **La cuarta no**: queda escrita dentro del JavaScript
y solo cambia reconstruyendo la imagen.

---

## 2. Frontend

El frontend es el caso confuso, porque su imagen final es `nginx:1.27-alpine`
sirviendo ficheros estáticos. **No hay ningún proceso de aplicación que lea
variables de entorno.** Lo que ocurre son dos cosas separadas.

### 2.1 En build: las `VITE_*` se incrustan en el bundle

Vite sustituye las variables con prefijo `VITE_` por su valor literal dentro del
JavaScript durante `pnpm build`. Después de eso están escritas en los `.js` de
`dist/` y no hay forma de cambiarlas sin reconstruir.

```
Makefile:47        DPP_BASE_URL ?= https://dpp.trustex.eu
Makefile:108       docker build --build-arg VITE_DPP_BASE_URL=$(DPP_BASE_URL)
Dockerfile:14-15   ARG VITE_DPP_BASE_URL → ENV VITE_DPP_BASE_URL
Dockerfile:17      RUN pnpm build        ← aquí queda incrustada
```

| Variable | Dónde se usa | Por defecto |
|---|---|---|
| `VITE_DPP_BASE_URL` | `frontend/src/lib/dpp-identifier.ts` | `https://dpp.trustex.eu` |

Es la única `VITE_*` del proyecto.

> **No la busques en Terraform.** `DPP_BASE_URL` en `trustex-web/Makefile` es su
> única fuente — ese repo es el que construye la imagen. Hubo una variable
> `frontend_dpp_base_url` en `terraform.tfvars` "para tener la configuración en un
> sitio", pero Terraform no podía actuar sobre ella —un `apply` tras cambiarla no
> producía ningún cambio— y lo único que conseguía era divergir del Makefile en
> silencio. Se eliminó.
>
> Para cambiarla, **desde `trustex-web`**:
>
> ```bash
> make build-frontend DPP_BASE_URL=https://dpp.otro-dominio.eu
> ```

### 2.2 En arranque del contenedor: `BACKEND_HOST`

La URL del Cloud Run del backend no se conoce cuando se construye la imagen, así
que se resuelve al arrancar. La imagen base de nginx ejecuta automáticamente
todo script ejecutable de `/docker-entrypoint.d/` antes de levantar nginx:

```
locals.tf          frontend_service_env = { BACKEND_HOST, ... }
   ↓  Cloud Run inyecta la variable en el contenedor
docker-entrypoint.d/40-render-nginx-conf.sh
   ↓  envsubst '${BACKEND_HOST}' < nginx.conf.template
/etc/nginx/conf.d/default.conf   →  proxy_pass https://<host-del-backend>
```

Es un **host pelado**, no una URL: `proxy_pass` pone el esquema por su cuenta y
Cloud Run enruta por la cabecera `Host`. El script aborta con `:?` si la variable
falta, así que un despliegue mal configurado falla al arrancar en vez de servir
un proxy roto.

El script usa una lista explícita de variables en `envsubst` en lugar de la
sustitución automática de la imagen base, que reemplazaría cualquier `${VAR}` y
chocaría con las `$variables` propias de nginx. Por eso el template **no** vive
en `/etc/nginx/templates/`.

`BACKEND_HOST` es la **única** variable de entorno del contenedor del frontend.
Antes se inyectaba también `BACKEND_URL`, que ningún proceso del contenedor leía
—es el nombre que usan `frontend/.env.example` y `vite.config.ts` para el proxy
del *servidor de desarrollo*—; se eliminó por no inducir a pensar que el
contenedor actuaba sobre ella.

### 2.3 El bundle siempre llama a `/api/v1` relativo

`frontend/src/infraestructure/http.ts` construye las URLs sobre un prefijo fijo
`/api/v1`, sin host. Por eso la llamada es **same-origin**, nginx hace de proxy,
las cookies de sesión son de primera parte y el CORS del backend casi nunca se
ejercita. No hay ninguna variable que apunte el navegador al backend, y es
deliberado: es lo que permite prescindir del balanceador.

---

## 3. Backend

Es el único servicio con configuración de verdad. El contrato lo define
`backend/src/config/env.ts` con Zod, y **si falta una obligatoria el proceso
lanza `Invalid environment variables` y muere**, cosa que Cloud Run solo muestra
como un health check fallido.

### 3.1 Obligatorias — van en `terraform/secrets/backend`

Sin valor por defecto. Terraform se niega a desplegar si falta alguna (§7).

| Variable | Notas |
|---|---|
| `JWT_SECRET` | Cadena larga y aleatoria |
| `BLOCKCHAIN_RPC_URL` | |
| `BLOCKCHAIN_PRIVATE_KEY` | |
| `FACTORY_CONTRACT_ADDRESS` | |
| `FORWARDER_CONTRACT_ADDRESS` | |
| `PINATA_JWT` | |
| `WALLET_ENCRYPTION_KEY` | Exactamente 64 hex (32 bytes) — Terraform también valida la longitud |

### 3.2 Opcionales con valor por defecto

Van en el mismo fichero solo si quieres cambiar el default de `env.ts`.

| Variable | Por defecto |
|---|---|
| `NODE_ENV` | `development` en `env.ts`, pero el `Dockerfile` del backend ya fija `production` |
| `PORT` | `4000` en local; **en Cloud Run lo inyecta la plataforma** |
| `FRONTEND_URL` | `http://localhost:3000` |
| `PINATA_GATEWAY_URL` | `https://gateway.pinata.cloud` |
| `DEFAULT_DPP_SCHEMA_VERSION` | `en18223-2026-v1` |
| `SCANTRUST_BASE_URL` | `https://api.staging.scantrust.io/api/v2/` |
| `SCANTRUST_UAT_TOKEN` | vacío |
| `GEO_COUNTRY_HEADER` | `cf-ipcountry` |
| `TOKEN_IMPLEMENTATION_ADDRESS` | opcional |
| `BOOTSTRAP_TOKEN` | opcional, mínimo 16 caracteres |
| `GEOIP_API_URL` | opcional, `{ip}` como placeholder |

> **Cuidado con `FRONTEND_URL`.** Su default es `http://localhost:3000`, así que
> si no la pones el CORS del backend permite localhost en producción. Normalmente
> da igual porque la SPA va por el proxy same-origin y CORS no se ejercita, pero
> si algo llama al backend cross-origin, ponla — y hazlo por
> `frontend_public_url` en `terraform.tfvars`, no a mano en el fichero de
> secretos, para que Terraform la derive del dominio cuando lo haya.

### 3.3 Derivadas por Terraform — **no las escribas**

Se calculan a partir de la propia infraestructura y se inyectan en cada `apply`.
Ganan sobre cualquier valor del fichero de secretos (§5), de modo que un valor
viejo no pueda apuntar la aplicación a una instancia equivocada.

| Variable | De dónde sale |
|---|---|
| `DATABASE_URL` | Usuario, clave y nombre de conexión de Cloud SQL, sobre el socket `/cloudsql/<instancia>` |
| `DSS_VALIDATION_URL` | `.uri` del Cloud Run de DSS |

Son solo dos. Se inyectaba también `INSTANCE_CONNECTION_NAME`
(`project:region:instance`), pero nada en `trustex-web` la lee: el nombre de
conexión ya viaja dentro de `DATABASE_URL` como directorio del socket. Eliminada.

### 3.4 Reservadas por Cloud Run — declararlas rompe el despliegue

`PORT`, `K_SERVICE`, `K_REVISION`, `K_CONFIGURATION`. Cloud Run las pone él y
rechaza una revisión que además las declare. Terraform lo comprueba antes (§7).

`PORT` es la tentadora: no la pongas, Cloud Run la deriva de
`ports.container_port` y `env.ts` la lee de ahí.

---

## 4. Base de datos: `terraform/secrets/postgres`

**No son variables de entorno de ningún servicio.** Son entradas para Terraform:

```
DB_NAME, DB_USER, DB_PASSWORD
        ↓  Terraform crea la base y el usuario de Cloud SQL
        ↓  y construye una única cadena de conexión
DATABASE_URL = postgresql://DB_USER:DB_PASSWORD@localhost:5432/DB_NAME
                 ?host=/cloudsql/<connection name>&schema=public
```

Esa `DATABASE_URL` es la que reciben el backend y el job de migraciones, y es la
única cadena de conexión del sistema. El `host` va como parámetro de query
porque tanto `node-postgres` como el motor de Prisma toman de ahí el directorio
del socket e ignoran el host de la parte de autoridad. Usuario y contraseña van
url-encodados: pueden contener `:`, `@`, `/` o `#`.

Cambiar `DB_PASSWORD` y aplicar rota la clave en Cloud SQL y en los servicios a
la vez. `DB_NAME` y `DB_USER` no se pueden cambiar sin recrear la base y el
usuario.

Terraform guarda además una copia de `DB_PASSWORD` en Secret Manager como
break-glass. Ningún servicio la lee de ahí.

---

## 5. Job de setup

Sus flags salen de variables de `terraform.tfvars`, no de un fichero de secretos.
El contrato está en `backend/src/setup/setup.config.ts`.

| Variable del job | Variable de Terraform | Por defecto |
|---|---|---|
| `DATABASE_URL` | derivada | — |
| `SETUP_RUN_MIGRATIONS` | `setup_run_migrations` | `true` |
| `SETUP_RUN_SEED` | `setup_run_seed` | `false` — no es idempotente |
| `SETUP_DB_WAIT_RETRIES` | `setup_db_wait_retries` | `10` (1-60) |
| `SETUP_DB_WAIT_DELAY_MS` | `setup_db_wait_delay_ms` | `3000` (1-60000) |

El job carga solo `database-env.ts`, un subconjunto que exige únicamente
`DATABASE_URL`. Por eso no necesita `JWT_SECRET` ni las claves de blockchain
para migrar.

---

## 6. DSS: ninguna, y es deliberado

El contenedor de DSS no recibe ninguna variable, y su bloque `env` en
`cloudRun.tf` no existe a propósito. La guía de despliegue del propio
servicio dice que no requiere ninguna, y `CATALINA_OPTS` en particular
**debe dejarse en paz**: la imagen dimensiona el heap con
`-XX:MaxRAMPercentage=70.0` sobre el límite del contenedor. Fijar un `-Xmx`
desharía ese cálculo y arriesga un OOM-kill.

El comportamiento de DSS se controla desde Terraform con `dss_min_instances`, que
no es una variable de entorno sino la palanca que deriva el modo de despliegue
(instancias mínimas + `cpu_idle`). Ver [apps-y-servicios.md](apps-y-servicios.md).

### Y `DEBUG` tampoco existe ya

Hubo una variable `debug` en Terraform que inyectaba `DEBUG=true` en los tres
servicios. No aparecía en ningún sitio del código —ni en `backend/src`, ni en
`frontend/src`, ni la consumía la imagen de DSS—, así que se eliminó. Si algún
día hace falta un modo verboso, hay que implementarlo primero en la aplicación
y solo entonces darle una palanca en la infraestructura.

---

## 7. Precedencia: quién gana

El entorno del backend se compone en `locals.tf` con un `merge`, y en un `merge`
**gana el último**:

```
1. frontend_url_env       FRONTEND_URL calculada desde las variables
2. secrets_backend        terraform/secrets/backend            ← pisa 1
3. backend_derived_env    DATABASE_URL, DSS_VALIDATION_URL     ← pisa todo
```

Leído al revés: **los valores derivados de la infraestructura son intocables**
(un `DATABASE_URL` viejo en el fichero de secretos no puede apuntar el backend a
otra base), y el fichero de secretos manda sobre lo que Terraform calcula por
comodidad.

Frontend y DSS no tienen precedencia que resolver: el frontend recibe una sola
variable (`BACKEND_HOST`) y DSS ninguna.

---

## 8. Lo que Terraform comprueba antes de desplegar

Sobre `terraform/secrets/backend`, en `cloudRun.tf` como `lifecycle.precondition`
del servicio backend — **detienen el plan**, no son avisos:

- falta alguna de las siete obligatorias de `env.ts`
- se declara alguna variable reservada por Cloud Run
- `WALLET_ENCRYPTION_KEY` no tiene 64 caracteres

Y en `database.tf`, una precondición sobre `google_sql_user`: `DB_PASSWORD` no
puede estar vacía.

Los mismos criterios existen además como bloques `check` en `locals.tf`. Un
`check` solo genera un *warning*, pero tiene una ventaja: en `terraform plan`
reporta **todos** los problemas a la vez, mientras que una precondición se
detiene en el primero. Por eso conviven.

---

## 9. Recetas

**Cambiar un secreto del backend** (clave JWT, token de Pinata, RPC…)

```bash
$EDITOR terraform/secrets/backend
make secrets-encrypt      # actualiza el .age que sí va a git
make tf-apply             # nueva revisión con el valor nuevo
```

**Cambiar `VITE_DPP_BASE_URL`** — no basta con `apply`:

```bash
# en trustex-web
make build-frontend push-frontend DPP_BASE_URL=https://nuevo.dominio.eu FRONTEND_TAG=0.0.2

# en trustex-infra: subir frontend_tag a 0.0.2 en terraform.tfvars
make tf-apply
```

**Rotar la contraseña de la base de datos**

```bash
$EDITOR terraform/secrets/postgres   # DB_PASSWORD
make secrets-encrypt
make tf-apply    # rota en Cloud SQL y en los servicios a la vez
```

**Averiguar qué tiene desplegado un servicio ahora mismo**

```bash
gcloud run services describe trustex-dev-backend --region europe-west1 \
  --format='value(spec.template.spec.containers[0].env)'
```

**Añadir una variable nueva al backend**

1. Declararla en `backend/src/config/env.ts` (es el contrato).
2. Si es obligatoria, añadirla a `local.backend_required_env` en `locals.tf`
   para que Terraform se niegue a desplegar sin ella.
3. Ponerla en `terraform/secrets/backend.example` con un comentario.
4. Ponerla en `terraform/secrets/backend` y `make secrets-encrypt`.
