#!/usr/bin/env bash
set -Eeuo pipefail

# Interactive Steam compatdata mover
# Moves selected Steam library steamapps/compatdata folders into your main Steam
# library, then replaces the original compatdata folder with a symlink.
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

FORCE_CLI=0
AUTO_YES=0
AUTO_ALL=0

show_help() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -c, --cli      Force text-only CLI mode (bypasses terminal TUI)
  -y, --yes      Auto-confirm interactive prompts (useful for automation)
  -a, --all      Select and process all detected movable libraries (non-interactive)
  -h, --help     Show this help message and exit

EOF
}

# Parse command line options
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--cli)
      FORCE_CLI=1
      shift
      ;;
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
  local path="$1"

  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$path" 2>/dev/null || printf '%s\n' "$path"
  else
    printf '%s\n' "$path"
  fi
}

is_interix_symlink() {
  local file="$1"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  if head -c 20 "$file" 2>/dev/null | tr -d '\0' | grep -q "^IntxLNK"; then
    return 0
  fi
  return 1
}

read_interix_symlink() {
  local file="$1"
  local target=""
  if target="$(iconv -f UTF-16LE -t UTF-8 "$file" 2>/dev/null)"; then
    target="${target#IntxLNK}"
  else
    target="$(tr -d '\0' < "$file")"
    target="${target#IntxLNK}"
  fi
  printf '%s\n' "$(echo "$target" | xargs)"
}

resolve_symlink_target() {
  local file="$1"
  if [[ -L "$file" ]]; then
    readlink "$file"
  elif is_interix_symlink "$file"; then
    read_interix_symlink "$file"
  else
    echo ""
  fi
}

library_status_label() {
  local lib="$1"
  local status
  local dest

  if [[ -n "$MAIN_LIBRARY" ]] && [[ "$(normalize_path "$lib")" == "$(normalize_path "$MAIN_LIBRARY")" ]]; then
    echo "native"
    return 0
  fi

  status="$(status_for_library "$lib")"

  case "$status" in
    already\ symlinked*)
      dest="$(destination_base_for_main_library 2>/dev/null || echo "")"
      if [[ -n "$dest" ]]; then
        local current_target
        current_target="$(resolve_symlink_target "$lib/steamapps/compatdata")"
        if [[ "$(normalize_path "$current_target")" == "$(normalize_path "$dest")" ]]; then
          printf '%s\n' "symlinked"
        else
          printf '%s\n' "outdated"
        fi
      else
        printf '%s\n' "symlinked"
      fi
      ;;
    local\ compatdata\ folder\ exists) printf '%s\n' "local" ;;
    *) printf '%s\n' "empty" ;;
  esac
}

ui_supported=0
ui_rows=24
ui_cols=80
ui_cursor_saved=0

ui_refresh_size() {
  ui_rows="$(tput lines 2>/dev/null || printf '24')"
  ui_cols="$(tput cols 2>/dev/null || printf '80')"
}

ui_enter() {
  if [[ "$ui_supported" -ne 1 ]]; then
    return 1
  fi

  tput smcup 2>/dev/null || true
  tput civis 2>/dev/null || true
  ui_cursor_saved=1
  return 0
}

ui_leave() {
  if [[ "$ui_cursor_saved" -eq 1 ]]; then
    tput cnorm 2>/dev/null || true
    tput rmcup 2>/dev/null || true
    ui_cursor_saved=0
  fi
}

ui_init() {
  if [[ "$FORCE_CLI" -eq 1 ]]; then
    ui_supported=0
    return 0
  fi

  if [[ -t 0 && -t 1 && -n "${TERM:-}" && "${TERM}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
    ui_supported=1
    ui_refresh_size
    trap ui_leave EXIT INT TERM
    ui_enter
  fi
}

ui_clear() {
  printf '\033[H\033[J'
}

ui_truncate() {
  local text="$1"
  local width="$2"

  if (( width <= 0 )); then
    printf '%s' ""
    return 0
  fi

  if (( ${#text} <= width )); then
    printf '%s' "$text"
  elif (( width <= 3 )); then
    printf '%.*s' "$width" "$text"
  else
    printf '%s...' "${text:0:width-3}"
  fi
}

ui_read_key() {
  local key rest

  IFS= read -rsn1 key || return 1

  if [[ -z "$key" ]]; then
    printf '%s' 'ENTER'
    return 0
  fi

  case "$key" in
    " ")
      printf '%s' 'SPACE'
      return 0
      ;;
    $'\r'|$'\n')
      printf '%s' 'ENTER'
      return 0
      ;;
  esac

  if [[ "$key" == $'\x1b' ]]; then
    if IFS= read -rsn2 -t 0.01 rest; then
      case "$rest" in
        "[A"|"OA")
          printf '%s' 'UP'
          return 0
          ;;
        "[B"|"OB")
          printf '%s' 'DOWN'
          return 0
          ;;
        "[H"|"[1~")
          printf '%s' 'HOME'
          return 0
          ;;
        "[F"|"[4~")
          printf '%s' 'END'
          return 0
          ;;
      esac
    fi
  fi

  printf '%s' "$key"
}

