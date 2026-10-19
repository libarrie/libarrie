# ADR 0013: Self-hosted deployment

Status: accepted

The only ready-made way to run Libarrie was the development Compose stack.
That stack always enables the development sign-in, which lets anyone sign in
as anyone. This adds a supported path for a personal or small deployment,
and stops the development sign-in from running on a public address.

## Development sign-in

- **Origin check:** `DEV_ISSUER_SECRET` is refused at startup unless
  `WEB_ORIGIN` is an `http://` origin on localhost or a private-network IP
  address:
  - IPv4: loopback, RFC 1918 and link-local;
  - IPv6: loopback, unique-local and link-local.

  Private addresses stay allowed because testing the apps on a phone needs a
  LAN address (`clients/ios/README.md`). `hosted` mode already refused it
  outright.
- **What it can't catch:** the check covers the configured origin, not where
  requests come from. A development stack whose ports are published to the
  internet is still open. The development `compose.yaml` and the
  self-hosting guide warn against that.

## Production stack

`deploy/production/compose.yaml`, with a `Caddyfile` and `.env.example`:

- **Caddy 2.10** terminates HTTPS with automatic certificates for two
  names. The app name proxies to the API. The files name proxies to the
  object store unchanged, so presigned S3 signatures, which cover the host,
  stay valid.
- **The release images** (`ghcr.io/libarrie/libarrie-api` and
  `libarrie-worker` at `LIBARRIE_VERSION`), with a `build:` fallback to
  `server/release/Dockerfile`. A one-shot `migrate` service runs before the
  API and worker.
- **Postgres** `pgvector/pgvector:0.8.1-pg17` and **SeaweedFS 4.48**, pinned
  rather than `latest`.
  - SeaweedFS's credentials are written from `.env` at start.
  - Its CORS is limited to the app's origin.
  - Removing it in favour of R2 is documented.
- **Only Caddy publishes ports.** Required secrets are Compose `:?` errors,
  so a missing one stops `up` with its name.
- **Self-hosting defaults:** `selfhost` mode, Mistral and Voyage, the
  `unprivileged` decoder sandbox, and no page or notebook limits.

Settings now treat an empty variable as unset everywhere (`get` matched
`get_optional`, `get_int` and the others), so Compose can pass optional
settings through as `${NAME:-}`.

The stack was verified end to end in an isolated project, with a mock
OpenID Connect provider and Caddy's internal certificates:

- migrations ran, and the API and worker started;
- sign-in completed with Secure `__Host-` cookies;
- the setup code claimed ownership;
- `/mcp` answered with its OAuth challenge and metadata;
- a presigned upload went through the files name;
- the decoder ran in its sandbox.

## Published images

`.github/workflows/publish-images.yml` runs on version tags (`v1.2.3`):

- each architecture builds natively and pushes by digest;
- a final job tags the multi-architecture images `1.2.3`, `1.2` and
  `latest`;
- the license gate and smoke checks run inside the build, as before;
- the images are labelled with the project's license, Apache-2.0
  (`org.opencontainers.image.licenses`);
- the SBOMs are kept as workflow artifacts.

## Not decided here

- Restricting who may sign up. Today anyone the identity provider
  authenticates gets an account, so the guide asks for a provider that only
  admits your own people.
