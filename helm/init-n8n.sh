#!/bin/bash
set -euo pipefail

namespace="n8n"

# n8n uses this key to encrypt saved credentials in its database. It must
# stay THE SAME for the life of this install - the previous version of this
# script generated a fresh random one on every run (including upgrades),
# which would have silently made every previously-saved n8n credential
# undecryptable the next time it ran. Generated once, into a Secret, and
# reused from then on.
ensure_encryption_key() {
    if kubectl get secret n8n-encryption-key -n "$namespace" >/dev/null 2>&1; then
        echo "Encryption key secret already exists - reusing it."
    else
        echo "Generating n8n's encryption key (once, permanently, for this install)..."
        kubectl create secret generic n8n-encryption-key \
          --from-literal=key="$(openssl rand -hex 32)" \
          --namespace "$namespace"
    fi

    encryption_key=$(kubectl get secret n8n-encryption-key -n "$namespace" \
      -o jsonpath='{.data.key}' | base64 -d)
}

install_n8n() {
    echo "--- Installing n8n ---"
    helm upgrade --install n8n ./n8n \
      --namespace "$namespace" \
      --create-namespace \
      --set n8n.encryptionKey="$encryption_key"
}

# --- Run ---
if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
    kubectl create namespace "$namespace"
fi

ensure_encryption_key
install_n8n
