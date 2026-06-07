#!/bin/bash

namespace="keycloak"

uninstall_helm_release() {
    echo "--- Uninstalling Keycloak Helm release ---"

    if ! helm status keycloak -n "$namespace" >/dev/null 2>&1; then
        echo "Helm release 'keycloak' not found in namespace '$namespace'. Skipping."
    else
        helm uninstall keycloak --namespace "$namespace"
        echo "Helm release 'keycloak' uninstalled."
    fi
}

delete_secrets() {
    echo "--- Deleting secrets ---"

    for secret in "keycloak-secrets" "postgres-custom-secrets"; do
        if kubectl get secret "$secret" -n "$namespace" >/dev/null 2>&1; then
            kubectl delete secret "$secret" -n "$namespace"
            echo "Deleted secret '$secret'."
        else
            echo "Secret '$secret' not found. Skipping."
        fi
    done
}

delete_pvcs() {
    echo "--- Deleting PersistentVolumeClaims ---"

    pvcs=$(kubectl get pvc -n "$namespace" --no-headers -o custom-columns=":metadata.name" 2>/dev/null)

    if [ -z "$pvcs" ]; then
        echo "No PVCs found in namespace '$namespace'. Skipping."
    else
        echo "The following PVCs will be deleted:"
        echo "$pvcs"
        read -rp "Are you sure you want to delete all PVCs? This deletes all DB data. [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            kubectl delete pvc --all -n "$namespace"
            echo "PVCs deleted."
        else
            echo "Skipping PVC deletion."
        fi
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

delete_local_secrets() {
    echo "--- Deleting local secret files ---"

    if [ -d "./secrets" ]; then
        read -rp "Delete local ./secrets directory? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -rf ./secrets
            echo "Local ./secrets directory deleted."
        else
            echo "Skipping local secrets deletion."
        fi
    else
        echo "No local ./secrets directory found. Skipping."
    fi
}

echo "========================================"
echo "  Keycloak Uninstall Script"
echo "========================================"
read -rp "This will uninstall Keycloak and related resources. Continue? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

uninstall_helm_release
delete_secrets
delete_pvcs
delete_namespace
delete_local_secrets

echo ""
echo "--- Uninstall complete ---"