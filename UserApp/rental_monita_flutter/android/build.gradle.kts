// プロジェクトレベルの Gradle 設定ファイル
plugins {
    // Google Services Gradle プラグインのバージョン依存関係を追加
    id("com.google.gms.google-services") version "4.5.0" apply false
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// ビルドタスクのクリーンアップ設定
tasks.register<Delete>("clean") {
    delete(rootProject.buildDir)
}