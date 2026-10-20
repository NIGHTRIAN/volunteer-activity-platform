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
        // ⚠️ 国内镜像放在**前面**，官方源在后作为兜底。
        //
        // 实测：本机访问 `maven.google.com` 不可达 / 极慢，
        // 而 AGP、AndroidX、Kotlin 插件全在 Google 的 Maven 仓库里。
        // 不换源的话首次构建会卡在下载依赖上（症状是没有任何报错、
        // 只是长时间不动）。
        //
        // 顺序很重要：Gradle 按声明顺序尝试，把镜像放前面才能真正生效；
        // 保留官方源是为了在镜像缺包时仍能构建（镜像同步有延迟）。
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
        maven { url = uri("https://mirrors.cloud.tencent.com/nexus/repository/maven-public/") }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
