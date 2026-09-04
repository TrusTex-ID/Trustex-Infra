# Balanceador de carga y VPC en Trustex: qué aportan y qué cuestan

Documento de decisión para la infraestructura de `terraform/`. Responde a dos preguntas:

1. ¿Qué influye tener un load balancer y por qué ahora está desactivado?
2. El backend de Node y el servicio DSS deben hablarse entre ellos, ¿interesa meter una VPC? ¿Tiene coste?

Presupuesto objetivo del proyecto: **20–25 $/mes**. Ese límite es el que decide casi todo lo que viene a continuación.

---

## 1. Load balancer

### 1.1 Lo que ya tienes sin balanceador

Cloud Run no es como una VM: cada servicio ya viene con una capa de entrada gestionada por Google. Sin añadir nada, ya tienes:

- **URL HTTPS pública** del tipo `https://trustex-dev-frontend-xxxx.a.run.app`.
- **Certificado TLS gestionado y renovado** por Google, gratis.
- **Balanceo entre instancias** del propio servicio: Cloud Run reparte las peticiones entre las réplicas que va creando (hasta `cloud_run_max_instances`).
- **Autoescalado desde cero**, incluido escalar a 0 cuando no hay tráfico.
- **Terminación TLS y HTTP/2** en los frontales de Google, cerca del usuario.

Es decir: la función que la gente asocia a "balanceador" (repartir carga entre réplicas) **ya la hace Cloud Run**. Un load balancer de GCP delante de Cloud Run no se pone para balancear; se pone por otras razones.

### 1.2 Lo que añade un load balancer (y solo se consigue con él)

| Capacidad | Por qué importa |
|---|---|
| **Un único dominio para frontend y API** | Servir `app.trustex.eu/` (frontend) y `/api/*` (Node) desde el mismo host. Esto es enrutado por path, y sin LB solo se consigue con el proxy de nginx del propio frontend. |
| **Elimina CORS y evita exponer URLs `run.app`** | Al estar todo bajo el mismo origen, el navegador no hace peticiones cross-origin. |
| **IP estática anycast** | Necesaria si un tercero (banco, pasarela, cliente corporativo) tiene que meter tu IP en una allowlist. |
| **Cloud Armor (WAF)** | Reglas de bloqueo, rate limiting, protección OWASP, mitigación DDoS de capa 7. Solo se puede enganchar a un LB. |
| **Cloud CDN** | Caché en el edge para el bundle estático de la SPA. Reduce coste de egress y latencia. |
| **Certificados propios** | Si necesitas subir tu propio certificado en lugar del gestionado por Google. |
| **Dominio propio en cualquier región** | Ver el punto 1.4, que es importante para este proyecto. |
| **Multi-región** | Repartir tráfico entre regiones con una sola IP. Hoy no aplica: todo está en una región. |

### 1.3 Lo que cuesta

Aquí está el motivo real de que esté desactivado. El precio del balanceador **no depende del tráfico**, es una cuota fija por existir:

| Concepto | Precio | Al mes (730 h) |
|---|---|---|
| Regla de reenvío global (primeras 5) | 0,025 $/hora | **~18,25 $** |
| Regla de reenvío regional | 0,018 $/hora | ~13,14 $ |
| Datos procesados por el LB | 0,008 $/GiB (entrada y salida) | Despreciable a este volumen |
| Certificado gestionado, URL map, backend services, NEGs | 0 $ | 0 $ |

Dos matices importantes:

- **Las primeras 5 reglas globales se cobran como un único paquete de 0,025 $/hora.** La configuración de `loadBalancer.tf` crea 2 reglas (una en el 443 y otra en el 80 para redirigir a HTTPS), pero ambas caben en ese paquete: se paga ~18,25 $/mes en total, no el doble.
- El cargo es **por proyecto y por tipo de regla** (global y regional se contabilizan por separado).

### 1.4 El conflicto con el presupuesto

El desglose aproximado del proyecto tal como está configurado hoy:

| Componente | Estimación mensual |
|---|---|
| Cloud SQL `db-f1-micro`, 10 GB HDD, zonal | ~9–12 $ |
| Cloud Run (3 servicios, `min_instances = 0`) | ~0–3 $ |
| Artifact Registry (pocos GB) | ~0,5 $ |
| Secret Manager | ~0,1 $ |
| **Subtotal** | **~10–16 $** |
| **+ Load balancer global** | **+18,25 $** |
| **Total con LB** | **~28–34 $** |

Con el balanceador te sales del límite de 25 $/mes, y te sales por una cuota fija que pagas aunque nadie visite la aplicación. Por eso `enable_load_balancer` tiene `default = false`: el código está escrito y listo, pero no se despliega hasta que la decisión de negocio lo justifique.

### 1.5 El detalle que hay que tener en cuenta sobre el dominio propio

La alternativa barata al balanceador es el **domain mapping** de Cloud Run (`domainMapping.tf`): asocias `app.trustex.com` directamente al servicio, con certificado gestionado gratis y sin cuota fija.

