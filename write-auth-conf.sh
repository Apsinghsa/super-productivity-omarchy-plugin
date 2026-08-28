#!/bin/bash
# Securely write the curl auth config file for the Super Productivity plugin.
#
# Usage: write-auth-conf.sh <dir> <final-path>
#
# The bearer token is read from stdin (a single line), never from argv, so it
# cannot be observed through /proc/<pid>/cmdline.
#
# The config is written with exclusive, random-name, no-follow semantics:
#   1. <dir> is created if needed and verified private (0700, owned by us,
#      not a symlink) -- refusal if that cannot be established.
#   2. Content goes to a fresh `mktemp` file (0600, O_EXCL random name).
#   3. The file is fsynced, then atomically renamed over <final-path>.
#      rename(2) replaces a symlink at the target instead of following it.
set -eu

DIR=${1:-}
OUT=${2:-}
[ -n "$DIR" ] && [ -n "$OUT" ] || { echo "usage: write-auth-conf.sh <dir> <final-path>" >&2; exit 1; }

# Token arrives as one line. Timeout so a stuck pipe cannot leak a process.
IFS= read -r -t 2 TOKEN || exit 1

# Strict token format: 8-128 chars of [A-Za-z0-9_.-]. This rejects quotes,
# newlines, NUL and every other control, so nothing can inject additional
# curl config directives or escape the quoted header value.
case "$TOKEN" in
  *[!A-Za-z0-9_.-]*) echo "token rejected: contains characters outside [A-Za-z0-9_.-]" >&2; exit 1 ;;
esac
[ "${#TOKEN}" -ge 8 ] && [ "${#TOKEN}" -le 128 ] || { echo "token rejected: length must be 8-128" >&2; exit 1; }

if [ ! -d "$DIR" ]; then
  mkdir -p "$DIR" || { echo "refusing: cannot create $DIR" >&2; exit 1; }
fi
[ ! -L "$DIR" ] || { echo "refusing: $DIR is a symlink" >&2; exit 1; }
[ "$(stat -c %u "$DIR")" = "$(id -u)" ] || { echo "refusing: $DIR is not owned by us" >&2; exit 1; }
chmod 700 "$DIR" || { echo "refusing: cannot make $DIR private" >&2; exit 1; }
[ ! -d "$OUT" ] || { echo "refusing: $OUT is a directory" >&2; exit 1; }

TMP=$(mktemp "$DIR/.auth.XXXXXX") || { echo "refusing: cannot create temp file in $DIR" >&2; exit 1; }
trap 'rm -f "$TMP"' EXIT HUP INT TERM

umask 077
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$TMP" || exit 1
sync "$TMP" || exit 1
mv -f "$TMP" "$OUT" || exit 1
sync -d "$DIR" 2>/dev/null || true
trap - EXIT HUP INT TERM