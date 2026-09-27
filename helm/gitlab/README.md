# GitLab CE

GitLab Community Edition at **https://bwing/gitlab**, installed by
`../init-gitlab.sh` into the `gitlab` namespace, with Keycloak SSO. Everything it depends on
lives in that one namespace:

| Workload          | Image                 | What it is                                                                 |
|-------------------|-----------------------|----------------------------------------------------------------------------|
| `gitlab`          | `gitlab/gitlab-ce`    | Omnibus GitLab: Rails/Puma, Sidekiq, Workhorse, Gitaly, gitlab-shell/sshd, nginx |
| `gitlab-postgres` | `postgres:16`         | GitLab's database (bundled Postgres inside Omnibus is disabled)           |
| `gitlab-redis`    | `redis:7.4-alpine`    | GitLab's cache/queues (bundled Redis inside Omnibus is disabled)          |

Why the Omnibus image and not GitLab's official cloud-native chart: the
cloud-native chart doesn't support being served under a sub-path like
`/gitlab`, wants its own wildcard domain, and pulls in its own
nginx-ingress/cert-manager/MinIO. Omnibus supports a relative URL root
natively, which matches how every other app here is exposed on `bwing`.

## Logging in

### Keycloak SSO (OpenID Connect)

`init-gitlab.sh` creates a confidential `gitlab` client in Keycloak (realm
`master` by default - override with `GITLAB_KEYCLOAK_REALM`), stores its
secret in the `gitlab-oidc` Secret and turns on `gitlab.oidc`. The login
page then shows **Sign in with Keycloak**.

* **Who can sign in:** any user in the realm. OIDC login is free in CE;
  mapping Keycloak groups to GitLab admins or "required groups" is a
  Premium feature, so that part isn't available here.
* **New users need approval** (`gitlab.oidc.blockAutoCreatedUsers: true`):
  first SSO login creates the account in *Admin -> Users -> Pending
  approval*; root approves it. Run with `GITLAB_OIDC_BLOCK_NEW_USERS=false`
  to let every realm user straight in.
* **Admins:** promote in GitLab, *Admin -> Users -> Edit -> Access level:
  Administrator*.
* **Email:** give Keycloak users an email address - GitLab needs one and
  otherwise invents a placeholder.
* **Existing local users** are *not* auto-linked by email (that would let
  anyone who can set that email in Keycloak take over the account). To link
  one, log in locally, then *Edit profile -> Account -> Service sign-in ->
  Connect Keycloak*.

How the pod reaches Keycloak at `https://bwing/keycloak`:

* `hostAliases` points `bwing` at Traefik's in-cluster ClusterIP
  (`gitlab.oidc.internalIngressIP`, filled in by the script) - same trick as
  the mongodb chart.
* The homelab CA from `init-tls.sh` is copied into a `gitlab-ca` ConfigMap
  and an init container copies it into `/etc/gitlab/trusted-certs` on the
  config volume (Omnibus needs that directory writable, so it can't be a
  ConfigMap mount), which Omnibus adds to its own OpenSSL trust store on start. Without it, SSO fails with an SSL error.
  If you run `init-tls.sh` after installing GitLab, it updates the release
  for you (GitLab restarts).

The client secret is **not** rotated on every run (unlike the Headlamp /
Compass scripts) because GitLab takes minutes to restart. The script reads
the current secret from Keycloak and only updates the Secret and restarts
GitLab when it differs. To rotate it on purpose, regenerate it in Keycloak
(*Clients -> gitlab -> Credentials*) and re-run the script.

### Local root account (fallback)

`root` with GitLab's auto-generated initial password stays available -
use it if Keycloak is down. `init-gitlab.sh` prints the password, or:

```bash
kubectl -n gitlab exec deploy/gitlab -- grep 'Password:' /etc/gitlab/initial_root_password
```

GitLab deletes that file **24 hours** after first boot, so change the root
password right away. Lost it?
`kubectl -n gitlab exec -it deploy/gitlab -- gitlab-rake "gitlab:password:reset[root]"`

Consider also turning off open sign-ups (*Admin -> Settings -> General ->
Sign-up restrictions*) so the only way in is Keycloak or an admin-created
account. If you later set `gitlab.oidc.autoSignIn: true`, the local login
form is still at `https://bwing/gitlab/users/sign_in?auto_sign_in=false`.

## Git access

* **HTTPS:** `git clone https://bwing/gitlab/<group>/<project>.git`
  With the self-signed / private-CA cert, either trust the CA from
  `init-tls.sh` on your machine or use `git -c http.sslVerify=false ...`.
* **SSH:** `git clone ssh://git@bwing:30022/<group>/<project>.git`
  Port 22 on the node belongs to the host's own sshd, so GitLab's sshd is a
  NodePort (`gitlab.ssh.nodePort`). The UI shows clone URLs with this port.

## Storage

All PVCs (`gitlab-config`, `gitlab-logs`, `gitlab-data`,
`gitlab-postgres-data`, `gitlab-redis-data`) and the `gitlab-secrets` Secret
are annotated `helm.sh/resource-policy: keep` - `helm uninstall` leaves
repositories and the database intact. Delete them by hand to really wipe.

`gitlab-config` holds `/etc/gitlab/gitlab-secrets.json` - it encrypts CI
variables, 2FA secrets, runner tokens, etc. Back it up together with the
database; a DB restore without it is only partially usable.

Backups: `kubectl -n gitlab exec deploy/gitlab -- gitlab-backup create`
(writes to `/var/opt/gitlab/backups` on the `gitlab-data` volume).

## Configuration

GitLab is configured through `GITLAB_OMNIBUS_CONFIG`
(`templates/configmap.yaml`), rendered from `values.yaml`. Put extra
`gitlab.rb` settings in `gitlab.extraConfig`. Container registry, Pages, KAS
and built-in Prometheus are off (they need their own hostname/port, or just
cost RAM on a single node).

Resource needs: GitLab wants ~4 GB RAM for itself. The chart requests 3 Gi
and caps at 6 Gi.

## Upgrading

The image tag is pinned (`gitlab.image.tag`). GitLab has **required upgrade
stops** - don't jump several minor versions at once. Check
https://docs.gitlab.com/update/upgrade_paths/, bump the tag one stop at a
time, re-run `init-gitlab.sh`, and wait for background migrations
(Admin -> Monitoring -> Background migrations) to finish before the next
stop. Also check the PostgreSQL version each GitLab major requires.

## Known gotcha: large pushes over HTTPS

Traefik v3's default `readTimeout` on entrypoints is 60s, which can cut off
very large `git push`es over HTTPS. If you hit that, raise it in
`init-traefik.sh`'s HelmChartConfig, e.g.:

```yaml
ports:
  websecure:
    transport:
      respondingTimeouts:
        readTimeout: 600s
```

(or just push over SSH).
