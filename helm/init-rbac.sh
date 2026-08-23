#!/bin/bash
set -euo pipefail

# Wires Keycloak groups into real, per-user Kubernetes RBAC for anyone who
# logs into Headlamp via SSO. This script handles everything that's safe to
# automate against the live cluster:
#   - a "groups" claim mapper on the Keycloak "headlamp" client
#   - two Keycloak groups: k8s-admins, k8s-viewers
#   - ClusterRoleBindings mapping those groups to cluster-admin / view
#
# It does NOT touch the k3s API server itself - that's a node-level change
# with real outage risk if botched, so it's the separate ./configure-k3s-oidc.sh
# script, run by hand on the k3s node. See helm/headlamp/README.md.
#
# Run this AFTER init-headlamp.sh (needs the "headlamp" client to exist) and
# BEFORE or AFTER configure-k3s-oidc.sh - order between those two doesn't
# matter, but neither one does anything for real Kubernetes access until
# both have run.

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

keycloak_namespace="keycloak"
realm="$HEADLAMP_KEYCLOAK_REALM"
client_id="$HEADLAMP_KEYCLOAK_CLIENT_ID"
group_prefix="$K8S_GROUP_PREFIX"

find_keycloak_pod() {
    keycloak_pod=$(kubectl get pods -n "$keycloak_namespace" -l app.kubernetes.io/instance=keycloak \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [ -z "$keycloak_pod" ]; then
        echo "Error: could not find a running Keycloak pod in namespace '$keycloak_namespace'." >&2
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

find_client_uuid() {
    client_uuid=$(kcadm get clients -r "$realm" -q "clientId=$client_id" --fields id \
      | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 \
      | sed -E 's/.*"([^"]+)"$/\1/' || true)

    if [ -z "$client_uuid" ]; then
        echo "Error: client '$client_id' not found in realm '$realm'." >&2
        echo "Run init-headlamp.sh first." >&2
        exit 1
    fi
}

add_groups_mapper() {
    echo "--- Adding a 'groups' claim mapper to client '$client_id' ---"

    local existing
    existing=$(kcadm get "clients/$client_uuid/protocol-mappers/models" -r "$realm" \
      | grep -oE '"name"[[:space:]]*:[[:space:]]*"groups"' || true)

    if [ -n "$existing" ]; then
        echo "Mapper 'groups' already exists on client '$client_id'. Skipping."
        return 0
    fi

    kcadm create "clients/$client_uuid/protocol-mappers/models" -r "$realm" \
      -s name=groups \
      -s protocol=openid-connect \
      -s protocolMapper=oidc-group-membership-mapper \
      -s 'config."full.path"=false' \
      -s 'config."id.token.claim"=true' \
      -s 'config."access.token.claim"=true' \
      -s 'config."userinfo.token.claim"=true' \
      -s 'config."claim.name"=groups'

    echo "Mapper created - '$client_id' tokens now carry a flat 'groups' claim."
}

create_group_if_missing() {
    local group_name="$1"
    local existing
    existing=$(kcadm get groups -r "$realm" \
      | grep -oE '"name"[[:space:]]*:[[:space:]]*"'"${group_name}"'"' || true)

    if [ -n "$existing" ]; then
        echo "Group '$group_name' already exists. Skipping."
    else
        kcadm create groups -r "$realm" -s name="$group_name"
        echo "Group '$group_name' created."
    fi
}

apply_cluster_role_bindings() {
    echo "--- Binding Keycloak groups to Kubernetes RBAC ---"
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: k8s-admins-cluster-admin
subjects:
  - kind: Group
    name: "${group_prefix}k8s-admins"
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: k8s-viewers-view
subjects:
  - kind: Group
    name: "${group_prefix}k8s-viewers"
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
EOF
}

# --- Run ---
find_keycloak_pod
login_kcadm
find_client_uuid
add_groups_mapper
create_group_if_missing "k8s-admins"
create_group_if_missing "k8s-viewers"
apply_cluster_role_bindings

echo ""
echo "--- Done ---"
echo "Keycloak groups 'k8s-admins' / 'k8s-viewers' exist and Kubernetes will"
echo "map them to cluster-admin / view once tokens carry group names as"
echo "'${group_prefix}k8s-admins' / '${group_prefix}k8s-viewers' - that prefixing"
echo "happens at the API server, via configure-k3s-oidc.sh."
echo ""
echo "Assign people to a group in the Keycloak admin console:"
echo "  realm '$realm' -> Users -> pick a user -> Groups tab -> Join."
echo ""
echo "This has no effect on real Kubernetes access until the API server trusts"
echo "Keycloak as an OIDC provider - run configure-k3s-oidc.sh next (on the k3s"
echo "node itself) if you haven't already."
