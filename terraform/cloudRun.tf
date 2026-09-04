# Three Cloud Run services, all scaling to zero (min_instance_count = 0) to stay
# within the ~$20–25/month budget. HTTPS is provided automatically on *.run.app.
# CPU / memory / ports / scaling / probes are fixed here — change them in this
# file. The database setup job lives in cloudRunJobs.tf.
#
# Request path: browser -> frontend (nginx) -> /api/v1 -> backend -> DSS + Cloud SQL.
# The SPA never calls the backend cross-origin; nginx proxies it same-origin.

locals {
  # Without this, enabling the load balancer would buy nothing: the services
  # would keep answering on their own *.run.app URLs, so anyone could reach them
  # directly and bypass the LB — and with it the managed certificate, the URL
  # map and anything later put in front (Cloud Armor, IAP). Closing ingress to
  # the load balancer is what makes it the only way in.
  #
  # Only for frontend and backend: DSS is never behind the LB, and its own
  # ingress must stay open because the backend calls it over the internet with
  # an ID token, not through the load balancer.
  #
  # Note this is incompatible with domainMapping.tf, which needs direct ingress.
  # The two are alternatives, as their respective comments already say.
  cloudrun_ingress = local.lb_enabled ? "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" : "INGRESS_TRAFFIC_ALL"
}

# ---------------------------------------------------------------------------
# Frontend — React/Vite SPA built to static files and served by nginx.
# The image is nginx:1.27-alpine listening on :80 (frontend/Dockerfile), not a
# Node server, so there is no NODE_ENV and no VITE_* at runtime: VITE_* values
# are inlined into the bundle at build time via --build-arg.
# ---------------------------------------------------------------------------

