# Qué se despliega y cómo encaja con el código

Este documento es el puente entre los repos de aplicación y `terraform/`. Si
cambias un puerto, una variable de entorno obligatoria o un Dockerfile en
`trustex-web`, aquí está lo que hay que tocar en la infraestructura.

Repos, tal y como se esperan clonados uno al lado del otro:

```
cetim/trustex/
├── trustex-infra/            este repo
├── trustex-web/              frontend + backend + job de setup
└── dss-validation-docker/    servicio de validación de firmas de la UE
```

---

## 1. Los cuatro artefactos

| Cloud Run | Imagen | Se construye desde | Escucha | Base de datos |
|---|---|---|---|---|
| `trustex-<env>-frontend` | `frontend` | `trustex-web/frontend/Dockerfile` | **80** (nginx) | no |
| `trustex-<env>-backend` | `backend` | `trustex-web/backend/Dockerfile` | 8080 (Express) | sí |
| `trustex-<env>-dss` | `dss` | `dss-validation-docker/Dockerfile` | 8080 (Tomcat) | no |
| `trustex-<env>-setup` (Job) | `setup` | `trustex-web/setup/Dockerfile` | — | sí |

`make images` imprime la misma tabla con las rutas del registry ya resueltas.

### Frontend: no es Next.js

Es una SPA de **React + Vite** compilada a ficheros estáticos y servida por
**nginx**, no un servidor Node. Tres consecuencias para la infraestructura:

1. El puerto del contenedor es **80**, no 3000.
2. `NODE_ENV` no significa nada en tiempo de ejecución.
3. Las variables `VITE_*` (hoy solo `VITE_DPP_BASE_URL`) las incrusta Vite en el
   bundle de JavaScript **durante el build**. No se pueden cambiar desde Cloud
   Run: van como `--build-arg` (`make build-frontend`, `var.frontend_dpp_base_url`).

### Backend

Express + Prisma. Lee `PORT` (lo inyecta Cloud Run) y una sola variable de
conexión, `DATABASE_URL`. El contrato completo está en
`backend/src/config/env.ts`; las obligatorias sin valor por defecto están
listadas en `local.backend_required_env` y un `check` de Terraform avisa antes
del apply si falta alguna.

### DSS

Es la webapp de demostración del proyecto **DSS de la Comisión Europea** sobre
Tomcat 10, empaquetada en `dss-validation-docker`. No tiene base de datos ni
configuración propia del proyecto: el backend le hace
`POST /services/rest/validation/validateSignature`
(`backend/src/verification/dss-client.ts`). Terraform le pasa su URL al backend
como `DSS_VALIDATION_URL`.

Ese repo trae su propia guía de despliegue en Cloud Run
(`docs/despliegue-en-produccion.md`) y `terraform/cloudRun.tf` la implementa
literalmente. Lo que hay que entender antes de tocar nada:

**El fallo de este servicio no es una caída, es una respuesta equivocada.**
Mientras las listas de confianza europeas (LOTL) no están cargadas, las
validaciones responden `200 OK` con `signatureLevel: "AdESig"` en lugar de
`"QESig"`. No fallan: mienten, en silencio. De ahí sale casi toda la
configuración:

- **Caché LOTL horneado en la imagen.** Es un *requisito*, no una optimización.
  Con escala a cero la CPU está limitada entre peticiones, así que el hilo de
  fondo que descarga el LOTL (`onlineRefresh`, 2–3 min) puede no terminar nunca
  en una demo de tres llamadas. Con el caché dentro de la imagen, los trust
  anchors se cargan en el `@PostConstruct` (`offlineRefresh`), donde Cloud Run
  sí da CPU completa. `lotl-cache/` se versiona **vacío**, así que hay que
  poblarlo antes del primer build: `make dss-lotl-up` → esperar a
  `Nb of loaded trusted lists` → `make dss-lotl-save` → `make build-dss`.
- **Sondas a `/health`, nunca a `/health/ready`.** Cloud Run no distingue
  *listo* de *vivo*: el `503` que devuelve `/health/ready` mientras carga el
  LOTL se leería como contenedor muerto y lo reiniciaría en bucle.
  `/health/ready` es para ti y para el backend — `make dss-ready`.
