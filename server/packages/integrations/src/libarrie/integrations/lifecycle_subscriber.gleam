//// Optional delivery of account lifecycle commands to an external
//// subscriber (an entitlement authority that must react to account
//// closure). Core sends the full desired lifecycle state; the subscriber
//// applies only newer revisions and acknowledges replays.

import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/string

pub type Client {
  /// `base_url` is the subscriber's prefix: commands go to
  /// `{base_url}/accounts/{id}/lifecycle`.
  Client(base_url: String, token: String)
}

pub type Delivery {
  Acknowledged(body: String)
  /// Retry later (network failure, 5xx, 429).
  Retryable(detail: String)
  /// The request was rejected and needs operator attention.
  Rejected(status: Int, body: String)
}

pub fn deliver(client: Client, account_id: String, body: String) -> Delivery {
  let base = case string.ends_with(client.base_url, "/") {
    True -> string.drop_end(client.base_url, 1)
    False -> client.base_url
  }
  case request.to(base <> "/accounts/" <> account_id <> "/lifecycle") {
    Error(_) -> Rejected(0, "invalid LIFECYCLE_SUBSCRIBER_URL")
    Ok(req) -> {
      let req =
        req
        |> request.set_method(http.Put)
        |> request.set_header("authorization", "Bearer " <> client.token)
        |> request.set_header("content-type", "application/json")
        |> request.set_body(body)
      case httpc.configure() |> httpc.timeout(15_000) |> httpc.dispatch(req) {
        Error(e) -> Retryable(string.inspect(e))
        Ok(resp) ->
          case resp.status {
            s if s >= 200 && s < 300 -> Acknowledged(string.slice(resp.body, 0, 2000))
            429 -> Retryable("429")
            s if s >= 500 -> Retryable(string.inspect(s))
            s -> Rejected(s, string.slice(resp.body, 0, 500))
          }
      }
    }
  }
}
