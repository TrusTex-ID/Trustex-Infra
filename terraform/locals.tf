locals {
  name_prefix = "trustex-${var.environment}"

  common_labels = {
    project     = "trustex"
    environment = var.environment
    managed_by  = "terraform"
  }

  # Cloud SQL connection name used by Cloud Run's built-in Unix socket connector.
  # Avoids a Serverless VPC Access connector (~$7+/month), which helps the budget.
  cloudsql_connection_name = google_sql_database_instance.main.connection_name

  # Built from variables, not from the repository resource, so image names stay
  # known at plan time even before the registry exists.
  artifact_registry_repository_id = "trustex"
  artifact_registry_url           = "${var.region}-docker.pkg.dev/${var.project_id}/${local.artifact_registry_repository_id}"

  # A *_image override wins; otherwise the image is <registry>/<service>:<tag>.
  #
  # Which Dockerfile builds each one (see docs/apps-y-servicios.md):
  #   frontend -> trustex-web/frontend/Dockerfile   Vite SPA served by nginx
  #   backend  -> trustex-web/backend/Dockerfile    Express + Prisma
  #   dss      -> dss-validation-docker/Dockerfile  EU DSS webapp on Tomcat
  #   setup    -> trustex-web/setup/Dockerfile      Prisma migrate/seed job
  frontend_image = var.frontend_image != "" ? var.frontend_image : "${local.artifact_registry_url}/frontend:${var.frontend_tag}"
  backend_image  = var.backend_image != "" ? var.backend_image : "${local.artifact_registry_url}/backend:${var.backend_tag}"
  dss_image      = var.dss_image != "" ? var.dss_image : "${local.artifact_registry_url}/dss:${var.dss_tag}"
  setup_image    = var.setup_image != "" ? var.setup_image : "${local.artifact_registry_url}/setup:${var.setup_tag}"

  # ---------------------------------------------------------------------------
  # Env vars from terraform/secrets/{backend,postgres}.
  #
  #   postgres -> inputs Terraform needs to provision Cloud SQL (DB_NAME,
  #               DB_USER, DB_PASSWORD). NOT forwarded to any service: the apps
  #               only see the DATABASE_URL that Terraform builds from them.
  #   backend  -> environment of the Node backend service (JWT, blockchain,
  #               Pinata, Scantrust, ...). Forwarded as-is.
  #
  # Values land in plaintext in terraform state — treat the state as a secret.
  # Files are gitignored and produced by `make secrets-decrypt`.
  # ---------------------------------------------------------------------------

  secrets_env_regex = "(?m)^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(.*)$"

  backend_env_file  = "${path.module}/secrets/backend"
  postgres_env_file = "${path.module}/secrets/postgres"

  backend_env_raw  = fileexists(local.backend_env_file) ? file(local.backend_env_file) : ""
  postgres_env_raw = fileexists(local.postgres_env_file) ? file(local.postgres_env_file) : ""

  secrets_backend = {
    for pair in regexall(local.secrets_env_regex, local.backend_env_raw) :
    pair[0] => trimspace(pair[1])
  }

  secrets_postgres = {
    for pair in regexall(local.secrets_env_regex, local.postgres_env_raw) :
    pair[0] => trimspace(pair[1])
  }

  # ---------------------------------------------------------------------------
  # Database connection
  #
  # Cloud Run reaches Cloud SQL over the Unix socket its built-in connector
  # mounts at /cloudsql/<connection name>. Both database consumers read a single
  # DATABASE_URL:
  #   - runtime: the node-postgres pool in backend/src/database/prisma.service.ts
  #   - setup job: `prisma migrate deploy` via backend/prisma.config.ts
  # node-postgres and the Prisma engine both take the socket directory from the
  # `host` query parameter and ignore the host in the authority part.
  # ---------------------------------------------------------------------------

  db_name_effective     = lookup(local.secrets_postgres, "DB_NAME", "trustex")
  db_user_effective     = lookup(local.secrets_postgres, "DB_USER", "trustex")
  db_password_effective = lookup(local.secrets_postgres, "DB_PASSWORD", "")

  cloudsql_socket_dir = "/cloudsql/${local.cloudsql_connection_name}"

  # urlencode on user/password: they may legitimately contain :, @, / or #.
  database_url = join("", [
    "postgresql://",
    urlencode(local.db_user_effective),
    ":",
    urlencode(local.db_password_effective),
    "@localhost:5432/",
    local.db_name_effective,
    "?host=",
    urlencode(local.cloudsql_socket_dir),
    "&schema=public",
  ])

  # ---------------------------------------------------------------------------
  # Values Terraform derives from the infrastructure itself. They are unknown
  # until Cloud SQL / Cloud Run exist, so Terraform injects them instead of
  # asking you to copy them into the secrets files. Merged last, so they always
  # win: a stale value left in a secrets file cannot point the app at the wrong
  # instance.
  # ---------------------------------------------------------------------------

  backend_derived_env = {
    # Read by backend/src/config/database-env.ts. The instance connection name
    # is not passed separately: it is already inside this URL as the socket
    # directory, and nothing in trustex-web reads it on its own.
    DATABASE_URL = local.database_url
    # backend/src/verification/dss-client.ts appends
    # /services/rest/validation/validateSignature to this base URL.
    DSS_VALIDATION_URL = google_cloud_run_v2_service.dss.uri
  }

  # CORS origin for the browser (backend/src/common/middleware/cors.middleware.ts).
  #
  # The SPA calls /api/v1 same-origin through the frontend's nginx proxy, so CORS
  # is normally never exercised and this may stay empty. It cannot be wired to
  # google_cloud_run_v2_service.frontend.uri: the frontend already depends on the
  # backend URI (BACKEND_HOST), so that would be a dependency cycle — hence the
  # variable. Listed before the secrets files so `secrets/backend` can override.
  #
  # Not coalesce(): it rejects empty strings as well as nulls, so the "" fallback
  # is never reached and the call fails outright when neither variable is set —
  # which is the default configuration.
  frontend_public_url_effective = (
    var.frontend_public_url != "" ? var.frontend_public_url :
    var.frontend_custom_domain != "" ? "https://${var.frontend_custom_domain}" :
    ""
  )

  frontend_url_env = local.frontend_public_url_effective != "" ? {
    FRONTEND_URL = local.frontend_public_url_effective
  } : {}

  # Backend Cloud Run. On a key clash: the backend file beats the computed
  # FRONTEND_URL, and the Terraform-derived values beat everything.
  backend_service_env = merge(
    local.frontend_url_env,
    local.secrets_backend,
    local.backend_derived_env,
  )

  # The frontend image is static nginx: no application process, so the only
  # environment variable it can act on is the one its entrypoint substitutes.
  # docker-entrypoint.d/40-render-nginx-conf.sh renders BACKEND_HOST into
  # nginx.conf.template at container start and aborts if it is unset.
  #
  # A bare host, not a URL: proxy_pass supplies the scheme itself and Cloud Run
  # routes on the Host header.
  #
  # VITE_* values cannot be set here at all — Vite inlines them into the JS
  # bundle at build time, so they go through `docker build --build-arg` in
  # `make build-frontend`. See docs/variables-de-entorno.md.
  frontend_service_env = {
    BACKEND_HOST = replace(google_cloud_run_v2_service.backend.uri, "https://", "")
  }

  # Setup Cloud Run Job: database connection plus its own flags
  # (backend/src/setup/setup.config.ts).
  setup_job_env = {
    DATABASE_URL           = local.database_url
    SETUP_RUN_MIGRATIONS   = var.setup_run_migrations ? "true" : "false"
    SETUP_RUN_SEED         = var.setup_run_seed ? "true" : "false"
    SETUP_DB_WAIT_RETRIES  = tostring(var.setup_db_wait_retries)
    SETUP_DB_WAIT_DELAY_MS = tostring(var.setup_db_wait_delay_ms)
  }

  # Keys backend/src/config/env.ts requires with no default. A revision missing
  # any of them throws "Invalid environment variables" on boot, which Cloud Run
  # only surfaces as a failed health check.
  backend_required_env = [
    "JWT_SECRET",
    "BLOCKCHAIN_RPC_URL",
    "BLOCKCHAIN_PRIVATE_KEY",
    "FACTORY_CONTRACT_ADDRESS",
    "FORWARDER_CONTRACT_ADDRESS",
    "PINATA_JWT",
    "WALLET_ENCRYPTION_KEY",
  ]

  backend_missing_env = [
    for key in local.backend_required_env : key
    if lookup(local.secrets_backend, key, "") == ""
  ]

  # Cloud Run sets these itself and rejects a revision that also declares them.
  # PORT in particular is tempting to write in the secrets file — don't: Cloud
  # Run derives it from ports.container_port and src/config/env.ts reads it.
  cloudrun_reserved_env = ["PORT", "K_SERVICE", "K_REVISION", "K_CONFIGURATION"]

  backend_reserved_env_used = [
    for key in local.cloudrun_reserved_env : key
    if contains(keys(local.secrets_backend), key)
  ]
}

