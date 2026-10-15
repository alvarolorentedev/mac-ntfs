#!/bin/bash
#
# Creates a dedicated Developer ID Application certificate for MacNTFS.
#
# Portal flow (no Xcode, no Account Holder API key, no Keychain export):
#
#   MODE=csr ./scripts/create-dev-id-certificate.sh
#     writes key.pem + macntfs.certSigningRequest into OUT_DIR; upload the CSR
#     at developer.apple.com and download the issued certificate
#
#   MODE=p12 CER_PATH=~/Downloads/developerID_application.cer UPLOAD=1 \
#       ./scripts/create-dev-id-certificate.sh
#     assembles macntfs-devid.p12 from the retained private key + certificate
#     and uploads the CI secrets
#
# API flow (only if the API key itself is allowed to create certificates):
#
#   MODE=api ASC_KEY_PATH=... ASC_KEY_ID=... ASC_ISSUER_ID=... \
#       ./scripts/create-dev-id-certificate.sh
#
# Environment:
#   TEAM_ID      (default D8UFJKPSQP)
#   TEAM_NAME    (default "Alvaro Jose Lorente Perez")
#   OUT_DIR      where key/CSR/p12 live (default ~/.secrets/mac-ntfs)
#   P12_PASSWORD (optional; generated and printed once when unset)
#   UPLOAD=1     upload DEVELOPER_ID_P12 / DEVELOPER_ID_P12_PASSWORD secrets
#   GH_REPO      repository for UPLOAD (default alvarolorentedev/mac-ntfs)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEAM_ID="${TEAM_ID:-D8UFJKPSQP}"
TEAM_NAME="${TEAM_NAME:-Alvaro Jose Lorente Perez}"
OUT_DIR="${OUT_DIR:-$HOME/.secrets/mac-ntfs}"
UPLOAD="${UPLOAD:-0}"
GH_REPO="${GH_REPO:-alvarolorentedev/mac-ntfs}"
MODE="${MODE:-csr}"

KEY="$OUT_DIR/key.pem"
CSR="$OUT_DIR/macntfs.certSigningRequest"
P12="$OUT_DIR/macntfs-devid.p12"
SUBJECT="/UID=$TEAM_ID/CN=Developer ID Application: $TEAM_NAME ($TEAM_ID)/OU=$TEAM_ID/O=$TEAM_NAME/C=US"

upload_secrets() {
    if [ "$UPLOAD" != "1" ]; then
        return 0
    fi
    echo "==> uploading repository secrets to $GH_REPO"
    base64 -i "$P12" | tr -d '\n' | gh secret set DEVELOPER_ID_P12 --repo "$GH_REPO"
    gh secret set DEVELOPER_ID_P12_PASSWORD --repo "$GH_REPO" --body "$P12_PASSWORD"
    echo "    DEVELOPER_ID_P12 and DEVELOPER_ID_P12_PASSWORD uploaded"
}

generate_key_and_csr() {
    local key_path="$1"
    local csr_path="$2"
    if [ -f "$key_path" ]; then
        echo "error: $key_path already exists; refusing to overwrite an existing key" >&2
        echo "       remove it explicitly if you really want a new certificate" >&2
        exit 1
    fi
    echo "==> generating a 2048-bit key and CSR"
    openssl genrsa -out "$key_path" 2048 2>/dev/null
    openssl req -new -key "$key_path" -out "$csr_path" -subj "$SUBJECT"
}

assemble_p12() {
    local key_path="$1"
    local cert_path="$2"
    if [ ! -f "$key_path" ]; then
        echo "error: $key_path not found; run MODE=csr first" >&2
        exit 1
    fi
    if [ ! -f "$cert_path" ]; then
        echo "error: certificate not found: $cert_path" >&2
        exit 1
    fi

    SCRATCH="$(mktemp -d)"
    trap 'rm -rf "$SCRATCH"' EXIT

    echo "==> reading the issued certificate"
    if openssl x509 -inform DER -in "$cert_path" -out "$SCRATCH/cert.pem" 2>/dev/null; then
        :
    else
        cp "$cert_path" "$SCRATCH/cert.pem"
    fi
    openssl x509 -in "$SCRATCH/cert.pem" -noout -subject -serial -enddate

    P12_PASSWORD="${P12_PASSWORD:-}"
    local generated_password=0
    if [ -z "$P12_PASSWORD" ]; then
        P12_PASSWORD="$(openssl rand -hex 16)"
        generated_password=1
    fi

    echo "==> packaging the .p12"
    # -legacy: macOS `security import` rejects the modern PBES2/AES PKCS#12
    # encoding with "MAC verification failed"; the legacy encoding imports
    # cleanly on every supported macOS version.
    openssl pkcs12 -export -legacy \
        -inkey "$key_path" \
        -in "$SCRATCH/cert.pem" \
        -out "$P12" \
        -passout "pass:$P12_PASSWORD" \
        -name "Developer ID Application: $TEAM_NAME ($TEAM_ID)"

    echo
    echo "==> done"
    echo "    certificate bundle: $P12"
    if [ "$generated_password" = 1 ]; then
        echo "    p12 password (shown only once): $P12_PASSWORD"
    fi
    upload_secrets
}

case "$MODE" in
    csr)
        mkdir -p "$OUT_DIR"
        generate_key_and_csr "$KEY" "$CSR"
        echo
        echo "==> upload this file at developer.apple.com:"
        echo "    $CSR"
        echo
        echo "    Certificates, Identifiers & Profiles -> Certificates -> + ->"
        echo "    Developer ID Application -> upload the CSR -> download the .cer"
        echo
        echo "    then run:"
        echo "    MODE=p12 CER_PATH=<downloaded .cer> UPLOAD=1 $0"
        ;;
    p12)
        if [ -z "${CER_PATH:-}" ]; then
            echo "error: CER_PATH is not set (path to the downloaded certificate)" >&2
            exit 1
        fi
        assemble_p12 "$KEY" "$CER_PATH"
        ;;
    api)
        for variable in ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID; do
            if [ -z "${!variable:-}" ]; then
                echo "error: $variable is not set (required for MODE=api)" >&2
                exit 1
            fi
        done
        mkdir -p "$OUT_DIR"
        SCRATCH="$(mktemp -d)"
        trap 'rm -rf "$SCRATCH"' EXIT
        generate_key_and_csr "$SCRATCH/key.pem" "$SCRATCH/req.csr"
        echo "==> requesting the certificate from the App Store Connect API"
        CSR_PATH="$SCRATCH/req.csr" CERT_DER_PATH="$SCRATCH/cert.der" \
            swift "$REPO_ROOT/scripts/asc-certificate.swift"
        assemble_p12 "$SCRATCH/key.pem" "$SCRATCH/cert.der"
        ;;
    *)
        echo "error: unknown MODE '$MODE' (use csr, p12 or api)" >&2
        exit 2
        ;;
esac
