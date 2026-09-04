# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/).
Este proyecto versiona infraestructura, no una librería: los cambios se agrupan
por revisión, y cada entrada dice qué se rompía antes y qué se rompe ahora.

## [No publicado] — 2026-09-04

Revisión general de la configuración de Terraform. Se validó con
`terraform validate` y con un `terraform plan` real contra
`project-4894bbdc-540f-48c0-ac5` (provider `hashicorp/google` v5.45.2).

Antes de esta revisión **ningún `terraform plan` podía completarse** con la
configuración por defecto. Ahora el plan llega al final (25 recursos a crear) y
solo se detiene en la precondición que exige rellenar los ficheros de secretos.

### Corregido

- **`terraform validate` fallaba con `Invalid index`** — `secrets.tf` indexaba
  directamente `local.secrets_postgres["DB_PASSWORD"]`. El `count` del recurso
  no protege esa expresión: Terraform la evalúa estáticamente y el objeto está
  vacío mientras `terraform/secrets/postgres` no defina la clave. Sustituido por
  `lookup(local.secrets_postgres, "DB_PASSWORD", "")`, que es lo que ya usaba la
  línea del `count` justo encima.

- **`terraform plan` fallaba siempre en la configuración por defecto** —
  `locals.tf` calculaba `frontend_public_url_effective` con `coalesce(...)`
  usando `""` como último recurso. `coalesce` descarta las cadenas vacías además
  de los nulls, así que ese fallback es inalcanzable y la llamada aborta con
  *"no non-null, non-empty-string arguments"* cuando ni `frontend_public_url` ni
  `frontend_custom_domain` están definidos — es decir, en el caso por defecto
  documentado. Reemplazado por ternarios encadenados, que conservan la misma
  precedencia y sí devuelven `""`.

- **El balanceador opcional era esquivable** — con `enable_load_balancer = true`
  los servicios seguían con `ingress = "INGRESS_TRAFFIC_ALL"`, así que sus URLs
  `*.run.app` respondían igual y cualquiera podía saltarse el balanceador, su
  certificado gestionado y su URL map. Se pagaban ~18 $/mes por una capa
  decorativa. `cloudRun.tf` deriva ahora el ingress de `local.lb_enabled`:
  `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER` cuando el LB está activo. Solo
  frontend y backend; DSS nunca está detrás del LB y el backend lo llama por
  internet con un ID token.

- **El timeout del backend cortaba las validaciones de firma en frío** — estaba
  fijo en `120s`, pero es el plazo exterior de una validación cuyo eslabón
  interno, DSS en modo A, tarda 40-90 s solo en arrancar en frío (su propio
  timeout es `300s`). La primera validación tras un rato de inactividad se
  cortaba desde fuera y el fallo parecía un bug del backend. Ahora el timeout
  del backend sigue el modo de DSS igual que hace el propio servicio DSS:
  `local.dss_always_on ? "120s" : "300s"`.

- **`require_ssl` está deprecado en el provider** (confirmado en el schema de
  v5.45.2, `"deprecated": true`). Cambiado a su equivalente exacto,
  `ssl_mode = "ENCRYPTED_ONLY"`. Elimina el warning del plan y evita el trabajo
  cuando el provider lo retire. Sin efecto funcional.

- **`database.tf` no pasaba `terraform fmt`** (alineación en `availability_type`).
  Era el único fichero del directorio en ese estado.

### Añadido

- **Presupuesto de facturación con alertas** (`budget.tf`). El techo de
  ~20-25 $/mes es una restricción explícita del proyecto y no había nada que lo
  vigilara. Con Cloud Run escalando a cero, un sobrecoste es mucho más probable
  que venga de un cambio de configuración (`dss_min_instances >= 1`,
  `enable_load_balancer`, subir el tier de Cloud SQL) que del tráfico, y eso
  aparece en la factura un mes después. Avisos al 50 %, 80 %, 100 % y 100 %
  previsto. Un presupuesto **solo notifica**: nunca limita el gasto ni para un
  servicio.

  Desactivado salvo que se rellene `billing_account_id`, porque crear un
  presupuesto exige un rol sobre la *cuenta de facturación*
  (`roles/billing.costsManager`), que es distinto de ser owner del proyecto:

  ```bash
  gcloud billing projects describe project-4894bbdc-540f-48c0-ac5 \
    --format='value(billingAccountName)'
  ```

  Nuevas variables: `billing_account_id` (vacía = desactivado),
  `budget_amount` (25), `budget_currency` (`EUR`), `budget_alert_emails`
  (vacía = avisa a los admins de facturación y owners, el comportamiento por
  defecto de Cloud Billing).

