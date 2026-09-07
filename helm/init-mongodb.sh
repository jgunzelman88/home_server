#!/bin/bash
set -euo pipefail

# Installs MongoDB plus a Keycloak-gated "Compass" web UI (mongo-express
# behind an oauth2-proxy sidecar - see mongodb/README.md for why it's not
# literally the Compass desktop app) into the cluster.
#
# Prerequisites: Keycloak already installed and reachable
# (./init-keycloak.sh). Safe to re-run: the MongoDB admin password and the
# oauth2-proxy cookie secret are generated once and reused; only the
# Keycloak client secret rotates every run (same reasoning as
# init-headlamp.sh - see its comments), and the Compass pod is restarted
# afterwards so it always has the current one.

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

namespace="mongodb"
keycloak_namespace="keycloak"
host="$HOST"
realm="master"
client_id="${MONGODB_KEYCLOAK_CLIENT_ID:-compass}"

create_namespace() {
    if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
        echo "Namespace '$namespace' not found. Creating..."
        kubectl create namespace "$namespace"
    else
        echo "Namespace '$namespace' already exists."
    fi
}

# --- MongoDB admin secret -------------------------------------------------
create_mongodb_secret() {
    echo "--- Generating MongoDB admin credentials ---"

    if kubectl get secret mongodb-admin -n "$namespace" >/dev/null 2>&1; then
        echo "Secret 'mongodb-admin' already exists, skipping."
        return 0
    fi

    mkdir -p ./secrets

    local admin_pass
    admin_pass=$(openssl rand -base64 24)

    kubectl create secret generic mongodb-admin \
      --from-literal=password="$admin_pass" \
      --namespace "$namespace" \
      --dry-run=client -o yaml > ./secrets/mongodb-admin-secret.yaml

    kubectl apply -f ./secrets/mongodb-admin-secret.yaml
    echo "Secret 'mongodb-admin' created."
}

# --- Keycloak client for Compass -----------------------------------------
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

create_compass_client() {
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
          -s "redirectUris=[\"https://${host}/mongo/oauth2/callback\"]" \
          -s "webOrigins=[\"https://${host}\"]" \
          -i)
        echo "Client '$client_id' created (id=$client_uuid)."
    fi

    # `create` regenerates the secret but doesn't reliably print it (no
    # Location header on this endpoint) - fetch the value back with a
    # separate `get` instead, same as init-headlamp.sh.
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

# --- Compass (oauth2-proxy) secret ----------------------------------------
create_compass_secret() {
    echo "--- Storing Compass OIDC secret in Kubernetes ---"

    mkdir -p ./secrets

    local cookie_secret
    if kubectl get secret mongodb-compass -n "$namespace" >/dev/null 2>&1; then
        # Reuse the existing cookie secret so nobody's already-logged-in
        # session gets silently invalidated by a helm upgrade; only the
        # Keycloak client secret rotates above.
        cookie_secret=$(kubectl get secret mongodb-compass -n "$namespace" \
          -o jsonpath='{.data.cookie-secret}' | base64 -d)
    else
        cookie_secret=$(openssl rand -base64 32)
    fi

    kubectl create secret generic mongodb-compass \
      --from-literal=oauth2-client-secret="$client_secret" \
      --from-literal=cookie-secret="$cookie_secret" \
      --namespace "$namespace" \
      --dry-run=client -o yaml > ./secrets/mongodb-compass-secret.yaml

    kubectl apply -f ./secrets/mongodb-compass-secret.yaml
    echo "Secret 'mongodb-compass' applied in namespace '$namespace'."
}

# --- In-cluster reachability for keycloakBaseUrl's hostname ---------------
resolve_traefik_ip() {
    echo "--- Resolving Traefik's in-cluster ClusterIP (for oauth2-proxy's hostAlias) ---"

    traefik_ip=$(kubectl get svc traefik -n kube-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

    if [ -z "$traefik_ip" ]; then
        echo "Warning: couldn't find the 'traefik' Service in kube-system -" >&2
        echo "leaving compass.oidc.internalIngressIP unset. If oauth2-proxy" >&2
        echo "can't reach https://${host}/keycloak from inside the cluster," >&2
        echo "set it by hand - see mongodb/README.md." >&2
        traefik_ip=""
    fi
}

install_mongodb() {
    echo "--- Installing MongoDB + Compass ---"

    helm upgrade --install mongodb ./mongodb \
      --namespace "$namespace" \
      --create-namespace \
      --set mongodb.auth.existingSecret=mongodb-admin \
      --set compass.oidc.clientId="$client_id" \
      --set compass.oidc.realm="$realm" \
      --set compass.oidc.existingSecret=mongodb-compass \
      --set compass.oidc.internalIngressIP="$traefik_ip" \
      --set compass.ingress.host="$host"
}

restart_compass() {
    # Same reasoning as init-headlamp.sh's restart_headlamp: the client
    # secret was just rotated above, but a Secret change alone doesn't
    # restart the already-running oauth2-proxy container, which only reads
    # it at process start.
    echo "--- Restarting Compass so oauth2-proxy picks up the current client secret ---"
    kubectl rollout restart deployment/mongodb-compass -n "$namespace" 2>/dev/null \
      || echo "(couldn't find deployment/mongodb-compass - check 'kubectl get deploy -n $namespace' for the real name and restart it manually)"
    kubectl rollout status deployment/mongodb-compass -n "$namespace" --timeout=120s 2>/dev/null || true
}

# --- Run ---
create_namespace
create_mongodb_secret
find_keycloak_pod
login_kcadm
create_realm_if_missing
create_compass_client
create_compass_secret
resolve_traefik_ip
install_mongodb
restart_compass

echo ""
echo "--- MongoDB install complete ---"
echo "MongoDB (in-cluster): mongodb.${namespace}.svc.cluster.local:27017"
echo "Compass (web UI):     https://${host}/mongo"
echo "Realm: ${realm} - create a user there (Users -> Add user) to log in via Keycloak."