ui_draw_frame() {
  local title="$1"
  local subtitle="$2"
  local footer="$3"
  local body_top="$4"
  local body_bottom="$5"
  local body="$6"

  ui_refresh_size
  ui_clear
  printf '%s\n' "$title"
  printf '%s\n' "$subtitle"
  printf '%s\n' "$footer"
  printf '\n'
  printf '%s\n' "$body_top"
  printf '%s\n' "$body"
  printf '%s\n' "$body_bottom"
}

normalize_library_root() {
  local root="$1"

  root="${root/#\~/$HOME}"
  normalize_path "$root"
}

add_library() {
  local root="$1"
  local source="$2"

  [[ -z "$root" ]] && return 0

  root="$(normalize_library_root "$root")"

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

  root="$(normalize_library_root "$root")"
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
  if [[ "$ui_supported" -eq 0 ]]; then
    echo
    echo "Searching likely Steam locations for libraryfolders.vdf files."
  fi

  local root
  for root in "${SEARCH_ROOTS[@]}"; do
    [[ -d "$root" ]] || continue

    if [[ "$ui_supported" -eq 0 ]]; then
      echo "Searching: $root"
    fi

    while IFS= read -r -d '' libraryfolders_file; do
      parse_libraryfolders_vdf "$libraryfolders_file"
    done < <(
      find "$root" \
        -xdev \
        -maxdepth 6 \
        \( -path '*/.cache' -o -path '*/.Trash-*' -o -path '*/lost+found' -o -path '*/Trash/files' \) -prune -o \
        -path '*/steamapps/libraryfolders.vdf' -type f -print0 2>/dev/null
    )
  done
}

status_for_library() {
  local lib="$1"
  local compat="$lib/steamapps/compatdata"

  if [[ -L "$compat" ]]; then
    echo "already symlinked -> $(readlink "$compat")"
  elif is_interix_symlink "$compat"; then
    echo "already symlinked -> $(read_interix_symlink "$compat")"
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
    ((i += 1))
  done
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

parse_selection() {
  local input="$1"
  local max="$2"
  # shellcheck disable=SC2178
  local -n out_ref="$3"

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

screen_render_selection() {
  local -n libs_ref="$1"
  local -n checked_ref="$2"
  local cursor_index="$3"
  local title="Steam compatdata mover"
  local main_library="$4"
  local total="${#libs_ref[@]}"
  local selected=0
  local i

  for i in "${!libs_ref[@]}"; do
    if [[ "${checked_ref[$i]:-0}" -eq 1 ]]; then
      ((selected += 1))
    fi
  done

  ui_refresh_size
  ui_clear

  printf '%s\n' "$title"
  printf 'Main library: %s\n' "$main_library"
  printf 'Selected:     %d/%d\n' "$selected" "$total"
  printf '\n'
  printf 'Move selection\n'
  printf '\n'

  local header_rows=6
  local footer_rows=4
  local list_rows=$((ui_rows - header_rows - footer_rows))
  if (( list_rows < 3 )); then
    list_rows=3
  fi

  local start_index=0
  if (( cursor_index >= list_rows )); then
    start_index=$((cursor_index - list_rows + 1))
  fi
  if (( start_index > total - list_rows )); then
    start_index=$((total - list_rows))
  fi
  if (( start_index < 0 )); then
    start_index=0
  fi

  local end_index=$((start_index + list_rows))
  if (( end_index > total )); then
    end_index=$total
  fi

  local line index marker checkbox label lib_width status_width
  status_width=12
  lib_width=$((ui_cols - 19 - status_width))
  if (( lib_width < 20 )); then
    lib_width=20
  fi

  for ((index=start_index; index<end_index; index++)); do
    marker=" "
    [[ "$index" -eq "$cursor_index" ]] && marker=">"
    checkbox="[ ]"
    if [[ "${checked_ref[$index]:-0}" -eq 1 ]]; then
      checkbox="[X]"
    fi
    label="$(library_status_label "${libs_ref[$index]}")"
    line="$(ui_truncate "${libs_ref[$index]}" "$lib_width")"
    printf '%s %s %3d %-12s %s\n' "$marker" "$checkbox" $((index + 1)) "[$label]" "$line"
  done

  printf '\n'
  printf 'Arrows move  Space toggles  a selects all  n clears  Enter applies  q quits\n'
  if (( cursor_index >= 0 && cursor_index < total )); then
    printf 'Source: %s\n' "${LIB_SOURCES[${libs_ref[$cursor_index]}]:-unknown}"
  fi
}

screen_select_libraries() {
  local -n libs_ref="$1"
  # shellcheck disable=SC2178
  local -n out_ref="$2"
  local main_library="$3"
  local total="${#libs_ref[@]}"
  local -a checked=()
  local cursor=0
  local i key selected_count

  for ((i=0; i<total; i++)); do
    local label
    label="$(library_status_label "${libs_ref[$i]}")"
    if [[ "$label" == "local" || "$label" == "outdated" ]]; then
      checked[i]=1
    else
      checked[i]=0
    fi
  done

  while true; do
    screen_render_selection "$1" checked "$cursor" "$main_library"
    key="$(ui_read_key)" || return 1

    case "$key" in
      UP)
        if (( cursor > 0 )); then
          cursor=$((cursor - 1))
        fi
        ;;
      DOWN)
        if (( cursor < total - 1 )); then
          ((cursor += 1))
        fi
        ;;
      HOME)
        cursor=0
        ;;
      END)
        cursor=$((total - 1))
        ;;
      SPACE)
        if [[ "${checked[$cursor]:-0}" -eq 1 ]]; then
          checked[cursor]=0
        else
          checked[cursor]=1
        fi
        ;;
      a|A)
        for ((i=0; i<total; i++)); do
          checked[i]=1
        done
        ;;
      n|N)
        for ((i=0; i<total; i++)); do
          checked[i]=0
        done
        ;;
      ENTER)
        break
        ;;
      q|Q)
        return 1
        ;;
    esac
  done

  out_ref=()
  for ((i=0; i<total; i++)); do
    if [[ "${checked[$i]:-0}" -eq 1 ]]; then
      out_ref+=("$((i + 1))")
    fi
  done

  selected_count="${#out_ref[@]}"
  if (( selected_count == 0 )); then
    return 2
  fi

  return 0
}