- **Precondiciones duras en el servicio backend** (`cloudRun.tf`). Las tres
  comprobaciones sobre `terraform/secrets/backend` existían solo como bloques
  `check`, que **únicamente generan warnings**: el apply terminaba con éxito y
  el problema aparecía minutos después como una revisión que no pasa el health
  check, con `Invalid environment variables` enterrado en los logs. Ahora son
  `lifecycle.precondition` sobre el recurso que se rompería, y detienen el plan:

  - faltan variables obligatorias de `backend/src/config/env.ts`
  - se declaran variables reservadas por Cloud Run (`PORT`, `K_SERVICE`, ...)
  - `WALLET_ENCRYPTION_KEY` no tiene 64 caracteres hex

  Los bloques `check` se mantienen: en `terraform plan` reportan todos los
  problemas a la vez, mientras que una precondición se detiene en el primero.

- **`max_instance_request_concurrency = 40` en el backend**. Estaba sin fijar, o
  sea 80 por defecto, con 512 Mi para Node + Prisma + llamadas a blockchain e
  IPFS, y contra una instancia de Cloud SQL limitada a 50 conexiones. DSS ya se
  limitaba a 20 con un razonamiento explícito; el backend no tenía ninguno.
  40 × 2 instancias sigue siendo muy superior a la carga esperada.

- **Guardas duras sobre el balanceador** (`loadBalancer.tf`), como
  `lifecycle.precondition` en `google_compute_url_map.main` — el recurso que se
  crea siempre que el LB está activo, de modo que el plan se detiene antes de que
  exista ningún recurso facturable de compute:

  - `enable_load_balancer = true` con `lb_domains` vacío
  - `enable_load_balancer` y `frontend_custom_domain` a la vez (excluyentes desde
    el cambio de ingress: con el LB activo, un domain mapping apunta a un
    servicio que no responderá a ese dominio)

  Existían como bloques `check`, que solo avisan: el apply se completaba igual.

  Verificado ejecutando los tres casos contra el proyecto: sin dominios se
  bloquea, con dominio propio a la vez se bloquea, y bien configurado planifica
  los 12 recursos del balanceador de forma coherente.

### Cambiado

- **Los tags de imagen dejan de ser `latest` y pasan a ser inmutables** (`0.0.1`,
  `0.0.2`, …), con una `validation` en `variables.tf` que rechaza `latest` en los
  cuatro `*_tag`.

  No es solo higiene de versionado. Terraform fija la cadena de la imagen en la
  plantilla de la revisión de Cloud Run: al reutilizar un tag, la cadena no
  cambia, Terraform no ve diff y **no despliega nada**. El registry tendría la
  imagen nueva y el servicio seguiría sirviendo el digest viejo, sin ningún
  error. Subir el tag es lo que provoca la revisión nueva.

- **Construir imágenes sale de este repo.** Cada repo de aplicación pasa a tener
  su propio `Makefile` y a publicar sus propias imágenes:

  | Repo | Targets |
  |---|---|
  | `trustex-web` | `images`, `docker-login`, `build-*`, `push-*` (frontend, backend, setup) |
  | `dss-validation-docker` | `image`, `docker-login`, `lotl-up`, `lotl-save`, `build`, `push` |

  Antes, el `Makefile` de aquí construía las cuatro imágenes alcanzando los otros
  dos repos por ruta relativa (`WEB_DIR := ../trustex-web`), lo que obligaba a
  tenerlos clonados con ese nombre exacto y al lado. Efectos: este repo no era
  autosuficiente, un desarrollador de `trustex-web` no podía construir su propia
  imagen sin clonar la infraestructura, y en CI un pipeline de aplicación habría
  tenido que hacer checkout del repo de infra para leer un `Makefile`.

  El contrato entre repos es ahora **solo el tag**, que es justo lo que Terraform
  ya modelaba con las variables `*_tag`: se publica `0.0.2` allí, se pone
  `backend_tag = "0.0.2"` aquí y se aplica. Ninguno de los dos `Makefile` nuevos
  habla con Terraform.

  Los repos de aplicación resuelven el registry con
  `gcloud config get-value project` en lugar de leer el output de Terraform, para
  no reintroducir la dependencia en sentido contrario.

  El `Makefile` de este repo queda con secretos, Terraform y las tres tareas de
  operación que **no pueden vivir en otro sitio** porque leen outputs de
  Terraform: `db-setup`, `dss-ready` y `urls`.

