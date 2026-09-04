# Secrets (cifrados con age)

Todas las variables de entorno viven en **dos ficheros**, y son los dos únicos
que se cifran:

| Fichero | Contenido | Se sube a git |
|---|---|---|
| `backend` | Entorno del Cloud Run del backend | **No** (texto claro) |
| `postgres` | Entradas con las que Terraform crea Cloud SQL | **No** (texto claro) |
| `backend.age` | `backend` cifrado | Sí |
| `postgres.age` | `postgres` cifrado | Sí |

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

Para añadir un tercer fichero de secretos hay que declararlo en la lista
`ManagedFiles` / `MANAGED_FILES` de `scripts/secrets.ps1` y `scripts/secrets.sh`.

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
file        plaintext  encrypted
----        ---------  ---------
backend     yes        yes
postgres    no         yes
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
| `backend`, `postgres` | **No** (texto claro) |

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
