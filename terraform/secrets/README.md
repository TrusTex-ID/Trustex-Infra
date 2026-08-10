# Secrets (cifrados con age)

Todas las variables de entorno viven en **dos ficheros**, y son los dos únicos
que se cifran:

| Fichero | Contenido | Se sube a git |
|---|---|---|
| `backend` | Variables del backend | **No** (texto claro) |
| `postgres` | Variables de base de datos | **No** (texto claro) |
| `backend.age` | `backend` cifrado | Sí |
| `postgres.age` | `postgres` cifrado | Sí |

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
