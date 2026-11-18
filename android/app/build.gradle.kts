// «Лента» для Android: оболочка (Trusted Web Activity) для led-lenta.vercel.app.
// Сайт открывается через Chrome без адресной строки — работает Web Bluetooth,
// а обновления сайта приходят в приложение сами, без переустановки.
plugins {
    id("com.android.application")
}

val keystore: String? = System.getenv("KEYSTORE_FILE")

android {
    namespace = "app.lenta.remote"
    compileSdk = 34

    defaultConfig {
        applicationId = "app.lenta.remote"
        minSdk = 23
        targetSdk = 34
        versionCode = (System.getenv("VERSION_CODE") ?: "1").toInt()
        versionName = System.getenv("VERSION_NAME") ?: "1.0"
    }

    signingConfigs {
        create("release") {
            if (keystore != null) {
                storeFile = file(keystore)
                storePassword = System.getenv("KEYSTORE_PASSWORD")
                keyAlias = System.getenv("KEY_ALIAS") ?: "lenta"
                keyPassword = System.getenv("KEY_PASSWORD") ?: System.getenv("KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // без ключа в секретах — подписываем отладочным, чтобы APK всё равно ставился
            signingConfig = signingConfigs.getByName(if (keystore != null) "release" else "debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("com.google.androidbrowserhelper:androidbrowserhelper:2.5.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
}
