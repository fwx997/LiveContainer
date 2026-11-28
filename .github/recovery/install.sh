#!/bin/sh
# Prepared from the validated package; no payload download takes place here.
set -eu
umask 077
build='__BUILD__'
ipa_hash='__IPA_SHA256__'
core_hash='__CORE_SHA256__'
ipa_entry='Payload/LiveContainer.app/Recovery/siboot-aarch64'
state="${SIBOOT_HOME:-$HOME/.siboot}"
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_ipa="$source_dir/assets/LiveContainer+SideStore+SideInstaller.ipa"
stage=
child=
lock_owned=0
fail() { printf '%s\n' "$1" >&2; exit 1; }
matches() { [ -f "$1" ] && [ "$(sha256sum "$1" | cut -d ' ' -f 1)" = "$2" ]; }
cleanup() {
  if [ -n "$child" ]; then kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
  [ -z "$stage" ] || rm -rf "$stage"
  if [ "$lock_owned" = 1 ]; then rm -f "$state/recovery.lock/pid" "$state/recovery.lock/core.pid"; rmdir "$state/recovery.lock" 2>/dev/null || true; fi
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
mkdir -p "$state/bin" "$state/recovery-work"
state=$(CDPATH= cd -- "$state" && pwd)
if ! mkdir "$state/recovery.lock" 2>/dev/null; then
  owner=$(cat "$state/recovery.lock/pid" 2>/dev/null || true)
  case "$owner" in ''|*[!0-9]*) fail 'Another installation is preparing its lock. Retry shortly.' ;; esac
  kill -0 "$owner" 2>/dev/null && fail 'Another installation is running.'
  core_pid=$(cat "$state/recovery.lock/core.pid" 2>/dev/null || true)
  case "$core_pid" in ''|*[!0-9]*) ;; *) kill -0 "$core_pid" 2>/dev/null && fail 'The previous signing process is still running.' ;; esac
  rm -f "$state/recovery.lock/pid" "$state/recovery.lock/core.pid"
  rmdir "$state/recovery.lock" || fail 'Cannot recover the previous installation lock.'
  mkdir "$state/recovery.lock"
fi
lock_owned=1
printf '%s\n' "$$" > "$state/recovery.lock/pid"
for abandoned in "$state"/recovery-stage.*; do
  [ -d "$abandoned" ] && [ ! -L "$abandoned" ] || continue
  [ -f "$abandoned/.lc-recovery-stage" ] || continue
  rm -rf "$abandoned"
done
matches "$source_ipa" "$ipa_hash" || fail 'The local IPA is incomplete; the previous cache was kept.'
stage=$(mktemp -d "$state/recovery-stage.XXXXXX")
printf '%s\n' 'livecontainer-recovery-v1' > "$stage/.lc-recovery-stage"
cp "$source_ipa" "$stage/LiveContainer+SideStore+SideInstaller.ipa"
unzip -p "$source_ipa" "$ipa_entry" > "$stage/siboot-core" || fail 'The IPA has no complete recovery installer.'
matches "$stage/siboot-core" "$core_hash" || fail 'The embedded installer failed verification.'
matches "$stage/LiveContainer+SideStore+SideInstaller.ipa" "$ipa_hash" || fail 'The cached IPA failed verification.'
chmod 755 "$stage/siboot-core"
cat > "$stage/runner.sh" <<'RUNNER'
#!/bin/sh
set -eu
umask 077
cache=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
state=$(CDPATH= cd -- "$cache/.." && pwd)
core="$cache/siboot-core"
ipa="$cache/LiveContainer+SideStore+SideInstaller.ipa"
work=
child=
locked=0
inherited=0
cleanup() {
  if [ -n "$child" ]; then kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
  [ -z "$work" ] || rm -rf "$work"
  if [ "$locked" = 1 ] || [ "$inherited" = 1 ]; then rm -f "$state/recovery.lock/core.pid"; fi
  if [ "$locked" = 1 ]; then rm -f "$state/recovery.lock/pid"; rmdir "$state/recovery.lock" 2>/dev/null || true; fi
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
owner=$(cat "$state/recovery.lock/pid" 2>/dev/null || true)
if [ -n "${SIBOOT_RECOVERY_LOCK_PID:-}" ] && [ "$owner" = "$SIBOOT_RECOVERY_LOCK_PID" ] && kill -0 "$owner" 2>/dev/null; then
  inherited=1 # The preparing installer owns this lock while it waits for us.
elif mkdir "$state/recovery.lock" 2>/dev/null; then
  locked=1
else
  owner=$(cat "$state/recovery.lock/pid" 2>/dev/null || true)
  case "$owner" in ''|*[!0-9]*) echo 'Installation lock is being prepared; retry shortly.' >&2; exit 1 ;; esac
  kill -0 "$owner" 2>/dev/null && { echo 'Another installation is running.' >&2; exit 1; }
  core_pid=$(cat "$state/recovery.lock/core.pid" 2>/dev/null || true)
  case "$core_pid" in ''|*[!0-9]*) ;; *) kill -0 "$core_pid" 2>/dev/null && { echo 'The previous signing process is still running.' >&2; exit 1; } ;; esac
  rm -f "$state/recovery.lock/pid" "$state/recovery.lock/core.pid"
  rmdir "$state/recovery.lock"
  mkdir "$state/recovery.lock"
  locked=1
