//// Environment configuration shared by the API and worker (section 15).
////
//// Hosted and self-host modes are configuration, not forks. A lifecycle
//// subscriber is optional and never required to boot. Development-only adapters (mock
//// providers, the HS256 development issuer) are refused in hosted mode.

import envoy
import gleam/bool
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import libarrie/domain/context.{type Limit, Limited, Unlimited}
import libarrie/domain/text
import libarrie/integrations/lifecycle_subscriber
import libarrie/integrations/image
import libarrie/integrations/decoder
import libarrie/integrations/mistral
import libarrie/integrations/providers
import libarrie/integrations/voyage
import libarrie/integrations/storage
import libarrie/jobs

pub type Settings {
  Settings(
    mode: String,
    database_url: String,
    database_pool_size: Int,
    port: Int,
    /// Serve `/internal` only on this port, never on `port`, so it can stay
    /// off the public network.
    internal_port: Option(Int),
    migrations_dir: String,
    oidc_issuer: String,
    oidc_audience: String,
    oidc_jwks_url: Option(String),
    development_issuer_secret: Option(String),
    internal_api_token: Option(String),
    web_origin: String,
    oidc_client_id: String,
    oidc_client_secret: Option(String),
    /// Public client for the native apps (PKCE, no secret). Defaults to
    /// `libarrie-native` with the development issuer; otherwise unset, and
    /// native sign-in is unavailable until configured.
    oidc_native_client_id: Option(String),
    oidc_native_redirect_uri: String,
    oidc_authorization_endpoint: Option(String),
    oidc_token_endpoint: Option(String),
    secret_key_base: Option(String),
    web_static_dir: String,
    /// Optional receiver of account lifecycle commands (section 14).
    lifecycle_subscriber_url: Option(String),
    lifecycle_subscriber_token: Option(String),
    /// Audience of identity-provider access tokens accepted by the MCP
    /// server; defaults to its URL, `WEB_ORIGIN` + `/mcp` (ADR 0012).
    mcp_oauth_audience: Option(String),
    /// Scopes MCP clients should request from the identity provider.
    mcp_oauth_scopes: List(String),
    /// Used by workers only.
    ocr: providers.OcrProvider,
    domain: context.Config,
  )
}

/// Whether an origin is on this machine or a private network: an http://
/// origin whose host is localhost or a loopback, private (RFC 1918) or
/// link-local IP address, or a unique-local or link-local IPv6 address.
pub fn private_origin(origin: String) -> Bool {
  case uri.parse(origin) {
    Ok(uri.Uri(scheme: Some("http"), host: Some(host), ..)) -> {
      let host = string.lowercase(host)
      case string.split(host, ".") |> list.map(int.parse) {
        _ if host == "localhost" -> True
        [Ok(a), Ok(b), Ok(_), Ok(_)] ->
          a == 127
          || a == 10
          || { a == 172 && b >= 16 && b <= 31 }
          || { a == 192 && b == 168 }
          || { a == 169 && b == 254 }
        _ -> {
          let v6 = host |> string.replace("[", "") |> string.replace("]", "")
          v6 == "::1"
          || string.starts_with(v6, "fc")
          || string.starts_with(v6, "fd")
          || string.starts_with(v6, "fe80:")
        }
      }
    }
    _ -> False
  }
}

/// An empty variable counts as unset, so Compose files can pass optional
/// settings through as `${NAME:-}`.
fn get(name: String, default: String) -> String {
  case envoy.get(name) {
    Ok("") | Error(_) -> default
    Ok(value) -> value
  }
}

fn get_optional(name: String) -> Option(String) {
  case envoy.get(name) {
    Ok("") | Error(_) -> None
    Ok(value) -> Some(value)
  }
}

fn get_int(name: String, default: Int) -> Result(Int, String) {
  case envoy.get(name) {
    Error(_) | Ok("") -> Ok(default)
    Ok(value) ->
      int.parse(value) |> result.replace_error(name <> " must be an integer")
  }
}

fn get_limit(name: String, default: Limit) -> Result(Limit, String) {
  case envoy.get(name) {
    Error(_) | Ok("") -> Ok(default)
    Ok("unlimited") -> Ok(Unlimited)
    Ok(value) ->
      case int.parse(value) {
        Ok(n) if n >= 0 -> Ok(Limited(n))
        _ -> Error(name <> " must be a non-negative integer or 'unlimited'")
      }
  }
}

