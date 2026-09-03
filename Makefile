# Trustex infrastructure.
#
# Secrets:
#   make secrets-keygen     # once: create age keypair
#   make secrets-encrypt    # plaintext -> *.age (commit *.age)
#   make secrets-decrypt    # *.age -> plaintext (needs .age.key)
#   make secrets-clean      # remove plaintext, keep *.age
#   make secrets-status     # show what is encrypted / plaintext
#   make secrets-push FILE=backend SECRET=name   # push to GCP Secret Manager
#
# Images and deploy:
#   make images             # what each image is and where it is built from
#   make docker-login       # configure docker for Artifact Registry
#   make build-all push-all # the four images
#   make dss-lotl-up / dss-lotl-save   # pre-warm the DSS trusted-list cache
#   make db-setup           # run the Prisma migration job
#   make dss-ready          # is DSS actually serving qualified verdicts?
#
# The secrets logic lives in scripts/ instead of inline recipes: GNU Make on
# Windows falls back to cmd.exe when no sh is on PATH, so POSIX recipes cannot
# run here. For the same reason every recipe below is a single command.

ifeq ($(OS),Windows_NT)
SECRETS   := powershell -NoProfile -ExecutionPolicy Bypass -File scripts/secrets.ps1
PUSH_ARGS := push -File "$(FILE)" -Secret "$(SECRET)"
else
SECRETS   := sh scripts/secrets.sh
PUSH_ARGS := push "$(FILE)" "$(SECRET)"
endif

# ---------------------------------------------------------------------------
# Build configuration. Override on the command line:
#   make build-backend TAG=0.56.0
# ---------------------------------------------------------------------------

# Source repositories, as checked out next to this one.
WEB_DIR := ../trustex-web
DSS_DIR := ../dss-validation-docker

# Read from terraform.tfvars via the project_id output, so there is one source of
# truth. Override on the command line if terraform has not been initialised yet.
PROJECT_ID    ?= $(shell terraform -chdir=terraform output -raw project_id 2>/dev/null)
REGION        ?= europe-west1
ENVIRONMENT   ?= dev
REGISTRY      ?= $(REGION)-docker.pkg.dev/$(PROJECT_ID)/trustex
TAG           ?= latest
DPP_BASE_URL  ?= https://dpp.trustex.eu

TF := terraform -chdir=terraform

# Recursively expanded on purpose: these shell out, and must not run on every
# `make` invocation. They are only evaluated by the recipes that use them.
DSS_URL  ?= $(shell $(TF) output -raw dss_url 2>/dev/null)
ID_TOKEN ?= $(shell gcloud auth print-identity-token 2>/dev/null)

.DEFAULT_GOAL := help

.PHONY: help images secrets-keygen secrets-encrypt secrets-decrypt secrets-clean \
        secrets-status secrets-push docker-login \
        build-frontend build-backend build-dss build-setup build-all \
        push-frontend push-backend push-dss push-setup push-all \
        dss-lotl-up dss-lotl-save dss-ready \
        tf-init tf-plan tf-apply tf-output db-setup urls

help:
	@$(SECRETS) help

images:
	@echo "frontend  $(REGISTRY)/frontend:$(TAG)   <- $(WEB_DIR)/frontend/Dockerfile   (Vite SPA served by nginx, port 80)"
	@echo "backend   $(REGISTRY)/backend:$(TAG)    <- $(WEB_DIR)/backend/Dockerfile    (Express + Prisma, port 8080)"
	@echo "dss       $(REGISTRY)/dss:$(TAG)        <- $(DSS_DIR)/Dockerfile            (EU DSS webapp on Tomcat, port 8080)"
	@echo "setup     $(REGISTRY)/setup:$(TAG)      <- $(WEB_DIR)/setup/Dockerfile      (Cloud Run Job, build context = $(WEB_DIR))"

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------

secrets-keygen:
	@$(SECRETS) keygen

secrets-encrypt:
	@$(SECRETS) encrypt

secrets-decrypt:
	@$(SECRETS) decrypt

secrets-clean:
	@$(SECRETS) clean

secrets-status:
	@$(SECRETS) status

secrets-push:
	@$(SECRETS) $(PUSH_ARGS)

# ---------------------------------------------------------------------------
# Images
#
# All four Dockerfiles already pin --platform=linux/amd64 (or use an amd64 base),
# which Cloud Run requires.
# ---------------------------------------------------------------------------