resource "google_cloud_run_v2_service" "frontend" {
  name     = "${local.name_prefix}-frontend"
  location = var.region
  ingress  = local.cloudrun_ingress
  labels   = local.common_labels

  template {
    service_account = google_service_account.frontend.email

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    containers {
      image = local.frontend_image

      ports {
        container_port = 80 # nginx
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      # BACKEND_HOST: nginx must resolve /api/v1 to the backend, and renders its
      # config from this at start up — see docs/apps-y-servicios.md
      # ("El proxy /api/v1 en Cloud Run").
      dynamic "env" {
        for_each = local.frontend_service_env
        content {
          name  = env.key
          value = env.value
        }
      }

      startup_probe {
        tcp_socket {
          port = 80
        }
        period_seconds    = 5
        timeout_seconds   = 3
        failure_threshold = 6
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  # The image lives in Artifact Registry and the runtime SA needs the reader role
  # before the revision can pull it. Neither is referenced in the config above.
  depends_on = [
    time_sleep.api_propagation,
    google_artifact_registry_repository.main,
    google_project_iam_member.frontend_ar_reader,
  ]
}

# ---------------------------------------------------------------------------
# Backend — Express + Prisma. Reads PORT (Cloud Run injects 8080) and connects
# to Cloud SQL through the Unix socket mounted at /cloudsql, using the
# DATABASE_URL that locals.tf builds.
# ---------------------------------------------------------------------------

resource "google_cloud_run_v2_service" "backend" {
  name     = "${local.name_prefix}-backend"
  location = var.region
  ingress  = local.cloudrun_ingress
  labels   = local.common_labels

  template {
    service_account = google_service_account.backend.email

    # Blockchain writes and IPFS pinning are slow; the default 300s is plenty
    # but leaves a long tail of billable time on a hung request.
    #
    # It cannot be shorter than what DSS needs, though: this is the outer
    # deadline of a signature validation, and in Mode A a DSS cold start alone
    # is 40-90s. At 120s the caller would be cut off before DSS ever answered,
    # and the failure would look like a backend bug. So the budget follows the
    # DSS mode, exactly as the DSS service's own timeout does.
    timeout = local.dss_always_on ? "120s" : "300s"

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    # The default is 80, which for 512Mi running Node + Prisma + blockchain and
    # IPFS calls is optimistic: 80 in-flight requests share one small heap and
    # one connection pool, against a Cloud SQL instance capped at 50 connections.
    # 40 x 2 instances is still far more than this workload will see.
    max_instance_request_concurrency = 40

    # Built-in Cloud SQL connector (Unix socket at /cloudsql/INSTANCE)
    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [local.cloudsql_connection_name]
      }
    }

    containers {
      image = local.backend_image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      # PORT is injected by Cloud Run itself and read by src/config/env.ts.
      # Everything else comes from terraform/secrets/backend plus the values
      # Terraform derives (DATABASE_URL, DSS_VALIDATION_URL).
      dynamic "env" {
        for_each = local.backend_service_env
        content {
          name  = env.key
          value = env.value
        }
      }

      # /health is registered before the JWT middleware in src/app.ts, so it
      # answers unauthenticated. It is a liveness check and does not touch the
      # database (/ready does).
      startup_probe {
        http_get {
          path = "/health"
        }
        period_seconds    = 5
        timeout_seconds   = 3
        failure_threshold = 12
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  # The same three conditions locals.tf asserts in `check` blocks, repeated here
  # as preconditions because a `check` only ever produces a warning: the apply
  # succeeds, and the breakage surfaces minutes later as a revision that fails
  # its health check with "Invalid environment variables" buried in the logs.
  # These are exactly the mistakes worth refusing to deploy over, so they belong
  # on the resource that would break. The checks stay for `terraform plan`,
  # where they report all the problems at once instead of the first one.
  lifecycle {
    precondition {
      condition = length(local.backend_missing_env) == 0
      error_message = join(" ", [
        "terraform/secrets/backend is missing values required by backend/src/config/env.ts:",
        join(", ", local.backend_missing_env),
        "- the revision would fail to start. Run `make secrets-decrypt` and see terraform/secrets/backend.example.",
      ])
    }

    precondition {
      condition = length(local.backend_reserved_env_used) == 0
      error_message = join(" ", [
        "terraform/secrets/backend declares env vars reserved by Cloud Run:",
        join(", ", local.backend_reserved_env_used),
        "- the revision would be rejected. PORT comes from ports.container_port.",
      ])
    }

    precondition {
      condition = (
        lookup(local.secrets_backend, "WALLET_ENCRYPTION_KEY", "") == "" ||
        length(local.secrets_backend["WALLET_ENCRYPTION_KEY"]) == 64
      )
      error_message = "WALLET_ENCRYPTION_KEY must be 64 hex chars (32 bytes), as required by backend/src/config/env.ts."
    }
  }

  # A revision is only healthy once it can pull its image and reach the database,
  # so the roles, the schema and the DB user must all exist first. None of them
  # are referenced in the config above, hence the explicit list.
  depends_on = [
    time_sleep.api_propagation,
    google_artifact_registry_repository.main,
    google_project_iam_member.backend_ar_reader,
    google_project_iam_member.backend_cloudsql_client,
    google_sql_database.app,
    google_sql_user.app,
  ]
}

# ---------------------------------------------------------------------------
# DSS — the EU DSS demo webapp (signature validation) on Tomcat 10.
#
# This block implements the two deployment modes documented by the service
# itself, in dss-validation-docker/docs/despliegue-en-produccion.md. Read that
# before changing anything here; the reasoning is summarised in
# docs/apps-y-servicios.md.
#
# Stateless and database-free (its HSQLDB CRL/OCSP cache is in-memory): the
# backend POSTs to /services/rest/validation/validateSignature.
#
# The failure mode that shapes this configuration is not a crash. Until the
# European trusted lists (LOTL) are loaded, validations answer 200 OK with
# signatureLevel "AdESig" instead of "QESig" — a wrong answer, silently. Hence:
#   - 4 GiB and no CATALINA_OPTS here (see the resources block).
#   - Probes point at /health, never /health/ready.
#   - The image must ship a pre-warmed lotl-cache/, which the DSS repo versions
#     empty: `make dss-lotl-up` then `make dss-lotl-save` before `make build-dss`.
# ---------------------------------------------------------------------------

locals {
  # Mode B ("siempre caliente") in the service's own docs. Requesting a warm
  # instance without also pinning the CPU on is a documented trap: DSS refreshes
  # the trusted lists from a @Scheduled background thread, which never advances
  # while the CPU is throttled between requests. The two settings only make
  # sense together, so the mode is derived from one knob rather than left to be
  # half-configured.
  dss_always_on = var.dss_min_instances > 0
}

resource "google_cloud_run_v2_service" "dss" {
  name     = "${local.name_prefix}-dss"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"
  labels   = local.common_labels

  template {
    service_account = google_service_account.dss.email

    # Scale-to-zero needs the long timeout so the first request is not cut off
    # while the instance boots. A warm instance does not.
    timeout = local.dss_always_on ? "120s" : "300s"

    scaling {
      min_instance_count = var.dss_min_instances
      max_instance_count = local.dss_always_on ? 3 : 2
    }

    # Conservative on purpose: each validation loads the whole document into
    # memory and multipart.maxFileSize is 50 MB, so Cloud Run's default of 80
    # would exhaust the heap long before it decided to scale out.
    max_instance_request_concurrency = 20

    containers {
      image = local.dss_image

      ports {
        container_port = 8080 # Tomcat
      }

      resources {
        limits = {
          cpu = "2"
          # 4 GiB is the documented minimum-with-headroom, and it is deliberately
          # NOT paired with a CATALINA_OPTS override: the image sizes the heap as
          # -XX:MaxRAMPercentage=70.0 of this limit (~2.8 GB). Setting a fixed
          # -Xmx here would silently undo that and risk an OOM kill. Never go
          # below 3Gi.
          memory = "4Gi"
        }
        # Mode A leaves CPU throttled between requests, which is what makes
        # scale-to-zero nearly free. That is only safe because the baked LOTL
        # cache is loaded during @PostConstruct, where Cloud Run grants full CPU.
        cpu_idle          = !local.dss_always_on
        startup_cpu_boost = true
      }

      # No env block on purpose. The service's own deployment guide states that
      # it requires no environment variable, and CATALINA_OPTS in particular must
      # be left alone so the image can size the JVM heap from the memory limit
      # above. Its behaviour is steered from var.dss_min_instances instead.

      # /health, not /health/ready. Cloud Run has no separate readiness concept,
      # so the 503 that /health/ready returns while the trusted lists load would
      # be read as a dead container and restart it in a loop.
      # 24 x 10s = 240s, the maximum Cloud Run accepts for a startup probe.
      startup_probe {
        http_get {
          path = "/health"
        }
        period_seconds    = 10
        timeout_seconds   = 5
        failure_threshold = 24
      }

      liveness_probe {
        http_get {
          path = "/health"
        }
        period_seconds    = 30
        timeout_seconds   = 5
        failure_threshold = 3
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  depends_on = [
    time_sleep.api_propagation,
    google_artifact_registry_repository.main,
    google_project_iam_member.dss_ar_reader,
  ]
}

# ---------------------------------------------------------------------------
# Invokers
# ---------------------------------------------------------------------------

# Browser-facing: the SPA and, through its nginx proxy, the API.
resource "google_cloud_run_v2_service_iam_member" "frontend_public" {
  project  = google_cloud_run_v2_service.frontend.project
  location = google_cloud_run_v2_service.frontend.location
  name     = google_cloud_run_v2_service.frontend.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# nginx proxies to the backend without credentials, and cookies are set on the
# frontend origin, so the backend has to accept anonymous requests. Its own
# auth (JWT cookie + rate limiting) is in src/app.ts.
resource "google_cloud_run_v2_service_iam_member" "backend_public" {
  project  = google_cloud_run_v2_service.backend.project
  location = google_cloud_run_v2_service.backend.location
  name     = google_cloud_run_v2_service.backend.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# The only invoker DSS needs. The backend presents an OIDC ID token whose aud is
# the DSS URL, minted in trustex-web's dss-client.ts — see docs/apps-y-servicios.md.
resource "google_cloud_run_v2_service_iam_member" "dss_backend" {
  project  = google_cloud_run_v2_service.dss.project
  location = google_cloud_run_v2_service.dss.location
  name     = google_cloud_run_v2_service.dss.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.backend.email}"
}

# Escape hatch, off by default: opens the DSS webapp — UI, Swagger, SOAP and the
# demo-keystore signing endpoints included — to the whole internet.
resource "google_cloud_run_v2_service_iam_member" "dss_public" {
  count = var.dss_public_invoker ? 1 : 0

  project  = google_cloud_run_v2_service.dss.project
  location = google_cloud_run_v2_service.dss.location
  name     = google_cloud_run_v2_service.dss.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
