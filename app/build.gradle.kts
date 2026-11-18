plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "com.macoid.terminal"
    compileSdk = 34
    defaultConfig {
        applicationId = "com.macoid.terminal"
        minSdk = 26          // JGit needs java.nio.file (API 26+)
        targetSdk = 28       // allows exec from the app data dir (like Termux)
        versionCode = 10
        versionName = "4.2"
    }
    // Fixed signing key. Without it every GitHub Actions build is signed with a random debug key, Android refuses to
    // update the installed app ("conflicts with an existing package"), and uninstalling wipes everything installed in Macoid.
    // Same key on every build = install the new APK over the old one and all your packages stay.
    signingConfigs {
        create("macoid") {
            storeFile = file("macoid.keystore")
            storePassword = "macoid-sign"
            keyAlias = "macoid"
            keyPassword = "macoid-sign"
        }
    }
    buildTypes {
        getByName("debug") { signingConfig = signingConfigs.getByName("macoid") }
        getByName("release") { signingConfig = signingConfigs.getByName("macoid") }
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    lint { abortOnError = false; checkReleaseBuilds = false }
    packaging {
        resources {
            excludes += listOf("META-INF/AL2.0", "META-INF/LGPL2.1", "META-INF/DEPENDENCIES",
                "META-INF/LICENSE*", "META-INF/NOTICE*", "META-INF/INDEX.LIST", "META-INF/*.SF", "META-INF/*.DSA", "META-INF/*.RSA")
        }
    }
}
dependencies {
    implementation("org.eclipse.jgit:org.eclipse.jgit:5.13.3.202401111512-r")
    implementation("org.slf4j:slf4j-nop:1.7.36")
    // Real terminal: PTY + full VT100/xterm emulation + terminal view (same libraries Termux uses)
    implementation("com.github.termux.termux-app:terminal-view:v0.118.0")
    implementation("com.github.termux.termux-app:terminal-emulator:v0.118.0")
}
