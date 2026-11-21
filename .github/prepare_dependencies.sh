#!/bin/sh
set -eu

if [ -f Dependencies/OpenSSL.xcframework/Info.plist ]; then
    exit 0
fi

mkdir -p Dependencies
dependency_tmp=$(mktemp -d)
trap 'rm -rf "$dependency_tmp"' EXIT HUP INT TERM
curl --fail --location --retry 3 --connect-timeout 20 --max-time 300 \
    --output "$dependency_tmp/OpenSSL.xcframework.zip" \
    https://github.com/krzyzanowskim/OpenSSL/releases/download/3.6.5000/OpenSSL.xcframework.zip
unzip -q "$dependency_tmp/OpenSSL.xcframework.zip" -d "$dependency_tmp"
test -f "$dependency_tmp/OpenSSL.xcframework/Info.plist"
mv "$dependency_tmp/OpenSSL.xcframework" Dependencies/OpenSSL.xcframework