- **4 GiB y sin `CATALINA_OPTS`.** La imagen dimensiona el heap con
  `-XX:MaxRAMPercentage=70.0` sobre el límite del contenedor (~2,8 GB con 4 GiB).
  Poner un `-Xmx` fijo desde Terraform desharía ese cálculo y arriesga un
  OOM-kill. No bajar de 3 GiB.
- **Privado por IAM.** La imagen sirve además la UI web, Swagger, los servicios
  SOAP y `/server-sign/**`, que firma de verdad con un keystore de demo de
  contraseña pública. Por eso `dss_public_invoker` es `false` por defecto y solo
  la cuenta de servicio del backend tiene `run.invoker` (ver §2.2).

Los dos modos de la guía se derivan de una sola variable, `dss_min_instances`,
porque pedir instancia caliente sin fijar también la CPU es una trampa
documentada (el refresco horario del LOTL es un `@Scheduled` que se congela con
la CPU limitada):

| | Modo A — `dss_min_instances = 0` | Modo B — `dss_min_instances >= 1` |
|---|---|---|
| CPU entre peticiones | limitada (`cpu_idle = true`) | siempre asignada |
| Arranque en frío | 40–90 s con el caché horneado | ninguno |
| `timeout` / `max_instances` | 300 s / 2 | 120 s / 3 |
| Coste | prácticamente 0 | ~90–120 $/mes |

**Modo A es el que está puesto.** Modo B solo si el tráfico deja de ser puntual,
y ahí el presupuesto de 20–25 $/mes ya no se sostiene.

### Job de setup

`prisma migrate deploy` y, opcionalmente, `prisma db seed`
(`backend/src/setup/setup.service.ts`). Es un **Cloud Run Job** y no un
contenedor de arranque del backend porque Cloud Run no tiene init containers y
la migración no debe ejecutarse una vez por instancia.

Terraform crea el job pero **no lo ejecuta**: aplicar infraestructura y migrar
una base de datos son decisiones distintas. Se lanza con `make db-setup`.

---

## 2. Dos cambios pendientes en `trustex-web`

La infraestructura está completa, pero hay dos cosas que solo se pueden arreglar
en el código de la aplicación. Sin la primera, la API no responde; sin la
segunda, la validación de firmas devuelve `403`.

### 2.1 El proxy `/api/v1` en Cloud Run

La SPA llama a `/api/v1/...` en su **mismo origen**
(`frontend/src/infraestructure/http.ts`) y espera que nginx haga de proxy hacia
el backend. Así las cookies de sesión son de primera parte y no hay CORS. Pero
`frontend/nginx.conf` tiene el upstream escrito a mano:

```nginx
location /api/v1/ {
    proxy_pass http://backend:4000;
    proxy_set_header Host $host;
}
```

Eso es el nombre de servicio de `docker-compose`. En Cloud Run hace falta:

- el host real del Cloud Run del backend, que Terraform ya pasa al contenedor
  como `BACKEND_URL` (`https://host`) y `BACKEND_HOST` (solo el host);
- `https`, con SNI;
- `Host` **igual al host del backend**, porque Cloud Run enruta por `Host`.
  Reenviar el `Host` del frontend devuelve un 404 del frontal de Google.

El patrón habitual es plantillar la configuración al arrancar el contenedor. La
imagen `nginx` ya lo soporta: todo lo que esté en `/etc/nginx/templates/*.conf.template`
se pasa por `envsubst` y se escribe en `/etc/nginx/conf.d/`. En el Dockerfile del
frontend sería cambiar

```dockerfile
COPY nginx.conf /etc/nginx/conf.d/default.conf
```

por

```dockerfile
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
```

y en la plantilla usar `${BACKEND_HOST}`:

```nginx
location /api/v1/ {
    proxy_pass         https://${BACKEND_HOST};
    proxy_ssl_server_name on;
    proxy_set_header   Host ${BACKEND_HOST};
    proxy_http_version 1.1;
    proxy_set_header   Cookie $http_cookie;
    proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto $scheme;
    proxy_pass_header  Set-Cookie;
}
```

Mientras eso no exista, el frontend despliega y sirve la SPA, pero cualquier
llamada a la API devuelve 502.

Dos alternativas, si se prefiere no tocar la imagen:

