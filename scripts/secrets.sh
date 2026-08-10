#!/bin/sh
# Encrypt / decrypt terraform/secrets with age (Linux / macOS / CI).
# Windows uses scripts/secrets.ps1 instead. The Makefile picks the right one.
#
#   ./scripts/secrets.sh keygen
#   ./scripts/secrets.sh encrypt
#   ./scripts/secrets.sh decrypt
#   ./scripts/secrets.sh clean
#   ./scripts/secrets.sh status
#   ./scripts/secrets.sh push backend trustex-dev-backend

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SECRETS_DIR="$ROOT/terraform/secrets"
AGE_KEY="$SECRETS_DIR/.age.key"
AGE_PUB="$SECRETS_DIR/.age.pubkey"

# The only files that get encrypted. Add a new secret file here to include it.
MANAGED_FILES="backend postgres"

die() {
    echo "ERROR: $1" >&2
    exit 1
}

require_age() {
    command -v age >/dev/null 2>&1 ||
        die "age not found. Install: https://github.com/FiloSottile/age#installation"
}

cmd_keygen() {
    command -v age-keygen >/dev/null 2>&1 ||
        die "age-keygen not found. Install: https://github.com/FiloSottile/age#installation"
    [ -f "$AGE_KEY" ] && die "Key already exists: $AGE_KEY"
    mkdir -p "$SECRETS_DIR"
    age-keygen -o "$AGE_KEY"
    grep -E '^# public key:' "$AGE_KEY" | sed 's/^# public key: *//' >"$AGE_PUB"
    chmod 600 "$AGE_KEY"
    echo ""
    echo "Private key -> $AGE_KEY  (DO NOT commit; keep in a password manager)"
    echo "Public key  -> $AGE_PUB  (safe to commit)"
}

cmd_encrypt() {
    require_age
    [ -f "$AGE_PUB" ] || die "Missing $AGE_PUB. Run: make secrets-keygen"
    count=0
    for name in $MANAGED_FILES; do
        path="$SECRETS_DIR/$name"
        if [ ! -f "$path" ]; then
            echo "skip     $name (not found)"
            continue
        fi
        echo "encrypt  $name -> $name.age"
        age -e -R "$AGE_PUB" -o "$path.age" "$path"
        count=$((count + 1))
    done
    if [ "$count" -eq 0 ]; then
        echo "Nothing to encrypt. Expected: $MANAGED_FILES in terraform/secrets/"
    else
        echo "Encrypted $count file(s). Commit only *.age - plaintext stays local."
    fi
}

cmd_decrypt() {
    require_age
    [ -f "$AGE_KEY" ] || die "Missing private key $AGE_KEY. Restore it before decrypting."
    count=0
    for name in $MANAGED_FILES; do
        path="$SECRETS_DIR/$name"
        if [ ! -f "$path.age" ]; then
            echo "skip     $name.age (not found)"
            continue
        fi
        echo "decrypt  $name.age -> $name"
        age -d -i "$AGE_KEY" -o "$path" "$path.age"
        count=$((count + 1))
    done
    if [ "$count" -eq 0 ]; then
        echo "No *.age files to decrypt in terraform/secrets/"
    else
        echo "Decrypted $count file(s)."
    fi
}

cmd_clean() {
    count=0
    for name in $MANAGED_FILES; do
        path="$SECRETS_DIR/$name"
        [ -f "$path" ] || continue
        if [ -f "$path.age" ]; then
            echo "remove   $name"
            rm -f "$path"
            count=$((count + 1))
        else
            echo "skip     $name (no $name.age - encrypt first)"
        fi
    done
    echo "Removed $count plaintext file(s)."
}

cmd_status() {
    echo "=== $SECRETS_DIR ==="
    if [ -f "$AGE_KEY" ]; then echo "private key: present"; else echo "private key: MISSING (run: make secrets-keygen)"; fi
    if [ -f "$AGE_PUB" ]; then echo "public key:  present"; else echo "public key:  MISSING (run: make secrets-keygen)"; fi
    echo ""
    printf '%-11s %-10s %s\n' "file" "plaintext" "encrypted"
    printf '%-11s %-10s %s\n' "----" "---------" "---------"
    for name in $MANAGED_FILES; do
        path="$SECRETS_DIR/$name"
        if [ -f "$path" ]; then plain="yes"; else plain="no"; fi
        if [ -f "$path.age" ]; then enc="yes"; else enc="no"; fi
        printf '%-11s %-10s %s\n' "$name" "$plain" "$enc"
    done
    echo ""
    echo "Only *.age files are committed. Plaintext is gitignored."
}

cmd_push() {
    file=${1:-}
    secret=${2:-}
    [ -n "$file" ] || die "Usage: make secrets-push FILE=backend SECRET=trustex-dev-backend"
    [ -n "$secret" ] || die "Usage: make secrets-push FILE=backend SECRET=trustex-dev-backend"
    path="$SECRETS_DIR/$file"
    [ -f "$path" ] || die "Missing $path. Run make secrets-decrypt first."
    command -v gcloud >/dev/null 2>&1 || die "Install Google Cloud SDK (gcloud)"
    if ! gcloud secrets describe "$secret" >/dev/null 2>&1; then
        echo "Creating secret $secret..."
        gcloud secrets create "$secret" --replication-policy=automatic
    fi
    gcloud secrets versions add "$secret" --data-file="$path"
    echo "Uploaded $path -> Secret Manager: $secret"
}

cmd_help() {
    cat <<EOF
Secrets (age) - encrypts: $MANAGED_FILES

  make secrets-keygen
  make secrets-encrypt
  make secrets-decrypt
  make secrets-clean
  make secrets-status
  make secrets-push FILE=backend SECRET=trustex-dev-backend

Without make:  ./scripts/secrets.sh <keygen|encrypt|decrypt|clean|status>

Install age: https://github.com/FiloSottile/age#installation
EOF
}

case "${1:-help}" in
keygen) cmd_keygen ;;
encrypt) cmd_encrypt ;;
decrypt) cmd_decrypt ;;
clean) cmd_clean ;;
status) cmd_status ;;
push)
    shift
    cmd_push "$@"
    ;;
*) cmd_help ;;
esac
