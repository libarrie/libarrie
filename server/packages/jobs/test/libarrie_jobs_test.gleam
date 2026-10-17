import gleam/list
import gleam/option.{None}
import gleeunit
import libarrie/jobs

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn backoff_is_bounded_and_jittered_test() {
  let settings = jobs.default_settings()
  list.each([0, 1, 2, 5, 10, 40], fn(attempts) {
    let delay = jobs.backoff_seconds(attempts, settings)
    let assert True = delay >= 1 && delay <= settings.backoff_cap_seconds
  })
  let assert True = jobs.backoff_seconds(40, settings) >= settings.backoff_cap_seconds / 2
}

pub fn exhausted_counts_claims_test() {
  let job =
    jobs.Job(
      id: "j",
      account_id: None,
      operation_id: None,
      page_id: None,
      revision_id: None,
      transcript_revision_id: None,
      configuration_id: None,
      stage: "recognize",
      payload: "{}",
      attempts: 5,
      max_attempts: 5,
      attempt_token: "t",
      replay_generation: 0,
    )
  let assert False = jobs.exhausted(job)
  let assert True = jobs.exhausted(jobs.Job(..job, attempts: 6))
}

