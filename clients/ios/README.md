# Libarrie for iOS

SwiftUI app for iPhone and iPad (iOS 17+). It uses Apple frameworks only, with
no third-party dependencies.

```text
clients/ios/
  Package.swift              LibarrieKit and LibarrieUI (build for iOS and macOS)
  Sources/LibarrieKit/       API client, sign-in, image preparation, capture queue
  Sources/LibarrieUI/        SwiftUI screens and their models
  App/                       The iOS app shell: entry point, Info.plist, assets
  project.yml                XcodeGen spec for the Xcode project
  Tests/                     Unit tests (run on macOS)
```

## Run the tests

The tests run on macOS with only the Command Line Tools:

```sh
clients/ios/scripts/test.sh
```

- **Fixtures:** the API models are tested against the server's recorded
  responses in `contracts/fixtures/api`.
- **Upload queue:** tested against an in-memory model of the upload protocol.
  It covers lost responses, page-number conflicts, used-up processing
  allowance, expired links and reservations, relaunch, missing photos and
  account binding.

## Run the app

You need Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(MIT; `brew install xcodegen`).

```sh
cd clients/ios
xcodegen generate
open Libarrie.xcodeproj
```

Run the **Libarrie** scheme on a simulator. To run on a device, set your team
in `project.yml` (`DEVELOPMENT_TEAM`) or in Xcode's Signing settings.

**Local server:** start it with `docker compose up --build` from the
repository root. In the app, sign in to `http://localhost:8080`; the
development sign-in accepts any name.

**On a physical device**, `localhost` is the phone itself, so the server must
advertise addresses the phone can reach. Set these to your Mac's LAN address,
for example in `.env`:

```sh
WEB_ORIGIN=http://192.168.1.20:8080
S3_PUBLIC_ENDPOINT=http://192.168.1.20:8333
OIDC_ISSUER=http://192.168.1.20:8080/dev-issuer
LIBARRIE_BIND=0.0.0.0
```

`LIBARRIE_BIND=0.0.0.0` publishes ports 8080 and 8333 on your network, not
only on this Mac, so use it only on a network you trust. HTTP is allowed
only for local networks (`NSAllowsLocalNetworking`); real servers use HTTPS.

## How it works

- **Sign-in:**
  - The app needs only the server address. `GET /v1/client-configuration`
    supplies the sign-in endpoints, the native client ID and the upload
    checksum mode.
  - Sign-in uses the Authorization Code flow with PKCE in the system browser
    sheet (`ASWebAuthenticationSession`).
  - Tokens live only in the Keychain, device-only, so backups and device
    transfers never carry them.
  - Refreshes happen one at a time and keep the original sign-in time.
    Permanent deletion and account deletion ask for a fresh sign-in.
- **API calls:** they use a cookie-less `URLSession` with bearer tokens only,
  so the web session cookie can never mix in.
- **Photos:** images are prepared at capture.
  - HEIC is converted to JPEG with ImageIO.
  - GPS location is removed by default; Settings can keep it.
  - Orientation and other metadata are kept.
  - Photos over the server limit are re-encoded, never below 1,600 px.
- **Capture queue** (`UploadEngine`): section 13's state machine. Captures are
  saved on the device right away, in a recovery manifest plus immutable image
  files.
  - Uploads use a background `URLSession`, so they finish while the app is
    suspended.
  - The operation UUID never changes across retries. Lost responses are
    recovered by replaying the request or by looking up the operation; an
    expired operation needs an explicit, linked retry.
  - A photo is removed from the device only after the server reports its
    independent backup as verified, or when you remove it yourself after a
    warning.
  - Captures are bound to their account and server and never upload anywhere
    else.
- **Device backup:** pending captures go into the encrypted device backup by
  default (Settings can exclude them). After a restore, the app asks for
  sign-in, verifies each photo's checksum, and reconciles every capture with
  the server by its operation UUID before uploading anything.

## Not yet verified

There is no Xcode on the development machine, so these parts were not
compiled against the iOS SDK. `swift build` on macOS type-checks everything
else.

- The camera and document-scanner wrappers (`CameraViews.swift`).
- The iOS-only modifiers in `#if os(iOS)` blocks.
- The app shell in `App/`.

Expect small fixes on the first Xcode build.
