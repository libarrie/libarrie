# ADR 0014: Kubernetes Helm chart

Status: accepted

A Helm chart in `deploy/helm/libarrie` installs a production system into
Kubernetes. The API and the worker run as several replicas, and the worker
can autoscale.

## Shape

- **Deployments** for the API (with a Service and Ingress) and the worker.
  Each has a PodDisruptionBudget, and replicas are spread across nodes by
  default.
- **Required production settings** fail rendering with a message naming
  the missing one:
  - the `https://` origin;
  - the identity provider;
  - storage;
  - every secret, unless `secrets.existingSecret` names a Secret keyed by
    environment-variable names.

  `DEV_ISSUER_SECRET` is refused, even through `config` or
  `secrets.extra`.
- **Not bundled:** Postgres and object storage. Production deployments
  bring a managed or operator-run database and S3-compatible storage.
- **Configuration:** a ConfigMap and a Secret, loaded with `envFrom`. Pods
  carry checksums of both, so a configuration change rolls them.
- **Pod security:** non-root (uid 10001), read-only root filesystem, all
  capabilities dropped, `RuntimeDefault` seccomp, no service-account token.
  `/tmp` is a size-limited `emptyDir`. The decoder's `unprivileged` sandbox
  works under this context.
- **Probes:** the API starts on `/healthz`, stays live on `/healthz`, and is
  ready on `/readyz` (database reachable and migrated). The worker has no
  HTTP endpoint.

## Internal API

The internal API (`/internal/v1`, for an entitlement authority) should stay
off the public network (DESIGN.md). A standard Ingress can't exclude a path,
so core gained `INTERNAL_PORT`. When it's set, `/internal` is served only by
a second listener on that port, which serves nothing else but the health
checks, and the public port answers 404 for it. The chart always sets it
(`internalApi.port`, 8081) and exposes it through the ClusterIP Service
`<fullname>-internal`. The production Compose stack sets it too, so Caddy
never forwards `/internal`.

## Migrations

The migration runner is meant to run once per deploy, not from every
replica. So migrations run as a Job, as a `pre-install,pre-upgrade` Helm
hook. On install, hooks run before the release's own resources exist, so the
Job uses hook-scoped copies of the ConfigMap and Secret, deleted with it on
success. A failed Job stays for its logs.

## Replicas

Several replicas need no coordination. Sessions, rate limits, entitlements
and the job queue are in Postgres. Jobs are leased, so a stopped worker's
jobs are retried elsewhere. Periodic maintenance jobs are deduplicated.
Every API replica prints its own setup code while there's no owner, and
any of them works.

MCP sessions (2025-11-25 protocol) are in Postgres too, so they need no
sticky routing (ADR 0012).

## Worker autoscaling

KEDA scales the worker on queue depth: jobs running, plus pending or
retryable jobs that are due. It aims for `worker.concurrency` jobs per
worker. CPU would be the wrong signal, since workers mostly wait on Mistral
and Voyage. KEDA reads the worker's own `DATABASE_URL` (`connectionFromEnv`)
but connects from its own namespace, so an in-cluster database needs its
fully qualified name. Rendering fails if autoscaling is enabled without the
KEDA CRDs.

## Publishing

The chart is published to a classic Helm repository on GitHub Pages
(`helm repo add libarrie https://libarrie.github.io/libarrie`), not as an
OCI artifact, so `helm repo add` and `helm search` work.
`.github/workflows/release-chart.yml` lints the chart and validates its
output on every change. On `main`, chart-releaser publishes each new chart
version:
- it attaches the package to a GitHub Release `libarrie-<version>`, never
  marked as the latest release;
- it updates `index.yaml` on the `gh-pages` branch.

Releasing means bumping `version` in `Chart.yaml`, and `appVersion` with
each app release. One-time setup: create the `gh-pages` branch and serve
GitHub Pages from it.

`fullnameOverride` fixes the resource names, so a chart that depends on this
one can address its Services.

## Verification

The chart lints strictly, and kubeconform validates its output (with
KEDA's CRD schema). It was installed into a throwaway k3s 1.33 cluster with
KEDA 2.17, pgvector, SeaweedFS, a mock OpenID Connect provider and the
release images:

- the migration hook ran;
- two API replicas and the worker became ready;
- `helm upgrade` re-ran the hook and rolled the pods;
- KEDA scaled the worker from 1 to 4 when 12 jobs were queued;
- through Traefik's Ingress over HTTPS:
  - sign-in completed, and the setup code claimed ownership;
  - the session worked on either replica;
  - `/mcp` returned its OAuth challenge;
  - a presigned upload succeeded;
  - the decoder ran under the restricted pod security context.

The test caught one chart bug: Helm reads large YAML numbers as floats
(`5e+06`), so numeric settings are now written as integers.
