# PostgreSQL + pgAdmin Helm Chart (k3s)

Deploys a standalone PostgreSQL instance plus a pgAdmin UI on k3s with
Traefik ingress, following the same conventions as the other charts in
this `helm/` folder (`jellyfin`, `n8n`, `octoprint`).

- **Postgres** is exposed via a `ClusterIP` Service so any other pod in
  the cluster can connect to it.
- **pgAdmin** is served at `https://bwing/pgadmin` and comes pre-wired
  with a connection to the bundled Postgres instance.
- **pgAdmin → Keycloak SSO** is supported via pgAdmin's built-in OAuth2/OIDC
  login, off by default until you create a client in Keycloak (steps below).

This chart deploys its own Postgres — it does **not** reuse the
`keycloak-postgresql` Bitnami release from `init-keycloak.sh`. Give it its
own namespace (or reuse `keycloak`'s) as you prefer.

## Install

```bash
helm install postgres ./postgres -n postgres --create-namespace \
  --set postgresql.auth.password="$(openssl rand -base64 24)" \
  --set pgadmin.auth.password="$(openssl rand -base64 24)"
```

Or put real values in a `values-prod.yaml` override and:

```bash
helm upgrade --install postgres ./postgres -n postgres --create-namespace \
  -f values-prod.yaml
```

For real credentials, prefer creating your own Secrets and pointing the
chart at them instead of passing passwords on the command line — see
`postgresql.auth.existingSecret` and `pgadmin.auth.existingSecret` in
`values.yaml`.

## Connecting other pods to Postgres

Every other chart/pod in the cluster can reach this database at:

```
<release-name>.<namespace>.svc.cluster.local:5432
```

e.g. with the defaults above (`fullnameOverride: postgres`, namespace
`postgres`):

```
postgres.postgres.svc.cluster.local:5432
```

or just `postgres:5432` from a pod already inside the `postgres` namespace.
The default superuser/database is `postgres` — set `postgresql.auth.username`
/ `postgresql.auth.database` if you want a dedicated app user/db instead
(mirrors how `keycloak/values.yaml` points at its own Postgres user).

## pgAdmin

Reachable at `https://bwing/pgadmin` (change `pgadmin.ingress.host` /
`pgadmin.ingress.path` if you want it elsewhere). Login with
`pgadmin.auth.email` / the password in the `<release>-pgadmin` Secret.

A connection to this release's Postgres instance is pre-loaded via
`servers.json` (`pgadmin.preloadServer`) so it shows up in the tree as soon
as you log in — pgAdmin will still prompt for the Postgres password itself
the first time you connect to it, since `servers.json` doesn't carry
passwords.

**Note on the sub-path:** pgAdmin isn't as first-class about running under
a URL prefix as, say, n8n. This chart reuses the same
`X-Script-Name`/`X-Scheme` header + `stripPrefix` middleware trick this repo
already uses for OctoPrint, which is pgAdmin's documented way of running
behind a reverse-proxy sub-path. If you hit broken asset/redirect URLs,
the fallback is to give pgAdmin its own host (set `pgadmin.ingress.path: /`
and a dedicated `pgadmin.ingress.host`) instead of a sub-path.

## Enabling Keycloak SSO for pgAdmin

pgAdmin needs an OAuth2/OIDC client registered in Keycloak before you turn
this on. There's no automation for this in the repo yet (`init-keycloak.sh`
only stands up Keycloak itself), so it's a one-time manual step:

1. Log into the Keycloak admin console at `https://bwing/keycloak/admin/`.
2. Pick the realm you want pgAdmin's users to come from (defaults to
   `master` in this chart — for anything beyond a quick test, create a
   dedicated realm instead of using `master`).
3. **Clients → Create client**:
   - Client type: `OpenID Connect`
   - Client ID: `pgadmin` (or whatever you set in `pgadmin.oidc.clientId`)
   - Client authentication: **On** (confidential client)
   - Valid redirect URIs:
     `https://bwing/pgadmin/oauth2/authorize`
   - Web origins: `https://bwing`
4. Save, then open the client's **Credentials** tab and copy the client
   secret.
5. Set in your values (or pass on the CLI / via an existing Secret):

   ```yaml
   pgadmin:
     oidc:
       enabled: true
       clientId: pgadmin
       clientSecret: "<the secret from step 4>"   # or use existingSecret
       keycloakBaseUrl: "https://bwing/keycloak"
       realm: "master"                             # or your dedicated realm
   ```

6. `helm upgrade` the release. pgAdmin's login page will now show a
   "Sign in with Keycloak" button in addition to (or instead of, if you set
   `pgadmin.oidc.allowInternalLogin: false`) the local admin login.

pgAdmin builds the authorization/token/userinfo endpoints itself from the
realm's OIDC discovery document
(`{keycloakBaseUrl}/realms/{realm}/.well-known/openid-configuration`), so
you don't need to hand-enter those. If your pgAdmin/Keycloak versions
disagree on the exact redirect path, check pgAdmin's login page or logs
after enabling — it will report the callback URL it's expecting — and
update the client's "Valid redirect URIs" in Keycloak to match.

## Values reference

See `values.yaml` for the full set of knobs; the notable ones:

| Key | Purpose |
|---|---|
| `postgresql.auth.*` | Postgres superuser/db name and password (or `existingSecret`) |
| `postgresql.persistence.*` | PVC size/storage class for `/var/lib/postgresql/data` |
| `postgresql.service.port` | Port other pods connect to (default `5432`) |
| `pgadmin.auth.*` | pgAdmin admin login (or `existingSecret`) |
| `pgadmin.ingress.*` | Host/path pgAdmin is served under |
| `pgadmin.preloadServer.*` | Auto-add a connection to this chart's Postgres |
| `pgadmin.oidc.*` | Keycloak SSO settings (see above) |

## Uninstall

```bash
helm uninstall postgres -n postgres
kubectl -n postgres delete pvc -l app.kubernetes.io/instance=postgres   # deletes DB data — confirm first
```
