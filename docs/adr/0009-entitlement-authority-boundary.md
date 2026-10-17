# ADR 0009: External entitlement authorities, lifecycle subscribers and web extensions

Status: accepted

Core enforces limits and coverage but never decides them, and contains no
code or data about how any authority decides or funds an entitlement. A
self-hosted server runs with none of the integration points below
configured; its users see no trace of them.

## Integration points

There are exactly three.

- **Internal entitlement API** (`/internal/v1`, `INTERNAL_API_TOKEN`):
  entitlement assignments, credit grants, entitlement status and lifecycle
  status. This already existed (ADRs 0001, 0007); its contract is in
  `contracts/entitlements/`.
- **Lifecycle subscriber** (`LIFECYCLE_SUBSCRIBER_URL`,
  `LIFECYCLE_SUBSCRIBER_TOKEN`): an optional receiver of account lifecycle
  commands.
  - **Delivery:** the worker's `lifecycle_subscriber` task sends each
    command with `PUT {url}/accounts/{id}/lifecycle`, retrying with backoff.
  - **Without a subscriber:** commands go to the journal only, and
    `GET /v1/account-deletion` reports no subscriber delivery.
  - **Command shape:** account ID, command ID, lifecycle revision, status,
    requested and effective times, and retained closure-intent intervals.
    It has no subscriber-specific fields.
- **Web extensions:** a deployment can compile additions into its own build
  by calling `libarrie_api.main_with(extensions)` instead of `main`. A
  `libarrie/web/config.Extension` can add:
  - sections on the Usage page;
  - signed-in routes, dispatched before core's 404;
  - notices for `?done=` codes;
  - Content Security Policy `form-action` origins.

  An extension receives a `Viewer`: the signed-in account ID, the CSRF
  token, and core's page, fragment and redirect helpers. Its form helper
  runs core's CSRF and same-origin checks. The default `main` passes no
  extensions, so the Usage page, routes and CSP are unchanged.

## Schema

The baseline migration changed in place (neutral names such as
`charge_root_operation_id` and `lifetime_units_consumed`, and
`acknowledge_coverage_end` in the account-deletion API), so recreate any
existing local database (`docker compose down -v`). DESIGN.md 1.11 rewrites
section 12 as "Entitlement authorities and account closure".

## Consequences

- An operator who runs an authority implements the entitlement contract and,
  if it needs to react to closure, the lifecycle subscriber. It ships any
  user-facing pages as a web extension in its own build of the API image.
- Core tests cover the extension mechanism with an example extension
  (`web_extension_test.gleam`) and subscriber delivery against a fake
  receiver (`lifecycle_test.gleam`).
