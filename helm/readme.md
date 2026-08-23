# home_server Kubernetes setup

## Pre-requisites

* k3s installed on the node these scripts run on.
* k9s (handy for poking around, not required by any script).
* **Run every script in this directory ON THE K3S NODE ITSELF** (the `bwing`
  host) - `init-keycloak.sh`/`init-traefik.sh` write directly to
  `/var/lib/rancher/k3s/server/manifests/` on disk, and
  `configure-k3s-oidc.sh` edits `/etc/rancher/k3s/config.yaml` and restarts
  the `k3s` systemd service. None of this works from a separate admin
  workstation unless that machine *is* the k3s node.
* `env.sh` centralizes the handful of values every Headlamp/Keycloak-related
  script needs to agree on (the LAN hostname, the Keycloak realm, the
  Headlamp client ID, the OIDC group prefix). Every script sources it
  automatically - override any of them per-run the same way as before, e.g.
  `HEADLAMP_KEYCLOAK_REALM=other-realm ./init-rbac.sh`. You shouldn't need to
  edit `env.sh` itself unless you're deliberately changing one of those
  values everywhere at once.

## Install order

Each app is independent except where noted - jellyfin/n8n don't need
anything below. Headlamp and the OIDC/RBAC scripts build on each other in
this order:

1. **`./init-keycloak.sh`** - installs cert-manager, turns on HTTPS on
   Traefik (by calling `init-traefik.sh`), and installs Keycloak + its own
   Postgres. Safe to re-run (picks up `keycloak/values.yaml` changes via
   `helm upgrade`).
2. **`./init-headlamp.sh`** - installs Headlamp (the Kubernetes dashboard),
   creates a confidential OIDC client for it in Keycloak, and wires Keycloak
   SSO login into `headlamp/values.yaml`. Safe to re-run - it also rotates
   the client secret and restarts the Headlamp pod every time, so only
   re-run it when you actually want that (e.g. after `init-headlamp.sh`
   itself changed, or the secret leaked) rather than out of habit.
3. **`./init-tls.sh`** (optional but recommended) - replaces Traefik's
   ad-hoc, restart-unstable self-signed cert with a stable one from your own
   cert-manager CA. Fixes SSO logins breaking after a Traefik restart. Safe
   to re-run.
4. **`./init-rbac.sh`** + **`./configure-k3s-oidc.sh`** (optional) - maps
   Keycloak groups `k8s-admins`/`k8s-viewers` to real per-user Kubernetes
   RBAC, so who can do what in Headlamp depends on Keycloak group
   membership instead of everyone sharing one access level. `init-rbac.sh`
   is safe to re-run; `configure-k3s-oidc.sh` is a **one-time, node-level,
   higher-risk step** (see its own header comment) - run it once, not on a
   whim. Order between the two doesn't matter, but neither does anything for
   real access until both have run. Full details in
   `headlamp/README.md`'s "Per-group Kubernetes RBAC" section.

Independent apps, run whenever:

* **`./init-jellyfin.sh`** - installs Jellyfin into the `media` namespace.
* **`./init-n8n.sh`** - installs n8n into the `n8n` namespace. Its
  encryption key is generated once and stored in a Secret
  (`n8n-encryption-key`) - re-running this script reuses it rather than
  rotating it, which would otherwise make every previously-saved n8n
  credential undecryptable.

Fallback/one-off:

* **`./fix-headlamp-tls.sh`** - quick fix if Headlamp's SSO login fails with
  a TLS error and you haven't run (or don't want to run) `init-tls.sh` yet.
  Trusts whatever cert Traefik happens to be presenting *right now*, which
  can regenerate on a Traefik restart and need re-running later - `init-tls.sh`
  is the durable version of this fix.

## Uninstalling

* **`./uninstall-keycloak.sh`** - interactive, asks before deleting anything
  destructive (PVCs/DB data, the namespace, cert-manager, the Traefik HTTPS
  config, shared with other apps).
* **`./uninstall-headlamp.sh`** - interactive, same pattern. Also offers to
  delete the Keycloak client `init-headlamp.sh` created.

Neither uninstall script touches `init-tls.sh`'s CA/cert-manager resources
or `configure-k3s-oidc.sh`'s API server config - both of those are shared
cluster-wide infrastructure, not specific to either app, so tearing them
down isn't bundled into either app's uninstall.

## What's safe to re-run vs. not

Most scripts here are idempotent by design (check-then-create, or plain
`kubectl apply`/`helm upgrade --install`) and safe to run repeatedly. Two
exceptions worth knowing:

* **`configure-k3s-oidc.sh`** edits a node-level system file and restarts
  the k3s service - a bad value here can take down `kubectl`/Headlamp access
  entirely until fixed. It refuses to auto-edit `config.yaml` if it detects
  existing `kube-apiserver-arg` entries it didn't add, and backs up the file
  before changing it either way.
* **`init-headlamp.sh`** rotates the Keycloak client secret and restarts the
  Headlamp pod on every run (this is deliberate - see its comments on why a
  stale secret used to cause silent `unauthorized_client` login failures).
  That's harmless but means a Headlamp login session gets nothing worse than
  a pod restart if you re-run it unnecessarily.
