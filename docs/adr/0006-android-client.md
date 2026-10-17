# ADR 0006: Android client

Status: accepted (work package H, first pass)

## Context

Section 13 asks for Kotlin and Jetpack Compose with:
- camera or photo picker;
- Room-style local persistence;
- platform background work for transfers;
- secure token storage;
- the same queue state machine and API fixtures as iOS.

Uploads must not depend on keeping an Activity alive. No JDK or Android SDK
was installed on the development machine.

## Decisions

- **Two modules.**
  - `core` is pure Kotlin (JVM): models, the OkHttp API client, OIDC PKCE
    and token refresh, the image cache, and the capture store and upload
    engine. It is a direct port of the iOS logic and is tested with the same
    scenarios and the server's fixtures.
  - `app` holds the Android-specific parts.
- **Dependencies:** AndroidX, Kotlin, kotlinx and OkHttp only, all Apache-2.0.
  - No Google Play services, ML Kit or Coil.
  - The system photo picker and the system camera intent need no camera
    permission.
  - Images load through the app's own account-keyed cache, because the
    `/img` routes need the bearer token.
- **Queue persistence:** the same atomically rewritten JSON recovery manifest
  as iOS, rather than Room. It keeps one tested implementation for both
  queues, stays consistent inside Auto Backup, and its relative, validated
  paths survive restore.
- **Background work:** WorkManager runs one unique upload job per item
  (replaced on retry), plus a periodic job and an on-connect job that run the
  engine. The container rebuilds the engine from the stored session when
  WorkManager starts the process without the UI.
- **Tokens:**
  - Stored AES-GCM encrypted with an Android Keystore key, in `no_backup`.
  - Restored devices cannot decrypt them, so the user signs in again.
  - The Jetpack Security library is deprecated, so it is not used.
- **Sign-in:** Custom Tabs plus a `libarrie://oauth/callback` intent filter
  on `MainActivity`. If the user returns from the browser without a
  redirect, sign-in is treated as cancelled.
- **Device backup:**
  - Pending captures in `files/captures` are included in Auto Backup and
    device transfer.
  - Turning the setting off moves them to `no_backup/captures`. Android's
    backup rules are static, so moving the directory is the only way to
    honor the setting.
  - Settings can share the original photos as a portable copy.
- **Builds without local tools:** a Dockerfile runs the core tests and builds
  the APK with lint.
  - The Android stages run as linux/amd64 because `aapt2` is x86-64-only.
  - They use command-line tools 13114758, the last release with the Java
    `sdkmanager`.
  - The Android SDK license is accepted only inside that build image, with
    the repository owner's approval.

## Consequences and limits

- **Not exercised end to end:** the app has not run on an emulator or a
  device, including WorkManager uploads after process death and Auto Backup
  restore.
- **No document scanner:** Google's ML Kit scanner is proprietary and needs
  Play services. Users crop with the camera or the photo editor instead.
- **Reordering** in review uses buttons, not drag-and-drop. This is more
  accessible but slower for long batches.
