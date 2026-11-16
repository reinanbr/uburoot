// SPDX-License-Identifier: GPL-3.0-or-later
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // Only the Termux terminal libraries and libsu come from JitPack.
        maven("https://jitpack.io") {
            content {
                includeGroup("com.github.termux.termux-app")
                includeGroup("com.github.topjohnwu.libsu")
            }
        }
    }
}

rootProject.name = "UbuRoot"
include(":app")
