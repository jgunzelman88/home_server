#!/bin/bash

create_keycloak_secrets_random() {
    echo "--- Generating secure credentials for keycloak-postgresql-credentials ---"

    if kubectl get secret "$secret_name" >/dev/null 2>&1; then
        echo "Error: Secret '$secret_name' already exists in the cluster."
        echo "Aborting to prevent overwriting existing credentials."
        return 1
    fi

    # Generate random base64 passwords (32 bytes = 24 chars)
    local admin_pass=$(openssl rand -base64 32)
    local user_pass=$(openssl rand -base64 32)
    local repl_pass=$(openssl rand -base64 32)
    local metric_pass=$(openssl rand -base64 32)

    mkdir -p ./secrets

    # Create the secret manifest
    kubectl create secret generic keycloak-postgresql-credentials \
      --from-literal=admin-password="$admin_pass" \
      --from-literal=user-password="$user_pass" \
      --from-literal=replication-password="$repl_pass" \
      --from-literal=metrics-password="$metric_pass" \
      --dry-run=client -o yaml > ./secrets/keycloak-secrets.yaml
}

create_namespace() {
    local ns="keycloak"
    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
        echo "Namespace '$ns' not found. Creating..."
        kubectl create namespace "$ns"
    else
        echo "Namespace '$ns' already exists."
    fi
}

create_namespace
create_keycloak_secrets_random