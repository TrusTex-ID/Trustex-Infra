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
# Terraform and operating what it deployed:
#   make tf-init tf-plan tf-apply tf-output
#   make db-setup           # run the Prisma migration job
#   make dss-ready          # is DSS actually serving qualified verdicts?
#   make urls               # the three service URLs
#
# Building images is NOT here. Each application repository owns its own
# Dockerfiles, so it owns their build and push:
#
#   trustex-web/Makefile            frontend, backend, setup
#   dss-validation-docker/Makefile  dss, plus the LOTL cache pre-warming
#
# The contract between them is the image tag and nothing else: you push 0.0.2
# there, set the matching *_tag in terraform.tfvars here, and apply. That is why
# this repo no longer needs the other two checked out beside it.
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
# Configuration. Override on the command line:
#   make db-setup ENVIRONMENT=prod
# ---------------------------------------------------------------------------

# Read from terraform.tfvars via the project_id output, so there is one source
# of truth. Override on the command line if terraform is not initialised yet.
PROJECT_ID  ?= $(shell terraform -chdir=terraform output -raw project_id 2>/dev/null)
REGION      ?= europe-west1
ENVIRONMENT ?= dev

# Before the first apply there is no state, so the output above is empty and
# db-setup would call gcloud with `--project ` and fail obscurely. Recursively
# expanded on purpose: only the targets that need it pay the check.
CHECKED_PROJECT_ID = $(if $(strip $(PROJECT_ID)),$(strip $(PROJECT_ID)),$(error PROJECT_ID is empty. Run `make tf-apply` first or pass PROJECT_ID=<id> on the command line))

TF := terraform -chdir=terraform

# Recursively expanded on purpose: these shell out, and must not run on every
# `make` invocation. They are only evaluated by the recipes that use them.
DSS_URL  ?= $(shell $(TF) output -raw dss_url 2>/dev/null)
ID_TOKEN ?= $(shell gcloud auth print-identity-token 2>/dev/null)

.DEFAULT_GOAL := help

.PHONY: help secrets-keygen secrets-encrypt secrets-decrypt secrets-clean \
        secrets-status secrets-push \
        tf-init tf-plan tf-apply tf-output db-setup dss-ready urls

help:
	@$(SECRETS) help

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
# Terraform
# ---------------------------------------------------------------------------

tf-init:
	$(TF) init

tf-plan:
	$(TF) plan

tf-apply:
	$(TF) apply

tf-output:
	$(TF) output

# ---------------------------------------------------------------------------
# Operating the deployed infrastructure.
#
# These stay here rather than in an application repo because every one of them
# reads terraform outputs: they cannot work without this repo's state.
# ---------------------------------------------------------------------------

# Applies pending Prisma migrations. Run it after pushing a backend/setup image
# whose migrations are not in the database yet, before the new backend serves
# traffic. SETUP_RUN_SEED comes from terraform.tfvars, not from here.
db-setup:
	gcloud run jobs execute trustex-$(ENVIRONMENT)-setup --region $(REGION) --project $(CHECKED_PROJECT_ID) --wait

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
