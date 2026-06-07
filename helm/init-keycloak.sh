#!/bin/bash

namespace="keycloak"

helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

configure_traefik() {
    echo "--- Configuring Traefik for HTTPS ---"

    cat > /var/lib/rancher/k3s/server/manifests/traefik-config.yaml <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    ports:
      web:
        redirectTo:
          port: websecure
      websecure:
        tls:
          enabled: true
    ingressRoute:
      dashboard:
        enabled: false
EOF

    echo "Traefik config applied. Waiting for rollout..."
    kubectl rollout restart deployment/traefik -n kube-system
    kubectl rollout status deployment/traefik -n kube-system --timeout=60s
}

install_cert_manager() {
    echo "--- Installing cert-manager ---"

    if kubectl get namespace cert-manager >/dev/null 2>&1; then
        echo "cert-manager namespace already exists, skipping install."
        return 0
    fi

    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

    echo "Waiting for cert-manager to be ready..."
    kubectl rollout status deployment/cert-manager -n cert-manager --timeout=120s
    kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s
}

create_cluster_issuer() {
    echo "--- Creating ClusterIssuer ---"

    if [ -z "$CERT_MANAGER_EMAIL" ]; then
        read -rp "Enter your email for Let's Encrypt certificates: " CERT_MANAGER_EMAIL
    fi

    cat <<EOF | kubectl apply -f -
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
EOF

    echo "ClusterIssuer created."
}

create_keycloak_middleware() {
    echo "--- Creating Keycloak Traefik Middleware ---"

    cat <<EOF | kubectl apply -f -
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
EOF

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

    # Check both secrets
    for secret in "$kc_secret" "$pg_secret"; do
        if kubectl get secret "$secret" -n "$namespace" >/dev/null 2>&1; then
            echo "Error: Secret '$secret' already exists in namespace '$namespace'."
            echo "Aborting to prevent overwriting existing credentials."
            return 1
        fi
    done

    local admin_pass=$(openssl rand -base64 32)
    local repl_pass=$(openssl rand -base64 32)
    local postgres_pass=$(openssl rand -base64 32)

    mkdir -p ./secrets

    # Create keycloak-secrets (admin password)
    kubectl create secret generic "$kc_secret" \
      --from-literal=admin-password="$admin_pass" \
      --namespace "$namespace" \
      --dry-run=client -o yaml > ./secrets/keycloak-secrets.yaml

    # Create postgres-custom-secrets (db passwords)
    kubectl create secret generic "$pg_secret" \
      --from-literal=postgres-password="$postgres_pass" \
      --from-literal=replication-password="$repl_pass" \
      --namespace "$namespace" \
      --dry-run=client -o yaml > ./secrets/postgres-custom-secrets.yaml

    kubectl apply -f ./secrets/keycloak-secrets.yaml
    kubectl apply -f ./secrets/postgres-custom-secrets.yaml

    echo "Secrets created successfully."
}

# --- Run ---
configure_traefik
install_cert_manager
create_cluster_issuer

create_namespace
create_keycloak_secrets_random || exit 1
create_keycloak_middleware

helm install keycloak bitnami/keycloak \
  -f ./keycloak/values.yaml \
  --namespace "$namespace"