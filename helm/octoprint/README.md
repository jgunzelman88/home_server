# OctoPrint Helm chart (k3s)

OctoPrint with privileged USB access to the host and the web UI served at
**http://bwing/octoprint** through k3s's built-in Traefik ingress.

## Install

```bash
helm install octoprint ./octoprint -n octoprint --create-namespace
```

Pin the pod to the node the printer is plugged into:

```bash
helm install octoprint ./octoprint -n octoprint --create-namespace \
  --set nodeSelector."kubernetes\.io/hostname"=bwing
```

## How it works

- **USB**: the container runs `privileged: true` and mounts the host's `/dev`
  (hostPath), so the printer is visible whether it shows up as
  `/dev/ttyUSB0`, `/dev/ttyACM0`, etc.
- **Routing**: an Ingress for host `bwing`, path `/octoprint`, plus two
  Traefik Middlewares: `stripPrefix` (removes `/octoprint` before it hits the
  pod) and `headers` (adds `X-Script-Name: /octoprint` so OctoPrint generates
  correct URLs behind the subpath).
- **Storage**: a PVC (k3s `local-path` by default) mounted at `/octoprint`
  keeps config, uploaded gcode, and timelapses across restarts.

## Subpath fix (v0.1.1)

OctoPrint 1.9+ ignores `X-Script-Name` from proxies it doesn't trust, so the
UI loads but its API/socket calls go to `/api/...` instead of
`/octoprint/api/...` and the page hangs. This chart now runs an init
container that writes into `config.yaml`:

- `server.reverseProxy.prefixFallback: /octoprint` (from `ingress.path`)
- `server.reverseProxy.trustedDownstream`: 127.0.0.1/8, ::1, 10.42.0.0/16

If your cluster's pod CIDR isn't the k3s default `10.42.0.0/16`, override
`reverseProxyConfig.trustedDownstream`. Disable the whole mechanism with
`reverseProxyConfig.enabled=false`.

## Notes

- Old Traefik v1 installs: set `ingress.traefikApiVersion=traefik.containo.us/v1alpha1`.
- If OctoPrint complains about an untrusted reverse proxy on first load, add
  Traefik's pod CIDR (e.g. `10.42.0.0/16` on stock k3s) under Settings →
  Server → "Trusted proxy servers", or set it in `config.yaml` under
  `server.reverseProxy.trustedProxies`.
- Serving under HTTPS later? Change `X-Scheme` to `https` in
  `templates/middleware.yaml` or override via values.
