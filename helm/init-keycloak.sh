#!/bin/bash

create_keycloak_secrets_random() {
    echo "--- Generating secure credentials for keycloak-postgresql-credentials ---"

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
      --dry-run=client -o yaml > keycloak-secrets.yaml
}

kubectl create namespace keycloak

create_keycloak_secrets_random()
