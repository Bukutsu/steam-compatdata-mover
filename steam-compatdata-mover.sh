#!/usr/bin/env bash
set -Eeuo pipefail

# Interactive Steam compatdata mover
# Moves selected Steam library steamapps/compatdata folders into your main Steam
# library, then replaces the original compatdata folder with a symlink.
#
# Do NOT run this script with sudo.

if [[ "${EUID}" -eq 0 ]]; then
  echo "Do not run this script as root/sudo."
  echo "Run it as your normal Linux user."
  exit 1
fi

USER_NAME="${USER:-$(id -un)}"
USER_GROUP="$(id -gn)"

# --- Configuration & Globals ---
declare -a STEAM_VDF_CANDIDATES=(
  "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf"
  "$HOME/.steam/steam/steamapps/libraryfolders.vdf"
  "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/libraryfolders.vdf"
)

declare -a STEAM_MAIN_CANDIDATES=(
  "$HOME/.local/share/Steam"
  "$HOME/.steam/steam"
  "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
)

declare -a SEARCH_ROOTS=(
  "$HOME/.local/share"
  "$HOME/.steam"
  "$HOME/.var/app/com.valvesoftware.Steam/.local/share"
  "/run/media/$USER_NAME"
  "/media/$USER_NAME"
  "/mnt"
)

AUTO_YES=0
AUTO_ALL=0

show_help() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -y, --yes      Auto-confirm interactive prompts (useful for automation)
  -a, --all      Select and process all detected movable libraries (non-interactive)
  -h, --help     Show this help message and exit

EOF
}

# Parse command line options
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      AUTO_YES=1
      shift
      ;;
    -a|--all)
      AUTO_ALL=1
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      show_help >&2
      exit 1
      ;;
  esac
done

declare -A LIBS=()
declare -A LIB_SOURCES=()
declare -A VDF_FILES=()
MAIN_LIBRARY=""

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

normalize_path() {
  realpath -m "$1" 2>/dev/null || echo "$1"
}

add_library() {
  local root="$1"
  local source="$2"

  [[ -z "$root" ]] && return 0

  root="${root/#\~/$HOME}"
  root="$(normalize_path "$root")"

  if [[ -d "$root/steamapps" ]]; then
    LIBS["$root"]=1
    if [[ -n "${LIB_SOURCES[$root]:-}" ]]; then
      LIB_SOURCES["$root"]+=", $source"
    else
      LIB_SOURCES["$root"]="$source"
    fi
  fi
}

add_main_library() {
  local root="$1"
  local source="$2"

  root="${root/#\~/$HOME}"
  root="$(normalize_path "$root")"
  add_library "$root" "$source"

  if [[ -z "$MAIN_LIBRARY" && -d "$root/steamapps" ]]; then
    MAIN_LIBRARY="$root"
  fi
}

parse_libraryfolders_vdf() {
  local file="$1"

  [[ -f "$file" ]] || return 0

  file="$(normalize_path "$file")"
  if [[ -n "${VDF_FILES[$file]:-}" ]]; then
    return 0
  fi
  VDF_FILES["$file"]=1

  local base
  base="$(dirname "$(dirname "$file")")"

  add_main_library "$base" "Steam main library"

  while IFS= read -r path; do
    path="${path//\\\\/\\}"
    add_library "$path" "libraryfolders.vdf"
  done < <(
    sed -nE \
      -e 's/^[[:space:]]*"path"[[:space:]]*"([^"]+)".*/\1/p' \
      -e 's/^[[:space:]]*"[0-9]+"[[:space:]]*"([^"/\\]*[/\\][^"]*)".*/\1/p' \
      "$file"
  )
}

scan_known_steam_configs() {
  local file
  for file in "${STEAM_VDF_CANDIDATES[@]}"; do
    parse_libraryfolders_vdf "$file"
  done

  local path
  for path in "${STEAM_MAIN_CANDIDATES[@]}"; do
    add_main_library "$path" "Common Steam path"
  done
}