pub fn load() -> Result(Settings, String) {
  let mode = get("LIBARRIE_MODE", "selfhost")
  use _ <- result.try(case mode {
    "selfhost" | "hosted" -> Ok(Nil)
    _ -> Error("LIBARRIE_MODE must be selfhost or hosted")
  })
  use pool_size <- result.try(get_int("DATABASE_POOL_SIZE", 10))
  use port <- result.try(get_int("PORT", 8080))
  use internal_port <- result.try(case get_optional("INTERNAL_PORT") {
    None -> Ok(None)
    Some(value) ->
      case int.parse(value) {
        Ok(p) if p > 0 && p < 65_536 && p != port -> Ok(Some(p))
        _ -> Error("INTERNAL_PORT must be a port number other than PORT")
      }
  })
  use stored <- result.try(get_limit("DEFAULT_STORED_PAGES", Limited(30)))
  use notebooks <- result.try(get_limit("DEFAULT_NOTEBOOKS", Limited(1)))
  use lifetime <- result.try(get_limit("DEFAULT_LIFETIME_PROCESSING", Limited(30)))
  use download_seconds <- result.try(get_int("DOWNLOAD_URL_SECONDS", 300))
  use slots <- result.try(get_int("ACCOUNT_JOB_SLOTS", 4))
  use grace_days <- result.try(get_int("ACCOUNT_CLOSURE_GRACE_DAYS", 7))
  use archive_days <- result.try(get_int("JOBS_ARCHIVE_RETENTION_DAYS", 30))
  use _ <- result.try(case get_optional("LIFECYCLE_SUBSCRIBER_URL"), get_optional("LIFECYCLE_SUBSCRIBER_TOKEN") {
    None, _ | Some(_), Some(_) -> Ok(Nil)
    Some(_), None -> Error("LIFECYCLE_SUBSCRIBER_URL requires LIFECYCLE_SUBSCRIBER_TOKEN")
  })
  use <- bool.guard(archive_days < 1, Error("JOBS_ARCHIVE_RETENTION_DAYS must be at least 1"))
  use part_bytes <- result.try(get_int("EXPORT_PART_BYTES", 2_000_000_000))
  use chunk_bytes <- result.try(get_int("EXPORT_UPLOAD_CHUNK_BYTES", 8_388_608))
  use max_exports <- result.try(get_int("EXPORT_MAX_CONCURRENT", 2))
  use ocr_cost <- result.try(get_int("SPEND_OCR_COST_MICROS", 6000))
  use account_daily <- result.try(get_int("SPEND_ACCOUNT_DAILY_MICROS", 5_000_000))
  use deployment_daily <- result.try(get_int("SPEND_DEPLOYMENT_DAILY_MICROS", 50_000_000))
  use max_pause_hours <- result.try(get_int("SPEND_MAX_PAUSE_HOURS", 36))
  use provider_concurrency <- result.try(get_int("PROVIDER_CONCURRENCY", 8))
  use requests_per_minute <- result.try(get_int("RATE_REQUESTS_PER_MINUTE", 1200))
  use searches_per_minute <- result.try(get_int("RATE_SEARCHES_PER_MINUTE", 60))
  use _ <- result.try(case mode, grace_days {
    "hosted", d if d < 1 || d > 30 ->
      Error("hosted ACCOUNT_CLOSURE_GRACE_DAYS must be between 1 and 30")
    _, d if d < 0 || d > 30 -> Error("ACCOUNT_CLOSURE_GRACE_DAYS must be 0-30")
    _, _ -> Ok(Nil)
  })
  use _ <- result.try(case max_pause_hours * 3600 > 86_400 {
    True -> Ok(Nil)
    False -> Error("SPEND_MAX_PAUSE_HOURS must exceed the 24-hour budget window")
  })
  use _ <- result.try(case chunk_bytes >= 5_242_880 {
    True -> Ok(Nil)
    False -> Error("EXPORT_UPLOAD_CHUNK_BYTES must be at least 5 MiB (S3 part minimum)")
  })
  let dev_secret = get_optional("DEV_ISSUER_SECRET")
  use _ <- result.try(case mode, dev_secret {
    "hosted", Some(_) ->
      Error("DEV_ISSUER_SECRET (development issuer) is not allowed in hosted mode")
    "hosted", _ if download_seconds > 300 ->
      Error("hosted download URLs may live at most 300 seconds")
    _, _ -> Ok(Nil)
  })
  // The development issuer signs in anyone as anyone, so it only runs on a
  // machine or private network, never on a public address.
  use _ <- result.try(case dev_secret {
    Some(_) ->
      case private_origin(get("WEB_ORIGIN", "http://localhost:8080")) {
        True -> Ok(Nil)
        False ->
          Error(
            "DEV_ISSUER_SECRET enables the development sign-in, which lets anyone sign in as anyone; "
            <> "it only works when WEB_ORIGIN is localhost or a private-network IP address. "
            <> "Unset it and configure your identity provider (OIDC_ISSUER, OIDC_JWKS_URL, OIDC_CLIENT_ID).",
          )
      }
    None -> Ok(Nil)
  })
  use #(ocr, embedding) <- result.try(model_providers(mode))
  use previous_embeddings <- result.try(previous_providers(mode))
  use decoder_config <- result.try(decoder_settings(mode))
  use _ <- result.try(check_spend_ceiling(mode, account_daily, ocr_cost))
  let hash_keys =
    get("IDENTITY_HASH_KEYS", "dev:libarrie-development-identity-key")
    |> string.split(",")
    |> list.filter_map(fn(entry) { string.split_once(string.trim(entry), ":") })
  use _ <- result.try(case list.length(hash_keys) {
    n if n >= 1 && n <= 3 -> Ok(Nil)
    _ -> Error("IDENTITY_HASH_KEYS must hold 1-3 key_id:secret entries")
  })
  let endpoint = get("S3_ENDPOINT", "http://localhost:8333")
  use upload_integrity <- result.try(case get("S3_UPLOAD_INTEGRITY", "sha256") {
    "sha256" -> Ok(storage.Sha256Header)
    "md5" -> Ok(storage.ContentMd5)
    _ -> Error("S3_UPLOAD_INTEGRITY must be sha256 or md5 (use md5 for Cloudflare R2)")
  })
  let storage_config =
    storage.Config(
      endpoint:,
      public_endpoint: get("S3_PUBLIC_ENDPOINT", endpoint),
      region: get("S3_REGION", "us-east-1"),
      bucket: get("S3_BUCKET", "libarrie"),
      access_key_id: get("S3_ACCESS_KEY_ID", "libarrie-dev-access"),
      secret_access_key: get("S3_SECRET_ACCESS_KEY", "libarrie-dev-secret"),
      upload_integrity:,
    )
  use journal_store <- result.try(journal_settings(mode, storage_config))
  // Session cookies are Secure and __Host- prefixed only on HTTPS origins.
  use _ <- result.try(case mode, string.starts_with(get("WEB_ORIGIN", "http://localhost:8080"), "https://") {
    "hosted", False -> Error("hosted mode requires an https:// WEB_ORIGIN")
    _, _ -> Ok(Nil)
  })
  use _ <- result.try(case mode, get_optional("SECRET_KEY_BASE") {
    "hosted", None -> Error("hosted mode requires SECRET_KEY_BASE (64+ random characters, shared by all replicas)")
    _, Some(key) if key != "" ->
      case string.length(key) >= 64 {
        True -> Ok(Nil)
        False -> Error("SECRET_KEY_BASE must be at least 64 characters")
      }
    _, _ -> Ok(Nil)
  })
  Ok(Settings(
    mode:,
    database_url: get(
      "DATABASE_URL",
      "postgres://libarrie:libarrie@localhost:5433/libarrie",
    ),
    database_pool_size: pool_size,
    port:,
    internal_port:,
    migrations_dir: get("MIGRATIONS_DIR", "../../../database/migrations"),
    oidc_issuer: get("OIDC_ISSUER", "http://localhost:8080/dev-issuer"),
    oidc_audience: get("OIDC_AUDIENCE", "libarrie"),
    oidc_jwks_url: get_optional("OIDC_JWKS_URL"),
    development_issuer_secret: dev_secret,
    internal_api_token: get_optional("INTERNAL_API_TOKEN"),
    web_origin: get("WEB_ORIGIN", "http://localhost:8080"),
    oidc_client_id: get("OIDC_CLIENT_ID", get("OIDC_AUDIENCE", "libarrie")),
    oidc_client_secret: get_optional("OIDC_CLIENT_SECRET"),
    oidc_native_client_id: case get_optional("OIDC_NATIVE_CLIENT_ID"), dev_secret {
      Some(id), _ -> Some(id)
      None, Some(_) -> Some("libarrie-native")
      None, None -> None
    },
    oidc_native_redirect_uri: get("OIDC_NATIVE_REDIRECT_URI", "libarrie://oauth/callback"),
    oidc_authorization_endpoint: get_optional("OIDC_AUTHORIZATION_ENDPOINT"),
    oidc_token_endpoint: get_optional("OIDC_TOKEN_ENDPOINT"),
    secret_key_base: get_optional("SECRET_KEY_BASE"),
    web_static_dir: get("WEB_STATIC_DIR", "../../../clients/web/static"),
    lifecycle_subscriber_url: get_optional("LIFECYCLE_SUBSCRIBER_URL"),
    lifecycle_subscriber_token: get_optional("LIFECYCLE_SUBSCRIBER_TOKEN"),
    mcp_oauth_audience: get_optional("MCP_OAUTH_AUDIENCE"),
    mcp_oauth_scopes: get("MCP_OAUTH_SCOPES", "")
      |> string.split(" ")
      |> list.filter(fn(scope) { scope != "" }),
    ocr:,
    domain: context.Config(
      storage: storage_config,
      journal_store:,
      image_limits: image.default_limits(),
      foreground_upload_url_seconds: 900,
      background_upload_url_seconds: 6 * 3600,
      reservation_seconds: 24 * 3600,
      download_url_seconds: int.min(download_seconds, 300),
      default_stored_pages: stored,
      default_notebooks: notebooks,
      default_lifetime_processing: lifetime,
      lazy_expiry_batch: 25,
      recovery_hold_days: 30,
      trash_retention_days: 30,
      job_archive_retention_days: archive_days,
      identity_hash_keys: hash_keys,
      embedding:,
      previous_embeddings:,
      chunking_version: text.chunking_version,
      normalization_version: text.normalization_version,
      jobs: jobs.Settings(..jobs.default_settings(), default_account_slots: slots),
      closure_grace_seconds: grace_days * 86_400,
      closure_max_seconds: 30 * 86_400,
      lifecycle_subscriber: get_optional("LIFECYCLE_SUBSCRIBER_URL") != None,
      configured_owner: get_optional("LIBARRIE_OWNER"),
      decoder: decoder_config,
      exports: context.ExportSettings(
        part_bytes:,
        upload_chunk_bytes: chunk_bytes,
        max_concurrent: max_exports,
        retention_seconds: 7 * 86_400,
        download_window_seconds: 72 * 3600,
      ),
      spend: context.SpendSettings(
        ocr_cost_micros: ocr_cost,
        account_daily_micros: account_daily,
        deployment_daily_micros: deployment_daily,
        max_pause_seconds: max_pause_hours * 3600,
        provider_concurrency:,
        permit_lease_seconds: 180,
        circuit_threshold: 10,
        circuit_open_seconds: 60,
      ),
      rate_limits: context.RateLimits(
        requests_per_minute:,
        searches_per_minute:,
        corrections_per_page_hour: 60,
        rescans_per_page_day: 3,
      ),
    ),
  ))
}

