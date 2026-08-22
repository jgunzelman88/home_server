#!/bin/bash
set -euo pipefail

# NOTE: this trusts whatever ad-hoc cert Traefik happens to be presenting
# *right now*, which can regenerate on a Traefik restart and silently break
# again later. For the durable fix (a stable cert-manager CA that Traefik
# always serves for "bwing", which also covers every other app in this repo),
# run ./init-tls.sh instead - this script is kept as a quick one-off fallback.

namespace="headlamp"
host="bwing"

echo "--- Extracting the cert Traefik currently presents for $host ---"
cert_file="$(mktemp -t traefik-cert-XXXXXX.pem)"

echo | openssl s_client -connect "${host}:443" -servername "$host" 2>/dev/null \
  | openssl x509 -outform PEM > "$cert_file"

if [ ! -s "$cert_file" ]; then
    echo "Error: didn't get a certificate back from ${host}:443. Is it reachable from here?" >&2
    exit 1
fi

echo "--- Checking it actually covers '$host' ---"
if openssl x509 -in "$cert_file" -noout -text | grep -A1 "Subject Alternative Name" | grep -q "$host"; then
    echo "OK: '$host' is in the certificate's SAN."
else
    echo "WARNING: '$host' was not found in the certificate's Subject Alternative Name." >&2
    echo "Trusting this cert alone likely won't be enough - Go's TLS client also checks" >&2
    echo "the hostname. Headlamp's login may still fail with a TLS error after this." >&2
fi

echo "--- Loading it into the '$namespace' namespace as ConfigMap 'headlamp-ca' ---"
kubectl create configmap headlamp-ca \
  --from-file=ca.crt="$cert_file" \
  --namespace "$namespace" \
  --dry-run=client -o yaml | kubectl apply -f -

rm -f "$cert_file"

echo "--- Upgrading the Headlamp Helm release to pick it up ---"
helm upgrade headlamp headlamp/headlamp \
  -f ./headlamp/values.yaml \
  --namespace "$namespace"

echo ""
echo "--- Done ---"
echo "Restarting the pod so it re-reads the mounted CA:"
kubectl rollout restart deployment/headlamp -n "$namespace" 2>/dev/null \
  || echo "(couldn't find deployment/headlamp - check 'kubectl get deploy -n $namespace' for the real name and restart it manually)"
echo ""
echo "Try logging into https://${host}/headlamp again once the pod is back up:"
echo "  kubectl rollout status deployment/headlamp -n $namespace"
echo ""
echo "Note: Traefik's default cert can regenerate on a Traefik restart, which would"
echo "silently invalidate this again. If TLS errors come back later, re-run this"
echo "script - or ask about the more durable fix (a stable cert-manager CA bound to"
echo "Traefik's TLSStore instead of Traefik's ad-hoc self-signed default cert)."
