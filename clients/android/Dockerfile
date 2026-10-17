# Build context: the repository root.
#
#   Gradle wrapper (written to clients/android):
#     docker build -f clients/android/Dockerfile --target wrapper-out -o clients/android .
#   Core tests (pure Kotlin, no Android SDK):
#     docker build -f clients/android/Dockerfile --target core-test .
#
# Nothing here runs a container; Gradle runs during the image build only.
ARG GRADLE_IMAGE=gradle:9.8.1-jdk21

FROM ${GRADLE_IMAGE} AS wrapper
WORKDIR /w
RUN touch settings.gradle.kts && gradle wrapper --gradle-version 9.8.1 --distribution-type bin --no-daemon -q

FROM scratch AS wrapper-out
COPY --from=wrapper /w/gradlew /w/gradlew.bat /
COPY --from=wrapper /w/gradle/wrapper/ /gradle/wrapper/

FROM ${GRADLE_IMAGE} AS core-test
ENV LIBARRIE_CORE_ONLY=1
WORKDIR /src/clients/android
COPY contracts/fixtures /src/contracts/fixtures
COPY clients/android/settings.gradle.kts clients/android/build.gradle.kts clients/android/gradle.properties ./
COPY clients/android/gradle/libs.versions.toml gradle/
COPY clients/android/core core
RUN --mount=type=cache,target=/home/gradle/.gradle/caches \
    gradle :core:test --no-daemon --console=plain

# Android SDK. Accepting the Android SDK License Agreement here was approved
# by the repository owner; the SDK stays inside this build image.
#   App build and lint:
#     docker build -f clients/android/Dockerfile --target app-build .
# linux/amd64: Google ships aapt2 for x86-64 Linux only (emulated on arm64
# hosts). Tools 13114758 is the last release with the Java sdkmanager.
FROM --platform=linux/amd64 ${GRADLE_IMAGE} AS android-sdk
ARG CMDLINE_TOOLS=commandlinetools-linux-13114758_latest.zip
ENV ANDROID_HOME=/opt/android-sdk
ENV PATH=$PATH:/opt/android-sdk/cmdline-tools/latest/bin
RUN apt-get update -qq && apt-get install -y -qq unzip >/dev/null \
 && mkdir -p $ANDROID_HOME/cmdline-tools \
 && curl -fsSLo /tmp/tools.zip https://dl.google.com/android/repository/$CMDLINE_TOOLS \
 && unzip -q /tmp/tools.zip -d $ANDROID_HOME/cmdline-tools \
 && mv $ANDROID_HOME/cmdline-tools/cmdline-tools $ANDROID_HOME/cmdline-tools/latest \
 && rm /tmp/tools.zip
RUN yes | sdkmanager --licenses >/dev/null \
 && sdkmanager --install "platform-tools" >/dev/null

FROM android-sdk AS app-build
WORKDIR /src/clients/android
COPY contracts/fixtures /src/contracts/fixtures
COPY clients/android/settings.gradle.kts clients/android/build.gradle.kts clients/android/gradle.properties ./
COPY clients/android/gradle/libs.versions.toml gradle/
COPY clients/android/core core
COPY clients/android/app app
RUN --mount=type=cache,target=/home/gradle/.gradle/caches \
    gradle :app:assembleDebug :app:lintDebug --no-daemon --console=plain \
 && mkdir -p /out && cp app/build/outputs/apk/debug/*.apk /out/ \
 && (cp app/build/reports/lint-results-debug.* /out/ 2>/dev/null || true)

FROM scratch AS app-out
COPY --from=app-build /out/ /
