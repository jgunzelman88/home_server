#!/bin/bash
set -euo pipefail

# Gives Traefik a STABLE, correctly-named certificate for "bwing" instead of
# its ad-hoc self-signed default cert (which can regenerate on a Traefik
# restart and silently break anything that trusts it, e.g. Headlamp's OIDC
# calls to Keycloak - see fix-headlamp-tls.sh's warning about this).
#
# Uses cert-manager (already installed by init-keycloak.sh) to mint our own
# self-signed root CA once, then a leaf cert for "bwing" signed by that CA,
# and points Traefik's TLSStore at it. Because it's a real TLSStore default,
# EVERY app in this repo (keycloak, n8n, octoprint, jellyfin, headlamp) picks
# up the stable cert automatically - no per-app Ingress changes needed.
#
# Safe to re-run; all the resources below are declarative (kubectl apply).

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

ca_namespace="cert-manager"       # cert-manager's default cluster-resource-namespace
traefik_namespace="kube-system"   # where k3s runs its bundled Traefik
host="$HOST"

require_cert_manager() {
    if ! kubectl get namespace "$ca_namespace" >/dev/null 2>&1; then
        echo "Error: no '$ca_namespace' namespace found - run init-keycloak.sh first" >&2
        echo "(it installs cert-manager) or install cert-manager yourself." >&2
        exit 1
    fi
}

create_bootstrap_issuer() {
    echo "--- Creating bootstrap SelfSigned ClusterIssuer ---"
    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
EOF
}

create_root_ca() {
    echo "--- Creating homelab root CA (10y, self-signed once) ---"
    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: homelab-ca
  namespace: ${ca_namespace}
spec:
  isCA: true
  commonName: homelab-ca
  secretName: homelab-ca-secret
  duration: 87600h
  renewBefore: 720h
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
    group: cert-manager.io
EOF

    echo "Waiting for the root CA to be issued..."
    kubectl wait --for=condition=Ready certificate/homelab-ca \
      -n "$ca_namespace" --timeout=60s
}

create_ca_issuer() {
    echo "--- Creating ClusterIssuer backed by the homelab root CA ---"
    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: homelab-ca-issuer
spec:
  ca:
    secretName: homelab-ca-secret
EOF
}

create_bwing_cert() {
    echo "--- Issuing a leaf cert for '$host', signed by the homelab CA ---"
    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${host}-tls
  namespace: ${traefik_namespace}
spec:
  secretName: ${host}-tls
  dnsNames:
    - ${host}
  duration: 2160h
  renewBefore: 360h
  issuerRef:
    name: homelab-ca-issuer
    kind: ClusterIssuer
    group: cert-manager.io
EOF

    echo "Waiting for the '$host' certificate to be issued..."
    kubectl wait --for=condition=Ready "certificate/${host}-tls" \
      -n "$traefik_namespace" --timeout=60s
}

set_traefik_default_cert() {
    echo "--- Pointing Traefik's default TLS cert at '${host}-tls' ---"
    cat <<EOF | kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: TLSStore
metadata:
  name: default
  namespace: ${traefik_namespace}
spec:
  defaultCertificate:
    secretName: ${host}-tls
EOF
}

sync_headlamp_ca() {
    echo "--- Trusting the homelab CA inside Headlamp (for its OIDC calls to Keycloak) ---"

    if ! kubectl get namespace headlamp >/dev/null 2>&1; then
        echo "Namespace 'headlamp' not found - skipping (run init-headlamp.sh first if you want this)."
        return 0
    fi

    local ca_cert
    ca_cert="$(mktemp -t homelab-ca-XXXXXX.crt)"
    kubectl get secret homelab-ca-secret -n "$ca_namespace" \
      -o jsonpath='{.data.tls\.crt}' | base64 -d > "$ca_cert"

    kubectl create configmap headlamp-ca \
      --from-file=ca.crt="$ca_cert" \
      --namespace headlamp \
      --dry-run=client -o yaml | kubectl apply -f -

    rm -f "$ca_cert"

    if helm status headlamp -n headlamp >/dev/null 2>&1; then
        echo "Restarting Headlamp so it picks up the (now stable) CA..."
        kubectl rollout restart deployment/headlamp -n headlamp 2>/dev/null || true
    fi
}

# --- Run ---
require_cert_manager
create_bootstrap_issuer
create_root_ca
create_ca_issuer
create_bwing_cert
set_traefik_default_cert
sync_headlamp_ca

echo ""
echo "--- Done ---"
echo "Traefik now serves a stable, self-signed cert for '$host' (valid ~10 years"
echo "for the root, auto-renewed by cert-manager for the leaf) instead of its own"
echo "ad-hoc default cert. This applies to every app in this repo automatically."
echo ""
echo "Your browser will still warn about it (it's not a public CA) - to make that"
echo "go away too, export the root CA and trust it locally:"
echo "  kubectl get secret homelab-ca-secret -n ${ca_namespace} -o jsonpath='{.data.tls\\.crt}' | base64 -d > homelab-ca.crt"
echo "Then import homelab-ca.crt into your OS/browser's trusted root store."
