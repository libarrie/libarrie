//// Forward-only SQL migration runner (section 15).
////
//// Run as a single deployment job, never concurrently from every replica. An
//// advisory lock still serializes accidental concurrent runs. Each file is
//// applied in its own transaction and recorded in `schema_migrations`.

import gleam/dynamic/decode
import gleam/list
import gleam/result
import gleam/string
import libarrie/database.{type Connection}
import simplifile

pub type MigrationError {
  ReadFailed(path: String)
  StatementFailed(file: String, detail: String)
}

const lock_key = "7238461923"

pub fn run(conn: Connection, directory: String) -> Result(List(String), MigrationError) {
  use files <- result.try(
    simplifile.read_directory(directory)
    |> result.replace_error(ReadFailed(directory)),
  )
  let files =
    files
    |> list.filter(string.ends_with(_, ".sql"))
    |> list.sort(string.compare)

  let setup =
    database.execute(
      conn,
      "create table if not exists schema_migrations (
         version text primary key,
         applied_at timestamptz not null default now())",
      [],
    )
  use _ <- result.try(
    setup
    |> result.map_error(fn(e) {
      StatementFailed("schema_migrations", database.describe(e))
    }),
  )

  list.try_fold(files, [], fn(applied, file) {
    use sql <- result.try(
      simplifile.read(directory <> "/" <> file)
      |> result.replace_error(ReadFailed(file)),
    )
    let outcome =
      database.transaction(conn, fn(tx) {
        use _ <- result.try(
          database.execute(
            tx,
            "select 1 from pg_advisory_xact_lock(" <> lock_key <> ")",
            [],
          )
          |> result.map_error(database.describe),
        )
        use existing <- result.try(
          database.query(
            tx,
            "select version from schema_migrations where version = $1",
            [database.text(file)],
            decode.at([0], decode.string),
          )
          |> result.map_error(database.describe),
        )
        case existing {
          [_] -> Ok(False)
          _ -> {
            use _ <- result.try(
              split_statements(sql)
              |> list.try_each(fn(statement) {
                database.execute(tx, statement, [])
                |> result.map_error(database.describe)
              }),
            )
            use _ <- result.try(
              database.execute(
                tx,
                "insert into schema_migrations (version) values ($1)",
                [database.text(file)],
              )
              |> result.map_error(database.describe),
            )
            Ok(True)
          }
        }
      })
    case outcome {
      Ok(True) -> Ok([file, ..applied])
      Ok(False) -> Ok(applied)
      Error(database.Aborted(detail)) -> Error(StatementFailed(file, detail))
      Error(database.QueryFailed(e)) ->
        Error(StatementFailed(file, database.describe(e)))
    }
  })
  |> result.map(list.reverse)
}

type ScanState {
  Normal
  SingleQuoted
  DoubleQuoted
  DollarQuoted(tag: String)
  LineComment
  BlockComment
}

/// Split a SQL script into statements on top-level semicolons, respecting
/// quoted strings, identifiers, dollar-quoted bodies and comments. The
/// extended query protocol used by `pog` accepts one statement at a time.
pub fn split_statements(sql: String) -> List(String) {
  scan(string.to_graphemes(sql), Normal, "", [])
  |> list.map(string.trim)
  |> list.filter(fn(statement) { statement != "" && !only_comments(statement) })
}

fn only_comments(statement: String) -> Bool {
  statement
  |> string.split("\n")
  |> list.all(fn(line) {
    let line = string.trim(line)
    line == "" || string.starts_with(line, "--")
  })
}

fn scan(
  chars: List(String),
  state: ScanState,
  current: String,
  done: List(String),
) -> List(String) {
  case state, chars {
    _, [] -> list.reverse([current, ..done])
    Normal, [";", ..rest] -> scan(rest, Normal, "", [current, ..done])
    Normal, ["'", ..rest] -> scan(rest, SingleQuoted, current <> "'", done)
    Normal, ["\"", ..rest] -> scan(rest, DoubleQuoted, current <> "\"", done)
    Normal, ["-", "-", ..rest] -> scan(rest, LineComment, current, done)
    Normal, ["/", "*", ..rest] -> scan(rest, BlockComment, current, done)
    Normal, ["$", ..rest] ->
      case dollar_tag(rest, "") {
        Ok(#(tag, after)) ->
          scan(after, DollarQuoted(tag), current <> "$" <> tag <> "$", done)
        Error(Nil) -> scan(rest, Normal, current <> "$", done)
      }
    Normal, [c, ..rest] -> scan(rest, Normal, current <> c, done)
    SingleQuoted, ["'", ..rest] -> scan(rest, Normal, current <> "'", done)
    SingleQuoted, [c, ..rest] -> scan(rest, SingleQuoted, current <> c, done)
    DoubleQuoted, ["\"", ..rest] -> scan(rest, Normal, current <> "\"", done)
    DoubleQuoted, [c, ..rest] -> scan(rest, DoubleQuoted, current <> c, done)
    LineComment, ["\n", ..rest] -> scan(rest, Normal, current <> "\n", done)
    LineComment, [_, ..rest] -> scan(rest, LineComment, current, done)
    BlockComment, ["*", "/", ..rest] -> scan(rest, Normal, current <> " ", done)
    BlockComment, [_, ..rest] -> scan(rest, BlockComment, current, done)
    DollarQuoted(tag), ["$", ..rest] ->
      case closes_dollar(rest, tag) {
        Ok(after) -> scan(after, Normal, current <> "$" <> tag <> "$", done)
        Error(Nil) -> scan(rest, state, current <> "$", done)
      }
    DollarQuoted(_), [c, ..rest] -> scan(rest, state, current <> c, done)
  }
}

fn dollar_tag(
  chars: List(String),
  tag: String,
) -> Result(#(String, List(String)), Nil) {
  case chars {
    ["$", ..rest] -> Ok(#(tag, rest))
    [c, ..rest] ->
      case is_tag_char(c) {
        True -> dollar_tag(rest, tag <> c)
        False -> Error(Nil)
      }
    [] -> Error(Nil)
  }
}

fn is_tag_char(c: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789", c)
}

fn closes_dollar(chars: List(String), tag: String) -> Result(List(String), Nil) {
  let tag_chars = string.to_graphemes(tag)
  let n = list.length(tag_chars)
  case list.take(chars, n + 1) == list.append(tag_chars, ["$"]) {
    True -> Ok(list.drop(chars, n + 1))
    False -> Error(Nil)
  }
}
