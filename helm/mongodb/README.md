# MongoDB + "Compass" Helm Chart (k3s)

Deploys a standalone MongoDB instance plus a browser-based admin UI on k3s
with Traefik ingress, following the same conventions as the other charts in
this `helm/` folder (`jellyfin`, `n8n`, `octoprint`, `postgres`).

- **MongoDB** is exposed via a `ClusterIP` Service so any other pod in the
  cluster can connect to it.
- **"Compass"** is served at `https://bwing/mongo` and gated by Keycloak SSO.

## A note on the name "Compass"

MongoDB Compass is a desktop GUI application - it opens a `mongodb://`
connection directly from your own machine and isn't something you can run
behind a web ingress or put behind SSO. What's actually deployed here as
`compass` is [**mongo-express**](https://github.com/mongo-express/mongo-express),
the standard browser-based admin UI for MongoDB - the same role pgAdmin
plays for Postgres in `../postgres`. It's fronted by an
[**oauth2-proxy**](https://oauth2-proxy.github.io/oauth2-proxy/) container
running in the same pod, which is what actually adds the Keycloak login -
mongo-express has no OIDC support of its own.

If you also want the real Compass desktop app, `helm install` prints (and
`templates/NOTES.txt` always shows) a `kubectl port-forward` command plus
connection string for that - see "Connecting the real MongoDB Compass
desktop app" in the install output.

## Install

The easy way - `./init-mongodb.sh` (run from `helm/`, on the k3s node, same
as every other `init-*.sh` script in this repo) does all of the below for
you: creates the `mongodb` namespace, generates a MongoDB admin Secret,
creates a confidential OIDC client called `compass` in Keycloak (needs
`init-keycloak.sh` to have already been run), stores its secret plus a
freshly generated oauth2-proxy cookie secret in a second Secret, and
installs/upgrades the Helm release wired up to both.

```bash
cd helm
./init-mongodb.sh
```

Safe to re-run - the MongoDB admin password and the oauth2-proxy cookie
secret are only generated once and then reused; only the Keycloak client
secret rotates on every run (same reasoning as `init-headlamp.sh` - see its
comments), and the Compass pod is restarted afterwards so it always has the
current secret.

### Doing it by hand instead

```bash
kubectl create namespace mongodb

# MongoDB admin credentials
kubectl create secret generic mongodb-admin -n mongodb \
  --from-literal=password="$(openssl rand -base64 24)"

# In Keycloak: Clients -> Create client
#   Client ID: compass
#   Client authentication: On (confidential client)
#   Valid redirect URIs: https://bwing/mongo/oauth2/callback
#   Web origins: https://bwing
# then copy the client secret from its Credentials tab.

kubectl create secret generic mongodb-compass -n mongodb \
  --from-literal=oauth2-client-secret="<client secret from Keycloak>" \
  --from-literal=cookie-secret="$(openssl rand -base64 32 | tr '+/' '-_')"

helm install mongodb ./mongodb -n mongodb \
  --set mongodb.auth.existingSecret=mongodb-admin \
  --set compass.oidc.existingSecret=mongodb-compass
```

If oauth2-proxy can't reach `https://bwing/keycloak` from inside the
cluster (see "How SSO works" below), also pass
`--set compass.oidc.internalIngressIP=<ClusterIP of the traefik Service in kube-system>`.

## Connecting other pods to MongoDB

Every other chart/pod in the cluster can reach this database at:

```
mongodb://admin:<password>@mongodb.mongodb.svc.cluster.local:27017/?authSource=admin
```

or just `mongodb:27017` from a pod already inside the `mongodb` namespace.
Change `mongodb.auth.username` if you want a dedicated app user instead of
reusing the root user (you'd then also need to create that user yourself,
e.g. via mongosh or mongo-express, since this chart only provisions the
root user through `MONGO_INITDB_ROOT_*`).

## How SSO works

Traefik routes everything under `/mongo` straight to the Compass pod's
Service - unlike `../n8n` and `../octoprint`, there's **no `stripPrefix`
middleware** here. Instead, both containers in that pod are made
subpath-aware directly:

- `oauth2-proxy` is told `--proxy-prefix=/mongo/oauth2`, so it serves its own
  login/callback/logout routes there and reverse-proxies every other
  request under `/mongo` straight through to mongo-express.
- `mongo-express` is told `ME_CONFIG_SITE_BASEURL=/mongo/`, its own
  documented way of running under a subpath, and binds to `127.0.0.1`
  only - so it's reachable exclusively via `oauth2-proxy` inside the pod,
  never directly.

oauth2-proxy validates login against Keycloak, which means it has to reach
`compass.oidc.keycloakBaseUrl` (`https://bwing/keycloak` by default) from
*inside* the cluster for OIDC discovery and the token exchange. On a
single-node k3s box, `bwing` is normally only resolvable on the LAN, not
from inside a pod - so `compass.oidc.internalIngressIP` adds a `hostAlias`
pointing that hostname at the in-cluster Traefik Service's ClusterIP
instead (Traefik still routes purely on the `Host`/path it sees, so this is
safe - same trick, different mechanism, as `init-headlamp.sh` talking to
Keycloak over `localhost` via `kubectl exec` rather than through the public
URL). `init-mongodb.sh` resolves and sets this for you.

oauth2-proxy also validates Traefik's TLS certificate when it makes that
call. If you haven't run `../init-tls.sh` yet, Traefik's ad-hoc self-signed
cert will fail that check and login will error out - `init-tls.sh` (see
`../headlamp/README.md`) is the durable fix and benefits every app in this
repo. `compass.oidc.insecureSkipVerify: true` is a quick, temporary
workaround if you just want to test the flow first.

## Rotating the Compass client secret

Re-run `init-mongodb.sh` - it detects the existing `compass` client,
generates a fresh secret, rewrites the `mongodb-compass` Secret (keeping the
same cookie secret, so existing logins aren't invalidated), and restarts the
Compass pod so it picks up the new secret.

## Values reference

See `values.yaml` for the full set of knobs; the notable ones:

| Key | Purpose |
|---|---|
| `mongodb.auth.*` | MongoDB root user/password (or `existingSecret`) |
| `mongodb.persistence.*` | PVC size/storage class for `/data/db` |
| `mongodb.service.port` | Port other pods connect to (default `27017`) |
| `compass.basicAuth.*` | mongo-express's own login - off by default, defense-in-depth alongside SSO or the only gate if `oidc.enabled: false` |
| `compass.ingress.*` | Host/path Compass is served under |
| `compass.oidc.*` | Keycloak SSO settings (see "How SSO works" above) |

## Uninstall

```bash
helm uninstall mongodb -n mongodb
kubectl -n mongodb delete pvc -l app.kubernetes.io/instance=mongodb   # deletes DB data - confirm first
```