screen_show_progress() {
  local current="$1"
  local total="$2"
  local lib="$3"
  local message="$4"

  ui_refresh_size
  ui_clear
  printf 'Steam compatdata mover\n\n'
  printf 'Processing %d/%d\n' "$current" "$total"
  printf 'Library:     %s\n' "$lib"
  printf '\n'
  printf '%s\n' "$message"
}

print_final_summary() {
  local -n results_ref="$1"
  local i

  printf 'Steam compatdata mover\n\n'
  printf 'Finished.\n'
  printf '\n'
  for i in "${results_ref[@]}"; do
    printf '%s\n' "$i"
  done
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

  if [[ ! -e "$target" ]]; then
    return 0
  fi

  if [[ -O "$target" ]]; then
    return 0
  fi

  if [[ "$quiet" -eq 1 ]]; then
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
    echo "Library:"
    echo "  $lib"
    echo "Compatdata:"
    echo "  $compat"
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

  if [[ -L "$compat" ]] || is_interix_symlink "$compat"; then
    local current_target
    current_target="$(resolve_symlink_target "$compat")"
    if [[ "$current_target" != /* ]]; then
      # Resolve relative symlink relative to the parent directory of $compat ($lib/steamapps)
      current_target="$(dirname "$compat")/$current_target"
    fi

    if [[ "$(normalize_path "$current_target")" == "$norm_dest" ]]; then
      if [[ -L "$compat" ]]; then
        if [[ "$quiet" -eq 0 ]]; then
          echo "Skipping: compatdata is already symlinked to the correct destination."
        fi
        printf 'skipped: already symlinked for %s\n' "$lib"
        return 0
      else
        if [[ "$quiet" -eq 0 ]]; then
          echo "Updating legacy Interix symlink to a native symlink..."
        fi
        rm -f "$compat"
        ln -s "$dest" "$compat"
        printf 'updated: %s\n' "$lib"
        return 0
      fi
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
    echo "Done:"
    echo "  $compat -> $dest"
  fi
  printf 'moved: %s\n' "$lib"
}

run_text_flow() {
  local DEST_BASE
  local -a libraries=()
  local -a selected_numbers=()
  local result
  local num

  echo "Steam compatdata mover"
  echo
  echo "This moves Proton/Wine prefixes into your main Steam library"
  echo "and replaces each original compatdata folder with a symlink."
  echo
  echo "Close Steam before continuing."

  if ! prompt_yes_no "Continue?" "n"; then
    exit 0
  fi

  scan_known_steam_configs
  scan_libraryfolders_files

  load_selectable_libraries libraries

  if (( ${#libraries[@]} == 0 )); then
    echo
    echo "No movable Steam libraries found."
    exit 0
  fi

  if ! DEST_BASE="$(destination_base_for_main_library)"; then
    exit 1
  fi

  print_libraries libraries

  echo "Main Steam library:"
  echo "  $MAIN_LIBRARY"
  echo
  echo "Choose libraries to move."
  echo "Examples:"
  echo "  all"
  echo "  1"
  echo "  1 3 4"
  echo "  2-5"
  echo

  if [[ "$AUTO_ALL" -eq 1 ]]; then
    local i
    for ((i=1; i<=${#libraries[@]}; i++)); do
      selected_numbers+=("$i")
    done
  else
    read -r -p "Selection: " selection_raw
    parse_selection "$selection_raw" "${#libraries[@]}" selected_numbers
  fi

  if (( ${#selected_numbers[@]} == 0 )); then
    echo "No libraries selected. No changes applied."
    exit 0
  fi

  mkdir -p "$DEST_BASE"

  echo "Selected libraries:"
  for num in "${selected_numbers[@]}"; do
    echo "  [$num] ${libraries[$((num-1))]}"
  done

  echo
  if ! prompt_yes_no "Apply these changes?" "n"; then
    echo "Cancelled."
    exit 0
  fi

  for num in "${selected_numbers[@]}"; do
    result="$(move_library_compatdata "${libraries[$((num-1))]}" "$DEST_BASE" 0)"
    echo "$result"
  done

  echo
  echo "Finished."
  echo
  echo "Recommended check:"
  echo "  ls -l /path/to/SteamLibrary/steamapps/compatdata"
  echo
  echo "Then start Steam normally, without sudo."
}

run_tui_flow() {
  local DEST_BASE
  local -a libraries=()
  local -a selected_numbers=()
  local -a results=()
  local choice
  local idx
  local num
  local lib
  local result
  local action_text
  local total

  ui_clear
  printf 'Steam compatdata mover\n\n'
  printf 'Discovering Steam libraries...\n'

  scan_known_steam_configs
  scan_libraryfolders_files

  load_selectable_libraries libraries

  if (( ${#libraries[@]} == 0 )); then
    ui_clear
    printf 'Steam compatdata mover\n\n'
    printf 'No movable Steam libraries found.\n'
    ui_leave
    results=("No movable Steam libraries found. No changes applied.")
    print_final_summary results
    return 0
  fi

  if ! DEST_BASE="$(destination_base_for_main_library)"; then
    ui_clear
    printf 'Steam compatdata mover\n\n'
    printf 'Could not determine the main Steam library.\n'
    printf '\nPress any key to exit.\n'
    ui_read_key >/dev/null || true
    return 1
  fi

  screen_select_libraries libraries selected_numbers "$MAIN_LIBRARY"
  choice=$?
  if (( choice != 0 )); then
    case "$choice" in
      2)
        ui_leave
        results=("No libraries selected. No changes applied.")
        print_final_summary results
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  fi

  total="${#selected_numbers[@]}"
  mkdir -p "$DEST_BASE"

  idx=1
  for num in "${selected_numbers[@]}"; do
    lib="${libraries[$((num-1))]}"
    screen_show_progress "$idx" "$total" "$lib" "Moving compatdata..."
    if result="$(move_library_compatdata "$lib" "$DEST_BASE" 1)"; then
      case "$result" in
        moved:*)
          action_text="moved"
          ;;
        skipped:*)
          action_text="${result#skipped: }"
          ;;
        *)
          action_text="$result"
          ;;
      esac
    else
      action_text="failed"
    fi
    results+=("[$num] $lib: $action_text")
    ((idx += 1))
  done

  ui_leave
  print_final_summary results
}

is_steam_running() {
  if pgrep -x "steam" >/dev/null 2>&1 || pgrep -x "steamwebhelper" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

main() {
  # If AUTO_ALL or AUTO_YES is set, we bypass TUI and run text flow for non-interactive execution
  if [[ "$AUTO_ALL" -eq 1 || "$AUTO_YES" -eq 1 ]]; then
    FORCE_CLI=1
  fi

  ui_init

  if is_steam_running; then
    if [[ "$ui_supported" -eq 1 ]]; then
      ui_clear
      printf 'Steam compatdata mover\n\n'
      printf 'Warning: Steam appears to be running.\n'
      printf 'Please close Steam before continuing.\n\n'
      if ! prompt_yes_no "Continue anyway?" "n"; then
        ui_leave
        exit 0
      fi
    else
      echo "Warning: Steam appears to be running."
      if ! prompt_yes_no "Are you sure you want to continue?" "n"; then
        exit 0
      fi
    fi
  fi

  if [[ "$ui_supported" -eq 1 ]]; then
    run_tui_flow
  else
    run_text_flow
  fi
}

main "$@"
