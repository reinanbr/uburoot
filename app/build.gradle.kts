// SPDX-License-Identifier: GPL-3.0-or-later
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

val appVersionName = "0.4.0"
val appVersionCode = 5

android {
    namespace = "com.reinanbr.uburoot"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.reinanbr.uburoot"
        minSdk = 26
        targetSdk = 37
        versionCode = appVersionCode
        versionName = appVersionName
        ndk {
            // The chroot is arm64 only; drop the other ABIs Termux ships.
            abiFilters += "arm64-v8a"
        }
    }

    // No dependency metadata block in the APK signing block: it is encrypted
    // with a Google key, differs on every build (so two builds of one commit
    // never match byte for byte) and F-Droid flags it.
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    // Release signing comes from the environment (CI secrets), never from the
    // repo. Unless all four variables are set, the release APK is left unsigned
    // (and CI's release job refuses to publish it).
    fun env(name: String) = providers.environmentVariable(name).orNull?.takeIf { it.isNotEmpty() }
    val keystore = env("UBUROOT_KEYSTORE")?.let(::file)?.takeIf { it.isFile }
    val storePass = env("UBUROOT_KEYSTORE_PASSWORD")
    val alias = env("UBUROOT_KEY_ALIAS")
    val keyPass = env("UBUROOT_KEY_PASSWORD")
    if (keystore != null && storePass != null && alias != null && keyPass != null) {
        signingConfigs {
            create("release") {
                storeFile = keystore
                storePassword = storePass
                keyAlias = alias
                keyPassword = keyPass
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.termux.terminal.view)
    implementation(libs.termux.terminal.emulator)
    implementation(libs.libsu.core)

    testImplementation(libs.junit)
}

/**
 * The APK is also a Magisk/KernelSU/APatch module and a Magisk recovery zip:
 * src/module/ (module.prop, customize.sh, service.sh, META-INF/com/google/...)
 * goes to the APK root as Java resources, so it is inside the signed APK.
 */
abstract class ModuleFilesTask : DefaultTask() {
    @get:InputDirectory
    abstract val source: DirectoryProperty

    @get:Input
    abstract val versionName: Property<String>

    @get:Input
    abstract val versionCode: Property<Int>

    @get:OutputDirectory
    abstract val output: DirectoryProperty

    @TaskAction
    fun run() {
        val out = output.get().asFile
        out.deleteRecursively()
        source.get().asFile.copyRecursively(out)
        val prop = out.resolve("module.prop")
        prop.writeText(
            prop.readText()
                .replace("@VERSION_NAME@", versionName.get())
                .replace("@VERSION_CODE@", versionCode.get().toString()),
        )
    }
}

/** LICENSE, NOTICE and LICENSES/ go into the APK's assets/licenses/ for the About screen. */
abstract class LicenseAssetsTask : DefaultTask() {
    @get:InputFiles
    abstract val sources: ConfigurableFileCollection

    @get:OutputDirectory
    abstract val output: DirectoryProperty

    @TaskAction
    fun run() {
        val out = output.get().asFile.resolve("licenses")
        out.deleteRecursively()
        out.mkdirs()
        for (f in sources.files) {
            val name = if (f.name == "LICENSE") "GPL-3.0-or-later.txt" else f.name
            f.copyTo(out.resolve(name))
        }
    }
}

androidComponents {
    onVariants { variant ->
        val licenses = tasks.register<LicenseAssetsTask>("${variant.name}LicenseAssets") {
            sources.from(
                rootProject.file("LICENSE"),
                rootProject.file("NOTICE"),
                rootProject.file("LICENSES/Apache-2.0.txt"),
            )
        }
        variant.sources.assets?.addGeneratedSourceDirectory(licenses, LicenseAssetsTask::output)
        val task = tasks.register<ModuleFilesTask>("${variant.name}ModuleFiles") {
            source.set(layout.projectDirectory.dir("src/module"))
            versionName.set(appVersionName)
            versionCode.set(appVersionCode)
        }
        variant.sources.resources?.addGeneratedSourceDirectory(task, ModuleFilesTask::output)
    }
}
