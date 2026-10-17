# ADR 0005: Native sign-in and the iOS client

Status: accepted (work package G, first pass)

## Context

Section 13 asks for a SwiftUI app with:
- capture;
- a durable local queue with the section 13 state machine;
- background transfers, Keychain credentials, and backup and restore of
  pending captures;
- browsing, search, usage, export and account settings.

Native clients sign in with OIDC Authorization Code plus PKCE in the system
browser (section 6). The server had no native client and no refresh tokens,
and a phone could not discover how to sign in to a self-hosted server.

## Decisions

### Server

- **Native client:**
  - Configured with `OIDC_NATIVE_CLIENT_ID` and `OIDC_NATIVE_REDIRECT_URI`
    (default `libarrie://oauth/callback`).
  - The development issuer registers it automatically as `libarrie-native`.
  - Native codes produce three tokens:
    - an access token whose audience is `OIDC_AUDIENCE`, which the API
      verifies;
    - an ID token for the native client;
    - a rotating 30-day refresh token.
  - A refresh keeps the original `auth_time`, so it never satisfies the
    five-minute recent-sign-in rule.
- **`GET /v1/client-configuration`:** unauthenticated. It returns the sign-in
  endpoints, the native client ID and redirect, the upload checksum mode
  (`sha256`, or `md5` for R2) and limits. The app needs only a server address.
- **`GET /v1/pages/awaiting-processing`:** lists up to 100 pages waiting for
  deferred processing, with their source revisions. The web screen used the
  domain function directly; native clients had no way to call
  `process-deferred`.
- **Conformance fixtures:** `contracts/fixtures/api` holds real responses
  recorded by a server test. Every server run checks that response shapes
  still match. Clients decode the fixtures in their tests.

### iOS client (`clients/ios`)

- **No third-party dependencies** (Apple frameworks only), consistent with
  the licensing rule. XcodeGen generates the project; it is a development tool
  only.
- **Packages:** LibarrieKit holds the logic and LibarrieUI the screens. Both
  build for macOS too, so they type-check and test without Xcode.
- **No `@State`:** screens use `@Observable` models with `@Bindable`, cached
  per route by a navigator. The Command Line Tools lack SwiftUI's macro
  plugin, so `@State` code cannot compile without Xcode.
- **Queue persistence:** a JSON recovery manifest is rewritten atomically
  next to immutable image files, rather than kept in SQLite. It is small,
  always consistent in a device backup, and its relative paths are validated
  on restore.
- **Sign-in with another identity:** re-authentication rejects a different
  subject or issuer.
- **`reauthentication_required` 401:** shown to the user, never treated as
  an expired token.
- **Fixes found along the way:**
  - The web replacement upload omitted the required `If-Match`; it now sends
    `"c<content_version>"`.
  - Two OpenAPI schemas were quoted strings.

## Consequences and limits

- **Not compiled against the iOS SDK.** Xcode was unavailable, so the camera
  and scanner wrappers, the iOS-only modifiers and the app shell were never
  built for iOS. Expect small fixes on the first Xcode build.
- **Not exercised end to end:** a real device and simulator run of
  background uploads, relaunch delivery, and restore from an actual device
  backup.
- **Portable export of pending captures** is a share sheet of the original
  photo files (Settings). It doesn't include the queue metadata, so photos
  shared that way are re-added by hand, not reconciled.
- **Production OIDC providers** must issue refresh tokens to the native
  client (for example with `offline_access`) and accept the custom-scheme
  redirect.
- **Entitlements are display-only.** The apps show usage and current
  limits; nothing in them changes entitlements.