scan_libraryfolders_files() {
  echo
  echo "Searching likely Steam locations for libraryfolders.vdf files."

  local root
  for root in "${SEARCH_ROOTS[@]}"; do
    [[ -d "$root" ]] || continue

    echo "Searching: $root"

    while IFS= read -r -d '' libraryfolders_file; do
      parse_libraryfolders_vdf "$libraryfolders_file"
    done < <(
      find "$root" \
        -xdev \
        -maxdepth 6 \
        \( -path '*/.cache' -o -path '*/.Trash-*' -o -path 'lost+found' -o -path '*/Trash/files' \) -prune -o \
        -path '*/steamapps/libraryfolders.vdf' -type f -print0 2>/dev/null
    )
  done
}

status_for_library() {
  local lib="$1"
  local compat="$lib/steamapps/compatdata"

  if [[ -L "$compat" ]]; then
    echo "already symlinked -> $(readlink "$compat")"
  elif [[ -d "$compat" ]]; then
    echo "local compatdata folder exists"
  else
    echo "no compatdata folder yet"
  fi
}

load_selectable_libraries() {
  local -n out_ref="$1"
  local lib normalized_main

  normalized_main="$(normalize_path "$MAIN_LIBRARY")"

  mapfile -t out_ref < <(
    for lib in "${!LIBS[@]}"; do
      if [[ "$(normalize_path "$lib")" != "$normalized_main" ]]; then
        printf '%s\n' "$lib"
      fi
    done | sort
  )
}

destination_base_for_main_library() {
  if [[ -z "$MAIN_LIBRARY" ]]; then
    echo "Could not determine the main Steam library." >&2
    return 1
  fi

  normalize_path "$MAIN_LIBRARY/steamapps/compatdata"
}

ensure_native_destination_ready() {
  local dest="$1"

  if [[ -e "$dest" && ! -d "$dest" ]]; then
    echo "Destination already exists and is not a directory:"
    echo "  $dest"
    return 1
  fi

  mkdir -p "$dest"
}

