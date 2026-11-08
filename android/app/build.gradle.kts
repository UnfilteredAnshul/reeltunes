import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Upload key for Play. `android/key.properties` is local-only (gitignored);
// without it the release build falls back to the debug key so `--release`
// still runs on a dev machine.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "com.buildwithanshul.reeltunes"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Permanent after the first Play upload.
        applicationId = "com.buildwithanshul.reeltunes"
        // Flutter's floor, plus what the bundled CPython 3.12 build needs.
        minSdk = 24
        // minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // The extractor ships inside jniLibs: `libpython.so` and `libqjs.so` are
    // executables (nativeLibraryDir is one of the few places Android still
    // allows exec), and the two zip payloads are not ELF at all, so llvm-strip
    // must never touch them. useLegacyPackaging keeps them as real files on
    // disk, which the launcher needs in order to execute them.
    packaging {
        jniLibs {
            useLegacyPackaging = true
            doNotStrip += listOf("**/*.zip.so", "**/libytdlp.so")
        }
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Play rejects debug-signed uploads, so release uses the upload
            // key from android/key.properties (kept off git).
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
            // Appended after Flutter's own rules. Without this file R8 strips
            // Room's generated WorkDatabase constructor and WorkManager kills
            // the process before Flutter boots (see proguard-rules.pro).
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}
