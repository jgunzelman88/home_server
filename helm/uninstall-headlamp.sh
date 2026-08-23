#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

namespace="headlamp"
keycloak_namespace="keycloak"
realm="$HEADLAMP_KEYCLOAK_REALM"
client_id="$HEADLAMP_KEYCLOAK_CLIENT_ID"

uninstall_helm_release() {
    echo "--- Uninstalling Headlamp Helm release ---"

    if ! helm status headlamp -n "$namespace" >/dev/null 2>&1; then
        echo "Helm release 'headlamp' not found in namespace '$namespace'. Skipping."
    else
        helm uninstall headlamp --namespace "$namespace"
        echo "Helm release 'headlamp' uninstalled."
    fi
}

delete_secret() {
    echo "--- Deleting secret ---"

    if kubectl get secret headlamp-oidc -n "$namespace" >/dev/null 2>&1; then
        kubectl delete secret headlamp-oidc -n "$namespace"
        echo "Deleted secret 'headlamp-oidc'."
    else
        echo "Secret 'headlamp-oidc' not found. Skipping."
    fi
}

delete_namespace() {
    if kubectl get namespace "$namespace" >/dev/null 2>&1; then
        read -rp "Delete namespace '$namespace'? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            kubectl delete namespace "$namespace"
            echo "Namespace '$namespace' deleted."
        else
            echo "Skipping namespace deletion."
        fi
    else
        echo "Namespace '$namespace' not found. Skipping."
    fi
}

delete_keycloak_client() {
    echo "--- Deleting Keycloak client '$client_id' from realm '$realm' ---"

    local keycloak_pod
    keycloak_pod=$(kubectl get pods -n "$keycloak_namespace" -l app.kubernetes.io/instance=keycloak \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [ -z "$keycloak_pod" ]; then
        echo "Keycloak pod not found in namespace '$keycloak_namespace'. Skipping client cleanup."
        return 0
    fi

    read -rp "Delete the '$client_id' client from Keycloak realm '$realm'? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Skipping Keycloak client deletion."
        return 0
    fi

    local admin_pass
    admin_pass=$(kubectl get secret keycloak-secrets -n "$keycloak_namespace" \
      -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)

    if [ -z "$admin_pass" ]; then
        echo "Could not read Keycloak admin password (keycloak-secrets missing?). Skipping."
        return 0
    fi

    kubectl exec -n "$keycloak_namespace" "$keycloak_pod" -- \
      /opt/keycloak/bin/kcadm.sh config credentials \
        --server "http://localhost:8080/keycloak" \
        --realm master \
        --user admin \
        --password "$admin_pass" \
        --config /tmp/kcadm.config

    local existing_id
    existing_id=$(kubectl exec -n "$keycloak_namespace" "$keycloak_pod" -- \
      /opt/keycloak/bin/kcadm.sh get clients -r "$realm" -q "clientId=$client_id" --fields id \
        --config /tmp/kcadm.config \
      | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 \
      | sed -E 's/.*"([^"]+)"$/\1/' || true)

    if [ -z "$existing_id" ]; then
        echo "Client '$client_id' not found in realm '$realm'. Skipping."
        return 0
    fi

    kubectl exec -n "$keycloak_namespace" "$keycloak_pod" -- \
      /opt/keycloak/bin/kcadm.sh delete "clients/$existing_id" -r "$realm" \
        --config /tmp/kcadm.config
    echo "Deleted client '$client_id' from realm '$realm'."
}

echo "========================================"
echo "  Headlamp Uninstall Script"
echo "========================================"
read -rp "This will uninstall Headlamp and related resources. Continue? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

uninstall_helm_release
delete_secret
delete_namespace
delete_keycloak_client

echo ""
echo "--- Uninstall complete ---"
