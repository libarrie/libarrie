# ADR 0017: Private notebooks

Status: accepted

An owner can mark a notebook private (libarrie#1). A search that matches
one of its pages still says where the match is, but never returns the
matching text. The main reason is the MCP server (ADR 0012): an agent can
find the right page without the owner's sensitive notes being sent to an
LLM. The owner's answers in the issue set the scope: the text is hidden on
every query surface, MCP `get_text` refuses the notebook's pages, and the
flag can be set from the API, the web UI and both native apps.

## The flag

- **Storage:** `notebooks.private`, a boolean that defaults to false
  (`database/migrations/0002_notebook_private.sql`). Existing notebooks
  stay public.
- **API:** every notebook object has `private`. `POST /v1/notebooks` and
  `PATCH /v1/notebooks/{id}` accept it. An omitted or null `private` is
  false on create and no change on update, and PATCH keeps its If-Match
  rules. The OpenAPI input declares no default, so a generated client
  can't send false with every rename.
- **Read at query time.** Nothing about privacy is stored in the search
  index, its releases, jobs or the content-change log. A change applies
  from the next query, both ways, with no reindexing.
- **Where owners set it:** the web notebook forms, and the notebook
  editors in the iOS and Android apps.
  - The web forms post a `private_shown` marker with the checkbox. The
    server reads the box only when the marker is there, so a form without
    the control can't make a notebook public.
  - The native editors start their toggle from the saved flag and always
    send it, so a save that only renames keeps it.

## What it hides, and what stays visible

| Surface | A result for a page in a private notebook |
| --- | --- |
| `POST /v1/search` | Has no `snippet` and no `highlights` keys |
| Web search screen | Links to the page, with "Private notebook. The matching text isn't shown." in place of the snippet |
| iOS and Android search | The same, from `/v1/search` |
| MCP `search` | Has no `snippet`, in the structured content and in the text block |
| MCP `get_text` | A tool error (`isError: true`) that says the notebook is private, whether or not the page exists |

- **Visible:** the notebook's ID and name, and the page number. On
  `/v1/search`, also the page, revision, transcript-revision and
  index-generation IDs, `indexing_pending` and `match_kind`. None of these
  carries note text, and the owner asked for the name and IDs to stay.
- **Other notebooks' results are unchanged,** even in a response that
  mixes both. No result is marked private: the documented absence of
  `snippet` says it.
- **The text is never built.** `search.Hit.snippet` is an `Option`. For a
  private hit it's `None`, the snippet is never computed, and the compiler
  makes every consumer handle its absence.
- **Not hidden from the owner:** page detail (`GET /v1/pages/{id}`), the
  transcript endpoints, the page screens and exports still return the
  text. Hiding them would leave the owner unable to read a private
  notebook in any client.

## When the flag is read

Each surface reads the flag in the statement that decides whether text
goes out, or after the text was read. So a toggle, or a page moved into a
private notebook, applies from the next such statement. A request whose
deciding statement ran just before the change returns what it would have
returned a moment earlier.

- **Search:** `search.hit` reads the page's current notebook and its flag
  in a statement of its own for each hit, after the candidate queries that
  read the passage text. So text indexed after a toggle can't go out with
  an older flag. A later change, such as batching these lookups, must keep
  reading the flags after the candidate queries.
- **`get_text`:** it refuses right after it resolves the notebook, before
  it looks up the page, so the answer is the same whether or not the page
  exists. `pages.transcript_text` then reads the flag of the page's current
  notebook in the statement that reads the text. A toggle, or a move into
  a private notebook, between the lookup and the read is refused too, and
  any later caller of `transcript_text` fails closed the same way.

## The residual risk

A hit still confirms that a private page matches the query, and that
confirms more than guessing words suggests. The lexical path also matches
exact normalized substrings, and MCP `search` takes a `notebook` filter. So
a hostile or prompt-injected agent can confirm substrings of a private page
and extend a known prefix one character at a time. Only
`RATE_SEARCHES_PER_MINUTE` (default 60) bounds the rate, and semantic hits
add some noise.

So "private" protects against accidental disclosure to an agent, not
against an agent trying to extract the text. That follows from the owner's
requirement that a match still shows where it is. The agent likeliest to
try is a helpful one that `get_text` refused. So the refusal, the `search`
description and the server instructions say that the owner keeps this text
from agents, and ask agents not to piece it together from searches. That
steers a cooperative agent. It doesn't stop a hostile one. The hint next to
the private control, in all three editors, tells the owner what an agent's
search still shows.

## What "private" doesn't do

- **(a) AI processing:** the configured OCR and embedding providers still
  process private pages. Page images go to the OCR provider and passage
  text to the embedding provider: Mistral OCR and Voyage AI in production.
  The editors' privacy hint tells owners so, without naming the providers,
  which the operator chooses.
- **(b) Recall:** it doesn't recall snippets or page text that agents
  already received.
- **(c) Older builds** ignore the flag: during a rolling deploy, after a
  rollback past this release, and on servers that haven't upgraded yet.
  Such a server drops `private` from a save and still returns success.
  - The native apps check the notebook a save returns. When they asked
    for private and it isn't, they say so: `Saved, but this server doesn't
    support private notebooks yet, so "<name>" isn't private.`
  - The web can't, because the old build handled the request. The owner
    sees the setting off when a new build next renders the form.
  - An operator who must roll back past this release first blocks `/mcp`
    (see Operations).
- **(d) Owner routes:** it covers the MCP surface and `/v1/search`
  snippets, not the owner's own routes. Those return text to anything that
  holds the owner's credentials, such as another OAuth client of the same
  identity provider, or an assistant that drives the owner's browser.

## MCP and API tokens must have different audiences

`/v1` returns the text of private pages to the owner's tokens, so an MCP
credential must never work there. API keys never do (ADR 0012). OAuth
access tokens are kept apart only by their audiences. So every Libarrie
process refuses to start when the effective MCP audience
(`MCP_OAUTH_AUDIENCE`, else `WEB_ORIGIN` + `/mcp`) equals `OIDC_AUDIENCE`:
the API, the worker, and every command, including `migrate` and
`journal-replay`. The comparison is exact, like the verifiers' audience
match.

- **Upgrades:** the defaults never collide. A deployment that set the two
  audiences equal already let MCP tokens use all of `/v1`, against ADR
  0012. Its upgrade now stops at the migrate step, before the schema
  changes, with a message that names both variables. The fix is to give
  MCP its own audience.
- **Remaining caveat:** an identity provider that puts both audiences in
  one token would still let that token reach `/v1`. Rejecting such tokens
  on `/v1` would affect only the native apps, the only clients that send
  bearer tokens there, and only in that configuration. That's a follow-up.
  It should reject such a token with an error that names both audiences,
  rather than log a warning.

## Rules for future MCP tools

- Every MCP tool or resource that returns note content honors `private`.
  Note content is text, snippets or page images, including thumbnails and
  image URLs. A page image is the handwriting itself, and a multimodal
  agent can read it.
- MCP never sets `private` and never moves pages.

Comments where `mcp.gleam` registers its tools, and at the pinned tool list
in `mcp_test.gleam`, point here.

## Operations

### Database restores

A restore returns the database to a recovery point. `journal-replay` then
re-applies only trash, restore, purge and account lifecycle changes
(section 14). Privacy changes and page moves aren't journaled. So a
notebook made private after the recovery point becomes public again, and a
page moved into a private notebook after it goes back to its old notebook.
Search snippets and `get_text` would then return that text to agents, and
nothing tells the owner. Changes in the other direction fail closed.

So each restore procedure blocks `/mcp` in front of the API before the
restored database can answer it, and keeps it blocked until owners have
re-checked their notebooks. The web UI and the apps stay up, so owners can
re-check while agents can't reach them.

1. **Block `/mcp`.** Both methods answer `/mcp` with 503 and the body
   `MCP is paused.`:
   - **Compose:** add `respond /mcp* "MCP is paused." 503` to the
     `{$LIBARRIE_DOMAIN}` site in `deploy/production/Caddyfile`, and
     restart the `caddy` service if it's running.
   - **Helm:** apply a separate Ingress outside the release, as "Blocking
     `/mcp`" in `deploy/helm/libarrie/README.md` describes.
2. **Check it** before the restored database can answer: request
   `<origin>/mcp` without a key. Only a 503 with the body `MCP is paused.`
   confirms the block.
   - A 401 with a `WWW-Authenticate` challenge comes from the MCP server,
     so the block didn't take.
   - A bare 503 can be the ingress controller's own answer while the API
     has no ready pods.
3. **After `journal-replay`,** tell account owners the recovery point. Ask
   them to re-check which notebooks are private, to move again any pages
   they moved after it, and to revoke again any API key they revoked after
   it (Settings › Manage API keys). Revoking a key records no journal
   intent, so the restore brings the key back and `/mcp` would accept it.
4. **Unblock `/mcp`** once they have: remove the Caddyfile line and restart
   `caddy`, or delete the block's Ingress, Service and Deployment.

`docs/runbooks/r2-storage-and-journal.md`, `docs/self-hosting.md` and the
Helm README place these steps in their restore procedures.

A follow-up should journal privacy changes and page moves, so that
`journal-replay` re-applies them. That changes the section 14 journal
design. For one thing, a pending intent blocks lifecycle operations on its
scope until the journal acknowledges it, so a toggle would make an
immediate trash or restore of that notebook return 409.

### Rolling back past this release

An older build ignores the flag. For as long as it runs, MCP `search`
snippets and `get_text` return the text of every private notebook. That's
wider than a restore's exposure, which covers only notebooks changed after
the recovery point.

Don't roll back past this release if you can avoid it. If you must, first
block `/mcp` and check the block, as for a restore, so the older build
never serves it. Keep it until a build with private notebooks is back.

- The block must live outside what the rollback changes. With Compose,
  the Caddyfile is a bind mount, which a change of `LIBARRIE_VERSION`
  keeps. With Helm, `helm rollback` re-applies the older chart and values,
  so the block is an Ingress outside the release.
- Warning owners alone doesn't stop agents that already hold keys or
  tokens.

The upgrade sections of `docs/self-hosting.md` and the Helm README point
here.

### Rolling deploys

The migration adds the column without rewriting the table, but its
`alter` takes a brief ACCESS EXCLUSIVE lock on `notebooks`. While it waits
for that lock, notebook, page and search requests queue behind it. A
5-second `lock_timeout` caps each wait. On a timeout the migration rolls
back, records nothing and can be run again; the Helm migration Job retries
on its own. Until every API replica runs the new build, an old replica
still returns snippets and `get_text` text, and drops `private` from a
save.

## Where this departs from DESIGN.md and the fixtures README

Leaving out `snippet` isn't an additive change. The owner approved it for
this field in the issue: "Hide it everywhere and update our clients to
handle the case where it is omitted. We don't have to worry about other
clients right now." Older installed app builds and third-party clients
that require `snippet` fail on a private hit. Notebook responses only gain
a field, so they stay additive.

Following section 18 ("Record unresolved questions and deviations in
ADRs") and ADR 0008, this ADR records the deviation, and DESIGN.md isn't
edited. For results from private notebooks, it overrides:

- section 2, MVP journey 6: "Open a result showing notebook, page number,
  snippet, and image preview";
- section 3: "API changes must support older installed native clients";
- section 9: "Return snippet, notebook name/ID, page ID/number, revision
  ID, and optional highlight boxes";
- section 11: "Unknown additive response fields must not break clients",
  as far as it makes changes additive;
- `contracts/fixtures/README.md`: "Changes must stay additive for older
  installed apps (section 11): add fields, don't rename or remove them."

Section 11's example search response shows `snippet` and `highlights` on
every result; it is illustrative.

## Out of scope

- Hiding text from the owner's own reads and exports (above).
- Hiding the notebook name, per-page privacy, an account-wide default,
  privacy per API key, and a "private" badge in notebook lists.
- Keeping private notebooks out of OCR, indexing or embedding. They stay
  searchable, and only the text in results is withheld.
- Advertising support in `GET /v1/client-configuration`, so the native
  apps could hide the toggle on older servers. The apps fetch it only at
  sign-in, and during a rolling deploy a new replica can answer it while an
  old one handles the save. Checking the saved notebook checks the write
  that actually happened.

## Verification

- **Server:** `private_notebooks_test` covers the flag on every notebook
  response, its input rules, and trash and restore. It also covers search
  results from a private notebook: mixed with others, filtered to it,
  while indexing is pending, after a page move, and toggled both ways from
  the same index generation with no new jobs.
- **MCP:** `mcp_test` covers `search` and `get_text` by notebook name and
  ID, toggled both ways, the re-checked text read, the descriptions and
  instructions, and the audience separation.
- **Web:** the form and search tests, the accessibility snapshots (a
  private search hit, and the notebook settings opened), and the browser
  test, which makes a notebook private, searches it and follows the hit to
  the page, which still shows the text.
- **Contract and apps:** the `search_private` fixture, which the iOS and
  Android fixture tests decode. iOS `PresentationTests` and Android
  `NotebookDraftTest` pin the toggle's starting value and the request a
  save sends, and both apps test the older-server notice.
- **Upgrade:** migration `0002` was applied once by hand on top of a
  baseline database that held notebook rows. They read `private = false`.
