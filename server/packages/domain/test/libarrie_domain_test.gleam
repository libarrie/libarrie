import gleam/time/calendar as renewal_calendar
import gleam/time/timestamp as renewal_timestamp
import libarrie/domain/renewal
import gleam/list
import gleam/string
import gleeunit
import libarrie/domain/entitlements
import libarrie/domain/exports
import libarrie/domain/search
import libarrie/domain/settings
import libarrie/domain/text

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn normalize_keeps_identifiers_searchable_test() {
  let assert "inv 2024 07 call ada" = text.normalize("INV-2024-07: Call  Ada!")
  let assert "café 東京" = text.normalize("Café, 東京.")
}

pub fn chunk_short_page_is_one_passage_test() {
  let assert [chunk] = text.chunk("First paragraph.\n\nSecond paragraph.")
  let assert 0 = chunk.start_offset
  let assert True = string.contains(chunk.text, "Second paragraph.")
  let assert [] = text.chunk("   \n\n  ")
}

pub fn chunk_long_text_bounds_passages_test() {
  let paragraph = string.repeat("word ", 200)
  let source = string.join(list.repeat(paragraph, 5), "\n\n")
  let chunks = text.chunk(source)
  let assert True = list.length(chunks) >= 3
  list.each(chunks, fn(c) {
    let words = c.text |> string.split(" ") |> list.filter(fn(w) { w != "" })
    let assert True = list.length(words) <= 320
    let assert True = c.end_offset > c.start_offset
  })
  // Offsets point back into the original text.
  let assert [first, ..] = chunks
  let assert True =
    string.slice(source, first.start_offset, 4) == string.slice(first.text, 0, 4)
}

pub fn fusion_returns_one_result_per_page_test() {
  let lexical = [
    search.Candidate("p1a", "page1", "alpha", "lexical"),
    search.Candidate("p2a", "page2", "beta", "lexical"),
  ]
  let semantic = [
    search.Candidate("p1b", "page1", "alpha too", "semantic"),
    search.Candidate("p2a", "page2", "beta", "semantic"),
  ]
  let fused = search.fuse(lexical, semantic)
  let assert 2 = list.length(fused)
  // page2's single passage appears in both lists and wins the fused rank.
  let assert [top, ..] = fused
  let assert "page2" = top.page_id
  let assert True = list.contains(top.kinds, "semantic") && list.contains(top.kinds, "lexical")
}

fn payload(limits: String, features: String) -> String {
  "{\"command_id\":\"0b7a3c1e-8f0c-4c9a-9a51-6a1d1f0c9e11\",\"authority\":\"a\",\"revision\":1,"
  <> "\"effective_at\":\"2026-11-01T00:00:00Z\",\"limits\":" <> limits <> ","
  <> "\"processing_policy\":{\"kind\":\"lifetime\"},\"processing_coverage\":[],"
  <> "\"coverage_revocations\":[],\"renewal_policy\":{\"kind\":\"disabled\"},"
  <> "\"features\":" <> features <> ",\"scheduled_change\":null}"
}

const good_limits = "{\"stored_pages\":{\"kind\":\"limited\",\"value\":10},\"notebooks\":{\"kind\":\"unlimited\"},\"processing_pages_per_period\":{\"kind\":\"limited\",\"value\":3}}"

pub fn entitlement_payload_validation_test() {
  let assert Ok(_) = entitlements.parse(payload(good_limits, "{}"))
  let assert Error(_) =
    entitlements.parse(payload(
      "{\"stored_pages\":null,\"notebooks\":{\"kind\":\"unlimited\"},\"processing_pages_per_period\":{\"kind\":\"limited\",\"value\":3}}",
      "{}",
    ))
  let assert Error(_) =
    entitlements.parse(payload(
      "{\"notebooks\":{\"kind\":\"unlimited\"},\"processing_pages_per_period\":{\"kind\":\"limited\",\"value\":3}}",
      "{}",
    ))
  let assert Error(_) = entitlements.parse(payload(good_limits, "{\"search\":true}"))
  let assert Error(_) =
    entitlements.parse(payload(
      "{\"stored_pages\":{\"kind\":\"limited\",\"value\":-1},\"notebooks\":{\"kind\":\"unlimited\"},\"processing_pages_per_period\":{\"kind\":\"limited\",\"value\":3}}",
      "{}",
    ))
}

