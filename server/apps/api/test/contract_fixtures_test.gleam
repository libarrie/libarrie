//// Conformance fixtures for clients (contracts/fixtures/api). The server
//// is the source of truth: with LIBARRIE_WRITE_FIXTURES=1 this test
//// rewrites the fixtures from real responses; otherwise it checks that every
//// response still has the recorded shape (keys and value types; a null on
//// either side matches anything), so client-facing drift fails CI.

import envoy
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import libarrie/api/router
import simplifile
import support
import wisp/simulate

const directory = "../../../contracts/fixtures/api"

pub fn api_fixtures_test() {
  let app = support.app()
  let subject = "fixture-" <> support.random_id()
  let token = support.token_for(subject, 0)
  let account = support.account_id(app, token)
  let notebook = support.notebook(app, token, "Blue work notebook")
  let call = fn(method, path, body) { support.call(app, method, path, token, body, []) }

  record("client_configuration", raw(app, http.Get, "/v1/client-configuration"))
  record("me", call(http.Get, "/v1/me", None))
  record("settings", call(http.Get, "/v1/settings", None))
  record("notebook", call(http.Get, "/v1/notebooks/" <> notebook, None))
  record("notebook_list", call(http.Get, "/v1/notebooks", None))

  // A new-page upload: reservation, completion and processing.
  let bytes = support.png(Some("Met Grace Hopper about the compiler budget"))
  let operation = support.uuid()
  let created =
    support.create_upload(
      app,
      token,
      operation,
      [#("notebook_id", json.string(notebook)), #("page_number", json.int(1))],
      bytes,
      "immediate",
      [],
    )
  record("upload_session_created", created)
  let session = support.str(created, ["upload_session_id"])
  support.put_staging(app, account, session, bytes)
  record("upload_completed", support.complete(app, token, session))
  support.drain(app)
  let page = support.get(created, ["operation", "page_id"], decode.string)
  record("operation", call(http.Get, "/v1/operations/" <> operation, None))
  record("page_detail", call(http.Get, "/v1/pages/" <> page, None))
  record("page_list", call(http.Get, "/v1/notebooks/" <> notebook <> "/pages", None))
  record(
    "search",
    call(http.Post, "/v1/search", Some(json.object([#("query", json.string("Hopper"))]))),
  )
  record("usage", call(http.Get, "/v1/usage", None))
  let #(_, _) = support.upload_page(app, token, notebook, 2, Some("Process me later"), "deferred")
  record("pages_awaiting_processing", call(http.Get, "/v1/pages/awaiting-processing", None))

  // Errors clients branch on.
  record(
    "error_page_number_conflict",
    support.create_upload(
      app,
      token,
      support.uuid(),
      [#("notebook_id", json.string(notebook)), #("page_number", json.int(1))],
      support.png(Some("another")),
      "immediate",
      [],
    ),
  )
  record(
    "error_version_conflict",
    support.call(
      app,
      http.Patch,
      "/v1/pages/" <> page,
      token,
      Some(json.object([#("page_number", json.int(9))])),
      [#("if-match", "\"v999\"")],
    ),
  )

  // Exports.
  let started = call(http.Post, "/v1/exports", Some(json.object([])))
  record("export_created", started)
  support.drain(app)
  let export_id = support.str(started, ["export", "id"])
  record("export_list", call(http.Get, "/v1/exports", None))
  record("export_detail", call(http.Get, "/v1/exports/" <> export_id, None))

  // Trash and account lifecycle status.
  let current = call(http.Get, "/v1/pages/" <> page, None)
  let version = support.get(current, ["page", "version"], decode.int)
  record(
    "page_trashed",
    support.call(app, http.Delete, "/v1/pages/" <> page, token, None, [
      #("if-match", "\"v" <> string.inspect(version) <> "\""),
    ]),
  )
  record("trash", call(http.Get, "/v1/trash", None))
  record("account_deletion_status", call(http.Get, "/v1/account-deletion", None))
}

fn raw(app: router.App, method: http.Method, path: String) -> support.Reply {
  simulate.request(method, path) |> support.send(app, _)
}

fn record(name: String, reply: support.Reply) -> Nil {
  let path = directory <> "/" <> name <> ".json"
  let assert Ok(current) = json.parse(reply.body, decode.dynamic)
  case envoy.get("LIBARRIE_WRITE_FIXTURES") {
    Ok("1") -> {
      let assert Ok(_) = simplifile.create_directory_all(directory)
      let document =
        json.object([
          #("status", json.int(reply.status)),
          #("body", json.string(reply.body)),
        ])
      let assert Ok(_) = simplifile.write(path, json.to_string(document) <> "\n")
      Nil
    }
    _ -> {
      let assert Ok(text) = simplifile.read(path)
      let assert Ok(#(status, body)) =
        json.parse(text, {
          use status <- decode.field("status", decode.int)
          use body <- decode.field("body", decode.string)
          decode.success(#(status, body))
        })
      let assert Ok(recorded) = json.parse(body, decode.dynamic)
      case status == reply.status, same_shape(recorded, current, name) {
        True, Ok(Nil) -> Nil
        False, _ ->
          panic as {
            name <> ": status " <> string.inspect(reply.status) <> ", fixture has "
            <> string.inspect(status) <> "; rerun with LIBARRIE_WRITE_FIXTURES=1 if intended"
          }
        _, Error(at) ->
          panic as {
            name <> ": response shape changed at " <> at
            <> "; rerun with LIBARRIE_WRITE_FIXTURES=1 if intended"
          }
      }
    }
  }
}

type Shape {
  Object(dict.Dict(String, dynamic.Dynamic))
  Array(List(dynamic.Dynamic))
  Scalar(String)
  Null
}

fn shape(value: dynamic.Dynamic) -> Shape {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(d) -> Object(d)
    Error(_) ->
      case decode.run(value, decode.list(decode.dynamic)) {
        Ok(items) -> Array(items)
        Error(_) ->
          case dynamic.classify(value) {
            "Nil" | "Atom" ->
              case decode.run(value, decode.bool) {
                Ok(_) -> Scalar("Bool")
                Error(_) -> Null
              }
            other -> Scalar(other)
          }
      }
  }
}

fn same_shape(a: dynamic.Dynamic, b: dynamic.Dynamic, at: String) -> Result(Nil, String) {
  case shape(a), shape(b) {
    Null, _ | _, Null -> Ok(Nil)
    Scalar(x), Scalar(y) if x == y -> Ok(Nil)
    // JSON numbers like 0 and 1.5 can classify differently across runs.
    Scalar("Int"), Scalar("Float") | Scalar("Float"), Scalar("Int") -> Ok(Nil)
    Array(xs), Array(ys) ->
      case xs, ys {
        [x, ..], [y, ..] -> same_shape(x, y, at <> "[0]")
        _, _ -> Ok(Nil)
      }
    Object(x), Object(y) -> {
      let keys = fn(d) { dict.keys(d) |> list.sort(string.compare) }
      case keys(x) == keys(y) {
        False ->
          Error(at <> " (keys " <> string.join(keys(x), ",") <> " vs " <> string.join(keys(y), ",") <> ")")
        True ->
          list.try_each(keys(x), fn(k) {
            let assert Ok(xv) = dict.get(x, k)
            let assert Ok(yv) = dict.get(y, k)
            same_shape(xv, yv, at <> "." <> k)
          })
      }
    }
    _, _ -> Error(at)
  }
}
