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

uninstall_postgres() {
    echo "--- Uninstalling PostgreSQL Helm release ---"

    if ! helm status keycloak-postgresql -n "$namespace" >/dev/null 2>&1; then
        echo "Helm release 'keycloak-postgresql' not found in namespace '$namespace'. Skipping."
    else
        helm uninstall keycloak-postgresql --namespace "$namespace"
        echo "Helm release 'keycloak-postgresql' uninstalled."
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

delete_keycloak_middleware() {
    echo "--- Deleting Keycloak Traefik Middleware ---"

    if kubectl get middleware keycloak-headers -n "$namespace" >/dev/null 2>&1; then
        kubectl delete middleware keycloak-headers -n "$namespace"
        echo "Keycloak middleware deleted."
    else
        echo "Keycloak middleware not found. Skipping."
    fi
}

delete_cluster_issuer() {
    echo "--- Deleting ClusterIssuer ---"

    if kubectl get clusterissuer letsencrypt-prod >/dev/null 2>&1; then
        read -rp "Delete ClusterIssuer 'letsencrypt-prod'? (skip if used by other apps) [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            kubectl delete clusterissuer letsencrypt-prod
            echo "ClusterIssuer deleted."
        else
            echo "Skipping ClusterIssuer deletion."
        fi
    else
        echo "ClusterIssuer 'letsencrypt-prod' not found. Skipping."
    fi
}

delete_cert_manager() {
    echo "--- Removing cert-manager ---"

    if kubectl get namespace cert-manager >/dev/null 2>&1; then
        read -rp "Delete cert-manager? (skip if used by other apps) [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            kubectl delete -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
            echo "cert-manager removed."
        else
            echo "Skipping cert-manager deletion."
        fi
    else
        echo "cert-manager not found. Skipping."
    fi
}

delete_traefik_config() {
    echo "--- Removing Traefik config ---"

    local traefik_config="/var/lib/rancher/k3s/server/manifests/traefik-config.yaml"

    if [ -f "$traefik_config" ]; then
        read -rp "Delete Traefik config at $traefik_config? This reverts HTTPS redirect. [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -f "$traefik_config"
            echo "Traefik config deleted. Restarting Traefik..."
            kubectl rollout restart deployment/traefik -n kube-system
            kubectl rollout status deployment/traefik -n kube-system --timeout=60s
        else
            echo "Skipping Traefik config deletion."
        fi
    else
        echo "Traefik config not found. Skipping."
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
uninstall_postgres
delete_keycloak_middleware
delete_secrets
delete_pvcs
delete_namespace
delete_cluster_issuer
delete_cert_manager
delete_traefik_config
delete_local_secrets

echo ""
echo "--- Uninstall complete ---"