**Pero esa función no está disponible en todas las regiones.** Solo en: `asia-east1`, `asia-northeast1`, `asia-southeast1`, `europe-north1`, `europe-west1`, `europe-west4`, `us-central1`, `us-east1`, `us-east4`, `us-west1`.

La región por defecto del repo es `europe-southwest1` (Madrid), que **no está en esa lista**. Esto deja tres caminos:

| Opción | Coste extra | Consecuencia |
|---|---|---|
| Quedarse en Madrid, usar las URLs `run.app` | 0 $ | Sin dominio propio. Válido para desarrollo y demos. |
| Mover la región a `europe-west1` (Bélgica) | 0 $ | Dominio propio con certificado gratis. Latencia desde España ~10–20 ms peor, irrelevante para una app web. |
| Quedarse en Madrid y activar el LB | +18,25 $/mes | Dominio propio, y además Cloud Armor, CDN y enrutado por path. |

Para producción con dominio propio y presupuesto ajustado, **mover la región a `europe-west1` es la opción con mejor relación coste/beneficio**. Hay que decidirlo antes del primer `apply`: cambiar de región después implica recrear la base de datos y migrar los datos.

### 1.6 Cuándo activar el balanceador

Activa `enable_load_balancer = true` cuando se cumpla alguna de estas condiciones:

- Vas a producción real con usuarios externos y necesitas WAF o rate limiting.
- Un tercero exige una IP fija en allowlist.
- Quieres todo bajo un mismo dominio y path (`/api`) en lugar de tres URLs distintas.
- El tráfico de estáticos justifica CDN.
- El presupuesto sube por encima de ~35 $/mes.

Cómo activarlo:

```hcl
enable_load_balancer = true
lb_domains           = ["app.trustex.com"]
```

Las dos van juntas: con `enable_load_balancer = true` y `lb_domains` vacío no
hay certificado ni regla de forwarding, así que Terraform rechaza el plan en vez
de construir medio balanceador. Y es incompatible con `frontend_custom_domain`,
porque activar el balanceador cierra el ingress de Cloud Run al propio
balanceador —si no, las URLs `run.app` seguirían respondiendo y cualquiera podría
esquivarlo— y eso rompe el domain mapping. Terraform también lo rechaza.

Si buscas el punto intermedio, un **balanceador regional** (`EXTERNAL_MANAGED` regional) baja la cuota a ~13 $/mes y sigue permitiendo Cloud Armor. Pierdes la IP anycast global y el multi-región, que hoy no usas. Requiere modificar `loadBalancer.tf` para usar recursos regionales.

---

## 2. VPC para la comunicación Node ↔ DSS

### 2.1 Respuesta corta

**No hace falta VPC, y meterla ahora solo añadiría complejidad.** Dos servicios de Cloud Run se comunican entre sí llamando directamente a la URL HTTPS del otro, con autenticación por IAM. Es lo que ya está cableado en `cloudRun.tf`:

```137:140:terraform/cloudRun.tf
      env {
        name  = "JAVA_SERVICE_URL"
        value = google_cloud_run_v2_service.dss.uri
      }
```

Y el dato que cierra la discusión de coste: según la documentación de Google, **no hay cargos de red para el tráfico entre dos servicios de Cloud Run en la misma región**. Node hablando con DSS cuesta 0 $ en red, tanto ahora como con volumen alto, siempre que ambos estén en la misma región (lo están: los dos usan `var.region`).

### 2.2 Cómo debe hacerse esa comunicación (seguridad sin VPC)

La protección no viene de la red, viene de IAM. El servicio DSS no debería ser invocable por cualquiera; solo por la cuenta de servicio del backend de Node.

Hoy los tres servicios están públicos. El frontend y el backend lo necesitan (el navegador y el proxy de nginx llegan sin credenciales). DSS no: nadie lo llama desde el navegador. Lo correcto es:

1. **No dar `run.invoker` a `allUsers`** en el servicio DSS: es exactamente lo que hace `dss_public_invoker = false`.
2. **Dar `run.invoker` solo a la cuenta de servicio de Node** (`google_service_account.backend`).
3. En el código Node, obtener un **ID token de OIDC** con el claim `aud` igual a la URL del servicio DSS, y enviarlo en la cabecera `Authorization: Bearer <token>`. Las librerías cliente de Google (`google-auth-library` en Node) lo hacen en una línea, obteniendo el token del metadata server. El sitio es `backend/src/verification/dss-client.ts`, que hoy hace un `fetch` sin cabecera de autorización: mientras siga así, `dss_public_invoker` tiene que quedarse en `true`.

El resultado es equivalente en seguridad a una red privada: el tráfico se queda dentro de la red de Google y solo una identidad concreta puede invocar el servicio. Coste: 0 $.

### 2.3 Qué costaría meter una VPC

La VPC en sí es gratis, pero conectar Cloud Run a ella no siempre lo es:

