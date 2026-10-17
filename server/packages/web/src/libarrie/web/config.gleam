//// Web UI configuration.

import gleam/option.{type Option}
import libarrie/domain/context.{type Context}
import libarrie/integrations/identity
import lustre/element.{type Element}
import wisp

pub type Oidc {
  Oidc(
    issuer: String,
    client_id: String,
    client_secret: Option(String),
    authorization_endpoint: String,
    token_endpoint: String,
    /// `WEB_ORIGIN <> "/auth/callback"`.
    redirect_uri: String,
  )
}

/// The native apps' public OIDC client (PKCE, custom-scheme redirect).
pub type NativeClient {
  NativeClient(client_id: String, redirect_uri: String)
}

pub type Web {
  Web(
    ctx: Context,
    /// Exact origin, for example `https://app.libarrie.example`.
    origin: String,
    oidc: Oidc,
    /// Audience the API requires of bearer access tokens.
    audience: String,
    native: Option(NativeClient),
    verifier: identity.Verifier,
    /// Enables the built-in development issuer (never in hosted mode).
    dev_issuer_secret: Option(String),
    /// Signs the short-lived OIDC state cookie; stable across replicas.
    secret_key_base: String,
    static_dir: String,
    /// Object-store origins allowed by the Content Security Policy.
    upload_origin: String,
    download_origin: String,
    /// Additions compiled into a particular deployment; none by default.
    extensions: List(Extension),
    hosted: Bool,
  )
}

/// An addition a deployment compiles into its own build of the web UI (for
/// example account pages backed by an external entitlement authority). The
/// default build has none. Extensions only see the signed-in account and
/// core's rendering helpers.
pub type Extension {
  Extension(
    /// Origins, besides this one, that forms may submit or redirect to.
    form_action_origins: List(String),
    /// Sections appended to the Usage page.
    usage_sections: fn(Viewer) -> List(Element(Nil)),
    /// Signed-in routes. Return `None` for paths the extension does not own.
    route: fn(Viewer, wisp.Request, List(String)) -> Option(wisp.Response),
    /// The notice for a `?done=` code the extension's redirects use.
    notice: fn(String) -> Option(#(String, String)),
  )
}

/// The signed-in account and core's page helpers, as seen by an extension.
pub type Viewer {
  Viewer(
    account_id: String,
    csrf_token: String,
    /// A page in the application shell (a fragment for htmx requests).
    page: fn(String, List(Element(Nil)), Int) -> wisp.Response,
    /// An htmx fragment.
    fragment: fn(List(Element(Nil))) -> wisp.Response,
    redirect: fn(String) -> wisp.Response,
    /// Parse a form body after core's CSRF and same-origin checks.
    form: fn(fn(List(#(String, String))) -> wisp.Response) -> wisp.Response,
  )
}
