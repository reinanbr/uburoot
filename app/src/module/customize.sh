# shellcheck shell=sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Sourced by the Magisk / KernelSU / APatch module installer (not executed).
# This zip is also the UbuRoot APK: extract only the module scripts, never
# the app's dex/resources/libs.
# shellcheck disable=SC2034
SKIPUNZIP=1

# With SKIPUNZIP=1 the installer leaves module.prop to us as well.
unzip -o "$ZIPFILE" module.prop service.sh -d "$MODPATH" >&2 || abort "! Unable to extract the module files"
set_perm "$MODPATH/service.sh" 0 0 0755

# Keep a copy of the app. If Android is running (flashed from a root manager
# app) install it right away; from recovery there is no package manager, so
# service.sh installs it on the next boot.
cp -f "$ZIPFILE" "$MODPATH/uburoot.apk" || abort "! Unable to copy the app"
set_perm "$MODPATH/uburoot.apk" 0 0 0644
if [ "$BOOTMODE" = true ]; then
    ui_print "- Installing the UbuRoot app"
    if sh "$MODPATH/service.sh" --install-now; then
        ui_print "- App installed"
    else
        ui_print "- The app will be installed on the next boot"
    fi
else
    ui_print "- The app will be installed on the next boot"
fi