docker-login:
	gcloud auth configure-docker $(REGION)-docker.pkg.dev

# VITE_DPP_BASE_URL is inlined into the JS bundle here, not at runtime.
build-frontend:
	docker build -t $(REGISTRY)/frontend:$(TAG) --build-arg VITE_DPP_BASE_URL=$(DPP_BASE_URL) $(WEB_DIR)/frontend

build-backend:
	docker build -t $(REGISTRY)/backend:$(TAG) $(WEB_DIR)/backend

# Two reasons this is not a plain `docker build`:
#   - The Dockerfile uses `# syntax=` and `RUN --mount=type=cache`, which need
#     BuildKit. `docker buildx build` is BuildKit on every platform, and unlike
#     `DOCKER_BUILDKIT=1 docker build` it also works from cmd.exe.
#   - Expect ~10-20 minutes the first time: it compiles dss-demo-webapp with Maven.
# Run the dss-lotl-* targets below first, or the image ships an empty
# trusted-list cache and every cold start answers AdESig instead of QESig.
build-dss:
	docker buildx build -t $(REGISTRY)/dss:$(TAG) $(DSS_DIR)

# --- Pre-warming the DSS trusted-list cache --------------------------------
#
# The LOTL must be baked into the image: on Cloud Run the CPU is throttled
# between requests, so DSS's background refresh thread may never finish, and
# until it does validations return 200 OK with AdESig instead of QESig — a
# wrong answer, not an error. Baking it means the lists load at @PostConstruct,
# where Cloud Run still grants full CPU.
#
# Two targets rather than one because the wait in the middle is manual: there is
# no portable way to block on a log line from a Makefile on both Windows and
# POSIX. Between them, watch for "Nb of loaded trusted lists" (2-3 min):
#
#   make dss-lotl-up
#   docker compose -f ../dss-validation-docker/docker-compose.yml logs -f
#   make dss-lotl-save
#   make build-dss push-dss TAG=x.y.z
#
# Documented in dss-validation-docker/README.md section 8.
dss-lotl-up:
	docker compose -f $(DSS_DIR)/docker-compose.yml up --build -d

dss-lotl-save:
	docker cp dss-validation:/opt/dss-cache $(DSS_DIR)/lotl-cache
	docker compose -f $(DSS_DIR)/docker-compose.yml down

# Build context is the repo root: the job reuses backend/prisma.
build-setup:
	docker build -t $(REGISTRY)/setup:$(TAG) -f $(WEB_DIR)/setup/Dockerfile $(WEB_DIR)

build-all: build-frontend build-backend build-dss build-setup

push-frontend:
	docker push $(REGISTRY)/frontend:$(TAG)

push-backend:
	docker push $(REGISTRY)/backend:$(TAG)

push-dss:
	docker push $(REGISTRY)/dss:$(TAG)

push-setup:
	docker push $(REGISTRY)/setup:$(TAG)

push-all: push-frontend push-backend push-dss push-setup

# ---------------------------------------------------------------------------
# Terraform / deploy
# ---------------------------------------------------------------------------

tf-init:
	$(TF) init

tf-plan:
	$(TF) plan

tf-apply:
	$(TF) apply

tf-output:
	$(TF) output

# Applies pending Prisma migrations. Run it after pushing a backend/setup image
# whose migrations are not in the database yet, before the new backend serves
# traffic. SETUP_RUN_SEED comes from terraform.tfvars, not from here.
db-setup:
	gcloud run jobs execute trustex-$(ENVIRONMENT)-setup --region $(REGION) --project $(PROJECT_ID) --wait

# Prints the DSS health body. `"ready": true` / `"state": "READY"` means the
# trusted lists are loaded and eIDAS qualification is being computed; a
# LOADING_TRUSTED_LISTS state means it is still starting, so wait and retry
# rather than calling the deploy failed. Needs an ID token because DSS is
# IAM-protected. curl ships with Windows 10+ and every Linux/macOS.
dss-ready:
	curl -s -H "Authorization: Bearer $(ID_TOKEN)" $(DSS_URL)/health/ready
	curl -s -H "Authorization: Bearer $(ID_TOKEN)" $(DSS_URL)/health

urls:
	@$(TF) output -raw frontend_url
	@$(TF) output -raw backend_url
	@$(TF) output -raw dss_url
