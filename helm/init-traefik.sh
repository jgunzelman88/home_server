#!/bin/bash
set -euo pipefail

# One-time cluster infra: turns on HTTPS on k3s's bundled Traefik (redirects
# plain HTTP to HTTPS, enables TLS on the websecure entrypoint, hides the
# built-in Traefik dashboard route). Every app in this repo that terminates
# TLS through Traefik depends on this having been run at least once.
#
# Run this ON THE K3S NODE ITSELF - it writes directly to k3s's manifests
# directory on disk, the same way init-keycloak.sh (which calls this script
# as its first step) always has.
#
# Safe to re-run: only touches the file and restarts Traefik if the config
# actually changed, so re-running init-keycloak.sh doesn't bounce Traefik
# (and briefly disrupt every app's ingress) every single time.

config_file="/var/lib/rancher/k3s/server/manifests/traefik-config.yaml"

desired_config=$(cat <<'TRAEFIK'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    ports:
      web:
        redirectTo:
          port: websecure
      websecure:
        tls:
          enabled: true
    ingressRoute:
      dashboard:
        enabled: false
TRAEFIK
)

if [ -f "$config_file" ] && [ "$(cat "$config_file")" = "$desired_config" ]; then
    echo "Traefik HTTPS config already up to date - skipping restart."
    exit 0
fi

echo "--- Configuring Traefik for HTTPS ---"
echo "$desired_config" > "$config_file"

echo "Traefik config applied. Waiting for rollout..."
kubectl rollout restart deployment/traefik -n kube-system
kubectl rollout status deployment/traefik -n kube-system --timeout=60s
