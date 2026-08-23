#!/bin/bash
set -euo pipefail

namespace="media"

if helm status jellyfin -n "$namespace" >/dev/null 2>&1; then
    echo "Jellyfin already installed, upgrading..."
    helm upgrade jellyfin ./jellyfin --namespace "$namespace"
else
    helm install jellyfin ./jellyfin --namespace "$namespace" --create-namespace
fi
