pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven("https://jitpack.io")   // Termux terminal-emulator / terminal-view libraries
    }
}
rootProject.name = "Macoid"
include(":app")
