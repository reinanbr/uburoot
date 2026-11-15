// AGP 9 compiles Kotlin itself ("built-in Kotlin"): do not apply
// org.jetbrains.kotlin.android. The Compose compiler plugin is still needed.
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.spotless)
}

// ktlint through Spotless: ./gradlew spotlessCheck (CI) / spotlessApply (fix).
// Rules come from .editorconfig.
spotless {
    val ktlintVersion = libs.versions.ktlint.get()
    // Also set here: with them only in .editorconfig, ktlint run through
    // Spotless still stripped every trailing comma (seen 2026-11-15).
    val trailingCommas = mapOf(
        "ij_kotlin_allow_trailing_comma" to true,
        "ij_kotlin_allow_trailing_comma_on_call_site" to true,
    )
    kotlin {
        target("app/src/**/*.kt")
        ktlint(ktlintVersion).setEditorConfigPath(file(".editorconfig")).editorConfigOverride(trailingCommas)
    }
    kotlinGradle {
        target("*.gradle.kts", "app/*.gradle.kts")
        ktlint(ktlintVersion).setEditorConfigPath(file(".editorconfig")).editorConfigOverride(trailingCommas)
    }
}
