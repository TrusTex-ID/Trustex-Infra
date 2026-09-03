# Infraestructura Trustex en GCP

Tres servicios en Cloud Run, un job de migraciones y una base de datos gestionada,
descritos por Terraform. Todo escala a cero, y esa es la decisión que sostiene el
presupuesto de 20–25 $/mes.

Este documento da la vista de conjunto. El detalle técnico de cada pieza —
variables de Terraform, contrato de cada `Dockerfile`, comandos exactos— vive en
[apps-y-servicios.md](apps-y-servicios.md); la justificación de por qué no hay
balanceador ni VPC vive en [red-balanceador-y-vpc.md](red-balanceador-y-vpc.md).

---

## 1. El camino de una petición

El navegador solo conoce una URL: la del frontend. Todo lo demás cuelga por
detrás. Esa forma no es casual — es lo que permite prescindir de un balanceador
de carga y de una VPC, los dos gastos que se llevarían el presupuesto por
delante.

```
Navegador ──HTTPS pública──▶ Frontend (nginx, SPA)
                                   │
                                   │ /api/v1  (mismo origen, sin CORS)
                                   ▼
                              Backend (Express + Prisma)
                                   │                    │
                                   │ ID token / IAM      │ socket /cloudsql
                                   ▼                    ▼
                              DSS (Tomcat, eIDAS)   Cloud SQL (Postgres)
                                                         ▲
                                                         │ prisma migrate deploy
                                            Job de setup ┘ (se lanza a mano)
```

Los dos saltos que sostienen el presupuesto son el proxy de nginx
(`/api/v1` → backend, evita un balanceador global de ~18 $/mes) y el socket de
Cloud SQL (backend/job → base de datos, evita un conector de VPC Access de
~7 $/mes). El job de setup no está en el camino de ninguna petición: se lanza a
mano cuando hay migraciones nuevas.

---

## 2. Los cuatro artefactos

Cada uno es una imagen Docker distinta, con su propio `Dockerfile` y su propia
etiqueta en Artifact Registry. Ninguno comparte cuenta de servicio con otro.

| Servicio | Qué es | Puerto | Recursos | BD |
|---|---|---|---|---|
| `frontend` | SPA de React + Vite compilada a estáticos y servida por nginx | 80 | 1 vCPU · 512 MiB | — |
| `backend` | API Express con Prisma; emite los DPP y firma en blockchain | 8080 | 1 vCPU · 512 MiB | sí |
| `dss` | Validador de firmas cualificadas de la Comisión Europea, sobre Tomcat | 8080 | 2 vCPU · 4 GiB | — |
| `setup` (Cloud Run Job) | Aplica migraciones de Prisma y termina | — | 1 vCPU · 512 MiB | sí |

Y las piezas gestionadas que los rodean:

- **Cloud SQL** — Postgres 15 en `db-f1-micro`, disco HDD de 10 GB, una sola
  zona y copias de seguridad diarias con tres retenidas. Es la única pieza que
  cuesta dinero estando parada, y por eso es la que fija el suelo del
  presupuesto.
- **Artifact Registry** — un repositorio Docker con política de limpieza:
  conserva las cinco versiones más recientes y borra lo no etiquetado a los 30
  días.
- **Secret Manager** — guarda una copia de la contraseña de la base de datos
  para acceso de emergencia.
- **Certificados y dominio** — Cloud Run ya da HTTPS con certificado
  gestionado en `*.run.app`. Un dominio propio se enchufa con un domain
  mapping, que también es gratis y es la razón de estar en `europe-west1`.

---

## 3. Cómo se encuentran unos a otros

Ninguna URL ni credencial se escribe a mano en un fichero de configuración.
Terraform las deriva de la propia infraestructura y las inyecta, de modo que un
valor viejo no pueda apuntar la aplicación a una instancia equivocada.

- **`DATABASE_URL`** — se construye a partir del usuario y la contraseña de
  Cloud SQL más el nombre de conexión de la instancia:
  `?host=/cloudsql/<instancia>`. La leen tanto el pool del backend como
  `prisma migrate deploy` en el job, así que hay una sola cadena de conexión
  en todo el sistema.
- **`BACKEND_URL` / `BACKEND_HOST`** — la URL del Cloud Run del backend,
  entregada al frontend para que nginx sepa a dónde mandar `/api/v1`. Al ir
  por el mismo origen, las cookies de sesión son de primera parte y no hay
  CORS.
- **`DSS_VALIDATION_URL`** — la URL del Cloud Run de DSS, entregada al
  backend. Es una llamada servidor a servidor dentro de la misma región: sin
  coste de red y sin salir a internet por una VPC.

Las variables que sí son secretos —claves JWT, credenciales de blockchain,
tokens de Pinata y Scantrust— viven en dos ficheros cifrados con `age` que sí
se pueden subir a git. Antes de cada `apply`, Terraform comprueba que estén
todas las obligatorias: si falta una, avisa en el plan en lugar de dejar que la
revisión falle en silencio al arrancar.

---

## 4. DSS no falla: se equivoca

El validador de firmas europeo es la pieza que más condiciona la
configuración, y no por su tamaño. Mientras no ha cargado las listas de
confianza de la UE, responde `200 OK` pero califica una firma como `AdESig` en
lugar de `QESig`. No da error: da la respuesta equivocada, en silencio.