fi
if [ "$locked" = 1 ]; then printf '%s\n' "$$" > "$state/recovery.lock/pid"; fi
(cd "$cache" && sha256sum -c SHA256SUMS) || { echo 'The cached installer or IPA is corrupt.' >&2; exit 1; }
mkdir -p "$state/recovery-work"
# Only our own future signing workspace is managed here.
for old in "$state"/recovery-work/sign.*; do
  [ -d "$old" ] && [ ! -L "$old" ] || continue
  rm -rf "$old"
done
work=$(mktemp -d "$state/recovery-work/sign.XXXXXX")
export TMPDIR="$work"
printf 'Installing locally: %s\n' '__BUILD__'
if [ -r /dev/tty ] && (: < /dev/tty) 2>/dev/null; then
  "$core" --home "$state" --ipa "$ipa" "$@" < /dev/tty &
else
  "$core" --home "$state" --ipa "$ipa" "$@" <&0 &
fi
child=$!
printf '%s\n' "$child" > "$state/recovery.lock/core.pid"
status=0
wait "$child" || status=$?
child=
exit "$status"
RUNNER
printf '%s  %s\n' "$ipa_hash" 'LiveContainer+SideStore+SideInstaller.ipa' "$core_hash" 'siboot-core' > "$stage/SHA256SUMS"
printf '%s\n' "$build" > "$stage/build.txt"
old="$state/recovery-previous"
if [ -d "$old" ] && [ ! -e "$state/recovery-current" ]; then mv "$old" "$state/recovery-current"; fi
[ ! -e "$old" ] || rm -rf "$old"
if [ -e "$state/recovery-current" ]; then mv "$state/recovery-current" "$old"; fi
if ! mv "$stage" "$state/recovery-current"; then
  [ ! -e "$old" ] || mv "$old" "$state/recovery-current"
  fail 'Could not replace the recovery cache; the previous copy was restored.'
fi
stage=
cat > "$state/bin/siboot.pending" <<'LAUNCHER'
#!/bin/sh
set -eu
launcher=$(readlink -f "$0")
state=$(CDPATH= cd -- "$(dirname -- "$launcher")/.." && pwd)
exec sh "$state/recovery-current/runner.sh" "$@"
LAUNCHER
chmod 755 "$state/bin/siboot.pending"
mv -f "$state/bin/siboot.pending" "$state/bin/siboot"
[ ! -e "$old" ] || rm -rf "$old"
link_dir="${SIBOOT_LINK_DIR-/usr/local/bin}"
if [ -n "$link_dir" ]; then ln -sf "$state/bin/siboot" "$link_dir/siboot" 2>/dev/null || true; fi
printf 'Local recovery cache ready: %s\n' "$build"
if [ "${SIBOOT_PREPARE_ONLY:-0}" = 1 ]; then exit 0; fi
SIBOOT_RECOVERY_LOCK_PID="$$" sh "$state/bin/siboot" "$@" <&0 &
child=$!
status=0
wait "$child" || status=$?
child=
exit "$status"
