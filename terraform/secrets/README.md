# Secrets (cifrados con age)

Se cifran **cuatro ficheros**, todos dentro de `terraform/`. Los dos de este
directorio contienen las variables de entorno; los otros dos son la
configuración y el estado de Terraform:

| Fichero (desde `terraform/`) | Contenido | Se sube a git |
|---|---|---|
| `secrets/backend` | Entorno del Cloud Run del backend | **No** (texto claro) |
| `secrets/postgres` | Entradas con las que Terraform crea Cloud SQL | **No** (texto claro) |
| `terraform.tfvars` | Valores de las variables de Terraform | **No** (texto claro) |
| `terraform.tfstate` | Estado de Terraform (incluye secretos en claro) | **No** (texto claro) |
| `<fichero>.age` | Cada uno de los anteriores, cifrado | Sí |

El estado es local (no hay backend remoto), así que `terraform.tfstate.age` es
la única copia compartida: quien clone el repo y tenga `.age.key` puede
descifrarlo y operar sobre la infraestructura real. `make tf-apply` vuelve a
cifrar al terminar; después hay que **commitear el `.age`**. Si dos personas
aplican a la vez sin sincronizar, la última que suba el `.age` pisa el estado
de la otra: no hay bloqueo.

Los dos ficheros tienen papeles distintos:

- **`backend`** se inyecta tal cual como variables de entorno del Cloud Run del
  backend. El contrato exacto lo define `backend/src/config/env.ts` en
  `trustex-web`; si falta una obligatoria, la revision no arranca.
- **`postgres`** solo lo lee Terraform: con `DB_NAME`, `DB_USER` y `DB_PASSWORD`
  crea la base de datos y el usuario de Cloud SQL y construye la `DATABASE_URL`
  que reciben el backend y el job de migraciones. **No** se reenvia a ningun
  servicio, asi que no pongas ahi variables de aplicacion.

Terraform inyecta por su cuenta `DATABASE_URL` y `DSS_VALIDATION_URL`, y esos
valores ganan siempre a lo que haya en los ficheros: un valor viejo no puede
apuntar la app a otra instancia.

Para añadir otro fichero hay que declararlo en la lista `ManagedFiles` /
`MANAGED_FILES` de `scripts/secrets.ps1` y `scripts/secrets.sh` (rutas
relativas a `terraform/`) y asegurarse de que su `.age` no queda ignorado.

Los scripts comparan cada fichero con su `.age` descifrado antes de actuar:

- `encrypt` no reescribe un `.age` cuyo contenido no ha cambiado (age genera
  un cifrado distinto en cada pasada, así que si no git vería cambios falsos).
- `decrypt` **nunca sobrescribe** una copia local distinta: puede ser un
  `tfstate` posterior a un apply que aún no se ha cifrado. Si de verdad quieres
  la versión del repo, borra la local y vuelve a descifrar.
- `clean` solo borra el texto claro si coincide con su `.age`.
- `status` marca como `STALE` los `.age` desfasados.

## Requisitos

| Sistema | Instalación de age |
|---|---|
| Windows | `winget install FiloSottile.age` |
| macOS | `brew install age` |
| Linux | `apt install age` (o ver [releases](https://github.com/FiloSottile/age#installation)) |

`make` funciona igual en Windows, macOS y Linux: internamente llama a
`scripts/secrets.ps1` en Windows y a `scripts/secrets.sh` en el resto.

## Flujo

```bash
# 1) Una sola vez: generar el par de claves
make secrets-keygen

# 2) Rellenar los dos ficheros (usa los *.example como plantilla)

# 3) Cifrar antes de commit
make secrets-encrypt

# 4) Borrar el texto claro del disco (opcional)
make secrets-clean

# 5) En otro PC / CI: recuperar el texto claro (necesitas .age.key)
make secrets-decrypt

# Ver el estado en cualquier momento
make secrets-status
```

`make secrets-status` muestra exactamente qué hay:

```
file                plaintext  encrypted
----                ---------  ---------
secrets/backend     yes        yes
secrets/postgres    no         yes
terraform.tfvars    yes        yes
terraform.tfstate   yes        STALE (run make secrets-encrypt)
```

Si no tienes `make`, llama al script directamente:

```powershell
.\scripts\secrets.ps1 keygen      # Windows
```

```bash
./scripts/secrets.sh keygen       # macOS / Linux
```

## Qué se committea

| Archivo | Git |
|---|---|
| `.age.pubkey` | Sí (clave pública) |
| `*.age` | Sí (secretos cifrados) |
| `*.example` | Sí (plantillas) |
| `.age.key` | **No** (clave privada) |
| `backend`, `postgres`, `terraform.tfvars`, `terraform.tfstate` | **No** (texto claro) |
| `terraform.tfstate.backup` y similares | **No** |

Guarda `.age.key` en un gestor de contraseñas o en un sitio seguro del equipo.
Sin ella los `*.age` son irrecuperables.

> **Importante:** el `.gitignore` no protege ficheros que ya estén *trackeados*
> en git. Si añades un fichero de secretos nuevo, comprueba que git lo ignora:
> `git check-ignore -v terraform/secrets/<fichero>`. Si no lo ignora, ejecuta
> `git rm --cached terraform/secrets/<fichero>` antes de escribir nada real.

## Subir un secreto a GCP Secret Manager

```bash
make secrets-decrypt
make secrets-push FILE=backend SECRET=trustex-dev-backend
make secrets-push FILE=postgres SECRET=trustex-dev-postgres
```