/// Select model provider adapters (section 6).
///
/// Hosted mode refuses development mocks and enables a real adapter only
/// when its privacy terms are recorded (no training on submitted content,
/// bounded retention, signed DPA, documented region): set
/// `MISTRAL_TERMS_RECORD` / `VOYAGE_TERMS_RECORD` to the reference of that
/// record. API keys come from the environment or a secret manager and are
/// never logged.
fn model_providers(
  mode: String,
) -> Result(#(providers.OcrProvider, providers.EmbeddingProvider), String) {
  let ocr_choice = get("OCR_PROVIDER", "mock")
  let embedding_choice = get("EMBEDDING_PROVIDER", "mock")
  let require_terms = fn(name: String, variable: String) {
    case mode, get_optional(variable) {
      "hosted", None ->
        Error(name <> " is disabled in hosted mode until its privacy terms are recorded in " <> variable)
      _, _ -> Ok(Nil)
    }
  }
  use ocr <- result.try(case ocr_choice {
    "mock" ->
      case mode {
        "hosted" -> Error("mock OCR is development-only; set OCR_PROVIDER=mistral")
        _ -> Ok(providers.mock_ocr())
      }
    "mistral" -> {
      use key <- result.try(
        get_optional("MISTRAL_API_KEY") |> option.to_result("MISTRAL_API_KEY is required"),
      )
      use _ <- result.try(require_terms("Mistral OCR", "MISTRAL_TERMS_RECORD"))
      use min_confidence <- result.try(get_float("MISTRAL_MIN_CONFIDENCE", 0.5))
      let config = mistral.default_config(key)
      Ok(mistral.provider(mistral.Config(
        ..config,
        base_url: get("MISTRAL_BASE_URL", config.base_url),
        model: get("MISTRAL_OCR_MODEL", config.model),
        min_confidence:,
      )))
    }
    other -> Error("unsupported OCR_PROVIDER: " <> other)
  })
  use _ <- result.try(case string.ends_with(ocr.model_id, "latest") {
    True -> Error("pin an explicit OCR model version, not a -latest alias")
    False -> Ok(Nil)
  })
  use embedding <- result.try(case embedding_choice {
    "mock" ->
      case mode {
        "hosted" -> Error("mock embeddings are development-only; set EMBEDDING_PROVIDER=voyage")
        _ -> {
          use dimensions <- result.try(get_int("EMBEDDING_DIMENSIONS", 256))
          Ok(providers.mock_embedding(dimensions))
        }
      }
    "voyage" -> {
      use key <- result.try(
        get_optional("VOYAGE_API_KEY") |> option.to_result("VOYAGE_API_KEY is required"),
      )
      use _ <- result.try(require_terms("Voyage embeddings", "VOYAGE_TERMS_RECORD"))
      use dimensions <- result.try(get_int("EMBEDDING_DIMENSIONS", 1024))
      use _ <- result.try(case list.contains(voyage.allowed_dimensions, dimensions) {
        True -> Ok(Nil)
        False -> Error("EMBEDDING_DIMENSIONS for Voyage must be 256, 512, 1024 or 2048")
      })
      use price <- result.try(get_int("VOYAGE_PRICE_MICROS_PER_MTOK", 120_000))
      let config = voyage.default_config(key)
      Ok(voyage.provider(voyage.Config(
        ..config,
        base_url: get("VOYAGE_BASE_URL", config.base_url),
        model: get("VOYAGE_MODEL", config.model),
        dimensions:,
        price_micros_per_million_tokens: price,
      )))
    }
    other -> Error("unsupported EMBEDDING_PROVIDER: " <> other)
  })
  Ok(#(ocr, embedding))
}

/// `EMBEDDING_PREVIOUS`: earlier embedding models that stay callable during
/// a search migration and its rollback window, as comma-separated
/// `voyage:MODEL:DIMENSIONS` or `mock:DIMENSIONS` entries (Voyage reuses
/// `VOYAGE_API_KEY`). Leave unset once no account needs them; an account
/// whose release uses a model not listed here searches by words only until
/// its migration finishes, and rollback to it is unavailable.
fn previous_providers(mode: String) -> Result(List(providers.EmbeddingProvider), String) {
  get("EMBEDDING_PREVIOUS", "")
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(entry) { entry != "" })
  |> list.try_map(fn(entry) {
    case string.split(entry, ":"), mode {
      ["mock", _], "hosted" -> Error("mock embeddings are development-only")
      ["mock", dims], _ ->
        int.parse(dims)
        |> result.map(providers.mock_embedding)
        |> result.replace_error("EMBEDDING_PREVIOUS: bad dimensions in " <> entry)
      ["voyage", model, dims], _ -> {
        use key <- result.try(
          get_optional("VOYAGE_API_KEY") |> option.to_result("VOYAGE_API_KEY is required for EMBEDDING_PREVIOUS"),
        )
        use dimensions <- result.try(int.parse(dims) |> result.replace_error("EMBEDDING_PREVIOUS: bad dimensions in " <> entry))
        let config = voyage.default_config(key)
        Ok(voyage.provider(voyage.Config(
          ..config,
          base_url: get("VOYAGE_BASE_URL", config.base_url),
          model:,
          dimensions:,
        )))
      }
      _, _ -> Error("EMBEDDING_PREVIOUS entries are voyage:MODEL:DIMENSIONS or mock:DIMENSIONS")
    }
  })
}