- **Guarda contra `PROJECT_ID` vacío** en los tres `Makefile`. Salió al probar
  los nuevos: sin proyecto resuelto, el registry quedaba como
  `europe-west1-docker.pkg.dev//trustex/backend:0.0.1` —con un segmento vacío— y
  el fallo aparecía después como un error de Docker sin relación aparente. Ahora
  para con un mensaje que dice qué falta. Está definida de forma recursiva a
  propósito, así que solo salta en los targets que usan el registry: `lotl-up` y
  `lotl-save` siguen funcionando sin proyecto configurado.

- **Cloud SQL pasa de PostgreSQL 15 a 18**, y `trustex-web/backend/docker-compose.yml`
  de `postgres:16-alpine` a `postgres:18-alpine`.

  Dos motivos. El primero es que **desarrollo y producción estaban en versiones
  mayores distintas** —16 en local, 15 en Cloud SQL—, que es el tipo de desfase
  que solo se manifiesta en producción. El segundo es que la 15 no era una
  decisión: era el único valor de `database.tf` sin comentario que lo
  justificara, en un fichero donde el tier, el disco, la edición y el
  `max_connections` sí lo tienen.

  Nada en la aplicación ata la versión: ninguna de las diez migraciones de
  Prisma usa extensiones ni SQL específico de versión, y el esquema solo declara
  `provider = "postgresql"`. Cloud SQL acepta hasta `POSTGRES_18`. Elegirla antes
  del primer `apply` es gratis; cambiarla después exige un upgrade mayor in-place
  o un dump/restore. La 15 además pierde soporte de la comunidad a finales de
  2027, la 18 en 2030.

  `db-f1-micro` es un tier compartido heredado y las versiones nuevas pueden
  tardar en llegar a él. No se pudo comprobar por adelantado porque la API
  `sqladmin` no está habilitada en el proyecto hasta el primer `apply`. Si la
  creación fallara por la versión, el fallo es ruidoso y la alternativa es 17
  —todavía por delante de local, así que en ese caso hay que mover el
  `docker-compose.yml` a 17 y no volver a 15. Está anotado en `database.tf`.

### Corregido (segunda pasada)

- **Una IP global reservada y ociosa cuando el balanceador estaba a medio
  configurar.** `google_compute_global_address.lb` se creaba con solo
  `local.lb_enabled`, mientras que todas las reglas de forwarding exigen además
  `length(var.lb_domains) > 0`. Con `enable_load_balancer = true` y sin dominios
  —cuyo `check` solo avisaba— quedaba una IP estática reservada sin adjuntar a
  nada, que GCP factura precisamente por estar ociosa (~7 $/mes), a cambio de un
  balanceador que no funcionaba. Ahora la IP comparte la condición de las reglas
  de forwarding, y las precondiciones de arriba hacen que esa combinación ni
  siquiera llegue a aplicarse.

- **Aviso cuando `budget_alert_emails` está puesta sin `billing_account_id`.**
  No cuesta dinero, pero el fallo es silencioso: configuras a quién avisar si el
  gasto se dispara y no se crea ni el presupuesto ni los canales. Es un `check`
  y no una precondición porque no hay ningún recurso al que engancharla cuando
  el presupuesto está desactivado.

  Auditados de paso todos los `count` y `for_each` condicionales del proyecto
  (`secrets.tf`, `domainMapping.tf`, `cloudRun.tf`, `budget.tf`, `apis.tf`): el
  de la IP global era el único desalineado.

### Eliminado

Cuatro piezas de configuración que no producían ningún efecto. Todas parecían
palancas reales al leer el código, y ese era el problema: invitaban a cambiarlas
esperando algo, o a construir sobre ellas.

- **`var.debug` y todo `DEBUG`.** Inyectaba `DEBUG=true` en los tres servicios y
  **no aparece en ninguna parte del código**: ni en `backend/src`, ni en
  `frontend/src`, ni la consume la imagen de DSS. Eliminados la variable, el
  local `debug_env`, sus tres `merge` y las entradas de los `.tfvars`. Si algún
  día hace falta un modo verboso, se implementa primero en la aplicación.

