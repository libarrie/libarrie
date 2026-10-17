//// INTERNAL_PORT: `/internal` is served only on its own listener, so the
//// public port (and an Ingress in front of it) never reaches it.

import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/option.{None}
import libarrie/api/router
import libarrie/mcp
import libarrie_api
import mist
import support

const secret_key_base = "test-secret-key-base-0123456789abcdef-0123456789abcdef"

fn listen(handler) -> String {
  let started = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(_) =
      handler
      |> mist.new
      |> mist.bind("127.0.0.1")
      |> mist.port(0)
      |> mist.after_start(fn(port, _, _) { process.send(started, port) })
      |> mist.start
    process.sleep_forever()
  })
  let assert Ok(port) = process.receive(started, 5000)
  "http://127.0.0.1:" <> int.to_string(port)
}

fn status(base: String, path: String) -> Int {
  let assert Ok(req) = request.to(base <> path)
  let req =
    req
    |> request.set_method(http.Get)
    |> request.set_header("authorization", "Bearer " <> support.internal_token)
  let assert Ok(resp) = httpc.send(req)
  resp.status
}

fn mcp_config(app: router.App) -> mcp.Config {
  mcp.Config(
    ctx: app.ctx,
    resource: "https://notes.example/mcp",
    oauth: None,
    allowed_origins: [],
    secret_key_base:,
  )
}

pub fn internal_api_moves_to_its_own_port_test() {
  let app = support.app()
  let account = support.account_id(app, support.user(app))
  let path = "/internal/v1/accounts/" <> account <> "/entitlement-status"
  // Without INTERNAL_PORT the public listener serves it, as before.
  let shared =
    listen(libarrie_api.http_handler(app, mcp_config(app), secret_key_base, internal_elsewhere: False))
  let assert 200 = status(shared, path)
  // With it, the public listener doesn't, and the internal one does.
  let public =
    listen(libarrie_api.http_handler(app, mcp_config(app), secret_key_base, internal_elsewhere: True))
  let internal = listen(libarrie_api.internal_handler(app, secret_key_base))
  let assert 404 = status(public, path)
  let assert 404 = status(public, "/internal")
  let assert 200 = status(internal, path)
  let assert 200 = status(public, "/healthz")
  let assert 200 = status(internal, "/healthz")
  // The internal listener serves nothing else.
  let assert 404 = status(internal, "/v1/me")
  let assert 404 = status(internal, "/notebooks")
  let assert 404 = status(internal, "/mcp")
}
