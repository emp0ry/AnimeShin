pluginManagement {
    resolutionStrategy {
        eachPlugin {
            // Some Flutter plugins (and older templates) still request the legacy
            // 'kotlin-android' id. Map it to the Kotlin Gradle plugin version we use.
            if (requested.id.id == "kotlin-android") {
                useModule("org.jetbrains.kotlin:kotlin-gradle-plugin:2.2.0")
            }
        }
    }

    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // Updated to improve compatibility with newer Kotlin metadata (2.2.x).
    id("com.android.application") version "8.8.2" apply false
    // Keep Kotlin in sync with transitive dependencies (some ship Kotlin 2.2+ metadata).
    id("org.jetbrains.kotlin.android") version "2.2.0" apply false
}

include(":app")

