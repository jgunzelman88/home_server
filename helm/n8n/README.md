# n8n Helm Chart for k3s

Deploys [n8n](https://n8n.io) on k3s with Traefik ingress, serving the UI and
webhooks at **https://bwing/n8n**.

## Quick start

```bash
# 1. (Optional) create a dedicated namespace
kubectl create namespace n8n

# 2. Install / upgrade
helm upgrade --install n8n ./n8n-chart \
  --namespace n8n \
  --set n8n.encryptionKey="$(openssl rand -hex 32)"
```

The chart uses the k3s `local-path` storage class for SQLite persistence.

---

## Key env vars configured automatically

| Variable | Value |
|---|---|
| `N8N_PATH` | `/n8n` |
| `N8N_HOST` | `bwing` |
| `N8N_PROTOCOL` | `https` |
| `WEBHOOK_URL` | `https://bwing/n8n/` |
| `N8N_EDITOR_BASE_URL` | `https://bwing/n8n/` |

`N8N_PATH` tells n8n it lives under a sub-path.
The Traefik `StripPrefix` middleware strips `/n8n` before the request reaches
the pod so n8n still binds to `/` internally.

---

## Traefik objects created

| Kind | Name | Purpose |
|---|---|---|
| `Ingress` | `n8n` | Routes `bwing/n8n` → service |
| `Middleware` | `n8n-stripprefix` | Strips `/n8n` prefix |

---

## Switching to PostgreSQL

```yaml
# values override
postgresql:
  enabled: true
  host: "my-postgres-svc"
  database: "n8n"
  user: "n8n"
  password: "supersecret"
```

---

## Using cert-manager for TLS

```yaml
ingress:
  tls:
    enabled: true
    secretName: "bwing-tls"   # cert-manager Certificate resource name
```

---

## Scaling / HA

n8n with SQLite must run as a **single replica** (Recreate strategy is set).
For HA, switch to PostgreSQL and set:

```yaml
n8n:
  executionMode: queue
replicaCount: 2
```
and add a Redis instance for the queue backend.
