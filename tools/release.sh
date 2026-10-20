#!/usr/bin/env bash
# Release helpers used by .github/workflows/release.yml (also runnable locally).
#
#   tools/release.sh stamp <version> <build-number>   write the version into export_presets.cfg
#   tools/release.sh package <version>                pack build/<platform> outputs into dist/
#
# <version> is semver without the leading "v", e.g. 1.2.0 or 1.3.0-beta.1.
set -euo pipefail

cmd=${1:-}
version=${2:-}
[[ -n "$cmd" && -n "$version" ]] || { echo "usage: $0 stamp|package <version> [build-number]" >&2; exit 2; }
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || { echo "not a semver version: $version" >&2; exit 2; }

# Platform version fields only accept the numeric x.y.z part.
core=${version%%[-+]*}

case "$cmd" in
  stamp)
    build=${3:?build number required}
    # Edit in place without GNU/BSD sed differences.
    tmp=$(mktemp)
    awk -v core="$core" -v full="$version" -v build="$build" '
      /^application\/short_version=/   { print "application/short_version=\"" core "\""; next }
      /^application\/version=/         { print "application/version=\"" build "\""; next }
      /^application\/file_version=/    { print "application/file_version=\"" core "." build "\""; next }
      /^application\/product_version=/ { print "application/product_version=\"" core "." build "\""; next }
      /^version\/code=/                { print "version/code=" build; next }
      /^version\/name=/                { print "version/name=\"" full "\""; next }
      { print }
    ' export_presets.cfg > "$tmp"
    mv "$tmp" export_presets.cfg
    ;;

  package)
    rm -rf dist
    mkdir -p dist
    name="MeshPulse-$version"
    cp build/macos/MeshPulse.zip "dist/$name-macos-universal.zip"
    (cd build/windows && zip -q "../../dist/$name-windows-x86_64.zip" MeshPulse.exe MeshPulse.pck)
    tar -C build/linux -czf "dist/$name-linux-x86_64.tar.gz" MeshPulse.x86_64 MeshPulse.pck
    (cd build/web && zip -qr "../../dist/$name-web.zip" .)
    apk=build/android/MeshPulse-release.apk
    [[ -f "$apk" ]] || apk=build/android/MeshPulse.apk
    cp "$apk" "dist/$name-android.apk"
    (cd dist && shasum -a 256 -- * > SHA256SUMS.txt)
    ls -l dist
    ;;

  *)
    echo "unknown command: $cmd" >&2
    exit 2
    ;;
esac