- **`BACKEND_URL` del Cloud Run del frontend.** La imagen es nginx estático: el
  único mecanismo que lee variables es
  `docker-entrypoint.d/40-render-nginx-conf.sh`, y solo sustituye
  `BACKEND_HOST`. `BACKEND_URL` es el nombre que usan `frontend/.env.example` y
  `vite.config.ts` para el proxy del servidor de desarrollo, que no interviene
  en el contenedor desplegado. `BACKEND_HOST` es ahora la única variable del
  frontend, y `frontend_service_env` deja de necesitar un `merge`.

- **`INSTANCE_CONNECTION_NAME` del Cloud Run del backend.** Nada en
  `trustex-web` la lee (verificado con grep sobre todo el repo). El nombre de
  conexión ya viaja dentro de `DATABASE_URL` como directorio del socket
  `/cloudsql/<instancia>`, que es de donde lo toman tanto `node-postgres` como
  el motor de Prisma. `backend_derived_env` queda en dos entradas.

- **`var.frontend_dpp_base_url`.** Declarada "para que toda la configuración
  viva en un sitio", pero Terraform no podía actuar sobre ella: Vite incrusta
  las `VITE_*` en el bundle durante el build, así que un `apply` tras cambiarla
  no producía ningún cambio. Peor, el `Makefile` tenía el valor duplicado y
  hardcodeado, con lo que los dos podían divergir en silencio. `DPP_BASE_URL` en
  el `Makefile` es ahora la única fuente:

  ```bash
  make build-frontend DPP_BASE_URL=https://otro.dominio.eu
  ```

  El `Makefile`, `variables.tf` y los `.tfvars` explican en su sitio por qué no
  hay variable de Terraform para esto, para que nadie la vuelva a añadir.

También se limpió el bloque `dynamic "env"` del contenedor de DSS, que ahora no
itera sobre nada, y las menciones a las variables retiradas en
`secrets/backend.example`, `secrets/README.md`, `infraestructura.md`,
`apps-y-servicios.md` y `variables-de-entorno.md`.

- **`servicenetworking.googleapis.com`** de `apis.tf`. Solo hace falta para IP
  privada de Cloud SQL, que esta infraestructura no usa: se conecta por el
  socket Unix del conector integrado de Cloud Run, precisamente para evitar el
  coste de un VPC connector. Como `disable_on_destroy = false`, quitarla de
  Terraform no la deshabilita en el proyecto; simplemente deja de gestionarse.

  `billingbudgets.googleapis.com` y `monitoring.googleapis.com` se habilitan
  ahora de forma condicional, solo cuando se pide un presupuesto.

### Documentación

- **Nuevo `docs/variables-de-entorno.md`.** La configuración de este sistema
  tiene cuatro orígenes que se comportan de forma distinta, y estaba repartida
  entre comentarios de `locals.tf`, los ficheros `*.example` y dos documentos
  que hablan de otra cosa. El documento los mapea, tabla por servicio, y explica
  las trampas: qué se incrusta en el bundle en build y por tanto no cambia con un
  `apply`, qué deriva Terraform y no debes escribir, qué está reservado por Cloud
  Run, en qué orden gana un `merge`, y qué comprueba Terraform antes de
  desplegar. Enlazado desde el `README`, `infraestructura.md` y
  `apps-y-servicios.md`.

  Tres cosas que salieron al escribirlo y que no estaban dichas en ningún sitio:

  - **`frontend_dpp_base_url` no hace nada en Terraform.** No llega a Cloud Run;
    la consume el Makefile como `--build-arg`. Y el Makefile la tiene
    hardcodeada en `DPP_BASE_URL ?=` en vez de leerla del `.tfvars`, así que las
    dos pueden divergir en silencio. La forma fiable de cambiarla es
    `make build-frontend DPP_BASE_URL=...`.
  - **`DEBUG` no lo lee nadie.** `var.debug = true` la inyecta en los tres
    servicios y no aparece en `backend/src`, ni en `frontend/src`, ni la consume
    la imagen de DSS. Es un gancho sin implementar.
  - **`FRONTEND_URL` tiene `http://localhost:3000` como valor por defecto** en
    `env.ts`, así que sin configurar deja el CORS del backend abierto a localhost
    en producción. Casi nunca importa porque la SPA va same-origin por el proxy,
    pero conviene saberlo.

