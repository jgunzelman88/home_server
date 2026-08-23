#!/bin/bash
set -euo pipefail

# Run this ON THE K3S CONTROL-PLANE NODE ITSELF (the "bwing" host), as root.
# It is the highest-risk step in the OIDC/RBAC setup: a bad kube-apiserver
# flag can stop k3s's API server from starting at all, which means losing
# kubectl/Headlamp access to EVERYTHING until it's fixed. Read this whole
# script before running it.
#
# What it does:
#   1. Exports the homelab CA (from init-tls.sh) to disk so the API server
#      can validate Keycloak's TLS cert when it fetches OIDC discovery info.
#   2. Backs up /etc/rancher/k3s/config.yaml and appends kube-apiserver-arg
#      entries pointing the API server at Keycloak as an OIDC provider.
#   3. Restarts k3s and waits for the API server to come back healthy. If it
#      doesn't within 60s, it tells you exactly how to roll back.
#
# Refuses to touch config.yaml automatically if it already has apiserver
# args in it, to avoid mangling something you already set up - see the
# printed instructions in that case instead.

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

config_file="/etc/rancher/k3s/config.yaml"
ca_dest="/etc/rancher/k3s/homelab-ca.crt"
realm="$HEADLAMP_KEYCLOAK_REALM"
client_id="$HEADLAMP_KEYCLOAK_CLIENT_ID"
group_prefix="$K8S_GROUP_PREFIX"
host="$HOST"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this as root (sudo ./configure-k3s-oidc.sh)." >&2
    exit 1
fi

mkdir -p "$(dirname "$config_file")"

echo "--- Exporting the homelab CA so the API server can trust '$host' ---"
kubectl get secret homelab-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' \
  | base64 -d > "$ca_dest"
chmod 644 "$ca_dest"

oidc_args() {
    cat <<EOF
  - "oidc-issuer-url=https://${host}/keycloak/realms/${realm}"
  - "oidc-client-id=${client_id}"
  - "oidc-username-claim=preferred_username"
  - "oidc-username-prefix=oidc:"
  - "oidc-groups-claim=groups"
  - "oidc-groups-prefix=${group_prefix}"
  - "oidc-ca-file=${ca_dest}"
EOF
}

if [ -f "$config_file" ] && grep -q "oidc-issuer-url" "$config_file"; then
    echo "'$config_file' already has an oidc-issuer-url entry - not touching it."
    echo "Edit it by hand if you need to change realm/client/prefix, then:"
    echo "  systemctl restart k3s"
    exit 0
fi

if [ -f "$config_file" ] && grep -q "kube-apiserver-arg" "$config_file"; then
    echo "'$config_file' already has a kube-apiserver-arg list - refusing to" >&2
    echo "auto-append and risk mangling it. Add these lines under your" >&2
    echo "existing 'kube-apiserver-arg:' list by hand instead:" >&2
    echo "" >&2
    oidc_args >&2
    echo "" >&2
    echo "Then: systemctl restart k3s" >&2
    exit 1
fi

echo "--- Backing up $config_file ---"
backup_file="${config_file}.bak.$(date +%s)"
cp "$config_file" "$backup_file" 2>/dev/null && echo "Backed up to $backup_file" \
  || echo "(no existing $config_file to back up - creating a new one)"

echo "--- Appending OIDC apiserver args ---"
{
    echo "kube-apiserver-arg:"
    oidc_args
} >> "$config_file"

echo "--- Restarting k3s ---"
systemctl restart k3s

echo "--- Waiting for the API server to come back ---"
for i in $(seq 1 30); do
    if kubectl get --raw='/readyz' >/dev/null 2>&1; then
        echo "API server is up and healthy."
        echo ""
        echo "Log into https://${host}/headlamp as a user in the 'k8s-admins' or"
        echo "'k8s-viewers' Keycloak group (see init-rbac.sh) and confirm you can"
        echo "(or, for viewers, can't) make changes."
        exit 0
    fi
    sleep 2
done

echo "Error: API server did not come back healthy within 60s." >&2
echo "Check: journalctl -u k3s -n100 --no-pager" >&2
if [ -n "${backup_file:-}" ] && [ -f "$backup_file" ]; then
    echo "To roll back:" >&2
    echo "  cp $backup_file $config_file && systemctl restart k3s" >&2
fi
exit 1
