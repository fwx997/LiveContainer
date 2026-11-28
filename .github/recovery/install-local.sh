#!/bin/sh
# The same local entry works with every complete recovery ZIP.
set -eu
umask 077
folder=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
archive="$folder/LiveContainer-triple-local.zip"
state="${SIBOOT_HOME:-$HOME/.siboot}"
work=
child=
fail() { printf '%s\n' "$1" >&2; exit 1; }
cleanup() {
  if [ -n "$child" ]; then kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
  [ -z "$work" ] || rm -rf "$work"
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
case "$(uname -m)" in aarch64|arm64) ;; *) fail 'Run this in Open Minis on iPhone or iPad.' ;; esac
[ -f "$archive" ] || fail 'Put LiveContainer-triple-local.zip beside install-local.sh.'
command -v unzip >/dev/null 2>&1 || fail 'unzip is required.'
command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum is required.'
mkdir -p "$state/recovery-work"
# Only reclaim workspaces created by this entry after their owner has exited.
for abandoned in "$state"/recovery-work/import.*; do
  [ -d "$abandoned" ] && [ ! -L "$abandoned" ] || continue
  owner=$(cat "$abandoned/owner.pid" 2>/dev/null || true)
  case "$owner" in ''|*[!0-9]*) continue ;; esac
  kill -0 "$owner" 2>/dev/null || rm -rf "$abandoned"
done
work=$(mktemp -d "$state/recovery-work/import.XXXXXX")
printf '%s\n' "$$" > "$work/owner.pid"
cp "$archive" "$work/archive.zip"
archive="$work/archive.zip"
for name in install.sh SHA256SUMS assets/LiveContainer+SideStore+SideInstaller.ipa; do
  mkdir -p "$work/$(dirname -- "$name")"
  unzip -p "$archive" "siboot-local/$name" > "$work/$name" || fail 'The local recovery ZIP is incomplete.'
done
script_sum=0
ipa_sum=0
while read -r checksum name extra; do
  [ "${#checksum}" = 64 ] && [ -z "$extra" ] || fail 'Invalid recovery checksum entry.'
  case "$checksum" in *[!0-9a-f]*) fail 'Invalid recovery checksum value.' ;; esac
  case "$name" in
    install.sh) script_sum=$((script_sum + 1)) ;;
    assets/LiveContainer+SideStore+SideInstaller.ipa) ipa_sum=$((ipa_sum + 1)) ;;
    *) fail 'Unexpected recovery checksum filename.' ;;
  esac
done < "$work/SHA256SUMS"
[ "$script_sum" = 1 ] && [ "$ipa_sum" = 1 ] || fail 'Incomplete recovery checksums.'
(cd "$work" && sha256sum -c SHA256SUMS) || fail 'Local files failed verification; the existing cache was kept.'
sh "$work/install.sh" "$@" <&0 &
child=$!
status=0
wait "$child" || status=$?
child=
exit "$status"
