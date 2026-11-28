#!/bin/sh
# Synchronize one verified local recovery kit, then install from it.
set -eu
umask 077
BASE="${SIBOOT_BASE:-__SIBOOT_PRIMARY__}"
MIRRORS="${SIBOOT_MIRRORS-__SIBOOT_SECONDARY__}"
EXPECTED='__SIBOOT_PACKAGE_SHA256__'
ENTRY_EXPECTED='__SIBOOT_LOCAL_ENTRY_SHA256__'
IPA_EXPECTED='__SIBOOT_IPA_SHA256__'
INSTALLER_EXPECTED='__SIBOOT_INSTALLER_SHA256__'
BUILD='__SIBOOT_BUILD__'
ARCHIVE='LiveContainer-triple-local.zip'
PACKAGE_DIR="${SIBOOT_PACKAGE_DIR:-/var/minis/mounts/livecontainer}"
RETRIES="${SIBOOT_RETRIES:-3}"
RETRY_DELAY="${SIBOOT_RETRY_DELAY:-2}"
stage=
locked=0
fail() { printf '%s\n' "$1" >&2; exit 1; }
cleanup() {
  [ -z "$stage" ] || rm -rf "$stage"
  if [ "$locked" = 1 ]; then rm -f "$PACKAGE_DIR/.livecontainer-write-lock/owner.json"; rmdir "$PACKAGE_DIR/.livecontainer-write-lock" 2>/dev/null || true; fi
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
case "$(uname -m)" in aarch64|arm64) ;; *) fail 'Run this in Open Minis on iPhone or iPad.' ;; esac
case "$RETRIES:$RETRY_DELAY" in [1-9]:[0-9]) ;; *) fail 'Invalid retry settings.' ;; esac
command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum is required.'
command -v unzip >/dev/null 2>&1 || fail 'unzip is required.'
[ -d "$PACKAGE_DIR" ] || fail 'Mount the livecontainer folder in Open Minis first, or set SIBOOT_PACKAGE_DIR to an existing mounted folder.'
PACKAGE_DIR=$(CDPATH= cd -- "$PACKAGE_DIR" && pwd)
mkdir "$PACKAGE_DIR/.livecontainer-write-lock" 2>/dev/null || fail 'Another save is in progress. If it was interrupted, remove only .livecontainer-write-lock in this folder and retry.'
locked=1
printf '{"kind":"cloud","pid":%s,"createdAt":%s}\n' "$$" "$(date +%s)" > "$PACKAGE_DIR/.livecontainer-write-lock/owner.json"
matches() { [ -f "$1" ] && [ "$(sha256sum "$1" | cut -d ' ' -f 1)" = "$2" ]; }
fetch() {
  case "$1" in https://*|http://127.0.0.1:*/*) ;; *) fail 'Use an HTTPS mirror address.' ;; esac
  if command -v curl >/dev/null 2>&1; then
    curl -fL --connect-timeout 10 --max-time 300 --speed-time 30 --speed-limit 1024 --output "$stage/$ARCHIVE" "$1"
  else
    wget -T 30 -O "$stage/$ARCHIVE" "$1"
  fi
}
download() {
  for origin in "$BASE" $MIRRORS; do
    attempt=1
    while [ "$attempt" -le "$RETRIES" ]; do
      printf 'Downloading build %s, attempt %s/%s\n' "$BUILD" "$attempt" "$RETRIES"
      if fetch "${origin%/}/$ARCHIVE" && matches "$stage/$ARCHIVE" "$EXPECTED"; then return 0; fi
      attempt=$((attempt + 1))
      [ "$attempt" -gt "$RETRIES" ] || sleep "$RETRY_DELAY"
    done
  done
  return 1
}
verified_local_zip() {
  [ -f "$PACKAGE_DIR/$ARCHIVE" ] || return 1
  cp "$PACKAGE_DIR/$ARCHIVE" "$stage/$ARCHIVE" || return 1
  unzip -p "$stage/$ARCHIVE" 'siboot-local/assets/LiveContainer+SideStore+SideInstaller.ipa' > "$stage/local-ipa" || return 1
  unzip -p "$stage/$ARCHIVE" siboot-local/install.sh > "$stage/local-installer" || return 1
  unzip -p "$stage/$ARCHIVE" siboot-local/install-local.sh > "$stage/local-entry" || return 1
  matches "$stage/local-ipa" "$IPA_EXPECTED" && matches "$stage/local-installer" "$INSTALLER_EXPECTED" && matches "$stage/local-entry" "$ENTRY_EXPECTED"
}
stage="$PACKAGE_DIR/.livecontainer-pending-cloud"
[ ! -L "$stage" ] || fail 'The pending recovery directory cannot be a symlink.'
[ ! -e "$stage" ] || rm -rf "$stage"
mkdir "$stage"
if matches "$PACKAGE_DIR/$ARCHIVE" "$EXPECTED"; then
  archive="$PACKAGE_DIR/$ARCHIVE"
  printf '%s\n' 'Using the verified local ZIP; no download needed.'
elif verified_local_zip; then
  archive="$stage/$ARCHIVE"
  printf '%s\n' 'Using the locally saved IPA and matching installer; no download needed.'
elif [ -n "${SIBOOT_ARCHIVE:-}" ]; then
  matches "$SIBOOT_ARCHIVE" "$EXPECTED" || fail 'The selected local ZIP does not match this update.'
  cp "$SIBOOT_ARCHIVE" "$stage/$ARCHIVE"
  archive="$stage/$ARCHIVE"
else
  download || fail 'Could not download a valid package; the previous local kit was kept.'
  archive="$stage/$ARCHIVE"
fi
unzip -p "$archive" siboot-local/install-local.sh > "$stage/install-local.sh" || fail 'The local entry is missing.'
unzip -p "$archive" 'siboot-local/assets/LiveContainer+SideStore+SideInstaller.ipa' > "$stage/LiveContainer+SideStore+SideInstaller.ipa" || fail 'The IPA is missing.'
matches "$stage/install-local.sh" "$ENTRY_EXPECTED" || fail 'The local entry did not match the release.'
matches "$stage/LiveContainer+SideStore+SideInstaller.ipa" "$IPA_EXPECTED" || fail 'The IPA did not match the release.'
mv -f "$stage/LiveContainer+SideStore+SideInstaller.ipa" "$PACKAGE_DIR/LiveContainer+SideStore+SideInstaller.ipa"
mv -f "$stage/install-local.sh" "$PACKAGE_DIR/install-local.sh"
# The ZIP is the commit point: the local entry reads only this complete file.
if [ "$archive" != "$PACKAGE_DIR/$ARCHIVE" ]; then mv -f "$archive" "$PACKAGE_DIR/$ARCHIVE"; fi
printf 'Saved build %s in: %s\n' "$BUILD" "$PACKAGE_DIR"
cleanup
stage=
locked=0
exec sh "$PACKAGE_DIR/install-local.sh" "$@"
