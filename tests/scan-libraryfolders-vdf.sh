#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_HOME="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_HOME"
}
trap cleanup EXIT

export HOME="$TMP_HOME/home"
mkdir -p "$HOME"

source_file="$TMP_HOME/source.sh"
sed '/^main "\$@"$/d' "$REPO_ROOT/steam-compatdata-mover.sh" > "$source_file"
# shellcheck source=/dev/null
source "$source_file"

mount_root="$TMP_HOME/mount"
steam_root="$mount_root/SteamRoot"
library="$mount_root/Games/SteamLibrary"

mkdir -p "$steam_root/steamapps" "$library/steamapps"
cat > "$steam_root/steamapps/libraryfolders.vdf" <<EOF
"libraryfolders"
{
  "1"
  {
    "path" "$library"
  }
}
EOF

get_mounts() {
  printf '%s\n' "$mount_root"
}

scan_all_mounted_drives >/dev/null

if [[ "${LIBS[$library]:-}" != "1" ]]; then
  echo "Expected scan to discover library from libraryfolders.vdf: $library" >&2
  exit 1
fi

if [[ "${LIB_SOURCES[$library]:-}" != *"libraryfolders.vdf"* ]]; then
  echo "Expected library source to mention libraryfolders.vdf; got: ${LIB_SOURCES[$library]:-missing}" >&2
  exit 1
fi
