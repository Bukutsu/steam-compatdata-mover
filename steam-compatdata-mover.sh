#!/usr/bin/env bash
set -Eeuo pipefail

# Interactive Steam compatdata mover
# Moves selected Steam library steamapps/compatdata folders into your home directory,
# then replaces the original compatdata folder with a symlink.
#
# Do NOT run this script with sudo.
# Run Steam normally after using it.

if [[ "${EUID}" -eq 0 ]]; then
  echo "Do not run this script as root/sudo."
  echo "Run it as your normal Linux user."
  exit 1
fi

USER_NAME="${USER:-$(id -un)}"
USER_GROUP="$(id -gn)"
DEST_BASE_DEFAULT="$HOME/.steam-compatdata-libraries"

declare -A LIBS=()
declare -A LIB_SOURCES=()

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local answer

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
  local path="$1"

  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$path" 2>/dev/null || printf '%s\n' "$path"
  else
    printf '%s\n' "$path"
  fi
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

parse_libraryfolders_vdf() {
  local file="$1"

  [[ -f "$file" ]] || return 0

  local base
  base="$(dirname "$(dirname "$file")")"

  add_library "$base" "Steam main library"

  while IFS= read -r path; do
    path="${path//\\\\/\\}"
    add_library "$path" "libraryfolders.vdf"
  done < <(
    sed -nE \
      -e 's/^[[:space:]]*"path"[[:space:]]*"([^"]+)".*/\1/p' \
      -e 's/^[[:space:]]*"[0-9]+"[[:space:]]*"([^"]+)".*/\1/p' \
      "$file"
  )
}

scan_known_steam_configs() {
  local candidates=(
    "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf"
    "$HOME/.steam/steam/steamapps/libraryfolders.vdf"
    "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/libraryfolders.vdf"
  )

  local file
  for file in "${candidates[@]}"; do
    parse_libraryfolders_vdf "$file"
  done

  add_library "$HOME/.local/share/Steam" "common Steam path"
  add_library "$HOME/.steam/steam" "common Steam path"
  add_library "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam" "Flatpak Steam path"
}

get_mounts() {
  if command -v findmnt >/dev/null 2>&1; then
    findmnt -rn -o TARGET,FSTYPE |
      awk '
        $2 !~ /^(proc|sysfs|devtmpfs|devpts|tmpfs|securityfs|cgroup|cgroup2|pstore|efivarfs|mqueue|hugetlbfs|debugfs|tracefs|fusectl|configfs|overlay|squashfs|autofs|binfmt_misc|rpc_pipefs)$/ {
          print $1
        }
      '
  else
    awk '
      $3 !~ /^(proc|sysfs|devtmpfs|devpts|tmpfs|securityfs|cgroup|cgroup2|pstore|efivarfs|mqueue|hugetlbfs|debugfs|tracefs|fusectl|configfs|overlay|squashfs|autofs|binfmt_misc|rpc_pipefs)$/ {
        print $2
      }
    ' /proc/mounts
  fi
}

scan_all_mounted_drives() {
  echo
  echo "Scanning mounted drives for libraryfolders.vdf files."
  echo "This is faster than searching for every steamapps folder."

  local mountpoint
  while IFS= read -r mountpoint; do
    [[ -d "$mountpoint" ]] || continue

    # Avoid scanning pseudo or huge system areas directly.
    case "$mountpoint" in
      /proc|/sys|/dev|/run|/snap|/boot/efi) continue ;;
    esac

    echo "Scanning: $mountpoint"

    while IFS= read -r -d '' libraryfolders_file; do
      parse_libraryfolders_vdf "$libraryfolders_file"
    done < <(
      find "$mountpoint" \
        -xdev \
        \( -path '*/.cache' -o -path '*/.Trash-*' -o -path '*/lost+found' \) -prune -o \
        -type f -name libraryfolders.vdf -print0 2>/dev/null
    )
  done < <(get_mounts)
}

path_hash() {
  local input="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$input" | sha256sum | awk '{print substr($1,1,12)}'
  else
    printf '%s' "$input" | cksum | awk '{print $1}'
  fi
}

