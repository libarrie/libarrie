pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "libarrie"

// `core` is pure Kotlin (JVM): it builds and tests without the Android SDK.
include(":core")
// The Android app needs the SDK; LIBARRIE_CORE_ONLY=1 skips it.
if (System.getenv("LIBARRIE_CORE_ONLY") == null) include(":app")