De ahí salen tres decisiones que parecen arbitrarias y no lo son. El caché de
listas de confianza viaja horneado dentro de la imagen, para que se cargue en
el arranque, que es cuando Cloud Run concede CPU completa. Las sondas apuntan
a `/health` y nunca a `/health/ready`, porque el `503` de este último durante
la carga se leería como contenedor muerto y lo reiniciaría en bucle. Y el
contenedor recibe 4 GiB sin fijarle el heap a mano: la imagen lo calcula como
el 70 % del límite, y un `-Xmx` escrito desde Terraform desharía ese cálculo.

| | Modo A — escala a cero (configurado) | Modo B — siempre caliente |
|---|---|---|
| Instancias | 0 mínimo, 2 máximo | 1 mínimo, 3 máximo |
| CPU | limitada entre peticiones | siempre asignada |
| Arranque | 40–90 s en frío | ninguno |
| Coste | prácticamente nulo | 90–120 $/mes |

Los dos modos se eligen con una sola variable, `dss_min_instances`, porque
pedir instancia caliente sin fijar también la CPU es una trampa: el refresco
de las listas corre en un hilo de fondo que se congela en cuanto la CPU se
limita. Las dos opciones solo tienen sentido juntas, así que Terraform las
mueve a la vez.

---

## 5. Quién puede llamar a quién

Cada servicio corre con su propia cuenta de servicio y solo con los permisos
que necesita: el frontend no puede tocar la base de datos, y DSS tampoco,
porque no la usa.

- **Frontend y backend, públicos.** El navegador llega sin credenciales al
  primero, y el proxy de nginx llega sin credenciales al segundo. La
  autenticación real del backend es su cookie JWT, más un limitador de
  peticiones.
- **DSS, privado.** Solo la cuenta de servicio del backend tiene permiso de
  invocación. Importa más de lo que parece: además del validador, esa imagen
  sirve una interfaz web, Swagger, los servicios SOAP y un endpoint de firma
  con un almacén de claves de demostración cuya contraseña es pública.
- **Base de datos, sin puerta a internet.** No hay redes autorizadas: se
  entra por el conector de Cloud SQL, nunca por IP.

---

## 6. Dónde va el dinero

El objetivo son 20–25 $ al mes. Lo que lo hace posible es que el cómputo solo
se cobra mientras hay una petición en vuelo; la base de datos es lo único que
corre siempre.

| Recurso | Coste aproximado |
|---|---|
| Cloud SQL (`db-f1-micro`, 10 GB HDD, una zona) | 8–12 $ |
| Cloud Run (tres servicios y un job, todos a cero en reposo) | 1–3 $ |
| Artifact Registry (cinco versiones por imagen) | < 1 $ |
| Secret Manager, TLS, dominio (incluidos en la plataforma) | ~0 $ |
| **Estimado al mes** | **10–16 $** |

Lo que rompe el presupuesto, de mayor a menor impacto:

- **DSS en modo B: +90–120 $.** Una instancia de 2 vCPU y 4 GiB encendida las
  24 horas.
- **Balanceador global: +18 $.** Solo la regla de reenvío ya cuesta eso, use
  tráfico o no.
- **Conector de VPC Access: +7 $.** Innecesario: Cloud Run habla con Cloud SQL
  por socket y con DSS por HTTPS.

---

## 7. Puesta en marcha

El registro está vacío hasta que se sube la primera imagen, así que el primer
`apply` arranca con contenedores de prueba y se repite después con las
etiquetas reales.

1. `make secrets-decrypt` — recupera en claro los dos ficheros de secretos.
   Necesita la clave privada del equipo.
2. `make tf-init tf-apply` — crea registro, base de datos, cuentas de servicio
   y los servicios con imágenes de prueba.
3. `make dss-lotl-up` → `make dss-lotl-save` — pre-calienta el caché de listas
   de confianza para que viaje dentro de la imagen de DSS.
4. `make build-all push-all TAG=0.1.0` — construye y sube las cuatro
   imágenes. La de DSS compila con Maven: 10–20 minutos la primera vez.
5. `make tf-apply` — segunda pasada, ya con las etiquetas reales en
   `terraform.tfvars`.
6. `make db-setup` — lanza el job de migraciones. Se repite en cada
   despliegue que traiga cambios de esquema.
7. `make dss-ready` — confirma que DSS ya califica de verdad. Un
   `state: READY` es lo que valida el despliegue.

---

## 8. Dos cosas que faltan en el código

La infraestructura está completa, pero hay dos piezas que solo se pueden
arreglar en `trustex-web`. Conviene cerrarlas antes del primer despliegue
real: sin la primera, la API no responde.

**nginx apunta al nombre de docker-compose (bloqueante).** La configuración
del frontend manda `/api/v1` a `http://backend:4000` y reenvía la cabecera
`Host` del propio frontend. En Cloud Run, que enruta precisamente por esa
cabecera, eso devuelve un 404. Hay que generar la configuración al arrancar el
contenedor a partir del `BACKEND_HOST` que Terraform ya inyecta.
Síntoma: la SPA carga, pero toda llamada a la API da 502.

**El backend llama a DSS sin identificarse (bloqueante).** Con DSS cerrado
por IAM, el cliente tiene que mandar un ID token de OIDC. Terraform ya le ha
dado el permiso a la cuenta de servicio del backend; falta que el código lo
pida al servidor de metadatos — unas pocas líneas con `google-auth-library`,
sin credenciales escritas en el repositorio.
Síntoma: la validación de firmas responde 403. Apaño temporal: abrir DSS al
público (`dss_public_invoker = true`).
