plugins {
    id("com.android.application")
    // Google Services Gradle プラグインを追加
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.rental_monita"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // 通知パッケージに必要なライブラリを有効化
        isCoreLibraryDesugaringEnabled = true

        // JavaとKotlinのバージョンを17に統一
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.rental_monita"
        minSdk = flutter.minSdkVersion
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

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Firebase BoM（ライブラリのバージョン一括管理）をインポート
    implementation(platform("com.google.firebase:firebase-bom:33.0.0"))

    // 利用するFirebase機能の追加
    implementation("com.google.firebase:firebase-analytics")
    implementation("com.google.firebase:firebase-messaging") // クラウドメッセージング（FCM）

    // core library desugaring用ライブラリ
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

// Flutterが探す場所へAPKをコピー ---
val flutterCliApkOutputDir =
    rootProject.layout.projectDirectory.dir("../build/app/outputs/flutter-apk")

tasks.register<Copy>("syncFlutterApks") {
    from(layout.buildDirectory.dir("outputs/flutter-apk"))
    into(flutterCliApkOutputDir)
}

tasks.matching {
    it.name == "assembleDebug" || it.name == "assembleRelease"
}.configureEach {
    finalizedBy("syncFlutterApks")
}
