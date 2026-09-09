#!/bin/bash
set -euo pipefail

# Installs MongoDB plus a Keycloak-gated Compass web UI (compass-web, a
# self-hosted build of the real MongoDB Compass UI with native OIDC login -
# see mongodb/README.md) into the cluster.
#
# Prerequisites: Keycloak already installed and reachable
# (./init-keycloak.sh). Safe to re-run: the MongoDB admin password and the
# session secret are generated once and reused; only the Keycloak client
# secret rotates every run (same reasoning as init-headlamp.sh - see its
# comments), and the Compass pod is restarted afterwards so it always has
# the current one.

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

namespace="mongodb"
keycloak_namespace="keycloak"
host="$HOST"
realm="${MONGODB_KEYCLOAK_REALM:-$HEADLAMP_KEYCLOAK_REALM}"
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

    # compass-web mounts everything (including its OIDC callback) under
    # CW_BASE_ROUTE - with the chart's default ingress path "/mongo", the
    # real callback route is "/mongo/auth/callback", not a bare
    # "/auth/callback". This MUST match compass.oidc redirect URI exactly
    # (see compass-deployment.yaml's CW_OIDC_REDIRECT_URI).
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
          -s "redirectUris=[\"https://${host}/mongo/auth/callback\"]" \
          -s "webOrigins=[\"https://${host}\"]" \
          -i)
        echo "Client '$client_id' created (id=$client_uuid)."
    fi

    # Keep the redirect URI/web origins in sync on every run, not just at
    # creation - an already-existing client (e.g. left over from an earlier
    # version of this chart, or a manually-created one) would otherwise
    # keep whatever stale value it was created with forever, causing
    # Keycloak's "Invalid parameter: redirect_uri" error even though
    # everything else about the setup is correct.
    kcadm update "clients/$client_uuid" -r "$realm" \
      -s "redirectUris=[\"https://${host}/mongo/auth/callback\"]" \
      -s "webOrigins=[\"https://${host}\"]"

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

# --- Compass OIDC secret ---------------------------------------------------
create_compass_secret() {
    echo "--- Storing Compass OIDC secret in Kubernetes ---"

    mkdir -p ./secrets

    local session_secret
    if kubectl get secret mongodb-compass -n "$namespace" >/dev/null 2>&1; then
        # Reuse the existing session secret so nobody's already-logged-in
        # session gets silently invalidated by a helm upgrade; only the
        # Keycloak client secret rotates above.
        session_secret=$(kubectl get secret mongodb-compass -n "$namespace" \
          -o jsonpath='{.data.session-secret}' | base64 -d)
    else
        # compass-web just requires 32+ characters for its session secret -
        # no base64/alphabet requirement (unlike, say, oauth2-proxy's
        # cookie-secret), so plain hex is simplest.
        session_secret=$(openssl rand -hex 32)
    fi

    kubectl create secret generic mongodb-compass \
      --from-literal=oidc-client-secret="$client_secret" \
      --from-literal=session-secret="$session_secret" \
      --namespace "$namespace" \
      --dry-run=client -o yaml > ./secrets/mongodb-compass-secret.yaml

    kubectl apply -f ./secrets/mongodb-compass-secret.yaml
    echo "Secret 'mongodb-compass' applied in namespace '$namespace'."
}

# --- In-cluster reachability for keycloakBaseUrl's hostname ---------------
resolve_traefik_ip() {
    echo "--- Resolving Traefik's in-cluster ClusterIP (for compass-web's hostAlias) ---"

    traefik_ip=$(kubectl get svc traefik -n kube-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

    if [ -z "$traefik_ip" ]; then
        echo "Warning: couldn't find the 'traefik' Service in kube-system -" >&2
        echo "leaving compass.oidc.internalIngressIP unset. If Compass can't" >&2
        echo "reach https://${host}/keycloak from inside the cluster, set it" >&2
        echo "by hand - see mongodb/README.md." >&2
        traefik_ip=""
    fi
}

# This script always does a plain `helm upgrade --install --set ...` (no
# -f values file, no --reuse-values), so any setting NOT passed as a --set
# flag here resets to its values.yaml default on every run - including
# compass.oidc.trustCAConfigMap. If ../init-tls.sh already ran (it creates
# a "mongodb-ca" ConfigMap and points the release at it), re-running this
# script alone would otherwise silently drop that back to untrusted and
# reintroduce the "unable to verify the first certificate" error. Detect
# and carry it forward instead.
detect_ca_configmap() {
    if kubectl get configmap mongodb-ca -n "$namespace" >/dev/null 2>&1; then
        echo "Found 'mongodb-ca' ConfigMap (from init-tls.sh) - keeping Compass's CA trust."
        ca_configmap="mongodb-ca"
    else
        ca_configmap=""
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
      --set compass.oidc.trustCAConfigMap="$ca_configmap" \
      --set compass.ingress.host="$host"
}

restart_compass() {
    # Same reasoning as init-headlamp.sh's restart_headlamp: the client
    # secret was just rotated above, but a Secret change alone doesn't
    # restart the already-running Compass container, which only reads it
    # at process start.
    echo "--- Restarting Compass so it picks up the current client secret ---"
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
detect_ca_configmap
install_mongodb
restart_compass

echo ""
echo "--- MongoDB install complete ---"
echo "MongoDB (in-cluster): mongodb.${namespace}.svc.cluster.local:27017"
echo "Compass (web UI):     https://${host}/mongo"
echo "Realm: ${realm} - create a user there (Users -> Add user) to log in via Keycloak."
