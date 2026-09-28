#!/usr/bin/env bash
set -Eeuo pipefail

# Move Steam compatdata directories from secondary libraries to the main Steam
# library and replace them with symlinks.
#
# Do not run this script as root.

if [[ "${EUID}" -eq 0 ]]; then
  echo "Do not run this script as root." >&2
  exit 1
fi

STEAM_MAIN_CANDIDATES=(
  "$HOME/.local/share/Steam"
  "$HOME/.steam/steam"
  "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
)

STEAM_VDF_CANDIDATES=(
  "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf"
  "$HOME/.steam/steam/steamapps/libraryfolders.vdf"
  "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/libraryfolders.vdf"
)

AUTO_YES=0
AUTO_ALL=0

show_help() {
  cat <<EOF
Usage: $(basename "$0") [options]

Move Steam compatdata directories from secondary libraries to the main Steam
library and replace them with symlinks.

Options:
  -a, --all      Process all detected secondary libraries
  -y, --yes      Confirm prompts automatically
  -h, --help     Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) AUTO_YES=1; shift ;;
    -a|--all) AUTO_ALL=1; shift ;;
    -h|--help) show_help; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      show_help >&2
      exit 1
      ;;
  esac
done

is_steam_running() {
  pgrep -x "steam|steamwebhelper" >/dev/null 2>&1
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local answer

  if [[ "$AUTO_YES" -eq 1 ]]; then
    return 0
  fi

  while true; do
    if [[ "$default" == "y" ]]; then
      read -r -p "$prompt [Y/n]: " answer
      answer="${answer:-y}"
    else
      read -r -p "$prompt [y/N]: " answer
      answer="${answer:-n}"
    fi

    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

find_main_library() {
  local cand dir
  for cand in "${STEAM_MAIN_CANDIDATES[@]}"; do
    if [[ -d "$cand/steamapps" ]]; then
      realpath -m "$cand"
      return 0
    fi
  done

  for cand in "${STEAM_VDF_CANDIDATES[@]}"; do
    if [[ -f "$cand" ]]; then
      dir="$(dirname "$(dirname "$cand")")"
      if [[ -d "$dir/steamapps" ]]; then
        realpath -m "$dir"
        return 0
      fi
    fi
  done

  return 1
}

find_secondary_libraries() {
  local main_lib="$1"
  local vdf path
  local -A seen=()

  for vdf in "${STEAM_VDF_CANDIDATES[@]}"; do
    [[ -f "$vdf" ]] || continue

    while IFS= read -r path; do
      path="${path//\\\\/\\}"
      path="${path/#\~/$HOME}"
      path="$(realpath -m "$path" 2>/dev/null || echo "$path")"

      if [[ -d "$path/steamapps" && "$path" != "$main_lib" ]]; then
        if [[ -z "${seen[$path]:-}" ]]; then
          seen["$path"]=1
          printf '%s\n' "$path"
        fi
      fi
    done < <(
      sed -nE \
        -e 's/^[[:space:]]*"path"[[:space:]]*"([^"]+)".*/\1/p' \
        -e 's/^[[:space:]]*"[0-9]+"[[:space:]]*"([^"/\\]*[/\\][^"]*)".*/\1/p' \
        "$vdf"
    )
  done | sort -u
}

compatdata_status() {
  local lib="$1"
  local compat="$lib/steamapps/compatdata"

  if [[ -L "$compat" ]]; then
    printf 'already symlinked -> %s' "$(readlink "$compat")"
  elif [[ -d "$compat" ]]; then
    printf 'local compatdata folder exists'
  else
    printf 'no compatdata folder yet'
  fi
}

move_directory_entries() {
  local src="$1" dest="$2"
  local item base target
  local -a to_move=()
  local -a symlinks_to_remove=()

  while IFS= read -r -d '' item; do
    base="$(basename "$item")"
    if [[ -e "$dest/$base" || -L "$dest/$base" ]]; then
      target="$(readlink "$item" 2>/dev/null || true)"
      if [[ -n "$target" ]]; then
        if [[ "$target" == "$dest/$base" || "$(realpath -m "$target")" == "$(realpath -m "$dest/$base")" ]]; then
          symlinks_to_remove+=("$item")
          continue
        fi
      fi
      echo "Conflict: '$dest/$base' already exists. Skipping library to prevent data loss." >&2
      return 1
    fi
    to_move+=("$item")
  done < <(find "$src" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

  for item in "${symlinks_to_remove[@]}"; do
    rm -f "$item"
  done

  for item in "${to_move[@]}"; do
    if ! mv "$item" "$dest/"; then
      echo "Error moving '$item' to '$dest/'" >&2
      return 1
    fi
  done

  if ! rmdir "$src"; then
    echo "Warning: could not remove empty directory '$src'" >&2
    return 1
  fi
}

migrate_library() {
  local lib="$1" dest_base="$2"
  local steamapps="$lib/steamapps"
  local compat="$steamapps/compatdata"
  local lib_steamapps main_steamapps norm_dest current_target

  echo "==> $lib"

  if [[ ! -d "$steamapps" ]]; then
    echo "Skipping: steamapps directory not found."
    return 0
  fi

  lib_steamapps="$(realpath -m "$steamapps")"
  main_steamapps="$(realpath -m "$dest_base/..")"

  if [[ "$lib_steamapps" == "$main_steamapps" ]]; then
    echo "Skipping: already main library."
    return 0
  fi

  if [[ "$main_steamapps" == "$lib_steamapps"/* || "$lib_steamapps" == "$main_steamapps"/* ]]; then
    echo "Skipping: nested library path detected."
    return 0
  fi

  norm_dest="$(realpath -m "$dest_base")"
  if [[ -e "$dest_base" && ! -d "$dest_base" ]]; then
    echo "Error: destination '$dest_base' exists and is not a directory." >&2
    return 1
  fi
  mkdir -p "$dest_base"

  # Case 1: Already a symlink
  if [[ -L "$compat" ]]; then
    current_target="$(realpath -m "$compat" 2>/dev/null || readlink -f "$compat")"
    if [[ "$current_target" == "$norm_dest" ]]; then
      echo "Already symlinked to $dest_base."
      return 0
    fi

    echo "Updating symlink from $current_target..."
    if [[ -d "$current_target" && ! -L "$current_target" ]]; then
      if ! move_directory_entries "$current_target" "$dest_base"; then
        echo "Failed to move entries from old target. Leaving symlink unchanged." >&2
        return 1
      fi
    fi

    rm -f "$compat"
    ln -s "$dest_base" "$compat"
    echo "Updated: $compat -> $dest_base"
    return 0
  fi

  # Case 2: Not a directory and not a symlink
  if [[ -e "$compat" && ! -d "$compat" ]]; then
    echo "Skipping: $compat exists and is not a directory." >&2
    return 0
  fi

  # Case 3: Existing directory
  if [[ -d "$compat" ]]; then
    echo "Moving compatdata contents to $dest_base..."
    if ! move_directory_entries "$compat" "$dest_base"; then
      echo "Failed to move compatdata. Leaving directory unchanged." >&2
      return 1
    fi
  fi

  # Create symlink
  ln -s "$dest_base" "$compat"
  echo "Done: $compat -> $dest_base"
}

main() {
  local main_lib dest_base
  local -a libraries=() selected=()
  local lib choice

  if is_steam_running; then
    echo "Warning: Steam appears to be running."
    if ! prompt_yes_no "Continue anyway?" "n"; then
      exit 0
    fi
  fi

  if ! main_lib="$(find_main_library)"; then
    echo "Error: could not find main Steam library." >&2
    exit 1
  fi
  dest_base="$main_lib/steamapps/compatdata"

  mapfile -t libraries < <(find_secondary_libraries "$main_lib")

  if (( ${#libraries[@]} == 0 )); then
    echo "No secondary Steam libraries found to move."
    exit 0
  fi

  echo "Main Steam library:"
  echo "  $main_lib"
  echo
  echo "Secondary libraries detected:"
  local i=1
  for lib in "${libraries[@]}"; do
    echo "  [$i] $lib"
    echo "      Status: $(compatdata_status "$lib")"
    echo
    ((i += 1))
  done

  if [[ "$AUTO_ALL" -eq 1 ]]; then
    selected=("${libraries[@]}")
  else
    while true; do
      read -r -p "Would you like to process ALL libraries? [y/n/q] (q: quit): " choice
      case "${choice,,}" in
        y|yes)
          selected=("${libraries[@]}")
          break
          ;;
        n|no)
          echo
          echo "Select libraries individually:"
          for lib in "${libraries[@]}"; do
            if prompt_yes_no "Process '$lib'?" "y"; then
              selected+=("$lib")
            fi
          done
          break
          ;;
        q|quit)
          echo "Cancelled."
          exit 0
          ;;
        *)
          echo "Please enter y, n, or q."
          ;;
      esac
    done
  fi

  if (( ${#selected[@]} == 0 )); then
    echo "No libraries selected. No changes applied."
    exit 0
  fi

  echo
  echo "Selected libraries for migration:"
  for lib in "${selected[@]}"; do
    echo "  - $lib"
  done
  echo

  if ! prompt_yes_no "Apply these changes?" "n"; then
    echo "Cancelled."
    exit 0
  fi

  echo
  for lib in "${selected[@]}"; do
    migrate_library "$lib" "$dest_base"
  done

  echo
  echo "Finished. You can now safely restart Steam."
}

main "$@"