/// Hosted configuration validation (section 16): refuse to start when the
/// per-account daily ceiling is below the largest monthly processing
/// allowance x estimated per-page cost x 1.5 headroom.
fn check_spend_ceiling(
  mode: String,
  account_daily: Int,
  ocr_cost: Int,
) -> Result(Nil, String) {
  case mode {
    "hosted" -> {
      use largest <- result.try(get_int("LARGEST_MONTHLY_PROCESSING_ALLOWANCE", 1000))
      use explicit <- result.try(
        get_optional("SPEND_ACCOUNT_DAILY_MICROS")
        |> option.to_result("hosted mode requires an explicit SPEND_ACCOUNT_DAILY_MICROS"),
      )
      let _ = explicit
      let required = largest * ocr_cost * 3 / 2
      case account_daily >= required {
        True -> Ok(Nil)
        False ->
          Error(
            "SPEND_ACCOUNT_DAILY_MICROS ("
            <> int.to_string(account_daily)
            <> ") is below the largest monthly allowance x per-page cost x 1.5 ("
            <> int.to_string(required)
            <> ")",
          )
      }
    }
    _ -> Ok(Nil)
  }
}

fn get_float(name: String, default: Float) -> Result(Float, String) {
  case envoy.get(name) {
    Error(_) | Ok("") -> Ok(default)
    Ok(value) ->
      float.parse(value)
      |> result.lazy_or(fn() { int.parse(value) |> result.map(int.to_float) })
      |> result.replace_error(name <> " must be a number")
  }
}

