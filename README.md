# steam-compatdata-mover

Move Steam Proton prefixes from secondary libraries into your main Steam library, then link each secondary library's `steamapps/compatdata` folder to it. This can help fix `pfx is not owned by you` when games are on an NTFS drive. Game files stay where they are.

## Run

Close Steam, back up any prefixes you need to keep, and run this in a terminal as your normal user. Do not use `sudo`.

```bash
curl -fsSLo steam-compatdata-mover.sh https://raw.githubusercontent.com/Bukutsu/steam-compatdata-mover/main/steam-compatdata-mover.sh && bash steam-compatdata-mover.sh
```

Requires Linux, Bash, and curl. The command downloads the script into your current folder and runs it only if the download succeeds. To review it first, run just the `curl` part, then open `steam-compatdata-mover.sh` before running it with Bash.

The script detects Steam libraries, including Flatpak installs, lists them, and asks which ones to move. It also updates existing compatdata symlinks that point to an old location.

## Options

After downloading, run `bash steam-compatdata-mover.sh` with:

- `-a`, `--all`: select all detected secondary libraries.
- `-y`, `--yes`: accept yes/no prompts automatically.
- `-h`, `--help`: show help.

For unattended use, close Steam first, then run:

```bash
bash steam-compatdata-mover.sh -a -y
```

## Before moving

- Make sure the main library has enough free space. The script does not check it.
- If a prefix with the same name already exists in the destination, the script skips that library instead of merging or overwriting it.
- Failed moves are not rolled back. Keep a backup of prefixes you need.
- With `-y`, the script also accepts the warning if Steam is still running.

License: [GPL-3.0](LICENSE).
