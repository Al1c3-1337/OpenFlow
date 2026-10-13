plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningValues = listOf(
    "KEYSTORE_FILE", "KEYSTORE_PASSWORD", "KEY_ALIAS", "KEY_PASSWORD",
).associateWith { providers.environmentVariable(it).orNull?.takeIf(String::isNotBlank) }

val validateReleaseSigning by tasks.registering {
    doLast {
        val missing = releaseSigningValues.filterValues { it == null }.keys
        check(missing.isEmpty()) {
            "Android release signing requires these environment variables: ${missing.joinToString()}. " +
                "Use a debug build for local development without signing credentials."
        }
        check(file(releaseSigningValues.getValue("KEYSTORE_FILE")!!).isFile) {
            "Android release signing KEYSTORE_FILE must point to an existing keystore file."
        }
    }
}

android {
    namespace = "de.al1c3.openflow"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "de.al1c3.openflow"
        // Keep the original Android application's minimum supported OS.
        minSdk = 26
        targetSdk = 37
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            // Reuse the original Android signing identity; never fall back to a debug key.
            releaseSigningValues["KEYSTORE_FILE"]?.let { storeFile = file(it) }
            storePassword = releaseSigningValues["KEYSTORE_PASSWORD"]
            keyAlias = releaseSigningValues["KEY_ALIAS"]
            keyPassword = releaseSigningValues["KEY_PASSWORD"]
        }
    }

    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    dependsOn(validateReleaseSigning)
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
