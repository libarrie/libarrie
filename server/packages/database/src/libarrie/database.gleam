//// Thin, typed helpers over `pog` shared by the API, worker and domain code.
////
//// Conventions used by every query in Libarrie core:
////
//// - UUID parameters are bound as text and cast in SQL (`$1::uuid`), and UUID
////   columns are selected as `id::text`, so the application never depends on
////   the binary UUID wire format.
//// - Timestamps are rendered by the `rfc3339(timestamptz)` SQL function and
////   compared using database time (`now()`), never application clocks.

import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pog

pub type Connection =
  pog.Connection

pub type QueryError =
  pog.QueryError

/// Start a connection pool. The pool connects asynchronously; queries fail
/// with `ConnectionUnavailable` until it is ready.
pub fn connect(url: String, pool_size: Int) -> Result(Connection, String) {
  let name = process.new_name("libarrie_db")
  use config <- result.try(
    pog.url_config(name, url)
    |> result.replace_error("invalid DATABASE_URL"),
  )
  config
  |> pog.pool_size(pool_size)
  |> pog.start
  |> result.map(fn(started) { started.data })
  |> result.map_error(fn(_) { "could not start database pool" })
}

/// Run a query and decode every returned row.
pub fn query(
  conn: Connection,
  sql: String,
  params: List(pog.Value),
  decoder: Decoder(a),
) -> Result(List(a), QueryError) {
  params
  |> list.fold(pog.query(sql), pog.parameter)
  |> pog.returning(decoder)
  |> pog.execute(conn)
  |> result.map(fn(returned) { returned.rows })
}

/// Run a query that returns at most one row.
pub fn query_one(
  conn: Connection,
  sql: String,
  params: List(pog.Value),
  decoder: Decoder(a),
) -> Result(Option(a), QueryError) {
  use rows <- result.map(query(conn, sql, params, decoder))
  case rows {
    [row, ..] -> Some(row)
    [] -> None
  }
}

/// Run a statement and return the number of affected rows.
pub fn execute(
  conn: Connection,
  sql: String,
  params: List(pog.Value),
) -> Result(Int, QueryError) {
  params
  |> list.fold(pog.query(sql), pog.parameter)
  |> pog.execute(conn)
  |> result.map(fn(returned) { returned.count })
}

pub type TransactionError(e) {
  QueryFailed(QueryError)
  Aborted(e)
}

/// Run `body` in a transaction. Returning `Error` rolls back.
pub fn transaction(
  conn: Connection,
  body: fn(Connection) -> Result(a, e),
) -> Result(a, TransactionError(e)) {
  pog.transaction(conn, body)
  |> result.map_error(fn(error) {
    case error {
      pog.TransactionQueryError(e) -> QueryFailed(e)
      pog.TransactionRolledBack(e) -> Aborted(e)
    }
  })
}

// Parameter constructors ---------------------------------------------------

pub fn text(value: String) -> pog.Value {
  pog.text(value)
}

pub fn int(value: Int) -> pog.Value {
  pog.int(value)
}

pub fn bool(value: Bool) -> pog.Value {
  pog.bool(value)
}

pub fn float(value: Float) -> pog.Value {
  pog.float(value)
}

pub fn null() -> pog.Value {
  pog.null()
}

pub fn bytea(value: BitArray) -> pog.Value {
  pog.bytea(value)
}

pub fn nullable_text(value: Option(String)) -> pog.Value {
  pog.nullable(pog.text, value)
}

pub fn nullable_int(value: Option(Int)) -> pog.Value {
  pog.nullable(pog.int, value)
}

pub fn text_array(values: List(String)) -> pog.Value {
  pog.array(pog.text, values)
}

pub fn int_array(values: List(Int)) -> pog.Value {
  pog.array(pog.int, values)
}

pub type Value =
  pog.Value

// Error classification -----------------------------------------------------

/// Serialization failures, deadlocks and lost connections are safe to retry
/// as a whole transaction.
pub fn is_transient(error: QueryError) -> Bool {
  case error {
    pog.PostgresqlError(code: "40001", ..)
    | pog.PostgresqlError(code: "40P01", ..)
    | pog.PostgresqlError(code: "55P03", ..) -> True
    pog.ConnectionUnavailable | pog.QueryTimeout -> True
    _ -> False
  }
}

/// The constraint name for a constraint or exclusion violation, if any.
pub fn violated_constraint(error: QueryError) -> Option(String) {
  case error {
    pog.ConstraintViolated(constraint:, ..) -> Some(constraint)
    pog.PostgresqlError(code: "23P01", message:, ..) ->
      case string.contains(message, "pages_number_unique") {
        True -> Some("pages_number_unique")
        False -> Some(message)
      }
    _ -> None
  }
}

/// A short, sanitized description suitable for logs. Never includes
/// parameter values.
pub fn describe(error: QueryError) -> String {
  case error {
    pog.ConstraintViolated(constraint:, ..) -> "constraint " <> constraint
    pog.PostgresqlError(code:, name:, message:) ->
      "postgres " <> code <> " " <> name <> ": " <> message
    pog.UnexpectedArgumentCount(expected:, got:) ->
      "argument count expected "
      <> string.inspect(expected)
      <> " got "
      <> string.inspect(got)
    pog.UnexpectedArgumentType(expected:, got:) ->
      "argument type expected " <> expected <> " got " <> got
    pog.UnexpectedResultType(errors) ->
      "result decode " <> string.inspect(errors)
    pog.QueryTimeout -> "query timeout"
    pog.ConnectionUnavailable -> "connection unavailable"
  }
}
