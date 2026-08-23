# Headlamp on k3s, with Keycloak SSO

Deploys [Headlamp](https://headlamp.dev) (the Kubernetes web UI) using the
official upstream Helm chart, served at **https://bwing/headlamp** through
Traefik, and logged into via the existing Keycloak instance at
**https://bwing/keycloak**.

Unlike the other charts in `helm/` (jellyfin, n8n, octoprint, postgres),
Headlamp doesn't have hand-rolled templates here - `values.yaml` just
configures the chart published by the Headlamp project itself, the same way
`../keycloak/values.yaml` configures codecentric's `keycloakx` chart.

## Prerequisites

* Keycloak already installed and reachable at `https://bwing/keycloak`
  (i.e. `helm/init-keycloak.sh` has already been run).
* `kubectl` access to the cluster, and the `keycloak-secrets` Secret
  (created by `init-keycloak.sh`) still present in the `keycloak` namespace -
  `init-headlamp.sh` reads the Keycloak admin password from it.

## Install

```bash
cd helm
./init-headlamp.sh
```

This script:

1. Creates the `headlamp` namespace.
2. Adds the `headlamp` Helm repo (`https://kubernetes-sigs.github.io/headlamp/`).
3. Logs into Keycloak's admin CLI (`kcadm.sh`, run via `kubectl exec` into
   the Keycloak pod) using the admin password from the `keycloak-secrets`
   Secret.
4. Creates a realm (default: `master`, set in `../env.sh` - override per-run
   with `HEADLAMP_KEYCLOAK_REALM`) if it doesn't already exist, and a
   confidential OIDC client named `headlamp` in that realm, with redirect URI
   `https://bwing/headlamp/oidc-callback`.
5. Generates a client secret and stores it, along with the client ID and
   issuer URL, in a Kubernetes Secret named `headlamp-oidc` in the
   `headlamp` namespace (keys: `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`,
   `OIDC_ISSUER_URL`, `OIDC_SCOPES`) - this is what `values.yaml`'s
   `config.oidc.externalSecret` points at.
6. Installs/upgrades the `headlamp` Helm release from `./headlamp/values.yaml`.

After it finishes, create at least one user in the realm it printed
(Keycloak admin console → your realm → Users → Add user, then set a
password under the Credentials tab) - that's who can log into Headlamp.

## How it works

* **Subpath routing**: `config.baseURL: /headlamp` tells Headlamp itself to
  generate and expect URLs under `/headlamp`, so - like Keycloak's
  `http.relativePath` - there's no `stripPrefix` middleware involved (unlike
  n8n/octoprint, which run at `/` internally and need one).
* **TLS/headers**: an `extraManifests` entry creates a `headlamp-headers`
  Traefik `Middleware` (forces `X-Forwarded-Proto: https`), referenced from
  the `Ingress` annotations - the same role as `init-keycloak.sh`'s
  `keycloak-headers` Middleware, just declared inside the chart instead of
  applied imperatively, so `helm uninstall` cleans it up too.
* **SSO login**: `config.oidc.externalSecret` points Headlamp at the
  `headlamp-oidc` Secret `init-headlamp.sh` creates, so the actual client
  secret never lives in this repo. `config.oidc.callbackURL` /
  `env: OIDC_CALLBACK_URL` are both set explicitly to
  `https://bwing/headlamp/oidc-callback` - behind a reverse-proxy subpath
  Headlamp can't always infer this correctly on its own.
* **Cluster access**: `clusterRoleBinding` grants Headlamp's own
  ServiceAccount a minimal `view` fallback - it's not what controls what a
  logged-in *person* can do. See the next section for that.

## Per-group Kubernetes RBAC

Logging into Headlamp via Keycloak only gates the *web UI*. What a logged-in
person can actually do to the cluster is a separate question, answered by
whether the Kubernetes API server itself trusts Keycloak tokens and how
Keycloak's group claims map to Kubernetes RBAC. Two scripts set this up:

1. **`../init-rbac.sh`** (safe to run against the live cluster) - adds a
   `groups` claim mapper to the `headlamp` Keycloak client, creates two
   Keycloak groups (`k8s-admins`, `k8s-viewers`), and applies
   `ClusterRoleBinding`s mapping them to the built-in `cluster-admin` and
   `view` ClusterRoles.
2. **`../configure-k3s-oidc.sh`** (run by hand, as root, **on the k3s node
   itself**) - the piece that actually matters: it adds
   `--oidc-issuer-url`, `--oidc-client-id`, `--oidc-username-claim`,
   `--oidc-groups-claim` (plus `oidc-*-prefix` flags, to stop a
   maliciously- or accidentally-named Keycloak group like `system:masters`
   from colliding with a real Kubernetes identity) to k3s's API server, and
   points `--oidc-ca-file` at the homelab CA from `init-tls.sh` so it can
   validate Keycloak's cert. This is a node-level system file edit with real
   outage risk if it's wrong - the script backs up `config.yaml` first and
   automatically tells you how to roll back if the API server doesn't come
   back healthy.

Order between the two doesn't matter, but neither does anything for real
access until *both* have run. After that: put someone in the `k8s-admins`
or `k8s-viewers` Keycloak group (Users → a user → Groups tab → Join) and
they'll get `cluster-admin` or read-only access respectively when they log
into Headlamp - because Headlamp forwards their own Keycloak token to the
Kubernetes API rather than using its own ServiceAccount (that's what
`unsafeUseServiceAccountToken: false`, the default, means).

Group and role names beyond these two are entirely up to you - create more
Keycloak groups and `ClusterRoleBinding`s (or `RoleBinding`s, for
namespace-scoped access) the same way.

## Making the TLS trust permanent

Headlamp's OIDC login requires its backend to make outbound HTTPS calls to
Keycloak (the discovery doc + token exchange), which means it must trust
whatever cert Traefik presents for `bwing`. By default that's Traefik's own
ad-hoc self-signed cert, which **can regenerate on a Traefik restart** and
silently break SSO again.

Run `../init-tls.sh` once to fix this properly: it mints a stable, self-signed
homelab CA via cert-manager, issues a long-lived leaf cert for `bwing` from
it, points Traefik's `TLSStore` at that cert (which benefits every app in
this repo, not just Headlamp), and drops the CA into a `headlamp-ca`
ConfigMap that this chart's `values.yaml` already mounts via `SSL_CERT_FILE`.
After that, Traefik's cert for `bwing` stops changing out from under you.

`./fix-headlamp-tls.sh` still exists as a quick one-off fallback (it just
trusts whatever cert Traefik happens to be serving right now), but it can
need re-running if Traefik ever regenerates its default cert.

## Rotating the client secret

Re-run `init-headlamp.sh` - it detects the existing `headlamp` client,
generates a fresh secret, rewrites the `headlamp-oidc` Secret, and upgrades
the Helm release so the new pod picks it up.

## Troubleshooting

* **Redirects to the wrong URL / callback mismatch**: double check the
  client's "Valid redirect URIs" in the Keycloak admin console match
  `https://bwing/headlamp/oidc-callback` exactly.
* **Login hangs or 431/oversized-request errors**: Keycloak tokens can be
  larger than some proxy defaults expect; if you put anything else in front
  of Traefik, raise its header/buffer size limits.
* **"invalid_client" on login**: the `headlamp-oidc` Secret is stale (e.g.
  Keycloak was reinstalled and the client secret changed) - re-run
  `init-headlamp.sh`.
