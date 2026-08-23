#!/bin/bash
# Shared config for every script in this directory. SOURCE this, don't run
# it directly:
#   source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
#
# This exists because the same values (the LAN hostname, the Keycloak realm,
# the Headlamp client ID, the OIDC group prefix) used to be copy-pasted as
# defaults across init-headlamp.sh, uninstall-headlamp.sh, init-rbac.sh, and
# configure-k3s-oidc.sh independently. They drifted out of sync at least
# once already (uninstall-headlamp.sh kept defaulting to a realm that had
# since been changed everywhere else) - one source of truth now instead.
#
# Every value here can still be overridden per-invocation the same way as
# before, e.g.: HEADLAMP_KEYCLOAK_REALM=other-realm ./init-rbac.sh

HOST="${HOST:-bwing}"
HEADLAMP_KEYCLOAK_REALM="${HEADLAMP_KEYCLOAK_REALM:-master}"
HEADLAMP_KEYCLOAK_CLIENT_ID="${HEADLAMP_KEYCLOAK_CLIENT_ID:-headlamp}"
# Must match --oidc-groups-prefix passed to the k3s API server in
# configure-k3s-oidc.sh - kept here too so init-rbac.sh's ClusterRoleBindings
# always agree with it.
K8S_GROUP_PREFIX="${K8S_GROUP_PREFIX:-oidc:}"
