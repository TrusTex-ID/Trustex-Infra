# Qué se despliega y cómo encaja con el código

Este documento es el puente entre los repos de aplicación y `terraform/`. Si
cambias un puerto, una variable de entorno obligatoria o un Dockerfile en
`trustex-web`, aquí está lo que hay que tocar en la infraestructura.

Para la configuración en concreto —qué variable se fija al construir la imagen,
cuál en el `apply`, cuál deriva Terraform y cuál no la lee nadie— hay un
documento aparte: [variables-de-entorno.md](variables-de-entorno.md).

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

**Cada repo construye y publica sus propias imágenes.** Este repo no las
construye: solo consume los tags. `make images` en `trustex-web` y `make image`
en `dss-validation-docker` imprimen esta misma tabla con las rutas del registry
ya resueltas.

### Frontend: no es Next.js

Es una SPA de **React + Vite** compilada a ficheros estáticos y servida por
**nginx**, no un servidor Node. Tres consecuencias para la infraestructura:

1. El puerto del contenedor es **80**, no 3000.
2. `NODE_ENV` no significa nada en tiempo de ejecución.
3. Las variables `VITE_*` (hoy solo `VITE_DPP_BASE_URL`) las incrusta Vite en el
   bundle de JavaScript **durante el build**. No se pueden cambiar desde Cloud
   Run ni desde Terraform: van como `--build-arg`, y su única fuente es
   `DPP_BASE_URL` en `trustex-web/Makefile` (`make build-frontend
   DPP_BASE_URL=...`, desde ese repo).

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
  poblarlo antes del primer build, **desde `dss-validation-docker`**:
  `make lotl-up` → esperar a `Nb of loaded trusted lists` → `make lotl-save` →
  `make build`.
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

## 2. Dos ajustes que se hicieron en `trustex-web` para esta infraestructura

La infraestructura por sí sola no bastaba: el código de la aplicación asumía un
despliegue con `docker-compose`, no Cloud Run. Ambos se corrigieron directamente
en `trustex-web` — documentado ahí en
`docs/changes/2026-09-03.md` según manda su propio `CLAUDE.md` — y aquí queda el
porqué, por si hay que tocarlos otra vez.

### 2.1 El proxy `/api/v1` en Cloud Run

La SPA llama a `/api/v1/...` en su **mismo origen**
(`frontend/src/infraestructure/http.ts`) y espera que nginx haga de proxy hacia
el backend. Así las cookies de sesión son de primera parte y no hay CORS. Pero
`frontend/nginx.conf` tenía el upstream escrito a mano, apuntando al nombre de
servicio de `docker-compose` (`http://backend:4000`) y reenviando el `Host` del
propio frontend — que en Cloud Run, que enruta precisamente por esa cabecera,
devuelve un 404 del frontal de Google en vez de llegar al backend.

Arreglado plantillando la configuración al arrancar el contenedor:
`frontend/nginx.conf.template` usa `${BACKEND_HOST}` — el host que Terraform ya
inyecta como env var — tanto en `proxy_pass` (con `https` y
`proxy_ssl_server_name` para SNI) como en la cabecera `Host`, y
`frontend/docker-entrypoint.d/40-render-nginx-conf.sh` lo resuelve con
`envsubst` antes de que nginx arranque. Se usó una lista explícita de variables
para `envsubst` en vez del mecanismo automático de la imagen (que sustituye
cualquier `${VAR}` que coincida con el nombre de una variable de entorno,
arriesgando chocar con las propias `$variables` de nginx) — por eso la
plantilla no vive en `/etc/nginx/templates/`, que es donde ese mecanismo busca.

Alternativas que se descartaron por añadir coste o fragilidad: el balanceador
global (enruta `/api/*` sin proxy de nginx, pero son ~18 $/mes más) y CORS
(la SPA llamando directamente a la URL `run.app` del backend, con cookies de
tercera parte — frágil en Safari y en navegadores con bloqueo por defecto).

### 2.2 El ID token para llamar a DSS

`dss_public_invoker = false` deja el servicio DSS accesible solo con un ID
token de OIDC de una cuenta de servicio con `roles/run.invoker`. Terraform ya
le daba ese rol a la SA del backend; faltaba que el cliente firmara la
llamada — `backend/src/verification/dss-client.ts` hacía un `fetch` pelado, sin
cabecera de autorización.

Arreglado con `google-auth-library`: se resuelve un `IdTokenClient` una sola
vez (perezosamente, en el primer uso) y se pide un ID token nuevo en cada
llamada con `idTokenProvider.fetchIdToken(DSS_BASE_URL)`, añadido como
`Authorization: Bearer <token>`. Si no hay forma de obtener el token —caso del
`docker-compose` de `dss-validation-docker` en local, sin metadata server ni
credenciales configuradas— la llamada sigue adelante sin cabecera, porque esa
instancia local no tiene IAM delante. No hace falta ninguna variable de entorno
nueva ni tocar el flujo de desarrollo local.

Con esto, `dss_public_invoker` puede quedarse en `false`: ya no hace falta el
apaño de abrir DSS al público (`true`), que exponía a internet, además de la
validación, la UI web, Swagger, los servicios SOAP y `/server-sign/**` —que
firma con un keystore de demo cuya contraseña (`password`) está publicada.

Conviene además comprobar `/health/ready` (o el campo `ready` de `/health`)
antes de fiarse de una validación: un `AdESig` donde debería haber `QESig` es
la forma en que este servicio falla.

---

## 3. Orden de despliegue

Los pasos van en tres repos distintos: la infraestructura aquí, las imágenes en
el repo que las contiene. El prompt de cada bloque indica dónde estás.

```bash
# ---- trustex-infra ----------------------------------------------------------
# 1) Secretos
make secrets-decrypt          # o rellenar terraform/secrets/{backend,postgres}

# 2) Primer apply con imágenes de prueba
#    (descomenta los *_image de placeholder en terraform.tfvars)
make tf-init tf-apply

# ---- dss-validation-docker --------------------------------------------------
# 3) Pre-calentar el caché LOTL (solo la primera vez y cuando envejezca)
make lotl-up
docker compose logs -f
#   ...espera a "Nb of loaded trusted lists", Ctrl-C
make lotl-save

# 4) Construir y subir la imagen de DSS
make docker-login
make build push TAG=0.0.1

# ---- trustex-web ------------------------------------------------------------
# 5) Construir y subir las tres imágenes de la aplicación
make docker-login
make build-all push-all TAG=0.0.1

# ---- trustex-infra ----------------------------------------------------------
# 6) Apply real
#    (comenta los *_image; los *_tag ya valen 0.0.1)
make tf-apply

# 7) Migraciones
make db-setup

# 8) Comprobar que DSS sirve de verdad (state READY, no LOADING_TRUSTED_LISTS)
make dss-ready

# 9) URLs
make urls
```

Los `make docker-login` de los pasos 4 y 5 son el mismo comando y basta con
hacerlo una vez por máquina.

A partir de ahí, un despliegue normal del backend es: `make build-backend
push-backend BACKEND_TAG=0.0.2` **en `trustex-web`**, subir `backend_tag` a ese
mismo valor en `terraform.tfvars` **aquí**, `make tf-apply`, y `make db-setup` si
la versión trae migraciones nuevas.

Subir el tag no es opcional: Cloud Run fija la cadena de la imagen en la
plantilla de la revisión, así que reutilizar un tag deja a Terraform sin cambio
que aplicar y la revisión antigua sigue sirviendo. Por eso `latest` está
prohibido por una `validation` en `variables.tf`.

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