/// Sandboxed decoder (section 7). Hosted mode requires a sandbox; `none` is
/// for development hosts that cannot run the Linux binaries.
fn decoder_settings(mode: String) -> Result(Option(decoder.Config), String) {
  let bin_dir = get("DECODER_BIN_DIR", "/opt/libarrie/bin")
  let policy = get("DECODER_POLICY", "/opt/libarrie/policy/decoder.policy")
  let scratch = get("DECODER_SCRATCH_DIR", "/tmp/libarrie-decoder")
  use sandbox <- result.try(case get("DECODER_SANDBOX", "none") {
    "none" ->
      case mode {
        "hosted" -> Error("hosted mode requires DECODER_SANDBOX=minijail or unprivileged")
        _ -> Ok(None)
      }
    "minijail" ->
      Ok(Some(decoder.Minijail(
        minijail: bin_dir <> "/minijail0",
        root: get("DECODER_ROOT", "/opt/libarrie/sandbox-root"),
        policy:,
      )))
    "unprivileged" -> Ok(Some(decoder.Unprivileged(policy:)))
    other -> Error("unsupported DECODER_SANDBOX: " <> other)
  })
  use cpu <- result.try(get_int("DECODER_CPU_SECONDS", 20))
  use wall <- result.try(get_int("DECODER_WALL_SECONDS", 30))
  use memory <- result.try(get_int("DECODER_MEMORY_BYTES", 1_073_741_824))
  Ok(option.map(sandbox, fn(sandbox) {
    decoder.Config(
      ..decoder.default_config(bin_dir, sandbox, scratch),
      cpu_seconds: cpu,
      wall_seconds: wall,
      memory_bytes: memory,
    )
  }))
}

