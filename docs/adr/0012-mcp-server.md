# ADR 0012: MCP server for agents

Status: accepted

People want to use their notes from an AI agent of their choice. Libarrie
serves a Model Context Protocol server that lets an agent search a person's
notes and read page text, and nothing else.

## Where it runs

- **In the API server:** `/mcp` is served on the API's port. A request to
  `/mcp` or `/.well-known/oauth-protected-resource[/mcp]` goes to the MCP
  handler; everything else goes to the Wisp app as before. There's no
  separate component to deploy, and the MCP tools call the domain layer
  directly, with the same rules as `/v1`.
- **SDK:** [gleam_mcp](https://github.com/thedadams/gleam-mcp), pinned to a
  git commit (it isn't on Hex). It supports the 2026-07-28 and 2025-11-25
  protocol revisions over Streamable HTTP.
- **Package:** `server/packages/mcp` (`libarrie/mcp`).

## Authentication

Every request needs `Authorization: Bearer` with either of these:

- **An API key** (`lbk_` followed by 43 random characters). People create
  keys under Settings → API keys:
  - the key is shown once;
  - only its SHA-256 hash is stored (`api_keys`);
  - creating a key needs a sign-in within the last five minutes;
  - each person can have at most 25 keys;
  - revoking deletes the key at once;
  - account purge deletes every key of the account;
  - a key works on `/mcp` only, never on `/v1` or the web app;
  - `last_used_at` is updated at most once a minute.
- **An identity-provider access token**, with a real provider only (not the
  development issuer). It's verified like any other token from the issuer
  (signature via JWKS, issuer, expiry), but the audience must be the MCP
  server: `WEB_ORIGIN` + `/mcp`, or `MCP_OAUTH_AUDIENCE`. A token issued for
  the API or the native apps doesn't work here, as RFC 8707 resource
  binding intends. A first sign-in creates the account, as it does for the
  native apps. The effective MCP audience must differ from `OIDC_AUDIENCE`,
  compared exactly, or every Libarrie process refuses to start: private
  notebooks depend on MCP tokens never working on `/v1` (ADR 0017).

A request that fails authentication gets **401 with `WWW-Authenticate:
Bearer`**:

- With OAuth available, the challenge is
  `Bearer resource_metadata="{origin}/.well-known/oauth-protected-resource/mcp"`.
  That protected-resource metadata (RFC 9728) names `OIDC_ISSUER` as the
  authorization server, so MCP clients can discover it and run their OAuth
  flow. Client registration, whether dynamic or with client ID metadata
  documents, is the provider's business. `MCP_OAUTH_SCOPES` adds
  `scope="…"` and `scopes_supported` when the provider needs particular
  scopes.
- With API keys only (development issuer), the challenge is
  `Bearer realm="libarrie"`. The metadata paths return 404.
- When a token was sent but rejected, both forms add
  `error="invalid_token"`.

gleam_mcp handles the API key and the token through one identity hook
(`with_identity_authorization`). Libarrie adds the challenge to the SDK's
401. The authenticated user ID is the MCP principal:
- in the 2026 protocol, it's checked on every request;
- in the 2025 protocol, it's bound to the session.

## Sessions and replicas

The 2025-11-25 protocol has sessions: `initialize` returns an
`Mcp-Session-Id` that the client sends with every later request.
- **Where they live:** in Postgres, through gleam_mcp's session store
  (`gleam_mcp_postgres`), on the API's own database connection. Its tables
  (`mcp_sessions`, `mcp_resource_subscriptions`, `mcp_tasks`) are created
  by the adapter's `migrate`, which the API's `migrate` command runs.
- **What that gives:** any API replica can serve any session, so no sticky
  routing is needed, and sessions survive restarts and deploys.
- **Expiry:** 30 days without a request, renewed with use.
- **Request state:** follow-up requests (MRTR) are signed with a secret
  derived from `SECRET_KEY_BASE`, so they're valid on every replica.

gleam_mcp can also relay live traffic between replicas (`with_cluster`):
notifications to subscribers, server-to-client requests, task completions
and follow-up inputs. That needs Erlang distribution between the API pods.
Libarrie doesn't use any of those today: it publishes no notifications,
forbids tasks and never asks the client for input. So it doesn't join a
cluster, in line with DESIGN.md's rule against depending on Erlang
clustering. Without a cluster, a 2026-07-28 subscription only hears changes
published on its own replica, which is nothing. Revisit this if Libarrie
starts publishing notifications or asking clients for input.

## Tools

All three tools are read-only (`readOnlyHint`). They see only the
authenticated person's notes and never run as tasks.

| Tool | Arguments | Returns |
| --- | --- | --- |
| `get_me` | none | User ID, name, email; account ID and status |
| `search` | `query`; optional `notebook` | Up to 10 pages: notebook (ID, name), page number, snippet. Pages in private notebooks come without a snippet (ADR 0017) |
| `get_text` | `notebook`, `page` | The page's selected transcript text. Pages in private notebooks are refused (ADR 0017) |

- **Naming a notebook:** `notebook` takes a notebook ID, or a name matched
  ignoring case and surrounding spaces. Names aren't unique:
  - a name shared by several notebooks returns their IDs to choose from;
  - an unknown name lists the person's notebooks.
- **Search** is the same hybrid search as `/v1/search`, with the same rate
  limit and query-embedding budget.
- **Errors come back as tool errors**, which the agent can read and act on.
  This covers bad arguments, a missing page, a page not transcribed yet, a
  page in a private notebook (ADR 0017), and a blocked or closed account.
  Results carry both a text block and structured content.
- **Blocked accounts** (ADR 0011) still authenticate. `get_me` reports the
  status, and `search` and `get_text` refuse. Closed accounts are refused
  the same way.

## Release

The SDK and its dependencies pass the release license gate, and both
release images build. The dependencies include an `httpp` fork and hackney
with its dependencies, used by the SDK's client. The Gleam build stages
install git to fetch the git dependencies. The license gate now also reads
`licenses` from `mix.exs`, because `ssl_verify_fun` (MIT) declares it only
there.

## Not yet built

- Key expiry and per-key scopes.
- More tools, such as listing notebooks and pages.