| Elemento | Coste |
|---|---|
| La red VPC, subredes, rutas, reglas de firewall | **0 $** |
| **Direct VPC egress** (método moderno) | **0 $ de infraestructura.** Solo pagas el tráfico, y escala a cero como el servicio. |
| **Serverless VPC Access connector** (método antiguo) | **Instancias siempre encendidas**, facturadas como VMs de Compute Engine. Se cobran aunque no pase tráfico y aunque el servicio esté a cero. Del orden de 7–10 $/mes. |
| **Cloud NAT** (si el servicio con VPC además necesita salir a internet) | Cargo por gateway y por GB procesado. |
| **IP privada en Cloud SQL** (Private Service Access) | 0 $ de peering, pero obliga a que Cloud Run entre por VPC. |

El error clásico de presupuesto en Cloud Run es crear un **connector**: es una cuota fija permanente que, sumada a Cloud SQL, se come el margen igual que el balanceador. Si algún día hace falta VPC, hay que usar **Direct VPC egress**, no connector.

### 2.4 Por eso la base de datos está conectada como está

`cloudRun.tf` no usa VPC para llegar a Postgres. Usa el **conector nativo de Cloud SQL** de Cloud Run: un socket Unix montado en `/cloudsql/<connection_name>`, con autorización por IAM (`roles/cloudsql.client`).

```73:79:terraform/cloudRun.tf
    # Built-in Cloud SQL connector (Unix socket at /cloudsql/INSTANCE)
    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [local.cloudsql_connection_name]
      }
    }
```

Esto evita el connector de VPC y su coste fijo. El tráfico no sale a internet: va cifrado por la red de Google. La IP pública de la instancia está habilitada pero **sin redes autorizadas**, así que nadie puede conectarse a Postgres directamente desde fuera. Nota de coste: Google aplica un cargo pequeño por la IPv4 pública **mientras la instancia está apagada** (del orden de 0,01 $/hora); con la instancia en marcha, como es el caso, no se paga por la IP.

### 2.5 Cuándo sí necesitarías VPC

Vale la pena meterla si aparece alguno de estos requisitos:

- **Cumplimiento normativo** que exija `ingress = internal`, es decir, que el servicio no tenga ninguna puerta pública. Ojo: aquí hay una trampa. Con `ingress = internal`, una llamada de Cloud Run a Cloud Run **no se considera interna** salvo que la enrutes por la VPC. Hay que configurar Direct VPC egress en el llamante y una zona privada de Cloud DNS que resuelva `run.app` hacia los rangos de `private.googleapis.com`. Es la configuración más compleja de todo este documento, y por eso no se hace "por si acaso".
- **Cloud SQL solo con IP privada**, sin IP pública en absoluto.
- **Conexión a on-premise** por Cloud VPN o Interconnect.
- **IP de salida fija** para llamar a APIs de terceros con allowlist (requiere VPC + Cloud NAT).
- **Acceso a recursos que solo viven en la VPC**: Memorystore/Redis, GKE interno, VMs privadas.

### 2.6 Recomendación

Para el estado actual del proyecto:

- **No metas VPC.** Node ↔ DSS por URL HTTPS + ID token de IAM: gratis, simple y seguro.
- **Endurece IAM**: quita el acceso público del servicio DSS en cuanto el backend firme la llamada. El backend de Node sí tiene que seguir público mientras el proxy de nginx del frontend le llame sin credenciales.
- Si en el futuro hace falta red privada, usa **Direct VPC egress**, nunca un Serverless VPC Access connector.

---

## 3. Resumen de decisiones

| Pregunta | Decisión | Motivo |
|---|---|---|
| ¿Load balancer? | **No por ahora** (`enable_load_balancer = false`) | Cuota fija de ~18,25 $/mes que rompe el presupuesto de 25 $ sin aportar nada que Cloud Run no dé ya |
| ¿Cómo servir un dominio propio? | Domain mapping, **cambiando la región a `europe-west1`** | Gratis; en `europe-southwest1` esa función no existe |
| ¿VPC para Node ↔ DSS? | **No** | Cloud Run a Cloud Run en la misma región no tiene coste de red y se protege con IAM |
| ¿Cómo se protege el servicio DSS? | IAM: `run.invoker` solo para la SA del backend + ID token (`dss_public_invoker = false`) | Equivalente a red privada, coste 0 |
| ¿Cómo se conecta a Postgres? | Conector nativo de Cloud SQL (socket Unix) | Evita el coste fijo del connector de VPC |
| Si algún día hace falta VPC | Direct VPC egress | Escala a cero; el connector se cobra siempre |

### Fuentes

- [Precios de red de Google Cloud](https://cloud.google.com/vpc/network-pricing) — reglas de reenvío y datos procesados
- [Autenticación entre servicios de Cloud Run](https://cloud.google.com/run/docs/authenticating/service-to-service) — sin cargos de red en la misma región
- [Direct VPC egress frente a connectors](https://cloud.google.com/run/docs/configuring/connecting-vpc) — comparativa de coste
- [Regiones de Cloud Run](https://cloud.google.com/run/docs/locations) — regiones con domain mapping
- [Redes privadas y Cloud Run](https://cloud.google.com/run/docs/securing/private-networking) — requisitos de `ingress = internal`
