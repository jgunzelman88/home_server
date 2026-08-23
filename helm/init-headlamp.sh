#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

namespace="headlamp"
keycloak_namespace="keycloak"
host="$HOST"
realm="$HEADLAMP_KEYCLOAK_REALM"
client_id="$HEADLAMP_KEYCLOAK_CLIENT_ID"

helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
helm repo update

create_namespace() {
    if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
        echo "Namespace '$namespace' not found. Creating..."
        kubectl create namespace "$namespace"
    else
        echo "Namespace '$namespace' already exists."
    fi
}

find_keycloak_pod() {
    keycloak_pod=$(kubectl get pods -n "$keycloak_namespace" -l app.kubernetes.io/instance=keycloak \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [ -z "$keycloak_pod" ]; then
        echo "Error: could not find a running Keycloak pod in namespace '$keycloak_namespace'." >&2
        echo "Make sure init-keycloak.sh has been run and Keycloak is up." >&2
        exit 1
    fi
    echo "Using Keycloak pod: $keycloak_pod"
}

kcadm() {
    kubectl exec -n "$keycloak_namespace" "$keycloak_pod" -- \
      /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config
}

login_kcadm() {
    echo "--- Logging into Keycloak admin CLI ---"

    local admin_pass
    admin_pass=$(kubectl get secret keycloak-secrets -n "$keycloak_namespace" \
      -o jsonpath='{.data.admin-password}' | base64 -d)

    kcadm config credentials \
      --server "http://localhost:8080/keycloak" \
      --realm master \
      --user admin \
      --password "$admin_pass"
}

create_realm_if_missing() {
    echo "--- Ensuring realm '$realm' exists ---"

    if kcadm get "realms/$realm" >/dev/null 2>&1; then
        echo "Realm '$realm' already exists."
    else
        kcadm create realms -s realm="$realm" -s enabled=true
        echo "Realm '$realm' created."
    fi
}

create_headlamp_client() {
    echo "--- Creating Keycloak client '$client_id' in realm '$realm' ---"

    local existing_id
    existing_id=$(kcadm get clients -r "$realm" -q "clientId=$client_id" --fields id \
      | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 \
      | sed -E 's/.*"([^"]+)"$/\1/' || true)

    if [ -n "$existing_id" ]; then
        echo "Client '$client_id' already exists (id=$existing_id). Will regenerate its secret."
        client_uuid="$existing_id"
    else
        client_uuid=$(kcadm create clients -r "$realm" \
          -s clientId="$client_id" \
          -s protocol=openid-connect \
          -s publicClient=false \
          -s standardFlowEnabled=true \
          -s directAccessGrantsEnabled=false \
          -s serviceAccountsEnabled=false \
          -s "redirectUris=[\"https://${host}/headlamp/oidc-callback\"]" \
          -s "webOrigins=[\"https://${host}\"]" \
          -i)
        echo "Client '$client_id' created (id=$client_uuid)."
    fi

    # `create` regenerates the secret but doesn't reliably print it (no
    # Location header on this endpoint, so kcadm's output format here isn't
    # guaranteed) - fetch the value back with a separate `get` instead.
    kcadm create "clients/$client_uuid/client-secret" -r "$realm" >/dev/null

    client_secret=$(kcadm get "clients/$client_uuid/client-secret" -r "$realm" \
      | grep -oE '"value"[[:space:]]*:[[:space:]]*"[^"]+"' \
      | sed -E 's/.*"([^"]+)"$/\1/' || true)

    if [ -z "$client_secret" ]; then
        echo "Error: failed to read the generated client secret from Keycloak." >&2
        echo "Run this by hand to see what Keycloak actually returned:" >&2
        echo "  kubectl exec -n $keycloak_namespace $keycloak_pod -- /opt/keycloak/bin/kcadm.sh get clients/$client_uuid/client-secret -r $realm --config /tmp/kcadm.config" >&2
        exit 1
    fi
}

create_headlamp_secret() {
    echo "--- Storing Headlamp OIDC secret in Kubernetes ---"

    mkdir -p ./secrets

    kubectl create secret generic headlamp-oidc \
      --from-literal=OIDC_CLIENT_ID="$client_id" \
      --from-literal=OIDC_CLIENT_SECRET="$client_secret" \
      --from-literal=OIDC_ISSUER_URL="https://${host}/keycloak/realms/${realm}" \
      --from-literal=OIDC_SCOPES="openid profile email" \
      --namespace "$namespace" \
      --dry-run=client -o yaml > ./secrets/headlamp-oidc.yaml

    kubectl apply -f ./secrets/headlamp-oidc.yaml
    echo "Secret 'headlamp-oidc' applied in namespace '$namespace'."
}

install_headlamp() {
    echo "--- Installing Headlamp ---"

    if helm status headlamp -n "$namespace" >/dev/null 2>&1; then
        echo "Headlamp already installed, upgrading..."
        helm upgrade headlamp headlamp/headlamp \
          -f ./headlamp/values.yaml \
          --namespace "$namespace"
    else
        helm install headlamp headlamp/headlamp \
          -f ./headlamp/values.yaml \
          --namespace "$namespace"
    fi
}

restart_headlamp() {
    # OIDC_CLIENT_SECRET is injected via envFrom on the Secret above, and
    # Kubernetes only reads that at pod start - it does NOT hot-reload when
    # the Secret's contents change. If create_headlamp_client() regenerated
    # the secret but `helm upgrade` didn't otherwise change the Deployment's
    # pod template, the already-running pod keeps its OLD secret in memory
    # while Keycloak now has a new one, and login fails with Keycloak's
    # generic "unauthorized_client: Invalid client or Invalid client
    # credentials". Force a rollout every run so this can't happen silently.
    echo "--- Restarting Headlamp so it picks up the current client secret ---"
    kubectl rollout restart deployment/headlamp -n "$namespace" 2>/dev/null \
      || echo "(couldn't find deployment/headlamp - check 'kubectl get deploy -n $namespace' for the real name and restart it manually)"
    kubectl rollout status deployment/headlamp -n "$namespace" --timeout=120s 2>/dev/null || true
}

# --- Run ---
create_namespace
find_keycloak_pod
login_kcadm
create_realm_if_missing
create_headlamp_client
create_headlamp_secret
install_headlamp
restart_headlamp

echo ""
echo "--- Headlamp install complete ---"
echo "URL:   https://${host}/headlamp"
echo "Realm: ${realm} - create a user there (Users -> Add user) to log in."
