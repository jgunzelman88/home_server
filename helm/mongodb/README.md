# MongoDB + Compass Helm Chart (k3s)

Deploys a standalone MongoDB instance plus the real MongoDB Compass UI,
self-hosted as a web app, on k3s with Traefik ingress - following the same
conventions as the other charts in this `helm/` folder (`jellyfin`, `n8n`,
`octoprint`, `postgres`).

- **MongoDB** is exposed via a `ClusterIP` Service so any other pod in the
  cluster can connect to it.
- **Compass** is served at `https://bwing/mongo`, pre-connected to this
  release's MongoDB, and gated by Keycloak SSO.

## What "Compass" actually is here

This runs [**compass-web**](https://github.com/haohanyang/compass-web), a
self-hosted web build of the real MongoDB Compass interface - it's built on
MongoDB's own `@mongodb-js/compass-web` package (the same component behind
Atlas's Data Explorer), not a different admin tool standing in for Compass.
Unlike the desktop Compass app, this genuinely can run behind a web ingress
and be gated by SSO, and it has **native OIDC login** - no oauth2-proxy or
similar sidecar involved, Keycloak talks to it directly.

It's a small, lightly-staffed open-source project (not an official MongoDB
product) - worth a quick look at its repo/issues before relying on it
heavily, though it's active and the underlying UI is MongoDB's own code.

## Install

The easy way - `./init-mongodb.sh` (run from `helm/`, on the k3s node, same
as every other `init-*.sh` script in this repo) does all of the below for
you: creates the `mongodb` namespace, generates a MongoDB admin Secret,
creates a confidential OIDC client called `compass` in Keycloak (needs
`init-keycloak.sh` to have already been run), stores its secret plus a
freshly generated session secret in a second Secret, and installs/upgrades
the Helm release wired up to both.

```bash
cd helm
./init-mongodb.sh
```

Safe to re-run - the MongoDB admin password and the session secret are only
generated once and then reused; only the Keycloak client secret rotates on
every run (same reasoning as `init-headlamp.sh` - see its comments), and
the Compass pod is restarted afterwards so it always has the current one.

### Doing it by hand instead

```bash
kubectl create namespace mongodb

# MongoDB admin credentials
kubectl create secret generic mongodb-admin -n mongodb \
  --from-literal=password="$(openssl rand -base64 24)"

# In Keycloak: Clients -> Create client
#   Client ID: compass
#   Client authentication: On (confidential client)
#   Valid redirect URIs: https://bwing/mongo/auth/callback
#   Web origins: https://bwing
# then copy the client secret from its Credentials tab.

kubectl create secret generic mongodb-compass -n mongodb \
  --from-literal=oidc-client-secret="<client secret from Keycloak>" \
  --from-literal=session-secret="$(openssl rand -hex 32)"

helm install mongodb ./mongodb -n mongodb \
  --set mongodb.auth.existingSecret=mongodb-admin \
  --set compass.oidc.existingSecret=mongodb-compass
```

If compass-web can't reach `https://bwing/keycloak` from inside the cluster
(see "How SSO works" below), also pass
`--set compass.oidc.internalIngressIP=<ClusterIP of the traefik Service in kube-system>`.

## Connecting other pods to MongoDB

Every other chart/pod in the cluster can reach this database at:

```
mongodb://admin:<password>@mongodb.mongodb.svc.cluster.local:27017/?authSource=admin
```

or just `mongodb:27017` from a pod already inside the `mongodb` namespace.
Change `mongodb.auth.username` if you want a dedicated app user instead of
reusing the root user (you'd then also need to create that user yourself,
e.g. via Compass or mongosh, since this chart only provisions the root user
through `MONGO_INITDB_ROOT_*`).

## How SSO works