- **Balanceador global** (`enable_load_balancer = true`): enruta `/api/*` al
  backend desde el propio balanceador y el proxy de nginx deja de usarse. Son
  ~18 $/mes más.
- **CORS**: que la SPA llame a la URL `run.app` del backend. Habría que darle una
  variable `VITE_API_BASE_URL` (hoy no existe), poner `frontend_public_url` para
  que el backend la acepte como origen, y las cookies pasan a ser de tercera
  parte — frágil en Safari y en navegadores con bloqueo por defecto.

### 2.2 El ID token para llamar a DSS

`dss_public_invoker = false` deja el servicio DSS accesible solo con un ID token
de OIDC de una cuenta de servicio con `roles/run.invoker`. Terraform ya le ha
dado ese rol a la SA del backend, así que falta únicamente que el cliente firme
la llamada. Hoy `backend/src/verification/dss-client.ts` hace un `fetch` pelado:

```js
const response = await fetch(`${DSS_BASE_URL}/services/rest/validation/validateSignature`, { ... })
```

Con `google-auth-library` (la propia guía de DSS trae el ejemplo) son unas pocas
líneas; el token se obtiene del metadata server de Cloud Run, sin credenciales
en el código:

```js
import { GoogleAuth } from 'google-auth-library'

const client = await new GoogleAuth().getIdTokenClient(DSS_BASE_URL)
const { data } = await client.request({
  url: `${DSS_BASE_URL}/services/rest/validation/validateSignature`,
  method: 'POST',
  data: { signedDocument: { bytes, name } },
})
```

Mientras no exista, la única alternativa es `dss_public_invoker = true`, que
expone a internet no solo la validación sino también la UI web, Swagger, los
servicios SOAP y `/server-sign/**` — que firma con un keystore de demo cuya
contraseña (`password`) está publicada. Es un apaño para desarrollo, no algo
que deba quedarse.

Conviene además comprobar `/health/ready` (o el campo `ready` de `/health`)
antes de fiarse de una validación: un `AdESig` donde debería haber `QESig` es
la forma en que este servicio falla.

---

## 3. Orden de despliegue

```bash
# 1) Secretos
make secrets-decrypt          # o rellenar terraform/secrets/{backend,postgres}

# 2) Primer apply con imágenes de prueba
#    (descomenta los *_image de placeholder en terraform.tfvars)
make tf-init tf-apply

# 3) Pre-calentar el caché LOTL de DSS (solo la primera vez y cuando envejezca)
make dss-lotl-up
docker compose -f ../dss-validation-docker/docker-compose.yml logs -f
#   ...espera a "Nb of loaded trusted lists", Ctrl-C
make dss-lotl-save

# 4) Construir y subir las imágenes reales
make docker-login
make build-all push-all TAG=0.1.0

# 5) Apply real
#    (comenta los *_image y pon los *_tag = 0.1.0)
make tf-apply

# 6) Migraciones
make db-setup

# 7) Comprobar que DSS sirve de verdad (state READY, no LOADING_TRUSTED_LISTS)
make dss-ready

# 8) URLs
make urls
```

A partir de ahí, un despliegue normal es: `make build-backend push-backend
TAG=x.y.z`, subir `backend_tag` en `terraform.tfvars`, `make tf-apply` y
`make db-setup` si la versión trae migraciones nuevas.

---

## 4. Coste

| Recurso | Aproximado |
|---|---|
| Cloud SQL `db-f1-micro`, 10 GB HDD, zonal | 8–12 $/mes |
| Cloud Run x3 + job, todos a cero en reposo | < 1–3 $/mes con tráfico de demo |
| Artifact Registry (política: 5 versiones) | < 1 $/mes |
| Secret Manager, dominio de Cloud Run, TLS | ~0 |

El presupuesto de 20–25 $/mes lo sostiene el escalado a cero. Lo que lo rompe,
en orden de impacto: `dss_min_instances >= 1` (Modo B: ~90–120 $/mes), el
balanceador global (+18 $/mes) y un conector de VPC Access (+7 $/mes; por eso el backend usa
el conector de Cloud SQL por socket y no una VPC — ver
[red-balanceador-y-vpc.md](red-balanceador-y-vpc.md)).
