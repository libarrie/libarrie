//// Stable API error codes (section 11) and helpers for threading database
//// results through domain operations.

import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/result
import libarrie/database

pub type AppError {
  AppError(
    status: Int,
    code: String,
    message: String,
    details: List(#(String, Json)),
    retry_after: Option(Int),
  )
}

pub fn new(status: Int, code: String, message: String) -> AppError {
  AppError(status:, code:, message:, details: [], retry_after: None)
}

pub fn with_details(error: AppError, details: List(#(String, Json))) -> AppError {
  AppError(..error, details:)
}

pub fn not_found() -> AppError {
  new(404, "not_found", "The resource does not exist.")
}

pub fn bad_request(message: String) -> AppError {
  new(400, "invalid_request", message)
}

pub fn unprocessable(message: String) -> AppError {
  new(422, "invalid_request", message)
}

pub fn forbidden(message: String) -> AppError {
  new(403, "forbidden", message)
}

pub fn version_conflict() -> AppError {
  new(412, "version_conflict", "The resource changed; reload and retry.")
}

pub fn precondition_required() -> AppError {
  new(428, "precondition_required", "This request requires If-Match.")
}

pub fn account_closing() -> AppError {
  new(
    409,
    "account_closing",
    "The account is scheduled for closure; additions are disabled.",
  )
}

pub fn page_number_conflict(details: List(#(String, Json))) -> AppError {
  new(409, "page_number_conflict", "That page number is already in use.")
  |> with_details(details)
}

pub fn idempotency_conflict() -> AppError {
  new(
    409,
    "idempotency_conflict",
    "This operation ID or Idempotency-Key was already used with a different request.",
  )
}

pub fn cleanup_pending() -> AppError {
  AppError(
    ..new(
      503,
      "cleanup_pending",
      "Expired uploads are being cleaned up; retry shortly.",
    ),
    retry_after: Some(1),
  )
}

pub fn internal(detail: String) -> AppError {
  // The detail is for logs only and is never rendered to clients.
  AppError(
    status: 500,
    code: "internal_error",
    message: "An unexpected error occurred.",
    details: [#("log", json.string(detail))],
    retry_after: None,
  )
}

pub fn unavailable() -> AppError {
  AppError(
    ..new(503, "unavailable", "Temporarily unavailable; retry shortly."),
    retry_after: Some(2),
  )
}

/// Map a database error into an API error.
pub fn from_query(error: database.QueryError) -> AppError {
  case database.violated_constraint(error) {
    Some("pages_number_unique") -> page_number_conflict([])
    _ ->
      case database.is_transient(error) {
        True -> unavailable()
        False -> internal(database.describe(error))
      }
  }
}

/// `use rows <- db(database.query(...))`
pub fn db(
  result: Result(a, database.QueryError),
  next: fn(a) -> Result(b, AppError),
) -> Result(b, AppError) {
  result
  |> result.map_error(from_query)
  |> result.try(next)
}

/// Require a row to exist, otherwise 404.
pub fn found(
  result: Result(Option(a), database.QueryError),
  next: fn(a) -> Result(b, AppError),
) -> Result(b, AppError) {
  use value <- db(result)
  case value {
    Some(v) -> next(v)
    None -> Error(not_found())
  }
}

pub fn guard(
  condition: Bool,
  error: AppError,
  next: fn() -> Result(a, AppError),
) -> Result(a, AppError) {
  case condition {
    True -> next()
    False -> Error(error)
  }
}

pub fn to_json(error: AppError, request_id: String) -> Json {
  let details = case error.code {
    "internal_error" -> []
    _ -> error.details
  }
  json.object([
    #(
      "error",
      json.object([
        #("code", json.string(error.code)),
        #("message", json.string(error.message)),
        #("details", json.object(details)),
        #("request_id", json.string(request_id)),
      ]),
    ),
  ])
}
