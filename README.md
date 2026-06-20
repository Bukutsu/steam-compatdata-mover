# steam-compatdata-mover

Interactive Bash script for moving Steam `steamapps/compatdata` folders to a directory in your home folder, then replacing each original compatdata folder with a symlink.

## Usage

```bash
./steam-compatdata-mover.sh
```

Close Steam before running the script. Do not run it with `sudo`.

The script checks common Steam locations first. If you choose the mounted-drive scan, it searches for `libraryfolders.vdf` files and parses those instead of walking every drive for `steamapps` folders.

## Notes

- Default destination: `~/.steam-compatdata-libraries`
- Existing non-empty destinations are skipped to avoid overwriting data.
- Already symlinked compatdata folders are skipped.
