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

declare -A LIBS=()
declare -A LIB_SOURCES=()
declare -A VDF_FILES=()
MAIN_LIBRARY=""

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

library_status_label() {
  local lib="$1"
  local status

  if [[ -n "$MAIN_LIBRARY" ]] && [[ "$(normalize_path "$lib")" == "$(normalize_path "$MAIN_LIBRARY")" ]]; then
    echo "native"
    return 0
  fi

  status="$(status_for_library "$lib")"

  case "$status" in
    already\ symlinked*) printf '%s\n' "symlinked" ;;
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

  add_main_library "$HOME/.local/share/Steam" "common Steam path"
  add_main_library "$HOME/.steam/steam" "common Steam path"
  add_main_library "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam" "Flatpak Steam path"
}

scan_libraryfolders_files() {
  if [[ "$ui_supported" -eq 0 ]]; then
    echo
    echo "Searching likely Steam locations for libraryfolders.vdf files."
  fi

  local roots=(
    "$HOME/.local/share"
    "$HOME/.steam"
    "$HOME/.var/app/com.valvesoftware.Steam/.local/share"
    "/run/media/$USER_NAME"
    "/media/$USER_NAME"
    "/mnt"
  )

  local root
  for root in "${roots[@]}"; do
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

screen_render_selection() {
  local -n libs_ref=$1
  local -n checked_ref=$2
  local cursor_index="$3"
  local title="Steam compatdata mover"
  local main_library="$4"
  local dest_base="$5"
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
  printf 'Destination:  %s\n' "$dest_base"
  printf 'Selected:     %d/%d\n' "$selected" "$total"
  printf '\n'
  printf 'Move selection\n'
  printf '\n'

  local header_rows=7
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
  printf 'Arrows move  Space toggles  a selects all  n clears  Enter confirms  q quits\n'
  if (( cursor_index >= 0 && cursor_index < total )); then
    printf 'Source: %s\n' "${LIB_SOURCES[${libs_ref[$cursor_index]}]:-unknown}"
  fi
}

screen_select_libraries() {
  local -n libs_ref=$1
  local -n out_ref=$2
  local main_library="$3"
  local dest_base="$4"
  local total="${#libs_ref[@]}"
  local -a checked=()
  local cursor=0
  local i key selected_count

  for ((i=0; i<total; i++)); do
    if [[ "$(library_status_label "${libs_ref[$i]}")" == "local" ]]; then
      checked[$i]=1
    else
      checked[$i]=0
    fi
  done

  while true; do
    screen_render_selection "$1" checked "$cursor" "$main_library" "$dest_base"
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
          checked[$cursor]=0
        else
          checked[$cursor]=1
        fi
        ;;
      a|A)
        for ((i=0; i<total; i++)); do
          checked[$i]=1
        done
        ;;
      n|N)
        for ((i=0; i<total; i++)); do
          checked[$i]=0
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

screen_confirm_selection() {
  local -n libs_ref=$1
  local -n selected_ref=$2
  local dest_base="$3"
  local main_library="$4"
  local title="Confirm move"
  local total="${#selected_ref[@]}"
  local action=0
  local i

  while true; do
    ui_refresh_size
    ui_clear
    printf '%s\n' "$title"
    printf 'Main library: %s\n' "$main_library"
    printf 'Destination:  %s\n' "$dest_base"
    printf 'Selected:     %d\n' "$total"
    printf '\n'
    printf 'Proceed with these libraries?\n'
    printf '\n'

    local start=0
    local limit=$((ui_rows - 10))
    if (( limit < 3 )); then
      limit=3
    fi
    local end=$total
    if (( end > limit )); then
      end=$limit
    fi

    for ((i=start; i<end; i++)); do
      printf '  [%d] %s\n' "${selected_ref[$i]}" "${libs_ref[$((selected_ref[$i]-1))]}"
    done

    if (( total > end )); then
      printf '  ... and %d more\n' $((total - end))
    fi

    printf '\n'
    if (( action == 0 )); then
      printf '> Apply changes\n'
      printf '  Back\n'
    else
      printf '  Apply changes\n'
      printf '> Back\n'
    fi
    printf '\n'
    printf 'Use arrows, Enter, q.\n'

    case "$(ui_read_key)" in
      UP|DOWN)
        if (( action == 0 )); then
          action=1
        else
          action=0
        fi
        ;;
      ENTER)
        if (( action == 0 )); then
          return 0
        fi
        return 2
        ;;
      y|Y)
        return 0
        ;;
      b|B)
        return 2
        ;;
      q|Q)
        return 1
        ;;
    esac
  done
}