- **Ajustado el comentario de `frontend_service_env`** en `locals.tf`. Afirmaba
  que `BACKEND_URL` es "the origin the app config uses", lo cual solo es cierto
  en desarrollo: la imagen desplegada es nginx estático, sin proceso que lea
  variables de entorno, y el entrypoint solo sustituye `BACKEND_HOST`. El
  comentario dice ahora cuál de las dos hace el trabajo y por qué la otra sigue
  ahí.

- Los comentarios sobre `dss_public_invoker` en `terraform.tfvars`,
  `terraform.tfvars.example`, `variables.tf` y `cloudRun.tf` decían que
  `dss-client.ts` llamaba a DSS con un `fetch` pelado y que había que poner la
  variable en `true` o la validación devolvería 403. Está desactualizado:
  verificado en `trustex-web` (commit `e5f615a`), el cliente obtiene un ID token
  con `google-auth-library` y lo envía como `Authorization: Bearer`, con
  fallback sin cabecera solo donde no hay forma de conseguirlo (docker-compose
  local, que no tiene IAM delante). `dss_public_invoker = false` es correcto tal
  cual; `true` queda como apaño de depuración. `docs/apps-y-servicios.md` §2.2 ya
  lo describía bien.

### Pendiente — decisiones que no se han tomado aquí

- **El estado de Terraform es local y contiene secretos en claro.** Lo advierte
  el comentario de `locals.tf`: `DB_PASSWORD`, `JWT_SECRET`,
  `BLOCKCHAIN_PRIVATE_KEY` y `PINATA_JWT` acaban en el `.tfstate`. Hoy eso es un
  fichero en un portátil, sin versionado ni bloqueo concurrente. Lo razonable es
  un backend GCS (céntimos al mes), pero requiere crear el bucket antes que el
  backend que lo usa y migrar el estado con `terraform init -migrate-state`, así
  que no se ha hecho sin decidirlo:

  ```bash
  gsutil mb -l europe-west1 gs://trustex-tfstate-<sufijo>
  gsutil versioning set on gs://trustex-tfstate-<sufijo>
  ```

  ```hcl
  # providers.tf, dentro del bloque terraform { }
  backend "gcs" {
    bucket = "trustex-tfstate-<sufijo>"
    prefix = "infra"
  }
  ```

- **La IP pública de Cloud SQL se factura.** `ipv4_enabled = true` es necesario
  para el conector de Cloud Run, no es un error, pero desde 2024 GCP cobra las
  IPv4 públicas (~7 $/mes). Sumada a los ~9 $ de la `db-f1-micro` son ~16 $ antes
  de tocar nada más, con lo que el margen sobre los 20-25 $ es más estrecho de lo
  que sugieren los comentarios de `database.tf`. Conviene contrastarlo en la
  calculadora de GCP; la alternativa (IP privada) exige un VPC connector que
  cuesta lo mismo o más.

- **`disk_autoresize = false` con 10 GB y sin alerta.** Si el disco se llena, la
  base de datos deja de aceptar escrituras sin aviso previo. Es una decisión de
  presupuesto deliberada, pero merece al menos una alerta de Cloud Monitoring.

- **El backend es público (`allUsers`).** Está justificado y documentado: nginx
  hace de proxy sin credenciales. Implica que la API es alcanzable directamente
  saltándose el frontend, y que su JWT + rate limiting son la única defensa.

- **Nadie puede leer el secreto de Secret Manager.** `secrets.tf` guarda una
  copia de `DB_PASSWORD` pero ninguna cuenta de servicio tiene
  `roles/secretmanager.secretAccessor`. Funciona como break-glass porque lo lees
  con tus permisos de owner; si algún día una aplicación debe leerlo, falta el
  binding.

### Acción requerida antes del primer apply

`terraform/secrets/backend` y `terraform/secrets/postgres` están **vacíos** y no
hay ningún `*.age` en el repositorio, así que `make secrets-decrypt` no tiene
nada que descifrar. El plan se detiene en la precondición de `google_sql_user`.
Hay que rellenar `DB_PASSWORD` y las siete variables obligatorias del backend
(`JWT_SECRET`, `BLOCKCHAIN_RPC_URL`, `BLOCKCHAIN_PRIVATE_KEY`,
`FACTORY_CONTRACT_ADDRESS`, `FORWARDER_CONTRACT_ADDRESS`, `PINATA_JWT`,
`WALLET_ENCRYPTION_KEY`) partiendo de los `*.example`, y luego
`make secrets-encrypt` para versionar los `.age`.
