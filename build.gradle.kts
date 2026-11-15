// AGP 9 compiles Kotlin itself ("built-in Kotlin"): do not apply
// org.jetbrains.kotlin.android. The Compose compiler plugin is still needed.
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.compose) apply false
}