check "backend_env_file_present" {
  assert {
    condition     = fileexists(local.backend_env_file)
    error_message = "terraform/secrets/backend not found: the backend service will deploy without its env vars. Run `make secrets-decrypt` first."
  }
}

check "postgres_env_file_present" {
  assert {
    condition     = fileexists(local.postgres_env_file)
    error_message = "terraform/secrets/postgres not found: Cloud SQL would be created with default names and no password. Run `make secrets-decrypt` first."
  }
}

check "postgres_db_password_present" {
  assert {
    condition     = local.db_password_effective != ""
    error_message = "terraform/secrets/postgres must define DB_PASSWORD (used by Cloud SQL and to build DATABASE_URL)."
  }
}

check "backend_required_env_present" {
  assert {
    condition = length(local.backend_missing_env) == 0
    error_message = join(" ", [
      "terraform/secrets/backend is missing values required by backend/src/config/env.ts:",
      join(", ", local.backend_missing_env),
      "- the backend revision will fail to start. See terraform/secrets/backend.example.",
    ])
  }
}

check "backend_no_reserved_env" {
  assert {
    condition = length(local.backend_reserved_env_used) == 0
    error_message = join(" ", [
      "terraform/secrets/backend declares env vars reserved by Cloud Run:",
      join(", ", local.backend_reserved_env_used),
      "- remove them or the revision is rejected. PORT comes from ports.container_port.",
    ])
  }
}

check "wallet_encryption_key_length" {
  assert {
    condition = (
      lookup(local.secrets_backend, "WALLET_ENCRYPTION_KEY", "") == "" ||
      length(local.secrets_backend["WALLET_ENCRYPTION_KEY"]) == 64
    )
    error_message = "WALLET_ENCRYPTION_KEY must be 64 hex chars (32 bytes), as required by backend/src/config/env.ts."
  }
}
