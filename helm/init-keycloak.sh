#!/bin/bash

namespace="keycloak"

helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

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

create_namespace
create_keycloak_secrets_random || exit 1

helm install keycloak bitnami/keycloak \
  -f ./keycloak/values.yaml \
  --namespace "$namespace"