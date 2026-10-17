//// Sandboxed decoding in the upload path and derived images. Runs when a
//// decoder sandbox is configured (the Linux test run); skipped otherwise.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import libarrie/api/router
import support.{call, str}
import wisp/simulate

pub fn derived_images_and_decode_rejection_test() {
  let app = support.app()
  case app.ctx.config.decoder {
    None -> Nil
    Some(_) -> {
      let token = support.user(app)
      let other = support.user(app)
      let account = support.account_id(app, token)
      let notebook = support.notebook(app, token, "Derived")
      let #(done, page_id) =
        support.upload_page(app, token, notebook, 1, Some("thumbnail me"), "immediate")
      let assert 200 = done.status
      support.drain(app)
      let page = call(app, http.Get, "/v1/pages/" <> page_id, token, None, [])
      let thumb_url = str(page, ["page", "thumbnail_url"])
      let assert True = string.starts_with(thumb_url, "/img/") && string.ends_with(thumb_url, "/thumb")
      let reply =
        simulate.request(http.Get, thumb_url)
        |> simulate.header("authorization", "Bearer " <> token)
        |> app_send(app)
      let assert 200 = reply.status
      let assert Ok("image/jpeg") = list.key_find(reply.headers, "content-type")
      let assert Ok("private, max-age=86400") = list.key_find(reply.headers, "cache-control")
      let assert <<0xFF, 0xD8, _:bits>> = reply.body
      // Another account cannot read it, and the route requires sign-in.
      let assert 404 =
        app_send(simulate.request(http.Get, thumb_url) |> simulate.header("authorization", "Bearer " <> other), app).status
      let assert 401 = app_send(simulate.request(http.Get, thumb_url), app).status
      // A file whose headers pass but whose pixel data is corrupt is refused
      // by the sandboxed decoder.
      let good = support.png(Some("corrupt me"))
      let size = bit_array.byte_size(good)
      let assert Ok(head) = bit_array.slice(good, 0, size - 2000)
      let assert Ok(tail) = bit_array.slice(good, size - 1000, 1000)
      let corrupt = bit_array.concat([head, <<0:size(8000)>>, tail])
      let created =
        support.create_upload(
          app,
          token,
          support.uuid(),
          [#("notebook_id", json.string(notebook)), #("page_number", json.int(2))],
          corrupt,
          "immediate",
          [],
        )
      let session = str(created, ["upload_session_id"])
      support.put_staging(app, account, session, corrupt)
      let rejected = support.complete(app, token, session)
      let assert 422 = rejected.status
      let assert True = string.starts_with(str(rejected, ["error", "details", "reason"]), "decode:")
      let usage = call(app, http.Get, "/v1/usage", token, None, [])
      let assert 1 = support.get(usage, ["stored_pages"], decode.int)
      Nil
    }
  }
}

pub type Raw {
  Raw(status: Int, headers: List(#(String, String)), body: BitArray)
}

fn app_send(req, app: router.App) -> Raw {
  let resp = router.handle(app, req)
  Raw(resp.status, resp.headers, simulate.read_body_bits(resp))
}
