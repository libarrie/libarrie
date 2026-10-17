//// `Idempotency-Key` handling for mutations whose retries could duplicate
//// work (section 11). The record is written in the same transaction as the
//// mutation, so a replay with the same body returns the stored response and
//// a different body returns 409. Expiring these caches never expires the
//// logical deduplication of upload operations, which use durable operation
//// records instead.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import libarrie/database.{type Connection}
import libarrie/domain/error.{type AppError, db}

pub type Response {
  Response(status: Int, body: String)
}

pub fn run(
  conn: Connection,
  account_id: String,
  endpoint: String,
  key: Option(String),
  request_hash: String,
  body: fn() -> Result(#(Int, json.Json), AppError),
) -> Result(Response, AppError) {
  case key {
    None -> body() |> result.map(fn(r) { Response(r.0, json.to_string(r.1)) })
    Some(key) -> {
      let params = [
        database.text(account_id),
        database.text(endpoint),
        database.text(key),
      ]
      use _ <- db(database.execute(
        conn,
        "insert into idempotency_records (account_id, endpoint, key, request_hash, expires_at)
         values ($1::uuid, $2, $3, $4, now() + interval '24 hours')
         on conflict do nothing",
        [database.text(account_id), database.text(endpoint), database.text(key),
          database.text(request_hash)],
      ))
      use record <- error.found(database.query_one(
        conn,
        "select request_hash, response_status, response_body
         from idempotency_records
         where account_id = $1::uuid and endpoint = $2 and key = $3 for update",
        params,
        {
          use hash <- decode.field(0, decode.string)
          use status <- decode.field(1, decode.optional(decode.int))
          use stored <- decode.field(2, decode.optional(decode.string))
          decode.success(#(hash, status, stored))
        },
      ))
      case record {
        #(hash, _, _) if hash != request_hash -> Error(error.idempotency_conflict())
        #(_, Some(status), Some(stored)) -> Ok(Response(status, stored))
        _ -> {
          use #(status, response) <- result.try(body())
          let text = json.to_string(response)
          use _ <- db(database.execute(
            conn,
            "update idempotency_records set response_status = $4, response_body = $5
             where account_id = $1::uuid and endpoint = $2 and key = $3",
            [
              database.text(account_id),
              database.text(endpoint),
              database.text(key),
              database.int(status),
              database.text(text),
            ],
          ))
          Ok(Response(status, text))
        }
      }
    }
  }
}
