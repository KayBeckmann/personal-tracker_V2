import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release-Signatur aus der lokalen, git-ignorierten android/key.properties
// (storeFile, storePassword, keyAlias, keyPassword). Schlüssel und
// Passwörter liegen nie im Repo.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val hasReleaseKey = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "de.kaybeckmann.personal_tracker"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications braucht java.time auf älteren Geräten.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // Nicht mehr ändern, sonst behandelt Android sie als neue App.
        applicationId = "de.kaybeckmann.personal_tracker"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Fingerabdruck-Speicher (AndroidOptions.biometric) braucht API 28.
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Ohne Release-Schlüssel kein Release-Build — nie still mit dem
            // Debug-Schlüssel signieren.
            signingConfig = if (hasReleaseKey) signingConfigs.getByName("release") else null
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

gradle.taskGraph.whenReady {
    if (!hasReleaseKey && allTasks.any { it.name.contains("Release") && it.project == project }) {
        throw GradleException("android/key.properties fehlt — Release-Builds brauchen den Release-Schlüssel.")
    }
}
