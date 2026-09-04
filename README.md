# trustex-infra

Infraestructura de Trustex en Google Cloud, descrita con Terraform: Cloud Run
para el frontend, el backend y el validador de firmas DSS, un Cloud Run Job
para las migraciones, y Cloud SQL para la base de datos. Ver
[docs/infraestructura.md](docs/infraestructura.md) para la vista de conjunto,
[docs/apps-y-servicios.md](docs/apps-y-servicios.md) para el detalle técnico de
cada pieza y [docs/variables-de-entorno.md](docs/variables-de-entorno.md) para
el mapa de la configuración.

## Requisitos

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) (`gcloud`)
- [Docker](https://docs.docker.com/get-docker/), para construir las imágenes
- [age](https://github.com/FiloSottile/age#installation), para los secretos
  cifrados (ver [terraform/secrets/README.md](terraform/secrets/README.md))

En Windows, los dos primeros se instalan con `winget`:

```powershell
winget install --id Hashicorp.Terraform -e
winget install --id Google.CloudSDK -e
```

Reinicia la terminal después de instalar: el instalador actualiza el `PATH`
del sistema, pero no el de una sesión ya abierta.

## Login en gcloud

Antes de poder ejecutar `terraform plan` / `apply`, la CLI de Google Cloud
necesita dos tipos de credenciales distintos: las tuyas, para usar `gcloud`
desde la terminal, y las de "Application Default Credentials" (ADC), que son
las que leen Terraform y las librerías cliente. Son dos pasos separados y hace
falta ejecutar ambos:

```bash
# 1) Login interactivo: abre el navegador para autenticarte con tu cuenta
gcloud auth login

# 2) Fija el proyecto por defecto (el mismo que pones en terraform.tfvars)
gcloud config set project <tu-project-id>

# 3) Application Default Credentials: las que usa Terraform para hablar con la API
gcloud auth application-default login
```

Comprobar que ha funcionado:

```bash
gcloud auth list                 # cuenta activa marcada con *
gcloud config get-value project  # proyecto por defecto
```

Si vas a construir y subir imágenes Docker a Artifact Registry, hace falta
además autorizar a Docker una vez por máquina. Ese paso vive en los repos que
construyen las imágenes, no aquí:

```bash
make docker-login   # en trustex-web o en dss-validation-docker
                    # equivale a: gcloud auth configure-docker <region>-docker.pkg.dev
```

Este repo no construye imágenes: solo consume los tags que se publican allí.

## Primer despliegue

Una vez autenticado, sigue el orden de
[docs/infraestructura.md §7](docs/infraestructura.md#7-puesta-en-marcha):
secretos → `terraform init/apply` con imágenes de prueba → construir y subir
las imágenes reales → `terraform apply` final → job de migraciones. Todos los
comandos están en el `Makefile` (`make help` lista los de secretos; el propio
`Makefile` documenta el resto en su cabecera).
