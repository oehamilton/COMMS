plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import com.android.build.gradle.internal.dsl.BaseAppModuleExtension

android {
    namespace = "com.example.comms"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    @Suppress("UnstableApiUsage")
    configure<BaseAppModuleExtension> {
        compileOptions {
            isCoreLibraryDesugaringEnabled = true
            sourceCompatibility = JavaVersion.VERSION_1_8
            targetCompatibility = JavaVersion.VERSION_1_8
        }
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_1_8.toString()
    }

    dependencies {
        implementation(platform("org.jetbrains.kotlin:kotlin-bom"))
        coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    }

    defaultConfig {
        applicationId = "com.example.comms"
        minSdk = 24  // Updated from flutter.minSdkVersion (21) to 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}