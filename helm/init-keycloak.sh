#!/bin/bash
set -euo pipefail

namespace="keycloak"

helm repo add codecentric https://codecentric.github.io/helm-charts
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

install_cert_manager() {
    echo "--- Installing cert-manager ---"

    if kubectl get namespace cert-manager >/dev/null 2>&1; then
        echo "cert-manager already exists, skipping."
        return 0
    fi

    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

    echo "Waiting for cert-manager to be ready..."
    kubectl rollout status deployment/cert-manager -n cert-manager --timeout=120s
    kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s
}

create_cluster_issuer() {
    echo "--- Creating ClusterIssuer ---"

    if kubectl get clusterissuer letsencrypt-prod >/dev/null 2>&1; then
        echo "ClusterIssuer 'letsencrypt-prod' already exists, skipping."
        return 0
    fi

    if [ -z "${CERT_MANAGER_EMAIL:-}" ]; then
        read -rp "Enter your email for Let's Encrypt certificates: " CERT_MANAGER_EMAIL
    fi

    cat <<ISSUER | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${CERT_MANAGER_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            class: traefik
ISSUER

    echo "ClusterIssuer created."
}

create_keycloak_middleware() {
    echo "--- Creating Keycloak Traefik Middleware ---"

    cat <<MIDDLEWARE | kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: keycloak-headers
  namespace: ${namespace}
spec:
  headers:
    customRequestHeaders:
      X-Forwarded-Proto: "https"
    sslRedirect: true
MIDDLEWARE

    echo "Keycloak middleware created."
}

create_namespace() {
    if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
        echo "Namespace '$namespace' not found. Creating..."
        kubectl create namespace "$namespace"
    else
        echo "Namespace '$namespace' already exists."
    fi
}

create_keycloak_secrets_random() {
    echo "--- Generating secure credentials ---"

    local kc_secret="keycloak-secrets"
    local pg_secret="postgres-custom-secrets"
    local kc_exists=false
    local pg_exists=false

    kubectl get secret "$kc_secret" -n "$namespace" >/dev/null 2>&1 && kc_exists=true
    kubectl get secret "$pg_secret" -n "$namespace" >/dev/null 2>&1 && pg_exists=true

    if $kc_exists && $pg_exists; then
        echo "Secrets already exist, skipping generation."
        return 0
    fi

    if $kc_exists || $pg_exists; then
        echo "Error: only one of '$kc_secret'/'$pg_secret' exists in namespace" >&2
        echo "'$namespace' - that shouldn't happen. Check 'kubectl get secrets" >&2
        echo "-n $namespace' by hand before continuing." >&2
        exit 1
    fi

    local admin_pass=$(openssl rand -base64 32)
    local repl_pass=$(openssl rand -base64 32)
    local postgres_pass=$(openssl rand -base64 32)

    mkdir -p ./secrets

    kubectl create secret generic "$kc_secret" \
      --from-literal=admin-password="$admin_pass" \
      --namespace "$namespace" \
      --dry-run=client -o yaml > ./secrets/keycloak-secrets.yaml

    kubectl create secret generic "$pg_secret" \
      --from-literal=password="$postgres_pass" \
      --from-literal=replication-password="$repl_pass" \
      --namespace "$namespace" \
      --dry-run=client -o yaml > ./secrets/postgres-custom-secrets.yaml

    kubectl apply -f ./secrets/keycloak-secrets.yaml
    kubectl apply -f ./secrets/postgres-custom-secrets.yaml

    echo "Secrets created successfully."
}

install_postgres() {
    echo "--- Installing PostgreSQL ---"

    if helm status keycloak-postgresql -n "$namespace" >/dev/null 2>&1; then
        echo "PostgreSQL already installed, skipping."
        return 0
    fi

    helm install keycloak-postgresql oci://registry-1.docker.io/bitnamicharts/postgresql \
      --namespace "$namespace" \
      --set auth.username=keycloak \
      --set auth.database=keycloak \
      --set auth.existingSecret=postgres-custom-secrets \
      --set auth.secretKeys.userPasswordKey=password \
      --set primary.persistence.enabled=true \
      --set primary.persistence.size=4Gi \
      --set primary.persistence.storageClass=local-path \
      --set primary.resources.limits.cpu=500m \
      --set primary.resources.limits.memory=512Mi \
      --set primary.resources.requests.cpu=250m \
      --set primary.resources.requests.memory=256Mi

    echo "Waiting for PostgreSQL to be ready..."
    kubectl rollout status statefulset/keycloak-postgresql -n "$namespace" --timeout=120s
}

install_keycloak() {
    echo "--- Installing Keycloak ---"

    if helm status keycloak -n "$namespace" >/dev/null 2>&1; then
        echo "Keycloak already installed, upgrading..."
        helm upgrade keycloak codecentric/keycloakx \
          -f ./keycloak/values.yaml \
          --namespace "$namespace"
    else
        helm install keycloak codecentric/keycloakx \
          -f ./keycloak/values.yaml \
          --namespace "$namespace"
    fi
}

# --- Run ---
"$(dirname "${BASH_SOURCE[0]}")/init-traefik.sh"
install_cert_manager
create_cluster_issuer

create_namespace
create_keycloak_secrets_random
create_keycloak_middleware

install_postgres
install_keycloak

echo ""
echo "--- Keycloak install complete ---"
echo "URL: https://bwing/keycloak"
