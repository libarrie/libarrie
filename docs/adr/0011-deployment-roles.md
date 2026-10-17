# ADR 0011: Deployment roles: owners and admins

Status: accepted

Libarrie had no administrators: every person who signed in was a regular
user. This adds two deployment roles and an admin area in the web UI.

## Roles

- **Who holds them:** people (users), not accounts. Each user is `owner`,
  `admin`, or neither (`users.role`).
- **Where they're checked:** read with the session on every request, so a
  removed role takes effect at once.
- **No access to notes:** roles never grant access to anyone's notes,
  photos, transcripts or searches. Admin pages show account-level fields
  only: name, email (as the identity provider sent it), sign-in ID, account
  status and role.
- **Permissions, not roles:** admin actions check a named permission
  (`admin.can(role, permission)`). An owner can do everything an admin can,
  so making something owner-only later changes `can` alone.

  | Permission | Owner | Admin |
  | --- | --- | --- |
  | `ViewAdmin` (the admin area) | yes | yes |
  | `ManageAdmins` (grant and remove admin) | yes | yes |
  | `ManageOwners` (grant and remove owner) | yes | no |
  | `BlockUsers` (block and unblock) | yes | yes |
  | `DeleteUsers` (schedule and cancel deletion) | yes | yes |

- **Rules enforced in one transaction, serialized:**
  - Once ownership is claimed, at least one owner with an active account
    always exists. The last owner cannot be demoted or schedule account
    deletion (`last_owner`).
  - Only owners can make or remove owners, and admins can never change an
    owner's role (`owner_required`).
  - Only people with active accounts can be given a role.
  - Multiple owners are allowed.
- **Purge:** clears the role and the email.

## Claiming ownership

- **Setup code (default):** while no owner exists, each API process prints
  a one-time code in its log at startup:
  - it works once and expires after 24 hours;
  - only its SHA-256 hash is stored;
  - it is shown in Crockford base32, which has no ambiguous characters;
  - case, spaces and dashes are ignored when it's entered.

  Signing in and entering it at `/setup` makes that person an owner. Reading
  the server log proves you operate the server, which is the trust
  ownership needs. "First person to sign in becomes owner" was rejected: on
  a public server a stranger could win that race.
- **`LIBARRIE_OWNER`:** for automated deployments, a sign-in subject (from
  the configured issuer) that is made an owner whenever it signs in. While
  the setting names it, it stays an owner.
- **Recovery:** the operator command `libarrie_api setup-code` issues a
  recovery code, which works even when owners exist, for when the only
  owner lost access. It needs shell access to the server, so it's no weaker
  than setup.
- **Availability:** `/setup` exists only while no owner exists or a recovery
  code is outstanding; otherwise it returns "not found".

## Changing roles

- **Who can be promoted:** admins and owners search existing users (anyone
  who has signed in) and change roles from `/admin`. Email invitations were
  left out because many identity providers don't guarantee verified email
  addresses.
- **Each change:**
  - is confirmed on its own page;
  - requires a sign-in within the last five minutes;
  - passes the CSRF and same-origin checks;
  - is written to `admin_audit_log` (actor, target, from and to).
- **Non-admins:** `/admin` routes return "not found", and the Admin link
  appears only for admins.

## Blocking and deleting people

- **Who can act on whom:** admins can block or delete people without a
  role. Only owners can block or delete admins and owners
  (`owner_required`). Nobody can block or delete themselves here
  (`cannot_moderate_self`); their own account page handles deletion. The
  last active owner can't be blocked or deleted (`last_owner`), and a
  blocked owner doesn't count as active.
- **Recent sign-in:** every action needs a sign-in within the last five
  minutes, like role changes.
- **Blocking** sets `accounts.suspended_at`, `suspended_by` and an optional
  `suspension_reason` (shown only to admins). The account's status reads
  `suspended` for the API and the web app:
  - Web: every page redirects to `/account`, which says the account is
    blocked. Exports stay available, so people can always take their
    notes.
  - API: `/v1/me` and the export endpoints work. Everything else returns
    403 `account_suspended`.
  - Worker: recognition, indexing and derived jobs are postponed, and they
    resume on unblock.
  - Nothing is deleted. Unblocking restores full access.
- **Deleting** blocks the account and schedules closure with the normal
  grace period (`ACCOUNT_CLOSURE_GRACE_DAYS`). The person can still download
  exports during the grace period. An admin can cancel the deletion, which
  leaves the account blocked until they unblock it separately. Unblocking
  is refused while deletion is scheduled (`deletion_scheduled`).
- **Audit log:** `user.blocked`, `user.unblocked`,
  `user.deletion_scheduled` and `user.deletion_cancelled` are recorded.

## Email

- Web sign-in requests the `email` scope. The `email` claim from the ID
  token is recorded at each web sign-in, for display to admins only. It's
  never used to match people.
- The development issuer sends an email-shaped subject as the email claim.

## Also fixed

Entitlement timestamp comparison now rounds exact half microseconds to even,
as Postgres stores them (`.8848545` becomes `.884854`). This was the cause of
an intermittent `coverage_conflict` in the provisional-renewal test. A new
test reproduces it deterministically.

## Not yet built

Admin tools beyond roles, blocking and deletion: per-account limits,
background-job retry, and any owner-only permissions.
