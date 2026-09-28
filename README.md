# steam-compatdata-mover

A Bash script that moves Steam Proton prefixes from secondary libraries into your main Steam library. It replaces each secondary library's `steamapps/compatdata` directory with a symlink to `<main Steam library>/steamapps/compatdata`.

This can help with the Wine ownership error `pfx is not owned by you` when a secondary library is on NTFS. The script also handles existing compatdata symlinks, including ones that point to an old location.

## Use

Close Steam, then run the script as your normal user, without `sudo`:

```bash
./steam-compatdata-mover.sh
```

The script finds libraries from Steam's `libraryfolders.vdf` and common Steam paths, including the Flatpak location. It shows the libraries it found and asks which ones to process before making changes.

Options:

- `-a`, `--all`: select every detected secondary library.
- `-y`, `--yes`: confirm yes/no prompts automatically.
- `-h`, `--help`: show command help.

For unattended use, pass both `-a` and `-y`:

```bash
./steam-compatdata-mover.sh -a -y
```

## Before you run it

Back up any prefixes you need to keep. The script moves entries into the main library's `compatdata` directory. If an entry with the same name already exists there, it skips that library rather than merging the entries. Entries moved before a conflict are not rolled back.

Make sure the main library has enough free space. The script does not check available disk space. With `-y`, it also accepts the warning if Steam appears to be running, so close Steam yourself before using it unattended.

License: [GPL-3.0](LICENSE).
