# Encrypt / decrypt terraform/secrets so they can be committed to GitHub.
#
#   make secrets-keygen     # once: create age keypair
#   make secrets-encrypt    # plaintext -> *.age (commit *.age)
#   make secrets-decrypt    # *.age -> plaintext (needs .age.key)
#   make secrets-clean      # remove plaintext, keep *.age
#   make secrets-status      # show what is encrypted / plaintext
#   make secrets-push FILE=app.env SECRET=name   # push to GCP Secret Manager
#
# The logic lives in scripts/ instead of inline recipes: GNU Make on Windows
# falls back to cmd.exe when no sh is on PATH, so POSIX recipes cannot run here.

ifeq ($(OS),Windows_NT)
SECRETS   := powershell -NoProfile -ExecutionPolicy Bypass -File scripts/secrets.ps1
PUSH_ARGS := push -File "$(FILE)" -Secret "$(SECRET)"
else
SECRETS   := sh scripts/secrets.sh
PUSH_ARGS := push "$(FILE)" "$(SECRET)"
endif

.DEFAULT_GOAL := help

.PHONY: help secrets-keygen secrets-encrypt secrets-decrypt secrets-clean secrets-status secrets-push

help:
	@$(SECRETS) help

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
