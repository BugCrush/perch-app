import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Push notifications: needs app/google-services.json from the Firebase project.
    id("com.google.gms.google-services")
}

// The release key: android/key.properties (storeFile, storePassword, keyAlias, keyPassword)
// and the keystore it names, both git-ignored and kept only on the build machine (rotated
// 2026-11-19). Without them a release build is signed with the debug key and cannot update
// an installed release build.
val releaseKey = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "dev.perch.perch_app"
    // flutter_local_notifications 23 needs 37.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications uses java.time on older Android versions.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // The app's id on the phone and in Firebase (google-services.json must have an Android
        // app with this package name). A self-built app with its own Firebase project may use
        // its own: -PperchApplicationId=<id> (flutter build apk --android-project-arg
        // perchApplicationId=<id>, or ORG_GRADLE_PROJECT_perchApplicationId). Changing it makes
        // a different app: it cannot update one installed under another id.
        applicationId = (project.findProperty("perchApplicationId") as String?)?.takeIf { it.isNotBlank() }
            ?: "dev.perch.perch_app"
        // The relay whose https://<host>/pair the app opens (a pairing QR code scanned by the
        // phone's camera): the host of PERCH_DEFAULT_RELAY (the release workflow's variable),
        // or -PperchRelayHost=<host>. Without one, a name that never resolves.
        val relayHost = (project.findProperty("perchRelayHost") as String?)?.takeIf { it.isNotBlank() }
            ?: System.getenv("PERCH_DEFAULT_RELAY")?.let { java.net.URI(it.trim()).host }
            ?: "pair.invalid"
        manifestPlaceholders["perchRelayHost"] = relayHost
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // The release build's lint check crashes under JDK 17 (its Kotlin analysis calls
    // List.removeLast, a JDK 21 method): `flutter build apk --release` failed in
    // url_launcher's and firebase_core's lintVitalAnalyzeRelease. The app is not checked by
    // lint otherwise either.
    lint {
        checkReleaseBuilds = false
    }

    signingConfigs {
        if (releaseKey.getProperty("storeFile") != null) {
            create("release") {
                storeFile = rootProject.file(releaseKey.getProperty("storeFile"))
                storePassword = releaseKey.getProperty("storePassword")
                keyAlias = releaseKey.getProperty("keyAlias")
                keyPassword = releaseKey.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