Traefik routes everything under `/mongo` straight to the Compass pod's
Service - unlike `../n8n` and `../octoprint`, there's **no `stripPrefix`
middleware here**. compass-web is natively subpath-aware: `CW_BASE_ROUTE`
tells it to mount its UI, API, websocket, and OIDC routes all under
`/mongo` itself (the one exception is `/healthz`, which always stays
unprefixed - used for the pod's readiness/liveness probes).

compass-web validates login against Keycloak directly, which means it has
to reach `compass.oidc.keycloakBaseUrl` (`https://bwing/keycloak` by
default) from *inside* the cluster for OIDC discovery and the token
exchange. On a single-node k3s box, `bwing` is normally only resolvable on
the LAN, not from inside a pod - so `compass.oidc.internalIngressIP` adds a
`hostAlias` pointing that hostname at the in-cluster Traefik Service's
ClusterIP instead (Traefik still routes purely on the `Host`/path it sees,
so this is safe - same trick, different mechanism, as `init-headlamp.sh`
talking to Keycloak over `localhost` via `kubectl exec` rather than through
the public URL). `init-mongodb.sh` resolves and sets this for you.

compass-web (a Node app) also validates Traefik's TLS certificate when it
makes that call. Traefik's ad-hoc default cert is self-signed, so until
something trusts it, login fails with:

```
error: unable to verify the first certificate
```
or similar, from the OIDC discovery request. Two ways to fix it, same as
Headlamp's identical problem (`../headlamp/README.md`):

1. **Durable (recommended)**: run `../init-tls.sh`. It mints a stable
   cert-manager CA for `bwing` (shared by every app in this repo) and also
   copies that CA into a `mongodb-ca` ConfigMap in this namespace, points
   `compass.oidc.trustCAConfigMap` at it, and restarts Compass - after
   which Node trusts it via `NODE_EXTRA_CA_CERTS`, honored natively without
   any app-specific flag.
2. **Quick/temporary**: `--set compass.oidc.insecureSkipVerify=true`. Sets
   `NODE_TLS_REJECT_UNAUTHORIZED=0` for the whole process - gets you
   unblocked immediately to test the login flow, not something to leave on.

The redirect URI is set explicitly (`CW_OIDC_REDIRECT_URI`) rather than
inferred from request headers, so it's reliable regardless of how Traefik
forwards `X-Forwarded-*` - it must exactly match what's registered as the
Keycloak client's "Valid Redirect URI": `https://bwing/mongo/auth/callback`.

Basic auth and OIDC are **mutually exclusive** in compass-web itself - if
OIDC is configured, `compass.basicAuth.*` is ignored entirely regardless of
its own `enabled` setting.

## A note on persistence

compass-web can optionally encrypt and save connections a user adds
through its own UI (beyond the MongoDB connection below) to a file inside
its installed package directory, if you set a master password - this chart
deliberately doesn't wire that up, since doing it safely needs a `subPath`
volume mount rather than a PVC over that whole directory (which would hide
the app's own files). This isn't needed for the primary use case: the
MongoDB connection is injected via `CW_MONGO_URI` on every pod start, so
it's always there regardless of restarts - only extra, manually-added
connections would be lost on a pod restart.

## Restricting who can log in

By default `init-mongodb.sh` restricts Compass login to members of a
`mongo-admins` Keycloak group (override the name with
`MONGODB_ADMIN_GROUP=other-name ./init-mongodb.sh`, or set
`MONGODB_ADMIN_GROUP=` (empty) to disable the restriction entirely and let
any authenticated user in the realm log in - compass-web's own default).

There's only one tier: every member of the allowed group gets the same
full admin-level MongoDB access, since Compass connects with the shared
root Mongo credential - Keycloak group membership gates *whether you can
open Compass at all*, not what you can do inside it once you're in.

To add someone: Keycloak admin console -> your realm (`compass.oidc.realm`
in `values.yaml`, `master` by default) -> Users -> pick a user -> Groups
tab -> Join `mongo-admins`. Takes effect on their next full login - an
already-logged-in session isn't re-checked or revoked if they're later
removed from the group (compass-web only checks group membership at the
OIDC callback, not on every request - see its source if you need tighter
revocation than that).

Under the hood this is a `groups` claim mapper on the `compass` Keycloak
client (`full.path=false`, so membership shows up as a flat `"mongo-admins"`
rather than Keycloak's default `"/mongo-admins"` - compass-web's group
check is an exact, case-sensitive string match with no leading-slash
handling of its own, so getting this wrong silently locks everyone out
rather than erroring) plus `compass.oidc.allowedGroups`/`groupsClaim` in
`values.yaml`, which set `CW_OIDC_ALLOWED_GROUPS`/`CW_OIDC_GROUPS_CLAIM`.

## Rotating the Compass client secret

Re-run `init-mongodb.sh` - it detects the existing `compass` client,
generates a fresh secret, rewrites the `mongodb-compass` Secret (keeping
the same session secret, so existing logins aren't invalidated), and
restarts the Compass pod so it picks up the new secret.

## Values reference

See `values.yaml` for the full set of knobs; the notable ones:

| Key | Purpose |
|---|---|
| `mongodb.auth.*` | MongoDB root user/password (or `existingSecret`) |
| `mongodb.persistence.*` | PVC size/storage class for `/data/db` |
| `mongodb.service.port` | Port other pods connect to (default `27017`) |
| `compass.basicAuth.*` | compass-web's own login - only used when `oidc.enabled: false` |
| `compass.ingress.*` | Host/path Compass is served under |
| `compass.oidc.*` | Keycloak SSO settings (see "How SSO works" above) |

## Uninstall

```bash
helm uninstall mongodb -n mongodb
kubectl -n mongodb delete pvc -l app.kubernetes.io/instance=mongodb   # deletes DB data - confirm first
```