move_directory_entries() {
  local src="$1"
  local dest="$2"
  local item base
  local -a entries=()

  while IFS= read -r -d '' item; do
    base="$(basename "$item")"
    if [[ -e "$dest/$base" || -L "$dest/$base" ]]; then
      local target
      target="$(readlink "$item" 2>/dev/null || echo "")"
      if [[ -n "$target" ]]; then
        local norm_target norm_dest_item
        norm_target="$(normalize_path "$target")"
        norm_dest_item="$(normalize_path "$dest/$base")"
        if [[ "$norm_target" == "$norm_dest_item" ]]; then
          rm -f "$item"
          continue
        fi
      fi
      return 1
    fi
    entries+=("$item")
  done < <(find "$src" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

  for item in "${entries[@]}"; do
    if ! mv "$item" "$dest/"; then
      echo "Error: Failed to move $item to $dest/" >&2
      return 1
    fi
  done

  if ! rmdir "$src"; then
    echo "Warning: Could not remove empty source directory $src" >&2
  fi
}

fix_ownership_if_needed() {
  local target="$1"
  local quiet="${2:-0}"

  if [[ ! -e "$target" || -O "$target" || "$quiet" -eq 1 ]]; then
    return 0
  fi

  echo
  echo "The moved compatdata is not owned by your current user."
  echo "Target: $target"

  if command -v sudo >/dev/null 2>&1; then
    if prompt_yes_no "Use sudo to chown it to $USER_NAME:$USER_GROUP?" "y"; then
      sudo chown -R "$USER_NAME:$USER_GROUP" "$target"
    fi
  else
    echo "sudo was not found. You may need to run manually:"
    echo "  sudo chown -R '$USER_NAME:$USER_GROUP' '$target'"
  fi
}

check_disk_space() {
  local src="$1"
  local dest="$2"

  if [[ ! -d "$src" ]]; then
    return 0
  fi

  local src_size=0
  if command -v du >/dev/null 2>&1; then
    local du_out
    du_out="$(du -sk "$src" 2>/dev/null || echo "")"
    if [[ -n "$du_out" ]]; then
      src_size=$(echo "$du_out" | awk '{print $1 * 1024}')
    fi
  fi

  local dest_avail=0
  if command -v df >/dev/null 2>&1; then
    local df_out
    df_out="$(df -Pk "$dest" 2>/dev/null | tail -n 1 || echo "")"
    if [[ -n "$df_out" ]]; then
      dest_avail=$(echo "$df_out" | awk '{print $4 * 1024}')
    fi
  fi

  if (( src_size == 0 || dest_avail == 0 )); then
    return 0
  fi

  # 50MB safety margin
  local required=$((src_size + 52428800))

  if (( dest_avail < required )); then
    local src_size_mb=$((src_size / 1048576))
    local dest_avail_mb=$((dest_avail / 1048576))
    echo "Error: Not enough disk space on destination filesystem." >&2
    echo "  Required (with margin): ${src_size_mb} MB" >&2
    echo "  Available:             ${dest_avail_mb} MB" >&2
    return 1
  fi

  return 0
}

move_library_compatdata() {
  local lib="$1"
  local dest_base="$2"
  local quiet="${3:-0}"

  local steamapps="$lib/steamapps"
  local compat="$steamapps/compatdata"
  local dest="$dest_base"

  if [[ "$quiet" -eq 0 ]]; then
    echo
    echo "Library:    $lib"
    echo "Compatdata: $compat"
  fi

  if [[ ! -d "$steamapps" ]]; then
    if [[ "$quiet" -eq 0 ]]; then
      echo "Skipping: steamapps folder does not exist."
    fi
    printf 'skipped: no steamapps for %s\n' "$lib"
    return 0
  fi

  # Check for recursion/nested path issues
  local norm_compat norm_dest
  norm_compat="$(normalize_path "$compat")"
  norm_dest="$(normalize_path "$dest")"
  if [[ "$norm_dest" == "$norm_compat"/* || "$norm_compat" == "$norm_dest"/* ]]; then
    if [[ "$quiet" -eq 0 ]]; then
      echo "Skipping: nested library path detected between source and destination."
    fi
    printf 'skipped: nested path for %s\n' "$lib"
    return 0
  fi

  if [[ "$norm_compat" == "$norm_dest" ]]; then
    if [[ "$quiet" -eq 0 ]]; then
      echo "Skipping: this is already the native main library compatdata folder."
    fi
    mkdir -p "$dest"
    printf 'skipped: already native main library for %s\n' "$lib"
    return 0
  fi

  if [[ -L "$compat" ]]; then
    local current_target
    current_target="$(readlink "$compat")"
    if [[ "$current_target" != /* ]]; then
      current_target="$(dirname "$compat")/$current_target"
    fi

    if [[ "$(normalize_path "$current_target")" == "$norm_dest" ]]; then
      if [[ "$quiet" -eq 0 ]]; then
        echo "Skipping: compatdata is already symlinked to the correct destination."
      fi
      printf 'skipped: already symlinked for %s\n' "$lib"
      return 0
    fi

    if [[ "$quiet" -eq 0 ]]; then
      echo "Existing symlink points to a different destination:"
      echo "  Current: $current_target"
      echo "  Target:  $dest"
    fi

    if [[ -d "$current_target" && ! -L "$current_target" ]]; then
      if ! check_disk_space "$current_target" "$dest"; then
        printf 'skipped: insufficient disk space for %s\n' "$lib"
        return 0
      fi

      if [[ "$quiet" -eq 0 ]]; then
        echo "Moving files from old target to new destination..."
      fi
      ensure_native_destination_ready "$dest"
      if ! move_directory_entries "$current_target" "$dest"; then
        if [[ "$quiet" -eq 0 ]]; then
          echo "Warning: failed to move all entries from old target. Skipping link update."
        fi
        printf 'skipped: old target conflict for %s\n' "$lib"
        return 0
      fi
    fi

    if [[ "$quiet" -eq 0 ]]; then
      echo "Updating symlink..."
    fi
    rm -f "$compat"
    ln -s "$dest" "$compat"
    printf 'updated: %s\n' "$lib"
    return 0
  fi

  if [[ -e "$compat" && ! -d "$compat" ]]; then
    if [[ "$quiet" -eq 0 ]]; then
      echo "Skipping: compatdata exists but is not a directory."
    fi
    printf 'skipped: compatdata not a directory for %s\n' "$lib"
    return 0
  fi

  if ! ensure_native_destination_ready "$dest"; then
    if [[ "$quiet" -eq 0 ]]; then
      echo "Skipping this library to avoid overwriting data."
    fi
    printf 'skipped: destination not ready for %s\n' "$lib"
    return 0
  fi

  if [[ -d "$compat" ]]; then
    if ! check_disk_space "$compat" "$dest"; then
      printf 'skipped: insufficient disk space for %s\n' "$lib"
      return 0
    fi

    if [[ "$quiet" -eq 0 ]]; then
      echo "Moving compatdata..."
    fi
    if ! move_directory_entries "$compat" "$dest"; then
      if [[ "$quiet" -eq 0 ]]; then
        echo "Skipping this library to avoid overwriting data."
      fi
      printf 'skipped: destination conflict for %s\n' "$lib"
      return 0
    fi
  else
    if [[ "$quiet" -eq 0 ]]; then
      echo "No compatdata folder exists yet; using native main compatdata folder."
    fi
  fi

  if [[ "$quiet" -eq 0 ]]; then
    echo "Creating symlink..."
  fi
  ln -s "$dest" "$compat"

  fix_ownership_if_needed "$dest" "$quiet"

  if [[ "$quiet" -eq 0 ]]; then
    echo "Done: $compat -> $dest"
  fi
  printf 'moved: %s\n' "$lib"
}

run_text_flow() {
  local DEST_BASE
  local -a libraries=()
  local -a selected=()
  local result
  local lib

  echo "Steam compatdata mover"
  echo "======================"
  echo "This script moves Proton prefixes (compatdata) from secondary libraries"
  echo "to your main Linux library and replaces them with symbolic links."
  echo "This fixes Wine/Proton launch errors on NTFS partitions."
  echo
  echo "Important: Close Steam before continuing."
  echo

  if ! prompt_yes_no "Continue?" "n"; then
    echo "Cancelled."
    exit 0
  fi

  scan_known_steam_configs
  scan_libraryfolders_files

  load_selectable_libraries libraries

  if (( ${#libraries[@]} == 0 )); then
    echo
    echo "No secondary Steam libraries found to move."
    exit 0
  fi

  if ! DEST_BASE="$(destination_base_for_main_library)"; then
    exit 1
  fi

  echo
  echo "Main Steam library:"
  echo "  $MAIN_LIBRARY"
  echo
  echo "Secondary libraries detected:"
  local i=1
  for lib in "${libraries[@]}"; do
    echo "  [$i] $lib"
    echo "      Source: ${LIB_SOURCES[$lib]}"
    echo "      Status: $(status_for_library "$lib")"
    echo
    ((i += 1))
  done

  # Determine selection
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
          echo "Please select libraries individually:"
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

  mkdir -p "$DEST_BASE"

  for lib in "${selected[@]}"; do
    result="$(move_library_compatdata "$lib" "$DEST_BASE" 0)"
    echo "$result"
  done

  echo
  echo "Finished successfully!"
  echo "You can now safely restart Steam."
}

is_steam_running() {
  if pgrep -x "steam" >/dev/null 2>&1 || pgrep -x "steamwebhelper" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

main() {
  if is_steam_running; then
    echo "Warning: Steam appears to be running."
    if ! prompt_yes_no "Are you sure you want to continue?" "n"; then
      exit 0
    fi
  fi

  run_text_flow
}

main "$@"
