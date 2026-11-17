plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "com.macoid.terminal"
    compileSdk = 34
    defaultConfig {
        applicationId = "com.macoid.terminal"
        minSdk = 26          // JGit needs java.nio.file (API 26+)
        targetSdk = 28       // allows exec from the app data dir (like Termux)
        versionCode = 2
        versionName = "2.0"
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
}