pub fn export_part_packing_never_splits_pages_test() {
  let assert [1, 1, 2, 3, 4] = exports.assign_parts([400, 500, 300, 2000, 10], 1000)
  let assert [1] = exports.assign_parts([5000], 1000)
  let assert [] = exports.assign_parts([], 1000)
}

pub fn export_execution_deadline_test() {
  let assert 90_000 = exports.execution_deadline_seconds(1)
  let assert 93_600 = exports.execution_deadline_seconds(5001)
  let assert 259_200 = exports.execution_deadline_seconds(30_000_000)
}

pub fn export_slugs_are_safe_test() {
  let assert "field-notes-2026" = exports.slug("Field Notes / 2026")
  let assert "notebook" = exports.slug("../..")
  let assert "caf-notes" = exports.slug("Café notes")
}

pub fn highlight_ranges_test() {
  let assert [#(5, 11), #(16, 21)] = text.highlights("Call Hopper and Grace.", "hopper GRACE")
  let assert [] = text.highlights("nothing here", "x")
}

// Renewal anniversaries ----------------------------------------------------------------

fn at(text: String) {
  let assert Ok(t) = renewal_timestamp.parse_rfc3339(text)
  t
}

fn show(t) {
  renewal_timestamp.to_rfc3339(t, renewal_calendar.utc_offset)
}

pub fn anniversaries_clamp_without_drifting_test() {
  let anchor = at("2027-01-31T09:30:00Z")
  let assert "2027-02-28T09:30:00Z" = show(renewal.anniversary(anchor, 1))
  let assert "2027-03-31T09:30:00Z" = show(renewal.anniversary(anchor, 2))
  let assert "2028-02-29T09:30:00Z" = show(renewal.anniversary(anchor, 13))
  let assert "2028-01-31T09:30:00Z" = show(renewal.anniversary(anchor, 12))
  let assert "2027-03-31T09:30:00Z" = show(renewal.next_anniversary(anchor, at("2027-02-28T09:30:00Z")))
  let assert "2027-02-28T09:30:00Z" = show(renewal.next_anniversary(anchor, at("2027-01-31T09:30:00Z")))
}

pub fn renewal_policies_parse_test() {
  let assert Ok(renewal.Disabled) = renewal.parse("{\"kind\":\"disabled\"}")
  let assert Ok(renewal.BoundedOutage(grace_days: 7, ..)) =
    renewal.parse("{\"kind\":\"bounded_outage\",\"policy_id\":\"6f1d2c3b-4a59-4e1f-8a2b-3c4d5e6f7a8b\",\"schedule_id\":\"7a2e3d4c-5b6a-4f20-9b3c-4d5e6f7a8b9c\",\"service_anchor\":\"2027-01-16T00:00:00Z\",\"nominal_budget\":100,\"authorized_through\":\"2027-02-16T00:00:00Z\"}")
  let assert Error(_) =
    renewal.parse("{\"kind\":\"bounded_outage\",\"policy_id\":\"x\",\"schedule_id\":\"y\",\"service_anchor\":\"2027-01-16T00:00:00Z\",\"nominal_budget\":1,\"authorized_through\":\"2027-02-16T00:00:00Z\"}")
}

pub fn development_sign_in_stays_off_public_origins_test() {
  let allowed = [
    "http://localhost:8080", "http://127.0.0.1:8080", "http://192.168.1.20:8080",
    "http://10.0.0.5", "http://172.20.1.1:8080", "http://169.254.3.4",
    "http://[::1]:8080", "http://[fd12::1]:8080",
  ]
  let refused = [
    "https://notes.example.com", "http://notes.example.com",
    "https://localhost:8080", "http://203.0.113.9:8080", "http://172.32.0.1",
    "http://[2001:db8::1]", "not a url",
  ]
  let assert True = list.all(allowed, settings.private_origin)
  let assert False = list.any(refused, settings.private_origin)
}
