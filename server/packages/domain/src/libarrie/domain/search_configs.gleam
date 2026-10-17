//// Search configurations: an immutable embedding model, dimension,
//// chunking and normalization version. Every release, generation and
//// query uses exactly one, never a mix (section 9).

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import libarrie/database.{type Connection}
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError}
import libarrie/domain/text
import libarrie/integrations/providers

pub type Configuration {
  Configuration(
    id: String,
    provider: String,
    model: String,
    dimensions: Int,
    chunking_version: String,
    normalization_version: String,
  )
}

const columns = "c.id::text, c.embedding_provider, c.embedding_model, c.dimensions,
  c.chunking_version, c.normalization_version"

fn decoder() -> decode.Decoder(Configuration) {
  use id <- decode.field(0, decode.string)
  use provider <- decode.field(1, decode.string)
  use model <- decode.field(2, decode.string)
  use dimensions <- decode.field(3, decode.int)
  use chunking <- decode.field(4, decode.string)
  use normalization <- decode.field(5, decode.string)
  decode.success(Configuration(id, provider, model, dimensions, chunking, normalization))
}

pub fn get(conn: Connection, id: String) -> Result(Configuration, AppError) {
  use found <- error.found(database.query_one(
    conn,
    "select " <> columns <> " from search_configurations c where c.id = $1::uuid",
    [database.text(id)],
    decoder(),
  ))
  Ok(found)
}

/// The account's active release and its configuration.
pub fn active(conn: Connection, account_id: String) -> Result(#(String, Configuration), AppError) {
  use found <- error.found(database.query_one(
    conn,
    "select r.id::text, " <> columns <> " from accounts a
     join search_releases r on r.id = a.active_search_release_id
     join search_configurations c on c.id = r.configuration_id
     where a.id = $1::uuid",
    [database.text(account_id)],
    {
      use release <- decode.field(0, decode.string)
      use id <- decode.field(1, decode.string)
      use provider <- decode.field(2, decode.string)
      use model <- decode.field(3, decode.string)
      use dimensions <- decode.field(4, decode.int)
      use chunking <- decode.field(5, decode.string)
      use normalization <- decode.field(6, decode.string)
      decode.success(#(release, Configuration(id, provider, model, dimensions, chunking, normalization)))
    },
  ))
  Ok(found)
}

/// The embedding provider for a configuration, if this deployment can still
/// call it (the current model or one listed in `EMBEDDING_PREVIOUS`) and
/// this code still produces its chunking and normalization.
pub fn provider(ctx: Context, configuration: Configuration) -> Option(providers.EmbeddingProvider) {
  let supported =
    configuration.chunking_version == text.chunking_version
    && list.contains(["norm-v1", "norm-v2"], configuration.normalization_version)
  [ctx.config.embedding, ..ctx.config.previous_embeddings]
  |> list.find(fn(p) {
    supported
    && p.name == configuration.provider
    && p.model_id == configuration.model
    && p.dimensions == configuration.dimensions
  })
  |> option.from_result
}
