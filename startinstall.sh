#!/bin/sh
TMP_SCRIPT=$(mktemp /tmp/new-server.XXXXXX) || exit 1
trap 'rm -f "$TMP_SCRIPT"' EXIT INT TERM
if ! curl -fsSL -o "$TMP_SCRIPT" https://raw.githubusercontent.com/hummer74/new-server/main/new-server.sh; then
    echo "Download failed"
    exit 1
fi
[ -s "$TMP_SCRIPT" ] || { echo "Downloaded script is empty"; exit 1; }
bash -n "$TMP_SCRIPT" || { echo "Downloaded script is broken"; exit 1; }
if [ -c /dev/tty ]; then
    bash "$TMP_SCRIPT" "$@" </dev/tty
else
    bash "$TMP_SCRIPT" "$@"
fi