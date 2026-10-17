//// Cookie naming and attributes for the web origin.
////
//// On an `https://` origin every cookie is `Secure`, and the session and
//// sign-in cookies use the `__Host-` prefix (host-only, path `/`, never set
//// by a subdomain). Browsers accept those only over HTTPS: Chrome and
//// Firefox also allow `http://localhost`, but Safari and other WebKit
//// browsers do not. On a plain-HTTP origin, which only local development
//// uses (hosted mode requires HTTPS), cookies are therefore set without
//// `Secure` and without the prefix.

import gleam/http/request
import gleam/list
import gleam/option.{type Option}
import gleam/string
import wisp

pub fn secure(origin: String) -> Bool {
  string.starts_with(origin, "https://")
}

/// The cookie's name: `__Host-<base>` on HTTPS, `<base>` otherwise.
pub fn name(origin: String, base: String) -> String {
  case secure(origin) {
    True -> "__Host-" <> base
    False -> base
  }
}

/// `Path=/`, plus `Secure` on HTTPS.
pub fn scope(origin: String) -> String {
  case secure(origin) {
    True -> "; Path=/; Secure"
    False -> "; Path=/"
  }
}

/// Read a cookie under the name this origin uses (never the other one, so
/// an HTTPS deployment only trusts the `__Host-` form).
pub fn read(req: wisp.Request, origin: String, base: String) -> Option(String) {
  request.get_cookies(req) |> list.key_find(name(origin, base)) |> option.from_result
}