safe_name_for_library() {
  local lib="$1"
  local base hash

  base="$(basename "$lib")"
  base="${base//[^A-Za-z0-9._-]/_}"
  hash="$(path_hash "$lib")"

  printf '%s-%s\n' "$base" "$hash"
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

print_libraries() {
  local -n arr_ref=$1
  local i=1
  local lib

  echo
  echo "Detected Steam libraries:"
  echo

  for lib in "${arr_ref[@]}"; do
    printf '  [%d] %s\n' "$i" "$lib"
    printf '      Source: %s\n' "${LIB_SOURCES[$lib]}"
    printf '      Status: %s\n' "$(status_for_library "$lib")"
    echo
    ((i++))
  done
}

parse_selection() {
  local input="$1"
  local max="$2"
  local -n out_ref=$3

  out_ref=()

  input="${input//,/ }"

  if [[ "${input,,}" == "all" ]]; then
    local i
    for ((i=1; i<=max; i++)); do
      out_ref+=("$i")
    done
    return 0
  fi

  local token start end i
  for token in $input; do
    if [[ "$token" =~ ^[0-9]+$ ]]; then
      if (( token >= 1 && token <= max )); then
        out_ref+=("$token")
      else
        echo "Ignoring invalid choice: $token"
      fi
    elif [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"

      if (( start > end )); then
        echo "Ignoring invalid range: $token"
        continue
      fi

      for ((i=start; i<=end; i++)); do
        if (( i >= 1 && i <= max )); then
          out_ref+=("$i")
        else
          echo "Ignoring invalid choice in range: $i"
        fi
      done
    else
      echo "Ignoring invalid token: $token"
    fi
  done
}

ensure_destination_ready() {
  local dest="$1"

  if [[ -e "$dest" ]]; then
    if [[ -d "$dest" ]] && [[ -z "$(find "$dest" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
      return 0
    fi

    echo "Destination already exists and is not empty:"
    echo "  $dest"
    return 1
  fi

  mkdir -p "$dest"
}

fix_ownership_if_needed() {
  local target="$1"

  if [[ ! -e "$target" ]]; then
    return 0
  fi

  if [[ -O "$target" ]]; then
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

move_library_compatdata() {
  local lib="$1"
  local dest_base="$2"

  local steamapps="$lib/steamapps"
  local compat="$steamapps/compatdata"
  local dest="$dest_base/$(safe_name_for_library "$lib")"

  echo
  echo "Library:"
  echo "  $lib"
  echo "Compatdata:"
  echo "  $compat"
  echo "Destination:"
  echo "  $dest"

  if [[ ! -d "$steamapps" ]]; then
    echo "Skipping: steamapps folder does not exist."
    return 0
  fi

  if [[ -L "$compat" ]]; then
    echo "Skipping: compatdata is already a symlink."
    echo "Current target: $(readlink "$compat")"
    return 0
  fi

  if [[ -e "$compat" && ! -d "$compat" ]]; then
    echo "Skipping: compatdata exists but is not a directory."
    return 0
  fi

  if ! ensure_destination_ready "$dest"; then
    echo "Skipping this library to avoid overwriting data."
    return 0
  fi

  if [[ -d "$compat" ]]; then
    echo "Moving compatdata..."
    mv "$compat" "$dest"
  else
    echo "No compatdata folder exists yet; creating destination folder."
    mkdir -p "$dest"
  fi

  echo "Creating symlink..."
  ln -s "$dest" "$compat"

  fix_ownership_if_needed "$dest"

  echo "Done:"
  echo "  $compat -> $dest"
}

main() {
  echo "Steam compatdata mover"
  echo
  echo "This moves Proton/Wine prefixes out of Steam library folders"
  echo "and replaces each compatdata folder with a symlink."
  echo
  echo "Close Steam before continuing."

  if ! prompt_yes_no "Continue?" "n"; then
    exit 0
  fi

  scan_known_steam_configs

  if prompt_yes_no "Also search mounted drives for libraryfolders.vdf?" "y"; then
    scan_all_mounted_drives
  fi

  mapfile -t libraries < <(
    for lib in "${!LIBS[@]}"; do
      printf '%s\n' "$lib"
    done | sort
  )

  if (( ${#libraries[@]} == 0 )); then
    echo
    echo "No Steam libraries found."
    exit 1
  fi

  print_libraries libraries

  echo "Choose libraries to move."
  echo "Examples:"
  echo "  all"
  echo "  1"
  echo "  1 3 4"
  echo "  2-5"
  echo

  read -r -p "Selection: " selection_raw

  declare -a selected_numbers
  parse_selection "$selection_raw" "${#libraries[@]}" selected_numbers

  if (( ${#selected_numbers[@]} == 0 )); then
    echo "No valid libraries selected."
    exit 0
  fi

  echo
  read -r -p "Destination base [$DEST_BASE_DEFAULT]: " DEST_BASE
  DEST_BASE="${DEST_BASE:-$DEST_BASE_DEFAULT}"
  DEST_BASE="${DEST_BASE/#\~/$HOME}"
  DEST_BASE="$(normalize_path "$DEST_BASE")"

  mkdir -p "$DEST_BASE"

  echo
  echo "Selected destination:"
  echo "  $DEST_BASE"
  echo

  echo "Selected libraries:"
  local num
  for num in "${selected_numbers[@]}"; do
    echo "  [$num] ${libraries[$((num-1))]}"
  done

  echo
  if ! prompt_yes_no "Apply these changes?" "n"; then
    echo "Cancelled."
    exit 0
  fi

  for num in "${selected_numbers[@]}"; do
    move_library_compatdata "${libraries[$((num-1))]}" "$DEST_BASE"
  done

  echo
  echo "Finished."
  echo
  echo "Recommended check:"
  echo "  ls -l /path/to/SteamLibrary/steamapps/compatdata"
  echo
  echo "Then start Steam normally, without sudo."
}

main "$@"
