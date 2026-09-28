#!/bin/bash
set -euo pipefail

# Installs GitLab CE into the `gitlab` namespace at https://$HOST/gitlab,
# together with its own PostgreSQL and Redis (all in that same namespace -
# see gitlab/README.md), with Keycloak SSO via OpenID Connect.
#
# Prerequisites: Keycloak installed and reachable (./init-keycloak.sh), and
# ideally ./init-tls.sh (GitLab has to trust Traefik's cert to talk to
# Keycloak - without the homelab CA, SSO logins fail with a TLS error while
# the local root login keeps working).
#
# Login:
#   * "Sign in with Keycloak" - any user in the realm. New users need an
#     admin's approval first unless GITLAB_OIDC_BLOCK_NEW_USERS=false.
#   * root / auto-generated initial password - local break-glass admin,
#     printed at the end of this script.
#
# Safe to re-run: `helm upgrade --install`. Unlike init-mongodb.sh this does
# NOT rotate the Keycloak client secret every run - GitLab takes minutes to
# restart - it reads the client's current secret from Keycloak and only
# updates the Secret + restarts GitLab if it actually differs. Internal
# Postgres/Redis passwords are generated once and kept; PVCs survive
# `helm uninstall`.
#
# Any arguments are passed straight to `helm upgrade --install` (after the
# script's own --set flags, so they win), e.g.
#   ./init-gitlab.sh --set gitlab.image.tag=18.11.12-ce.0
# ./upgrade-gitlab.sh uses this to walk GitLab through its upgrade stops.

extra_helm_args=("$@")

cd "$(dirname "${BASH_SOURCE[0]}")"
source ./env.sh

namespace="gitlab"
release="gitlab"
keycloak_namespace="keycloak"
host="$HOST"
realm="${GITLAB_KEYCLOAK_REALM:-$HEADLAMP_KEYCLOAK_REALM}"
client_id="${GITLAB_KEYCLOAK_CLIENT_ID:-gitlab}"
block_new_users="${GITLAB_OIDC_BLOCK_NEW_USERS:-true}"
redirect_uri="https://${host}/gitlab/users/auth/openid_connect/callback"
# First boot runs all DB migrations - give it plenty of time.
rollout_timeout="${GITLAB_ROLLOUT_TIMEOUT:-25m}"

create_namespace() {
    if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
        echo "Namespace '$namespace' not found. Creating..."
        kubectl create namespace "$namespace"
    fi
}

# --- Keycloak client for GitLab ---------------------------------------------
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
    if ! kcadm get "realms/$realm" >/dev/null 2>&1; then
        kcadm create realms -s realm="$realm" -s enabled=true
        echo "Realm '$realm' created."
    fi
}

ensure_gitlab_client() {
    echo "--- Ensuring Keycloak client '$client_id' in realm '$realm' ---"

    local existing_id
    existing_id=$(kcadm get clients -r "$realm" -q "clientId=$client_id" --fields id \
      | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 \
      | sed -E 's/.*"([^"]+)"$/\1/' || true)

    if [ -n "$existing_id" ]; then
        echo "Client '$client_id' already exists (id=$existing_id)."
        client_uuid="$existing_id"
    else
        client_uuid=$(kcadm create clients -r "$realm" \
          -s clientId="$client_id" \
          -s name="GitLab" \
          -s protocol=openid-connect \
          -s publicClient=false \
          -s standardFlowEnabled=true \
          -s directAccessGrantsEnabled=false \
          -s serviceAccountsEnabled=false \
          -s "redirectUris=[\"${redirect_uri}\"]" \
          -s "webOrigins=[\"https://${host}\"]" \
          -i)
        echo "Client '$client_id' created (id=$client_uuid)."
        kcadm create "clients/$client_uuid/client-secret" -r "$realm" >/dev/null
    fi

    # Keep redirect URI / web origins / root URL in sync on every run, so a
    # stale or hand-made client can't cause "Invalid parameter: redirect_uri".
    kcadm update "clients/$client_uuid" -r "$realm" \
      -s "rootUrl=https://${host}/gitlab" \
      -s "redirectUris=[\"${redirect_uri}\"]" \
      -s "webOrigins=[\"https://${host}\"]" \
      -s 'attributes."pkce.code.challenge.method"=S256' \
      -s 'attributes."post.logout.redirect.uris"=https://'"${host}"'/gitlab/*'

    # Read the client's CURRENT secret (no regeneration) - whatever Keycloak
    # has is the source of truth, so GitLab can never hold a stale one.
    client_secret=$(kcadm get "clients/$client_uuid/client-secret" -r "$realm" \
      | grep -oE '"value"[[:space:]]*:[[:space:]]*"[^"]+"' \
      | sed -E 's/.*"([^"]+)"$/\1/' || true)

    if [ -z "$client_secret" ]; then
        echo "Error: failed to read the client secret from Keycloak." >&2
        echo "  kubectl exec -n $keycloak_namespace $keycloak_pod -- /opt/keycloak/bin/kcadm.sh get clients/$client_uuid/client-secret -r $realm --config /tmp/kcadm.config" >&2
        exit 1
    fi
}

