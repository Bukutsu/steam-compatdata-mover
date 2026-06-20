# steam-compatdata-mover

Interactive Bash script for moving Steam `steamapps/compatdata` folders into your main Steam library, then replacing each original compatdata folder with a symlink.

## Usage

```bash
./steam-compatdata-mover.sh
```

Close Steam before running the script. Do not run it with `sudo`.

In a capable terminal, the script opens a keyboard-driven TUI for choosing which libraries to move. It checks common Steam locations, then does a targeted native filesystem search for `steamapps/libraryfolders.vdf` files in likely Steam and mount locations.

## Notes

- Automatic destination: `<main Steam library>/steamapps/compatdata`
- Existing non-empty destinations are skipped to avoid overwriting data.
- Already symlinked compatdata folders are skipped.
- The text prompt flow is used automatically if the terminal UI is not available.
