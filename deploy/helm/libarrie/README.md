# Libarrie Helm chart

Runs Libarrie in Kubernetes:

- the API and web app, as several replicas behind an Ingress;
- the background worker, as several replicas, optionally autoscaled on the
  job queue with KEDA;
- database migrations as a Job before each install and upgrade.

The chart doesn't include a database or object storage; bring your own.
`docs/self-hosting.md` explains the identity provider, storage and backups
in more detail. It is written for the Compose stack, but the same settings
apply here.

## What you need

- **Kubernetes 1.27 or later** and an Ingress controller. TLS comes from the
  Ingress, for example with cert-manager.
- **Linux 5.13 or later with Landlock on the nodes**, for the image
  decoder's `unprivileged` sandbox. That's most current distributions and
  managed node images.
- **Postgres 17** with the `vector` (pgvector), `pg_trgm` and `btree_gin`
  extensions available. The first migration creates them, so the
  database user needs permission to. A managed Postgres that offers
  pgvector, or CloudNativePG with a pgvector image, both work.
- **S3-compatible object storage**, such as Cloudflare R2, AWS S3 or
  SeaweedFS. Browsers and the apps upload and download with presigned URLs,
  so its public endpoint must be reachable from their devices over HTTPS,
  with CORS allowing your origin. See
  `docs/runbooks/r2-storage-and-journal.md`.
- **An OpenID Connect provider** with a web client whose redirect URI is
  `<origin>/auth/callback`. Anyone it lets sign in gets an account, so use
  one that only admits your own people.
- **Mistral and Voyage AI API keys.**

## Install

Put the secrets in a Secret you manage, under their environment-variable
names:

```sh
kubectl create namespace libarrie
kubectl -n libarrie create secret generic libarrie-secrets \
  --from-literal=DATABASE_URL='postgres://libarrie:…@db.example.internal:5432/libarrie' \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -hex 32)" \
  --from-literal=IDENTITY_HASH_KEYS="k1:$(openssl rand -hex 32)" \
  --from-literal=S3_ACCESS_KEY_ID='…' \
  --from-literal=S3_SECRET_ACCESS_KEY='…' \
  --from-literal=OIDC_CLIENT_SECRET='…' \
  --from-literal=MISTRAL_API_KEY='…' \
  --from-literal=VOYAGE_API_KEY='…'
```

Optional keys are `JOURNAL_S3_ACCESS_KEY_ID`, `JOURNAL_S3_SECRET_ACCESS_KEY`,
`INTERNAL_API_TOKEN` and `LIFECYCLE_SUBSCRIBER_TOKEN`. Keep
`IDENTITY_HASH_KEYS` for good: deleted accounts are recorded under it.
Alternatively, set the `secrets.*` values and the chart creates the Secret.

Then write a values file:

```yaml
origin: https://notes.example.com
oidc:
  issuer: https://auth.example.com
  jwksUrl: https://auth.example.com/.well-known/jwks.json
  clientId: libarrie
storage:
  endpoint: https://<account-id>.r2.cloudflarestorage.com
  publicEndpoint: https://<account-id>.r2.cloudflarestorage.com
  region: auto
  bucket: libarrie
  uploadIntegrity: md5        # R2; sha256 elsewhere
secrets:
  existingSecret: libarrie-secrets
ingress:
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    nginx.ingress.kubernetes.io/proxy-buffering: "off"   # MCP streaming
```

Install it from the chart repository:

```sh
helm repo add libarrie https://libarrie.github.io/libarrie
helm install libarrie libarrie/libarrie -n libarrie -f values.yaml
```

Or from a checkout: `helm install libarrie deploy/helm/libarrie …`.

Rendering fails with a message naming any required setting that's missing,
and refuses the development sign-in outright.

To become the owner, use the one-time setup code in the API's log, as the
install notes describe, or set `owner` to your sign-in subject before your
first sign-in.

## Values