store_oidc_secret() {
    echo "--- Storing GitLab OIDC client secret in Kubernetes ---"
    local current=""
    current=$(kubectl get secret gitlab-oidc -n "$namespace" \
      -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d 2>/dev/null || true)

    if [ "$current" = "$client_secret" ]; then
        echo "Secret 'gitlab-oidc' already matches Keycloak."
        secret_changed=false
        return 0
    fi

    mkdir -p ./secrets
    kubectl create secret generic gitlab-oidc \
      --from-literal=client-secret="$client_secret" \
      --namespace "$namespace" \
      --dry-run=client -o yaml > ./secrets/gitlab-oidc-secret.yaml
    kubectl apply -f ./secrets/gitlab-oidc-secret.yaml
    # Only a real change needs a restart - and only if GitLab was already
    # running with the old value (a fresh install reads it at first start).
    if [ -n "$current" ]; then secret_changed=true; else secret_changed=false; fi
}

# --- In-cluster reachability + TLS trust for https://$host/keycloak ---------
resolve_traefik_ip() {
    traefik_ip=$(kubectl get svc traefik -n kube-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    if [ -z "$traefik_ip" ]; then
        echo "Warning: couldn't find the 'traefik' Service in kube-system - no hostAlias" >&2
        echo "for '$host' will be added. If GitLab can't reach https://${host}/keycloak" >&2
        echo "from inside the pod, set gitlab.oidc.internalIngressIP by hand." >&2
    fi
}

# Copies the homelab CA (from init-tls.sh) into this namespace directly, so
# this works whether init-tls.sh ran before or after the first GitLab install.
sync_ca() {
    if kubectl get secret homelab-ca-secret -n cert-manager >/dev/null 2>&1; then
        echo "--- Trusting the homelab CA inside GitLab (for its calls to Keycloak) ---"
        local ca_cert
        ca_cert="$(mktemp -t homelab-ca-XXXXXX.crt)"
        kubectl get secret homelab-ca-secret -n cert-manager \
          -o jsonpath='{.data.tls\.crt}' | base64 -d > "$ca_cert"
        kubectl create configmap gitlab-ca \
          --from-file=ca.crt="$ca_cert" \
          --namespace "$namespace" \
          --dry-run=client -o yaml | kubectl apply -f -
        rm -f "$ca_cert"
        ca_configmap="gitlab-ca"
    else
        echo "Warning: no homelab CA found (run ./init-tls.sh). GitLab won't trust" >&2
        echo "Traefik's cert, so 'Sign in with Keycloak' will fail with an SSL error" >&2
        echo "until you do - then just re-run this script. Local root login still works." >&2
        ca_configmap=""
    fi
}

# Guard: the chart's postgresql.dataSubdir changes with each PostgreSQL major.
# Installing it over a cluster that still runs an older major would start an
# EMPTY database - that move has to go through ./upgrade-gitlab.sh.
check_postgres_major() {
    [ "${#extra_helm_args[@]}" -eq 0 ] || return 0
    local running wanted
    running=$(kubectl get deploy gitlab-postgres -n "$namespace"       -o jsonpath='{.spec.template.spec.containers[?(@.name=="postgres")].env[?(@.name=="PGDATA")].value}' 2>/dev/null || true)
    [ -n "$running" ] || return 0
    wanted=$(grep -E '^  dataSubdir:' ./gitlab/values.yaml | sed -E 's/.*"([^"]+)".*/\1/')
    if [ "$(basename "$running")" != "$wanted" ]; then
        echo "Error: gitlab-postgres runs PGDATA=$running but the chart wants .../$wanted" >&2
        echo "(a PostgreSQL major upgrade). Run ./upgrade-gitlab.sh instead." >&2
        exit 1
    fi
}

install_gitlab() {
    echo "--- Installing GitLab CE (https://$host/gitlab) ---"
    helm upgrade --install "$release" ./gitlab \
      --namespace "$namespace" \
      --create-namespace \
      --set gitlab.host="$host" \
      --set gitlab.oidc.enabled=true \
      --set gitlab.oidc.keycloakBaseUrl="https://${host}/keycloak" \
      --set gitlab.oidc.realm="$realm" \
      --set gitlab.oidc.clientId="$client_id" \
      --set gitlab.oidc.existingSecret=gitlab-oidc \
      --set gitlab.oidc.blockAutoCreatedUsers="$block_new_users" \
      --set gitlab.oidc.internalIngressIP="$traefik_ip" \
      --set gitlab.oidc.trustCAConfigMap="$ca_configmap" \
      ${extra_helm_args[@]+"${extra_helm_args[@]}"}
}

wait_for_gitlab() {
    if [ "$secret_changed" = true ]; then
        echo "--- Client secret changed - restarting GitLab to pick it up ---"
        kubectl rollout restart deployment/gitlab -n "$namespace"
    fi

    kubectl rollout status deployment/gitlab-postgres -n "$namespace" --timeout=5m
    kubectl rollout status deployment/gitlab-redis -n "$namespace" --timeout=5m

    echo "--- Waiting for GitLab (first boot / restarts take 5-15 minutes) ---"
    if ! kubectl rollout status deployment/gitlab -n "$namespace" --timeout="$rollout_timeout"; then
        echo "GitLab isn't ready yet. Follow progress with:" >&2
        echo "  kubectl -n $namespace logs -f deploy/gitlab" >&2
        exit 1
    fi
}

print_summary() {
    echo
    echo "--- GitLab install complete ---"
    echo "URL: https://$host/gitlab"
    echo
    echo "SSO: 'Sign in with Keycloak' - users in realm '$realm'."
    echo "  Give them an email address in Keycloak (GitLab needs one)."
    if [ "$block_new_users" = true ]; then
        echo "  First-time SSO users wait for approval: log in as root ->"
        echo "  Admin -> Users -> Pending approval -> Approve. Make someone an"
        echo "  admin via Admin -> Users -> Edit -> Access level: Administrator."
    fi
    echo
    echo "Local admin (fallback if Keycloak is down):"
    echo "  Username: root"
    if pw=$(kubectl exec -n "$namespace" deploy/gitlab -- \
            sh -c "grep '^Password:' /etc/gitlab/initial_root_password 2>/dev/null | cut -d' ' -f2"); [ -n "$pw" ]; then
        echo "  Password: $pw"
        echo "  (GitLab deletes this file 24h after first boot - change the root password now.)"
    else
        echo "  Password: already changed / initial file expired. Reset with:"
        echo "    kubectl -n $namespace exec -it deploy/gitlab -- gitlab-rake \"gitlab:password:reset[root]\""
    fi
}

# --- Run ---
create_namespace
check_postgres_major
find_keycloak_pod
login_kcadm
create_realm_if_missing
ensure_gitlab_client
store_oidc_secret
resolve_traefik_ip
sync_ca
install_gitlab
wait_for_gitlab
print_summary
