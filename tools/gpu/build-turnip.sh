#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds Mesa's Turnip (Vulkan for Adreno) with the KGSL backend, the kernel driver
# Android uses. Ubuntu's own build has only the upstream "msm" backend (Mesa's default
# freedreno-kmds=['msm'], debian/rules doesn't change it), so on Android it finds no GPU.
#
# Runs inside an amd64 ubuntu:<series> container and cross-compiles for arm64 from
# Ubuntu's own source package (same version and patches as the installed Mesa):
#   docker run --rm -v "$PWD/out:/out" -v "$PWD/tools/gpu:/gpu:ro" ubuntu:26.04 sh /gpu/build-turnip.sh
# Output in /out: turnip-kgsl-<version>-arm64.tar.gz (+ .sha256), with
#   usr/local/lib/uburoot/gpu/libvulkan_freedreno_kgsl.so
#   usr/local/share/vulkan/icd.d/uburoot_freedreno_kgsl_icd.json
set -eu
OUT=${OUT:-/out}
export DEBIAN_FRONTEND=noninteractive

# shellcheck disable=SC1091 # the container's own file
. /etc/os-release
# amd64 from archive.ubuntu.com, arm64 from ports.ubuntu.com, sources enabled.
cat >/etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb deb-src
URIs: http://archive.ubuntu.com/ubuntu/
Suites: $VERSION_CODENAME $VERSION_CODENAME-updates $VERSION_CODENAME-security
Components: main universe
Architectures: amd64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports/
Suites: $VERSION_CODENAME $VERSION_CODENAME-updates $VERSION_CODENAME-security
Components: main universe
Architectures: arm64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
dpkg --add-architecture arm64
apt-get update -q
apt-get install -y -q --no-install-recommends dpkg-dev ca-certificates \
    meson ninja-build pkg-config python3-mako python3-yaml python3-packaging \
    glslang-tools bison flex patchelf gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
    libdrm-dev:arm64 libexpat1-dev:arm64 zlib1g-dev:arm64 libzstd-dev:arm64 \
    libx11-dev:arm64 libx11-xcb-dev:arm64 libxcb1-dev:arm64 libxcb-dri3-dev:arm64 \
    libxcb-present-dev:arm64 libxcb-randr0-dev:arm64 libxcb-shm0-dev:arm64 \
    libxcb-sync-dev:arm64 libxcb-xfixes0-dev:arm64 libxshmfence-dev:arm64 \
    libxrandr-dev:arm64 libxext-dev:arm64 libxxf86vm-dev:arm64

W=/build
rm -rf "$W"
mkdir -p "$W" "$OUT"
cd "$W"
apt-get source -q mesa
SRC=$(find "$W" -maxdepth 1 -type d -name 'mesa-*' | head -n 1)
VER=$(dpkg-parsechangelog -l "$SRC/debian/changelog" -S Version)

cat >"$W/cross.txt" <<'EOF'
[binaries]
c = 'aarch64-linux-gnu-gcc'
cpp = 'aarch64-linux-gnu-g++'
ar = 'aarch64-linux-gnu-ar'
strip = 'aarch64-linux-gnu-strip'
pkg-config = 'pkg-config'

[properties]
pkg_config_libdir = '/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

meson setup "$W/b" "$SRC" --cross-file "$W/cross.txt" --buildtype=release \
    -Dprefix=/usr/local -Db_ndebug=true \
    -Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl -Dgallium-drivers= \
    -Dplatforms=x11 -Dglx=disabled -Degl=disabled -Dgles1=disabled -Dgles2=disabled \
    -Dopengl=false -Dllvm=disabled -Dvulkan-layers= -Dtools= -Dvideo-codecs= \
    -Dzstd=enabled -Dexpat=enabled -Dbuild-tests=false
ninja -C "$W/b" src/freedreno/vulkan/libvulkan_freedreno.so src/freedreno/vulkan/freedreno_icd.aarch64.json

P="$W/pkg"
mkdir -p "$P/usr/local/lib/uburoot/gpu" "$P/usr/local/share/vulkan/icd.d"
aarch64-linux-gnu-strip -o "$P/usr/local/lib/uburoot/gpu/libvulkan_freedreno_kgsl.so" \
    "$W/b/src/freedreno/vulkan/libvulkan_freedreno.so"
# Ubuntu's freedreno_icd.json names its library by the bare "libvulkan_freedreno.so":
# with our copy loaded under that SONAME, glibc hands ours back for it and every
# Vulkan app sees the GPU twice (seen on the S9). A SONAME of our own avoids it.
patchelf --set-soname libvulkan_freedreno_kgsl.so "$P/usr/local/lib/uburoot/gpu/libvulkan_freedreno_kgsl.so"
API=$(sed -n 's/.*"api_version": *"\([^"]*\)".*/\1/p' "$W/b/src/freedreno/vulkan/freedreno_icd.aarch64.json")
cat >"$P/usr/local/share/vulkan/icd.d/uburoot_freedreno_kgsl_icd.json" <<EOF
{
    "ICD": {
        "api_version": "$API",
        "library_path": "/usr/local/lib/uburoot/gpu/libvulkan_freedreno_kgsl.so"
    },
    "file_format_version": "1.0.1"
}
EOF
printf 'mesa=%s\nkmds=kgsl\n' "$VER" >"$P/usr/local/lib/uburoot/gpu/BUILDINFO"
T="turnip-kgsl-$(echo "$VER" | tr '~+:' '---')-arm64.tar.gz"
tar -C "$P" --owner=0 --group=0 --numeric-owner --sort=name --mtime=@0 -czf "$OUT/$T" usr
(cd "$OUT" && sha256sum "$T" >"$T.sha256")
echo "built $OUT/$T"
