-- Libarrie core baseline schema (DESIGN.md section 5).
--
-- Conventions:
--   * Opaque UUID identifiers, UTC timestamptz, monotonically increasing
--     integer versions for optimistic concurrency.
--   * Every tenant-owned row carries account_id and composite foreign keys
--     enforce account consistency where practical.
--   * Columns needed by phased machinery (section 19) are reserved here so
--     later phases need no destructive migration.

create extension if not exists vector;
create extension if not exists pg_trgm;
create extension if not exists btree_gin;

-- RFC 3339 rendering used by every API read so the application never has to
-- decode native timestamp wire formats.
create function rfc3339(ts timestamptz) returns text
language sql immutable parallel safe as $$
  select to_char(ts at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
$$;

-- Identity and accounts ------------------------------------------------------

create table users (
  id uuid primary key,
  display_name text not null default '',
  -- As the identity provider sent it at sign-in; shown to admins only,
  -- never used to match people.
  email text,
  -- Deployment role (ADR 0011): owner or admin; none means a regular user.
  -- Roles never grant access to anyone's notes.
  role text check (role in ('owner', 'admin')),
  created_at timestamptz not null default now()
);
create index users_role on users (role) where role is not null;

-- One-time codes for claiming ownership. `setup` codes are printed in the
-- server log while no owner exists; `recovery` codes come from the
-- `setup-code` operator command and work even when owners exist. Only a
-- hash is stored; each code is single-use and expires.
create table owner_setup_codes (
  id uuid primary key,
  code_hash bytea not null unique,
  kind text not null check (kind in ('setup', 'recovery')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  claimed_at timestamptz,
  claimed_by uuid references users (id)
);

-- Who changed which role, for whom, and when.
create table admin_audit_log (
  id uuid primary key,
  actor_user_id uuid references users (id),
  action text not null,
  target_user_id uuid references users (id),
  detail jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index admin_audit_log_created on admin_audit_log (created_at desc);

create table accounts (
  id uuid primary key,
  owner_user_id uuid not null unique references users (id),
  status text not null default 'active'
    check (status in ('active', 'closure_scheduled', 'closing', 'closed')),
  closure_requested_at timestamptz,
  closure_effective_at timestamptz,
  lifecycle_revision bigint not null default 1,
  content_sequence bigint not null default 0,
  active_search_release_id uuid,
  allowance_schedule_id uuid,
  created_at timestamptz not null default now(),
  purged_at timestamptz,
  closure_cap_at timestamptz,
  search_migration_held boolean not null default false,
  auto_process_deferred boolean not null default false,
  -- Blocked by an admin (ADR 0011): sign-in shows a notice and allows
  -- exports only; processing pauses. Independent of closure.
  suspended_at timestamptz,
  suspended_by uuid references users (id),
  suspension_reason text
);

create table identities (
  user_id uuid not null references users (id),
  issuer text not null,
  subject text not null,
  created_at timestamptz not null default now(),
  primary key (issuer, subject)
);
create index identities_user on identities (user_id);

-- Keyed hash of issuer/subject retained for two years after purge
-- (section 10). Multiple HMAC keys may be live during rotation.
create table identity_usage_ledger (
  key_id text not null,
  identity_key bytea not null,
  lifetime_units_consumed integer not null default 0,
  account_status text not null,
  purged_at timestamptz,
  delete_after timestamptz,
  updated_at timestamptz not null default now(),
  primary key (key_id, identity_key)
);

-- Browser sessions (section 13). Only a hash of the cookie value is stored.
create table web_sessions (
  token_hash bytea primary key,
  user_id uuid not null references users (id),
  account_id uuid not null references accounts (id),
  csrf_token text not null,
  status_only boolean not null default false,
  auth_time timestamptz not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz
);

-- API keys for the MCP server (ADR 0012). Only a hash is stored; the key is
-- shown once. Revoking deletes the row.
create table api_keys (
  id uuid primary key,
  user_id uuid not null references users (id),
  account_id uuid not null references accounts (id),
  name text not null,
  -- The first characters of the key, so people can tell keys apart.
  prefix text not null,
  key_hash bytea not null unique,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);
create index api_keys_user on api_keys (user_id, created_at);

-- Entitlements and quota ledgers (section 10) --------------------------------

create table entitlement_assignments (
  account_id uuid not null references accounts (id),
  authority text not null,
  revision bigint not null,
  command_id uuid not null,
  payload_hash text not null,
  effective_at timestamptz not null,
  limits jsonb not null,
  features jsonb not null default '{}',
  processing_policy jsonb not null,
  renewal_policy jsonb not null default '{"kind":"disabled"}',
  received_at timestamptz not null default now(),
  primary key (account_id, authority, revision)
);

-- One row per account; first funding lock after the account row.
create table account_usage (
  account_id uuid primary key references accounts (id),
  stored_pages integer not null default 0 check (stored_pages >= 0),
  reserved_page_slots integer not null default 0 check (reserved_page_slots >= 0),
  notebooks integer not null default 0 check (notebooks >= 0)
);

create table usage_periods (
  id uuid primary key,
  account_id uuid not null references accounts (id),
  kind text not null check (kind in ('lifetime', 'reporting')),
  schedule_id uuid,
  starts_at timestamptz not null,
  ends_at timestamptz,
  allowance integer check (allowance is null or allowance >= 0),
  unlimited boolean not null default false,
  used integer not null default 0 check (used >= 0),
  reserved integer not null default 0 check (reserved >= 0),
  unique (account_id, id)
);
create unique index usage_periods_one_lifetime on usage_periods (account_id) where kind = 'lifetime';

create table processing_coverage (
  id uuid primary key,
  account_id uuid not null references accounts (id),
  authority text not null,
  kind text not null check (kind in ('base', 'upgrade')),
  parent_coverage_id uuid references processing_coverage (id),
  funding_change_id uuid,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  admission_end_at timestamptz not null,
  authorized_units integer not null check (authorized_units >= 0),
  funded_monthly_budget integer,
  used integer not null default 0 check (used >= 0),
  reserved integer not null default 0 check (reserved >= 0),
  revoked_unreserved integer not null default 0 check (revoked_unreserved >= 0),
  authority_revision bigint not null,
  confirmation_state text not null default 'confirmed'
    check (confirmation_state in ('confirmed', 'provisional')),
  created_at timestamptz not null default now(),
  check (starts_at < ends_at),
  check (admission_end_at >= starts_at and admission_end_at <= ends_at),
  check (used + reserved + revoked_unreserved <= authorized_units),
  unique (account_id, id),
  revoked_at timestamptz,
  renewal_policy_id uuid,
  provisioned_at timestamptz,
  confirmed_at timestamptz
);
create index processing_coverage_admission on processing_coverage (account_id, admission_end_at);

create table coverage_revocations (
  account_id uuid not null references accounts (id),
  authority text not null,
  revocation_id uuid not null,
  coverage_ids uuid[] not null,
  effective_at timestamptz not null,
  reason text not null
    check (reason in ('refund', 'grace_expired', 'account_closure', 'provisional_rejected', 'admin')),
  authority_revision bigint not null,
  payload_hash text not null,
  created_at timestamptz not null default now(),
  primary key (account_id, revocation_id)
);

create table credit_grants (
  id uuid primary key,
  account_id uuid not null references accounts (id),
  external_grant_id text not null unique,
  granted integer not null check (granted >= 0),
  reserved integer not null default 0 check (reserved >= 0),
  consumed integer not null default 0 check (consumed >= 0),
  revoked integer not null default 0 check (revoked >= 0),
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  check (reserved + consumed + revoked <= granted),
  unique (account_id, id),
  revoked_at timestamptz
);

create table account_job_slots (
  account_id uuid primary key references accounts (id),
  occupied integer not null default 0 check (occupied >= 0),
  slot_limit integer not null check (slot_limit >= 0)
);

-- Notebooks, pages and revisions ----------------------------------------------

create table notebooks (
  id uuid primary key,
  account_id uuid not null references accounts (id),
  name text not null,
  description text not null default '',
  color text,
  version bigint not null default 1,
  numbering_revision bigint not null default 1,
  deleted_at timestamptz,
  deletion_batch_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (account_id, id),
  purge_requested_at timestamptz
);
create index notebooks_account on notebooks (account_id, created_at, id);

create table objects (
  id uuid primary key,
  account_id uuid not null references accounts (id),
  bucket text not null,
  key text not null,
  content_type text not null,
  bytes bigint not null,
  checksum text not null,
  state text not null check (state in ('pending', 'stored', 'rejected', 'purged')),
  backup_status text not null default 'pending' check (backup_status in ('pending', 'verified', 'missing')),
  backup_verified_at timestamptz,
  width integer,
  height integer,
  created_at timestamptz not null default now(),
  purge_after timestamptz,
  unique (account_id, id),
  unique (bucket, key),
  kind text not null default 'source' check (kind in ('source', 'thumbnail', 'preview'))
);

create table pages (
  id uuid primary key,
  account_id uuid not null references accounts (id),
  notebook_id uuid not null,
  page_number integer not null check (page_number > 0),
  visibility text not null
    check (visibility in ('placeholder', 'active', 'restore_pending', 'trashed')),
  active_revision_id uuid,
  pending_revision_id uuid,
  awaiting_processing boolean not null default false,
  version bigint not null default 1,
  content_version bigint not null default 1,
  deleted_at timestamptz,
  deletion_batch_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (account_id, id),
  foreign key (account_id, notebook_id) references notebooks (account_id, id),
  -- Page numbers are unique among every non-trashed state. Deferrable so a
  -- bulk renumber can check uniqueness at commit (section 5).
  constraint pages_number_unique
    exclude using btree (notebook_id with =, page_number with =)
    where (visibility <> 'trashed')
    deferrable initially immediate,
  purge_requested_at timestamptz
);
create index pages_notebook_order on pages (notebook_id, page_number, id);

create table page_revisions (
  id uuid primary key,
  account_id uuid not null,
  page_id uuid not null,
  source_object_id uuid,
  selected_transcript_revision_id uuid,
  source_generation integer not null,
  status text not null,
  error_code text,
  created_at timestamptz not null default now(),
  unique (account_id, id),
  foreign key (account_id, page_id) references pages (account_id, id),
  foreign key (account_id, source_object_id) references objects (account_id, id),
  purge_requested_at timestamptz,
  thumbnail_object_id uuid,
  preview_object_id uuid,
  foreign key (account_id, thumbnail_object_id) references objects (account_id, id),
  foreign key (account_id, preview_object_id) references objects (account_id, id)
);

alter table pages
  add foreign key (account_id, active_revision_id) references page_revisions (account_id, id)
    deferrable initially deferred,
  add foreign key (account_id, pending_revision_id) references page_revisions (account_id, id)
    deferrable initially deferred;

create table ocr_results (
  id uuid primary key,
  account_id uuid not null,
  revision_id uuid not null,
  processing_version text not null,
  raw_text text not null,
  recognition_outcome text not null
    check (recognition_outcome in ('text_detected', 'blank_confirmed', 'unreadable', 'unsupported_content', 'provider_error')),
  language text,
  provider text not null,
  model_id text not null,
  boxes jsonb,
  created_at timestamptz not null default now(),
  unique (account_id, id),
  foreign key (account_id, revision_id) references page_revisions (account_id, id)
);

create table transcript_revisions (
  id uuid primary key,
  account_id uuid not null,
  revision_id uuid not null,
  parent_id uuid references transcript_revisions (id),
  ocr_result_id uuid references ocr_results (id),
  text text not null,
  origin text not null check (origin in ('ocr', 'user')),
  blank boolean not null default false,
  created_at timestamptz not null default now(),
  unique (account_id, id),
  foreign key (account_id, revision_id) references page_revisions (account_id, id)
);

alter table page_revisions
  add foreign key (account_id, selected_transcript_revision_id)
    references transcript_revisions (account_id, id) deferrable initially deferred;

-- Operations, uploads and reservations ----------------------------------------

create table operations (
  id uuid not null,
  account_id uuid not null references accounts (id),
  kind text not null check (kind in ('upload', 'replacement', 'reprocess', 'deferred_processing')),
  request_hash text not null,
  status text not null,
  failure_fault text check (failure_fault in ('user', 'system')),
  client_label text not null default '',
  notebook_id uuid,
  page_id uuid,
  revision_id uuid,
  processing_mode text not null default 'immediate' check (processing_mode in ('immediate', 'deferred')),
  upload_accepted_at timestamptz,
  parent_operation_id uuid,
  charge_root_operation_id uuid not null,
  recovery_hold_id uuid,
  terminal_reason text,
  error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (account_id, id),
  paused_since timestamptz
);
create index operations_page on operations (account_id, page_id, created_at);
-- At most one pending source-changing operation per page (section 5).
create unique index operations_one_source_guard on operations (account_id, page_id)
  where status in ('awaiting_upload', 'validating', 'queued', 'recognizing', 'indexing')
    and kind in ('upload', 'replacement', 'reprocess', 'deferred_processing');

create table upload_sessions (
  id uuid primary key,
  account_id uuid not null,
  operation_id uuid not null,
  page_id uuid not null,
  revision_id uuid not null,
  staging_key text not null,
  final_key text,
  expected_bytes bigint not null,
  checksum text not null,
  content_type text not null,
  status text not null check (status in ('awaiting_upload', 'completing', 'accepted', 'expired', 'cancelled', 'failed')),
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (account_id, operation_id),
  foreign key (account_id, operation_id) references operations (account_id, id),
  checksum_md5 text
);
create index upload_sessions_expiry on upload_sessions (account_id, expires_at) where status = 'awaiting_upload';

create table quota_reservations (
  id uuid primary key,
  account_id uuid not null,
  operation_id uuid not null,
  allocation_attempt integer not null default 1,
  page_slots integer not null default 0 check (page_slots in (0, 1)),
  processing_units integer not null default 0 check (processing_units in (0, 1)),
  coverage_id uuid,
  period_id uuid,
  credit_grant_id uuid,
  page_slot_state text not null default 'none'
    check (page_slot_state in ('none', 'reserved', 'stored', 'released')),
  processing_state text not null default 'none'
    check (processing_state in ('none', 'reserved', 'consumed', 'released', 'held')),
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (account_id, operation_id) references operations (account_id, id),
  foreign key (account_id, coverage_id) references processing_coverage (account_id, id),
  foreign key (account_id, period_id) references usage_periods (account_id, id),
  foreign key (account_id, credit_grant_id) references credit_grants (account_id, id),
  check (
    (processing_units = 0 and coverage_id is null and period_id is null and credit_grant_id is null)
    or (processing_units = 1 and num_nonnulls(coverage_id, period_id, credit_grant_id) = 1)
  )
);
create index quota_reservations_operation on quota_reservations (account_id, operation_id);

create table recovery_holds (
  id uuid primary key,
  account_id uuid not null,
  charge_root_operation_id uuid not null,
  reservation_id uuid not null references quota_reservations (id),
  source_revision_id uuid not null,
  request_hash text not null,
  state text not null check (state in ('held', 'claimed', 'consumed', 'released')),
  active_retry_operation_id uuid,
  first_failure_at timestamptz not null,
  claim_deadline timestamptz not null,
  unique (account_id, charge_root_operation_id)
);

create table usage_events (
  id uuid primary key,
  account_id uuid not null references accounts (id),
  operation_id uuid not null,
  charge_root_operation_id uuid not null,
  meter text not null,
  amount integer not null,
  reason text not null,
  created_at timestamptz not null default now(),
  unique (account_id, charge_root_operation_id, meter, reason)
);

create table idempotency_records (
  account_id uuid not null references accounts (id),
  endpoint text not null,
  key text not null,
  request_hash text not null,
  response_status integer,
  response_body text,
  expires_at timestamptz not null,
  primary key (account_id, endpoint, key)
);

-- Search: configurations, generations, passages and embeddings (section 9) ---

create table search_configurations (
  id uuid primary key,
  embedding_provider text not null,
  embedding_model text not null,
  dimensions integer not null,
  chunking_version text not null,
  normalization_version text not null,
  created_at timestamptz not null default now(),
  unique (embedding_provider, embedding_model, dimensions, chunking_version, normalization_version)
);

create table search_releases (
  id uuid primary key,
  account_id uuid not null references accounts (id),
  configuration_id uuid not null references search_configurations (id),
  state text not null check (state in ('active', 'shadow', 'retired', 'rollback_unavailable')),
  backfill_sequence bigint not null default 0,
  applied_sequence bigint not null default 0,
  created_at timestamptz not null default now(),
  unique (account_id, id),
  previous_release_id uuid,
  retired_at timestamptz
);

alter table accounts
  add foreign key (id, active_search_release_id) references search_releases (account_id, id)
    deferrable initially deferred;

create table index_generations (
  id uuid primary key,
  account_id uuid not null,
  page_id uuid not null,
  revision_id uuid not null,
  transcript_revision_id uuid not null,
  configuration_id uuid not null references search_configurations (id),
  state text not null check (state in ('built', 'published', 'superseded', 'empty')),
  created_at timestamptz not null default now(),
  unique (account_id, id),
  foreign key (account_id, revision_id) references page_revisions (account_id, id),
  foreign key (account_id, transcript_revision_id) references transcript_revisions (account_id, id)
);

create table search_release_pages (
  release_id uuid not null,
  account_id uuid not null,
  page_id uuid not null,
  index_generation_id uuid not null,
  primary key (release_id, page_id),
  foreign key (account_id, release_id) references search_releases (account_id, id),
  foreign key (account_id, page_id) references pages (account_id, id),
  foreign key (account_id, index_generation_id) references index_generations (account_id, id)
);
create index search_release_pages_generation on search_release_pages (account_id, index_generation_id);

-- Passages and embeddings are hash-partitioned by account so tenant-filtered
-- lexical and vector queries prune to one small partition (sections 5 and 9).
create table passages (
  id uuid not null,
  account_id uuid not null,
  index_generation_id uuid not null,
  ordinal integer not null,
  text text not null,
  normalized_text text not null,
  start_offset integer not null,
  end_offset integer not null,
  boxes jsonb,
  search_vector tsvector generated always as (to_tsvector('simple', normalized_text)) stored,
  primary key (account_id, id)
) partition by hash (account_id);

create table embeddings (
  passage_id uuid not null,
  account_id uuid not null,
  index_generation_id uuid not null,
  configuration_id uuid not null,
  embedding vector not null,
  model_id text not null,
  dimensions integer not null,
  primary key (account_id, passage_id, configuration_id),
  foreign key (account_id, passage_id) references passages (account_id, id) on delete cascade
) partition by hash (account_id);

do $$
begin
  for i in 0..15 loop
    execute format('create table passages_p%s partition of passages for values with (modulus 16, remainder %s)', i, i);
    execute format('create table embeddings_p%s partition of embeddings for values with (modulus 16, remainder %s)', i, i);
  end loop;
end $$;

create index passages_generation on passages (account_id, index_generation_id, ordinal);
create index passages_trigram on passages using gin (account_id, normalized_text gin_trgm_ops);
create index passages_fts on passages using gin (account_id, search_vector);
create index embeddings_generation on embeddings (account_id, index_generation_id);

create table content_changes (
  account_id uuid not null references accounts (id),
  sequence bigint not null,
  page_id uuid not null,
  content_version bigint not null,
  action text not null,
  created_at timestamptz not null default now(),
  primary key (account_id, sequence)
);

-- Durable job queue (section 8) -----------------------------------------------

create table jobs (
  id uuid primary key,
  account_id uuid references accounts (id),
  operation_id uuid,
  page_id uuid,
  revision_id uuid,
  transcript_revision_id uuid,
  configuration_id uuid,
  stage text not null,
  schema_version integer not null default 1,
  payload jsonb not null default '{}',
  dedupe_key text not null,
  replay_generation integer not null default 0,
  state text not null check (state in ('pending', 'running', 'retryable', 'succeeded', 'failed', 'cancelled')),
  run_after timestamptz not null default now(),
  attempts integer not null default 0,
  max_attempts integer not null default 5,
  owner_id text,
  attempt_token uuid,
  lease_expires_at timestamptz,
  heartbeat_at timestamptz,
  stage_deadline timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deadline_seconds integer
) with (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.02);

create unique index jobs_dedupe_live on jobs (dedupe_key)
  where state in ('pending', 'running', 'retryable');
create index jobs_claimable on jobs (run_after, id) where state in ('pending', 'retryable');
create index jobs_running_lease on jobs (lease_expires_at) where state = 'running';
create index jobs_operation on jobs (account_id, operation_id);

create table job_slot_leases (
  job_id uuid primary key references jobs (id),
  account_id uuid not null references accounts (id),
  attempt_token uuid not null,
  state text not null check (state in ('live', 'released'))
);
create index job_slot_leases_live on job_slot_leases (account_id) where state = 'live';

create table job_attempts (
  job_id uuid not null references jobs (id),
  attempt_number integer not null,
  token uuid not null,
  owner_id text not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  outcome text,
  provider_request_id text,
  sanitized_error text,
  primary key (job_id, attempt_number)
);

-- Lifecycle outbox and audit (sections 14, 16) ---------------------------------

create table lifecycle_outbox (
  command_id uuid not null,
  account_id uuid not null references accounts (id),
  scope_kind text not null,
  scope_id uuid not null,
  generation bigint not null,
  action text not null,
  destination text not null,
  payload jsonb not null,
  payload_hash text not null,
  state text not null default 'pending' check (state in ('pending', 'acknowledged')),
  acknowledgement text,
  retry_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  attempts integer not null default 0,
  last_error text,
  journal_sequence bigint,
  primary key (command_id, destination)
);
create index lifecycle_outbox_pending on lifecycle_outbox (retry_at) where state = 'pending';

create table audit_events (
  id uuid primary key,
  actor text not null,
  account_id uuid,
  action text not null,
  target text,
  request_id text,
  created_at timestamptz not null default now()
);

-- Lifecycle, exports, controls ---------------------------------------------------------

-- Jobs: per-job stage deadline override (exports need longer than the
-- default), and a dedupe guard for periodic maintenance buckets.

create table jobs_archive (like jobs including defaults);
create index jobs_archive_account on jobs_archive (account_id, created_at);
create table job_attempts_archive (like job_attempts including defaults);

-- Lifecycle outbox: one command identity delivered to several destinations
-- (journal and any lifecycle subscriber) under the same revision.
create index lifecycle_outbox_scope on lifecycle_outbox (account_id, scope_id) where state = 'pending';

-- Permanent purge ---------------------------------------------------------------


-- Storage objects queued for deletion after their rows commit away. Rows
-- outlive the object only until the deletion task confirms removal.
create table pending_object_deletions (
  id uuid primary key,
  bucket text not null,
  key text not null,
  reason text not null,
  created_at timestamptz not null default now(),
  attempts integer not null default 0,
  unique (bucket, key)
);

create table deletion_tombstones (
  account_id uuid not null,
  scope_kind text not null,
  scope_id uuid not null,
  generation bigint not null,
  action text not null,
  command_id uuid not null,
  created_at timestamptz not null default now(),
  retention_deadline timestamptz not null,
  primary key (account_id, scope_kind, scope_id, generation)
);

-- Exports ----------------------------------------------------------------------------

create table exports (
  id uuid primary key,
  account_id uuid not null references accounts (id),
  state text not null check (state in ('assembling', 'completed', 'failed', 'expired', 'cancelled', 'invalidated')),
  include_trash boolean not null default false,
  notebook_ids uuid[],
  snapshot_at timestamptz not null default now(),
  execution_deadline timestamptz not null,
  completed_at timestamptz,
  expires_at timestamptz,
  manifest_version integer not null default 2,
  part_count integer not null default 0,
  part_size_limit bigint not null,
  item_count integer not null default 0,
  total_bytes bigint not null default 0,
  error_code text,
  created_at timestamptz not null default now(),
  unique (account_id, id)
);
create index exports_account on exports (account_id, created_at desc);

create table export_items (
  export_id uuid not null references exports (id) on delete cascade,
  ordinal integer not null,
  part_number integer not null default 1,
  page_id uuid not null,
  notebook_id uuid not null,
  notebook_name text not null,
  page_number integer not null,
  visibility text not null,
  source_revision_id uuid not null,
  transcript_revision_id uuid,
  object_id uuid not null,
  object_key text not null,
  content_type text not null,
  bytes bigint not null,
  checksum text not null,
  processing_status text not null,
  primary key (export_id, ordinal)
);
create index export_items_part on export_items (export_id, part_number, ordinal);

create table export_parts (
  export_id uuid not null references exports (id) on delete cascade,
  part_number integer not null,
  key text not null,
  bytes bigint,
  checksum text,
  item_count integer not null default 0,
  ready_at timestamptz,
  primary key (export_id, part_number)
);

-- Pins block ordinary garbage collection of the artifacts an export or
-- migration depends on.
create table artifact_pins (
  owner_kind text not null,
  owner_id uuid not null,
  artifact_kind text not null,
  artifact_id uuid not null,
  expires_at timestamptz not null,
  primary key (owner_kind, owner_id, artifact_kind, artifact_id)
);
create index artifact_pins_artifact on artifact_pins (artifact_kind, artifact_id);

-- Account closure ------------------------------------------------------------------

create table closure_intents (
  id uuid primary key,
  account_id uuid not null references accounts (id),
  requested_at timestamptz not null default now(),
  withdrawn_at timestamptz
);
create index closure_intents_account on closure_intents (account_id, requested_at);


-- Provider spend, permits and circuits (section 16) ---------------------------------

create table provider_spend (
  id uuid primary key,
  account_id uuid,
  operation_id uuid,
  job_id uuid,
  provider text not null,
  purpose text not null,
  budget_window date not null,
  estimated_cost_micros bigint not null,
  actual_cost_micros bigint,
  outcome text not null default 'reserved'
    check (outcome in ('reserved', 'succeeded', 'failed', 'unknown')),
  created_at timestamptz not null default now()
);
create index provider_spend_account on provider_spend (account_id, budget_window);

create table spend_windows (
  scope text not null,
  budget_window date not null,
  reserved_micros bigint not null default 0,
  attempts integer not null default 0,
  primary key (scope, budget_window)
);

create table provider_permits (
  provider text not null,
  slot integer not null,
  holder uuid,
  expires_at timestamptz,
  primary key (provider, slot)
);

create table provider_circuits (
  provider text primary key,
  consecutive_failures integer not null default 0,
  open_until timestamptz,
  reason text
);


-- Fixed-window rate limit counters ---------------------------------------------------

create table rate_limit_counters (
  key text not null,
  window_start timestamptz not null,
  count integer not null default 0,
  primary key (key, window_start)
);

-- Journal objects sort by this sequence, so recovery replays events in order
-- and detects events missing from the journal.
create sequence lifecycle_journal_sequence;
create unique index lifecycle_outbox_journal_sequence
  on lifecycle_outbox (journal_sequence) where journal_sequence is not null;
-- Provisional renewal coverage awaiting entitlement-authority confirmation (section 10).
create index processing_coverage_provisional on processing_coverage (account_id)
  where confirmation_state = 'provisional';

-- Job archive pruning by age.
create index jobs_archive_updated on jobs_archive (updated_at);
create index job_attempts_archive_job on job_attempts_archive (job_id);

-- Search migration: at most one shadow release per account; the change log
-- is read in order and pruned by age.
create unique index search_releases_one_shadow on search_releases (account_id) where state = 'shadow';
create index content_changes_created on content_changes (created_at);

-- Pages uploaded for later processing (automatic admission scans these).
create index pages_awaiting_processing on pages (account_id) where awaiting_processing;
