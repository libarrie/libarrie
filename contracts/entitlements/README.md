# Entitlement contract

`PUT /internal/v1/accounts/{id}/entitlements` accepts the full desired-state
projection in `assignment.example.json`, sent by the account's entitlement
authority: an administrator's tooling or an external service (DESIGN.md
section 12).

- Every limit is tagged: `{"kind":"limited","value":n}` or `{"kind":"unlimited"}`.
  Missing or `null` limits are rejected with 422.
- `features` is additive only; naming a baseline right (viewing, search,
  export, correction, deletion) is rejected with 422.
- `processing_policy.kind` is `calendar_months_from_anchor`, `lifetime` or
  `unlimited`.
- Core applies only a newer `revision` per `authority`. An identical replay
  returns `applied: false`; a different payload at an applied revision returns
  409.
- Issued coverage records are immutable (interval, kind, parent and budget);
  non-empty base admission intervals may not overlap. Upgrade adjustments
  (`kind: "upgrade"`, `parent_coverage_id`) must lie inside their base.
- `coverage_revocations` entries are immutable by `revocation_id` and only
  shorten admission: `admission_end_at = max(starts_at, min(ends_at, effective_at))`.

## Renewal policy and provisional coverage

`renewal_policy` is either `{"kind":"disabled"}` or a bounded-outage policy:

```json
{
  "kind": "bounded_outage",
  "policy_id": "6f1d2c3b-4a59-4e1f-8a2b-3c4d5e6f7a8b",
  "schedule_id": "7a2e3d4c-5b6a-4f20-9b3c-4d5e6f7a8b9c",
  "service_anchor": "2027-01-16T00:00:00Z",
  "nominal_budget": 100,
  "authorized_through": "2027-02-16T00:00:00Z",
  "max_grace_days": 7
}
```

**Validation.** Anything else is rejected with 422:
- `max_grace_days` is between 1 and 7 (default 7).
- The IDs are UUIDs.
- `nominal_budget` is not negative.

**When core provisions.** If the authority hasn't delivered the next service month
by `authorized_through`, core provisions it itself, on the first processing
admission inside the window from `authorized_through` to
`authorized_through + max_grace_days`. It never does so for an account that
isn't `active` (a closure intent blocks it), or once the authority sends
`{"kind":"disabled"}`.

**The provisional record:**
- **Interval:** from `authorized_through` to the next monthly anniversary of
  `service_anchor`. The anchor's day is clamped to the month's last day, at
  the anchor's UTC time, so later months don't drift.
- **Budget:** `nominal_budget`, with `confirmation_state: "provisional"`.
- **Admission:** ends at the grace end; work already admitted stays valid.
- **ID:** deterministic, so the authority confirms or rejects the same record and
  can never add a second budget for the interval. It is UUIDv5 under namespace
  `4c1b0a6e-2f5d-5a3e-9c7b-8d1e6f0a2b34`, with the name
  `provisional-renewal:<authority>:<policy_id>:<schedule_id>:<starts_at>`,
  where `<starts_at>` is RFC 3339 UTC. The authority can also read the ID from
  `entitlement-status`.

**When the authority recovers:**
- **Confirm:** include the record with the same `coverage_id`, interval and
  `authorized_units`, and `"confirmation_state": "confirmed"`. Admission
  reopens to the end of the service month. A different interval or budget
  returns 409 `coverage_conflict`.
- **Reject:** send a `coverage_revocations` entry with reason
  `provisional_rejected`. Units consumed or pinned on the record stay honored.
- **Never** issue a separate confirmed record for an interval that was
  provisioned: overlapping base admission returns 409.

**Status.** `GET /internal/v1/accounts/{id}/entitlement-status` reports:
- `provisional_coverage`: each record core issued, with `state` of
  `provisional`, `confirmed` or `rejected`, plus its units.
- `outage_exposure_units`: units used or reserved on records the authority
  hasn't confirmed.

## Credit grants

`POST /internal/v1/accounts/{id}/credit-grants` with `"action": "revoke"` is
idempotent.
- Unreserved units become revoked at once.
- Units reserved by already admitted work stay usable by that work. If that
  work later releases them (cancellation, user-fault failure, expired
  recovery hold), they become revoked, never spendable again.
- Units that work consumes stay consumed; compensation is the authority's decision.
