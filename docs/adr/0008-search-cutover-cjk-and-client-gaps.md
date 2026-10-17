# ADR 0008: Per-account search cutover, CJK search, automatic deferred processing and client gaps

Status: accepted

This replaces the section 19 interim rules for search migration, deferred
processing and CJK scripts.

## Per-account search migration (section 9)

`libarrie_api reindex` no longer swaps every account at once.

- **Start:** for each account not on the deployment's search configuration,
  it creates a **shadow release** that snapshots the content sequence S. It
  queues `shadow_index` jobs for every searchable page; confirmed-blank pages
  get an empty marker directly.
- **Publishing during migration:** new and corrected pages keep publishing
  into the active release with *its* model. Earlier models stay callable
  through `EMBEDDING_PREVIOUS` (`voyage:MODEL:DIMENSIONS` or
  `mock:DIMENSIONS`). If the active release's model is gone, pages publish
  for word search only, and searches report `index_migration_pending`.
- **Catch-up:** the `search_migration` maintenance task (every 30 seconds)
  replays the content-change log past the shadow's watermark, coalescing per
  page. Applying changes to a shadow appends none, so catch-up can't feed
  itself.
- **Cutover:** happens under the account lock that every content writer
  takes. It requires all of the following, then swaps the active pointer in
  one short transaction:
  - the watermark equals the account's content sequence;
  - no `shadow_index` job is pending;
  - every searchable page maps to the same source, transcript and blankness
    in both releases.
- **Retention:** the replaced release stays `retired` for seven days, or is
  marked `rollback_unavailable` if its model is no longer configured. Then
  it is dropped in bounded batches.
- **Rollback:** `libarrie_api reindex-rollback ACCOUNT_ID` makes the retired
  release the shadow again, replays the log into it and cuts over under the
  same checks. It is never a pointer flip. The account is then held until the
  next `reindex`.
- **Cost:** migration work carries no processing allocation, uses its own
  spend purpose (`embed_migration`), and takes no account job slots, so it
  never delays a user's uploads.
- **Log retention:** the hourly prune keeps the content-change log while a
  shadow or retained release still needs it.
- **Status:** `libarrie_api reindex-status` reports releases per state.

Queries use the active release's normalization version and model, so text
and queries always match during a migration.

## Chinese, Japanese, Korean and Thai (section 9)

Postgres word search and pg_trgm's word similarity need word boundaries,
which these scripts don't write. Before, word similarity between `会議` and
a sentence containing it was 0, and only exact substrings matched.

- **Normalization `norm-v2`:** turns runs of these scripts into overlapping
  character bigrams (`東京駅で会議` becomes `東京 京駅 駅で で会 会議`).
  Measured in Postgres:
  - exact and multi-character queries now score 1.0;
  - full-text search matches;
  - one misread character scores 0.33 to 0.44.
- **Threshold:** queries containing these scripts use a word-similarity
  threshold of 0.3 instead of 0.5. This value must be calibrated on the
  handwriting evaluation set.
- **Reindex required:** the normalization version is part of the search
  configuration, so the bump means existing deployments must run `reindex`.
  Until then each account searches its current release exactly as before.

Listing these languages as supported still requires the measured
evaluation (section 9).

## Automatic deferred processing (section 7)

`GET` and `PUT /v1/settings` hold `auto_process_deferred`, which is off by
default.

- **What it does:** the `deferred` maintenance task (every minute) admits
  waiting pages for opted-in accounts through exactly the `process-deferred`
  contract.
- **No duplicates:** operation IDs are derived from the page and source
  (UUIDv5), so repeated runs never start two operations for one source.
- **Clients:** the web, iOS and Android settings screens offer the toggle.

## Web

- **Upload recovery:** selected photos survive a refresh. Each upload's
  bytes and exact request are kept in IndexedDB until the server accepts
  it, and recovery replays the same operation.
  - **Account binding:** entries are bound to the account (rendered as
    `data-account-id`) and discarded for any other account.
  - **Sign-out:** clears them.
  - **Storage failure:** if storage fails or is cleared, the user is asked
    to choose the photo again, as before.
- **Accessibility audit:** `clients/web/scripts/a11y.sh` runs the audit.
  - The server test suite renders 16 screens in light and dark themes.
  - axe-core (`@axe-core/playwright`, MPL-2.0, test-only) checks WCAG 2.2
    A and AA on each.
  - No server runs, and self-checks confirm axe reports a known violation
    and the real stylesheet is applied.
  - All 32 screens pass. Interactive states (dialogs, htmx swaps) are not
    covered.

## Android

The launcher icon is an adaptive icon. The brand's books are redrawn as a
vector foreground inside the safe zone, on a navy background, with a
monochrome layer for themed icons. This replaces the full-bleed PNG that
lint flagged.

## Decoder on x86_64

The x86_64 seccomp policy lacked the minijail-init and launcher syscalls
added to the arm64 policy during earlier debugging (`clone` restricted to
plain fork flags, `wait4`, `rt_sigaction`, `prctl`, `getpid`, `kill`). It
also lacked `fork`, which musl uses on x86_64. The minijail tier would have
killed every decode. These are now ported.

Verifying needs a real x86_64 kernel; qemu user-mode emulation can't enforce
seccomp or Landlock faithfully. `.github/workflows/decoder-x86_64.yml` runs
both sandbox tiers on GitHub's x86_64 runners when the code is pushed. Until
that passes, the x86_64 policy is ported but not verified.