screen_show_progress() {
  local current="$1"
  local total="$2"
  local lib="$3"
  local dest="$4"
  local message="$5"

  ui_refresh_size
  ui_clear
  printf 'Steam compatdata mover\n\n'
  printf 'Processing %d/%d\n' "$current" "$total"
  printf 'Library:     %s\n' "$lib"
  printf 'Destination:  %s\n' "$dest"
  printf '\n'
  printf '%s\n' "$message"
}

screen_show_summary() {
  local -n results_ref=$1
  local dest_base="$2"
  local i

  ui_refresh_size
  ui_clear
  printf 'Steam compatdata mover\n\n'
  printf 'Finished.\n'
  printf 'Destination: %s\n' "$dest_base"
  printf '\n'
  for i in "${results_ref[@]}"; do
    printf '%s\n' "$i"
  done
  printf '\nPress any key to exit.\n'
  ui_read_key >/dev/null || true
}

print_final_summary() {
  local -n results_ref=$1
  local dest_base="$2"
  local i

  printf 'Steam compatdata mover\n\n'
  printf 'Finished.\n'
  printf 'Destination: %s\n' "$dest_base"
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
    mv "$item" "$dest/"
  done

  rmdir "$src"
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
    echo "Destination:"
    echo "  $dest"
  fi

  if [[ ! -d "$steamapps" ]]; then
    if [[ "$quiet" -eq 0 ]]; then
      echo "Skipping: steamapps folder does not exist."
    fi
    printf 'skipped: no steamapps for %s\n' "$lib"
    return 0
  fi

  if [[ "$(normalize_path "$compat")" == "$(normalize_path "$dest")" ]]; then
    if [[ "$quiet" -eq 0 ]]; then
      echo "Skipping: this is already the native main library compatdata folder."
    fi
    mkdir -p "$dest"
    printf 'skipped: already native main library for %s\n' "$lib"
    return 0
  fi

  if [[ -L "$compat" ]]; then
    if [[ "$quiet" -eq 0 ]]; then
      echo "Skipping: compatdata is already a symlink."
      echo "Current target: $(readlink "$compat")"
    fi
    printf 'skipped: already symlinked for %s\n' "$lib"
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

  if ! DEST_BASE="$(destination_base_for_main_library)"; then
    exit 1
  fi

  print_libraries libraries

  echo "Main Steam library:"
  echo "  $MAIN_LIBRARY"
  echo
  echo "Automatic destination:"
  echo "  $DEST_BASE"
  echo

  echo "Choose libraries to move."
  echo "Examples:"
  echo "  all"
  echo "  1"
  echo "  1 3 4"
  echo "  2-5"
  echo

  read -r -p "Selection: " selection_raw
  parse_selection "$selection_raw" "${#libraries[@]}" selected_numbers

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

  mapfile -t libraries < <(
    for lib in "${!LIBS[@]}"; do
      printf '%s\n' "$lib"
    done | sort
  )

  if (( ${#libraries[@]} == 0 )); then
    ui_clear
    printf 'Steam compatdata mover\n\n'
    printf 'No Steam libraries found.\n'
    printf '\nPress any key to exit.\n'
    ui_read_key >/dev/null || true
    return 1
  fi

  if ! DEST_BASE="$(destination_base_for_main_library)"; then
    ui_clear
    printf 'Steam compatdata mover\n\n'
    printf 'Could not determine the main Steam library.\n'
    printf '\nPress any key to exit.\n'
    ui_read_key >/dev/null || true
    return 1
  fi

  while true; do
    if screen_select_libraries libraries selected_numbers "$MAIN_LIBRARY" "$DEST_BASE"; then
      :
    else
      choice=$?
      case "$choice" in
        2)
          ui_leave
          results=("No libraries selected. No changes applied.")
          print_final_summary results "$DEST_BASE"
          return 0
          ;;
        *)
          return 0
          ;;
      esac
    fi

    if screen_confirm_selection libraries selected_numbers "$DEST_BASE" "$MAIN_LIBRARY"; then
      break
    else
      choice=$?
      case "$choice" in
        2)
          continue
          ;;
        *)
          return 0
          ;;
      esac
    fi
  done

  total="${#selected_numbers[@]}"
  mkdir -p "$DEST_BASE"

  idx=1
  for num in "${selected_numbers[@]}"; do
    lib="${libraries[$((num-1))]}"
    screen_show_progress "$idx" "$total" "$lib" "$DEST_BASE" "Moving compatdata..."
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
  print_final_summary results "$DEST_BASE"
}

main() {
  ui_init

  if [[ "$ui_supported" -eq 1 ]]; then
    run_tui_flow
  else
    run_text_flow
  fi
}

main "$@"
