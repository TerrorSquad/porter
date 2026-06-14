pluginManagement {
    val flutterSdkPath =
        run {
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
    // Pinned to a stable AGP/Kotlin combo. The Flutter 3.44 template defaults
    // (AGP 9.0.1 / Kotlin 2.3.20) are too new for the third-party plugins this
    // app uses (file_picker, share_plus, the vendored mobile_scanner), whose
    // Kotlin won't compile under AGP 9. AGP must also be >= 8.9.1 for the
    // AndroidX deps the plugins pull in (androidx.core 1.17, browser 1.9), so
    // 8.10.x is the window that satisfies both.
    id("com.android.application") version "8.10.1" apply false
    id("org.jetbrains.kotlin.android") version "2.1.20" apply false
}

include(":app")
