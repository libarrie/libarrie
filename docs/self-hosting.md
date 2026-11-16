# Self-hosting Libarrie

For Kubernetes, use the Helm chart in `deploy/helm/libarrie` instead; its
README covers installation. The identity provider, storage and backup
sections below apply to both.

This guide runs Libarrie for yourself, your family or a small group on one
Linux machine, with `deploy/production/compose.yaml`. (`compose.yaml` at the
repository root is a local development stack. Never make it reachable from
the internet: its development sign-in lets anyone sign in as anyone.
Libarrie refuses to run that sign-in when `WEB_ORIGIN` is a public address,
but it can't tell where requests come from.)

The stack runs:

- Caddy, for HTTPS with automatic certificates;
- the API and web app;
- the background worker;
- Postgres with pgvector;
- RustFS for page images, unless you use Cloudflare R2 or another
  S3-compatible store.

Only Caddy is reachable from outside.

## What you need

- **A Linux machine** with Docker Engine and the Compose v2 plugin, and
  Linux 5.13 or later with Landlock enabled (most current distributions).
  The image decoder's sandbox needs it.
- **Two DNS names pointing at the machine**, such as `notes.example.com` for
  the app and `files.notes.example.com` for page images. Browsers and the
  apps upload to and download from the second one directly.
- **Ports 80 and 443 reachable** from wherever you use Libarrie, for HTTPS
  and certificates.
- **An identity provider** (OpenID Connect). Libarrie has no passwords of its
  own. See the next section.
- **API keys for Mistral and Voyage AI.** Mistral reads the handwriting, and
  Voyage makes search understand meaning as well as words. Page images go to
  Mistral and page text goes to Voyage, and both charge per use. Libarrie
  stops calling them when a daily spending ceiling is reached
  (`SPEND_ACCOUNT_DAILY_MICROS`, `SPEND_DEPLOYMENT_DAILY_MICROS`; the
  defaults are $5 per account and $50 in total).

## Choose an identity provider

Any OpenID Connect provider that signs tokens with RS256 and publishes a
JWKS works. To run your own, Pocket ID, Authelia, Authentik, Keycloak and
Zitadel are all good choices. A hosted provider also works.

> **Anyone your identity provider lets sign in gets a Libarrie account.**
> Libarrie has no separate list of who may join. Use a provider, or an
> application within it, that only your own people can sign in to. Don't
> use one where anyone can make an account, such as a public Google sign-in.
> Owners and admins can block and delete accounts from `/admin`.

Register these in the provider:

1. **A web client** (confidential, authorization code with PKCE):
   - redirect URI `https://notes.example.com/auth/callback`;
   - scopes `openid`, `profile` and `email`. The email address is shown to
     owners and admins only, and never used to match people.

   Its client ID and secret go in `OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET`.
2. **For the iOS and Android apps (optional):**
   - a public client (PKCE, no secret) with redirect URI
     `libarrie://oauth/callback`, in `OIDC_NATIVE_CLIENT_ID`;
   - the apps call the API with access tokens, so set `OIDC_AUDIENCE` to the
     audience your provider puts in them (the default is `libarrie`).
3. **For agents signing in to the MCP server with OAuth (optional):** the
   provider must issue JWT access tokens whose audience is
   `https://notes.example.com/mcp`, and let MCP clients register. Most
   people use an API key instead (Settings → API keys), which needs nothing
   here.

`OIDC_ISSUER` is the provider's issuer URL, exactly as it appears in its
tokens. `OIDC_JWKS_URL` is its key set, listed as `jwks_uri` in
`<issuer>/.well-known/openid-configuration`.

## Configure

On the machine:

```sh
git clone https://github.com/libarrie/libarrie.git
cd libarrie/deploy/production
cp .env.example .env
chmod 600 .env
```

Fill in `.env`:

- `LIBARRIE_VERSION`: a release, such as `0.1.0`.
- `LIBARRIE_DOMAIN` and `LIBARRIE_FILES_DOMAIN`: your two names.
- Generate these secrets, one each:

  ```sh
  openssl rand -hex 32        # SECRET_KEY_BASE (64 characters)
  openssl rand -hex 32        # POSTGRES_PASSWORD
  openssl rand -hex 16        # S3_ACCESS_KEY_ID
  openssl rand -hex 32        # S3_SECRET_ACCESS_KEY
  echo "k1:$(openssl rand -hex 32)"   # IDENTITY_HASH_KEYS
  ```

- The identity provider settings from the previous section.
- `MISTRAL_API_KEY` and `VOYAGE_API_KEY`.

Keep a copy of `.env` with your backups: a restored server needs the same
values, in particular `IDENTITY_HASH_KEYS`, under which deleted accounts are
recorded.

## Start

```sh
docker compose pull        # or: docker compose build (builds the images from source; slow)
docker compose up -d
docker compose logs api
```

Each start runs the database migrations first. While nobody owns the server,
the API's log shows a one-time setup code:

1. Open `https://notes.example.com`.
2. Sign in.
3. Go to `/setup` and enter the code.

You're now the owner and can open the admin area. Alternatively, set
`LIBARRIE_OWNER` to your sign-in subject (the `sub` claim) before you first
sign in. If you ever lose owner access, run
`docker compose run --rm api setup-code` for a recovery code.

## Storage

**Bundled (default).** RustFS keeps page images in the `objects` Docker
volume, behind Caddy at `LIBARRIE_FILES_DOMAIN`. Every request must be signed
with your keys (the API hands out short-lived signed URLs), and browsers may
only call it from your app's origin.

**Cloudflare R2 or another S3-compatible store.**
1. Set the `S3_*` variables in `.env` (see the commented example there, and
   `docs/runbooks/r2-storage-and-journal.md` for the bucket and its CORS
   rules).
2. Remove the `objectstore` service from `compose.yaml` and the files site
   from the `Caddyfile`.

**The lifecycle journal** records account deletions, so a restored backup
can't bring deleted data back. It goes to the `libarrie-journal` bucket in
the same store unless you set `JOURNAL_S3_*`. A separate store, such as a
second R2 bucket with a retention lock, protects it better.

## Back up

Back up the database and the page images together, plus `.env`:

```sh
docker compose exec -T postgres pg_dump -U libarrie -Fc libarrie > libarrie-$(date +%F).dump
```

For the bundled store, back up the `objects` volume, for example by stopping
`objectstore` briefly and archiving the volume with your usual tool. With
R2, use its own versioning or replication.

To restore:
1. Start a fresh stack with the same `.env`.
2. Restore the database with `pg_restore` and the page images.
3. Before anyone uses it, replay the journal so deletions made after the
   backup are applied again: `docker compose run --rm api journal-replay`.

## Upgrade

1. Read the release notes.
2. Change `LIBARRIE_VERSION` in `.env`.
3. Run:

   ```sh
   docker compose pull && docker compose up -d
   ```

Migrations run before the API and worker start. Take a backup first.

Releases before the switch to RustFS bundled SeaweedFS. RustFS can't read
SeaweedFS's volume, so if you use the bundled store, copy the page images
across when you upgrade: see `docs/runbooks/seaweedfs-to-rustfs.md`.

## Troubleshooting

- **The API exits at startup:** `docker compose logs api` names the setting
  at fault. Libarrie checks its configuration before serving.
- **Image uploads fail with "unavailable":** the kernel probably lacks
  Landlock. Check `docker compose logs worker`, and see
  `docs/runbooks/decoder-sandbox.md` for the `minijail` alternative.
- **Check that the API can reach your store:**
  `docker compose run --rm api storage-check`.
- **Sign-in fails:** confirm the redirect URI matches exactly,
  `OIDC_ISSUER` matches the `iss` claim, and the machine can reach
  `OIDC_JWKS_URL`.
