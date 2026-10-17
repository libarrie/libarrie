# Libarrie for Android

Kotlin and Jetpack Compose, Android 10 (API 29) and later. Every
dependency is Apache-2.0 (AndroidX, Kotlin, kotlinx, OkHttp); there are no
Google Play services.

```text
clients/android/
  core/   Pure Kotlin (JVM): API client, sign-in, image cache, capture queue
  app/    The Android app: Compose screens, WorkManager uploads,
          Keystore-protected tokens, image preparation
  Dockerfile   Builds and tests without installing anything locally
```

## Build and test

In Android Studio, open `clients/android`. To test with Gradle (JDK 17+):

```sh
cd clients/android
LIBARRIE_CORE_ONLY=1 ./gradlew :core:test   # no Android SDK needed
./gradlew :app:assembleDebug                 # needs the Android SDK
```

To do the same without a local JDK or SDK, from the repository root:

```sh
docker build -f clients/android/Dockerfile --target core-test .
docker build -f clients/android/Dockerfile --target app-out -o out/android .
```

- **`core-test`** runs the unit tests:
  - decoding the server's recorded responses in `contracts/fixtures/api`;
  - sign-in;
  - the upload queue against an in-memory model of the upload protocol.
- **`app-out`** builds the debug APK and the lint report. It installs the
  Android SDK inside the image, accepting the Android SDK License Agreement
  there. It runs as linux/amd64, because `aapt2` exists only for x86-64
  Linux; on Apple silicon this is emulated and slow.

## Run against the local server

Start the stack with `docker compose up --build` from the repository root.
Then forward the server's ports to the emulator or a USB-connected phone, so
`localhost` on the device reaches your Mac:

```sh
adb reverse tcp:8080 tcp:8080
adb reverse tcp:8333 tcp:8333
```

Sign in to `http://localhost:8080` with any name. Release builds allow
plain HTTP only to `localhost` and the emulator's host (`10.0.2.2`); debug
builds allow it on the local network too.

## How it works

- **Sign-in:**
  - The app needs only the server address. `GET /v1/client-configuration`
    supplies the sign-in endpoints, the native client ID and the upload
    checksum mode.
  - Sign-in uses the Authorization Code flow with PKCE in a Custom Tab (the
    system browser). The `libarrie://oauth/callback` redirect returns to
    `MainActivity`.
  - The session is AES-GCM encrypted with an Android Keystore key and
    stored in `no_backup`. Backups and device transfers therefore never carry
    usable tokens; after a restore you sign in again.
  - Refreshes happen one at a time and keep the original sign-in time.
    Permanent deletion and account deletion ask for a fresh sign-in.
- **API calls:** OkHttp with no cookie jar, bearer tokens only.
- **Photos:**
  - The photo picker or the system camera; no camera permission is needed.
  - HEIC is converted to JPEG with `ImageDecoder`.
  - GPS location is removed by default with a lossless EXIF rewrite;
    orientation is kept.
  - Photos over the server limit are re-encoded, never below 1,600 px.
- **Capture queue:** the same section 13 state machine and recovery rules as
  iOS. The code lives in `core`, so it is tested on any JVM.
  - Captures are saved on the device right away, in a recovery manifest plus
    immutable image files.
  - WorkManager performs the uploads and periodic queue runs, so they
    survive the app leaving the foreground or its process dying.
  - The operation UUID never changes across retries. An expired operation
    needs an explicit, linked retry.
  - A photo is removed from the device only after its independent backup is
    verified.
  - Captures upload only to the account and server they were taken for.
- **Device backup:** pending captures are in `files/captures`, which Auto
  Backup and device transfer include. Turning the setting off moves them to
  `no_backup/captures` (device-only). Settings can also share the original
  photos as files.
