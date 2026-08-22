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
4. Creates a realm (default: `home` - override with `HEADLAMP_KEYCLOAK_REALM`)
   if it doesn't already exist, and a confidential OIDC client named
   `headlamp` in that realm, with redirect URI
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
* **Cluster access**: `clusterRoleBinding.clusterRoleName: cluster-admin`
  grants full access to anyone who logs in via Keycloak, matching how the
  other admin tools in this repo are set up. Real per-user RBAC (different
  Keycloak users getting different Kubernetes permissions) additionally
  requires configuring the k3s API server itself as an OIDC client
  (`--oidc-issuer-url`, etc.) - out of scope here, but Headlamp's own docs
  cover it if you want to go further.

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