/// The independent deletion/lifecycle journal store (section 14). In hosted
/// mode it must be a different bucket with different credentials from the
/// primary store (for example a second R2 account or bucket with a bucket
/// lock rule and a token scoped to that bucket only).
fn journal_settings(
  mode: String,
  primary: storage.Config,
) -> Result(storage.Config, String) {
  let explicit = get_optional("JOURNAL_S3_BUCKET")
  let endpoint = get("JOURNAL_S3_ENDPOINT", primary.endpoint)
  let journal =
    storage.Config(
      endpoint:,
      public_endpoint: endpoint,
      region: get("JOURNAL_S3_REGION", primary.region),
      bucket: option.unwrap(explicit, "libarrie-journal"),
      access_key_id: get("JOURNAL_S3_ACCESS_KEY_ID", primary.access_key_id),
      secret_access_key: get("JOURNAL_S3_SECRET_ACCESS_KEY", primary.secret_access_key),
      upload_integrity: primary.upload_integrity,
    )
  case mode {
    "hosted" ->
      case explicit {
        None -> Error("hosted mode requires JOURNAL_S3_BUCKET and its own JOURNAL_S3_* credentials")
        Some(_) ->
          case
            journal.access_key_id == primary.access_key_id,
            journal.endpoint == primary.endpoint && journal.bucket == primary.bucket
          {
            True, _ -> Error("the journal must use credentials distinct from the primary store")
            _, True -> Error("the journal must not share the primary bucket")
            False, False -> Ok(journal)
          }
      }
    _ -> Ok(journal)
  }
}

/// The lifecycle subscriber client, when one is configured.
pub fn subscriber_client(config: Settings) -> Option(lifecycle_subscriber.Client) {
  case config.lifecycle_subscriber_url, config.lifecycle_subscriber_token {
    Some(url), Some(token) -> Some(lifecycle_subscriber.Client(url, token))
    _, _ -> None
  }
}
