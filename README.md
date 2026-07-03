# steam-compatdata-mover

Interactive Bash script for moving Steam `steamapps/compatdata` folders (Proton prefixes/saves) from secondary drives (like NTFS) to your native main Steam library, replacing the original directories with symbolic links.

## What it Fixes
- **NTFS Ownership Errors:** Fixes the common Proton/Wine error: `wineserver: .../compatdata/.../pfx is not owned by you` (since NTFS partitions lack Unix ownership features required by Wine).
- **Broken/Outdated Symlinks:** Automatically heals and redirects legacy or broken symlinks pointing to outdated paths.
- **Existing Symlinks:** Cleanly resolves pre-existing individual game symlinks inside the secondary library's `compatdata` directory without causing conflict errors.

## Usage

```bash
./steam-compatdata-mover.sh [options]
```

### Options:
- `-y, --yes`  : Auto-confirm all prompts (useful for automation).
- `-a, --all`  : Select and process all detected movable libraries.
- `-h, --help` : Show help instructions.

*Note: Close Steam before running the script. Do not run it with `sudo`.*

## Notes
- **Automatic Destination:** `<main Steam library>/steamapps/compatdata`
- **Headless automation:** Running with `-a -y` is ideal for login scripts.
- **Data safety:** Destination folders are validated with disk space checks before copying to prevent file corruption.