| Value | Default | |
| --- | --- | --- |
| `origin` | **required** | `https://` origin of the app, API and MCP server |
| `oidc.issuer`, `oidc.jwksUrl`, `oidc.clientId` | **required** | Your identity provider |
| `storage.endpoint`, `storage.publicEndpoint`, `storage.bucket` | **required** | Object storage |
| `secrets.existingSecret` | — | A Secret with the keys above; otherwise `secrets.*` is required |
| `mode` | `selfhost` | `hosted` adds stricter startup checks |
| `owner` | — | A sign-in subject made an owner when it signs in |
| `oidc.audience`, `oidc.nativeClientId`, `oidc.nativeRedirectUri` | — | The iOS and Android apps |
| `mcp.oauthAudience`, `mcp.oauthScopes` | `<origin>/mcp`, none | Agents signing in to the MCP server with OAuth |
| `journal.*` | the primary store | A separate store for the lifecycle journal |
| `spend.*`, `limits.*` | $5/account and $50/day; unlimited | Provider spending ceilings and per-account limits |
| `decoder.sandbox` | `unprivileged` | `minijail` needs `CAP_SYS_ADMIN` or a pod user namespace |
| `config`, `secrets.extra` | — | Any other setting from `server/README.md`, by environment variable |
| `api.replicas` | `2` | |
| `worker.replicas`, `worker.concurrency` | `2`, `4` | Jobs run at once per worker |
| `worker.autoscaling.*` | off | See below |
| `ingress.*`, `service.*` | Ingress on, TLS secret `<release>-tls` | |
| `internalApi.port` | `8081` | `/internal/v1` (for an entitlement authority) is served only here, through the ClusterIP Service `<fullname>-internal`, never through the Ingress |
| `fullnameOverride` | — | Fixed resource names, for example when this chart is a dependency |
| `podSecurityContext`, `securityContext` | non-root, read-only root, no capabilities, `RuntimeDefault` seccomp | |

`values.yaml` documents each one.

## Replicas and autoscaling

- **Shared state:** API replicas share sessions, rate limits and
  everything else through Postgres. `SECRET_KEY_BASE` is the same for all
  of them. Workers share the job queue: each job is leased to one worker,
  and a stopped worker's jobs are picked up again when their lease
  expires.
- **Disruption budgets:** each component allows one pod at a time to be
  unavailable when it has more than one replica.
- **Autoscaling the worker:** with [KEDA](https://keda.sh) installed, set
  `worker.autoscaling.enabled: true`. KEDA scales on the job queue (jobs
  running or due), adding a worker for every `worker.concurrency` jobs,
  between `minReplicas` and `maxReplicas`. CPU would be a poor signal:
  workers mostly wait on Mistral and Voyage. KEDA connects with the
  worker's `DATABASE_URL` from its own namespace, so a database inside the
  cluster needs its fully qualified name there
  (`postgres.<namespace>.svc`).
- **MCP sessions:** sessions of MCP clients on the 2025-11-25 protocol are
  stored in Postgres, so any API replica serves them and they survive
  restarts. No sticky sessions are needed.

## Upgrades

`helm upgrade` runs the migrations first, as a Job, then rolls the API and
worker. Pods also restart when their configuration changes. Take a database
backup before upgrading. A failed migration Job stays for
`kubectl logs job/libarrie-migrate`.

## Operator commands

The API image runs one-off commands (see "Commands" in `server/README.md`).
`setup-code`, `storage-check`, `journal-replay` and `reindex` are the
useful ones. Run them as a Job with the release's configuration:

```yaml
apiVersion: batch/v1
kind: Job
metadata: { name: libarrie-storage-check, namespace: libarrie }
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      securityContext: { runAsNonRoot: true, runAsUser: 10001 }
      containers:
        - name: command
          image: ghcr.io/libarrie/libarrie-api:0.1.0
          args: ["storage-check"]
          envFrom:
            - configMapRef: { name: libarrie-config }
            - secretRef: { name: libarrie-secrets }
```

After restoring a database backup, run `journal-replay` this way before
letting traffic in, so deletions made after the backup are applied again.

## Uninstall

`helm uninstall libarrie -n libarrie` removes what the chart created, except
a migration Job that failed last time, along with its configuration (Helm
hooks aren't part of the release); delete those by hand. Your database,
object storage and any Secret you created yourself stay.
