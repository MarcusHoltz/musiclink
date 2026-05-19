# MusicLink — Library Curator

MusicLink is a Docker container that lets you build a curated library from multiple shares using symbolic links. No files are copied or moved. Your originals stay exactly where they are.

Browse your music shares, pick albums or folders, create an organized symlink library in a separate output share — all from a browser.



![Symlink Curator for Media Shares](https://raw.githubusercontent.com/MarcusHoltz/marcusholtz.github.io/refs/heads/main/assets/img/header/header--scripts--musiclink-symlink-curator-nocopy-libraries.jpg "Symlink it up!")


* * *

## What does MusicLink solve?

If you run a music server like Navidrome, Plex, or Jellyfin and your collection is spread across several shares, you have limited options — point your player at everything and deal with the mess, or duplicate files into a clean library and waste disk space.

MusicLink lets you browse your shares from a web interface, select the files and folders you want, and it places shortcuts — called symlinks — into an output folder. Your server imports that share as its library. Clean, organized, zero duplication.


* * *

## Features

- **Browser-based web UI** — runs in any browser, no app to install, works over your local network

- **Full file browser** — navigate your shares folder by folder and select exactly what you want

- **Numbered menu** — simple interface, type a number and press Enter, easy to script or have AI control

- **Create subfolders on the fly** — organize your output share by mood, genre, era, whatever you want before you link

- **Symlink manifest** — every link you create is logged with the date and time it was added so you always know what's there and when you added it

- **Short and full path views** — toggle between compact and full path display in the link list

- **Inspect any link** — see full detail on a single entry: source, destination, date added, live status

- **Status badges** — every link shows OK, DEAD, CONFLICT, or MISSING at a glance

- **Verify** — read-only health check across all your links, no changes made

- **Sync** — rebuilds any missing or dead links from the manifest automatically, safe to run anytime

- **Remove links** — pick from a numbered list, optionally delete the symlink file from disk

- **Config menu** — set source and target directories from inside the app, saved automatically

- **Edit manifest directly** — raw TSV file opens in nano if you need to make manual corrections

- **CLI flags** — skip the menu entirely and script any operation from the command line, great for AI

- **Runs without Docker** — plain bash script, works on any Linux system with no dependencies

- **Portable data** — all config and manifest data lives in one folder, easy to back up


* * *

## 1. What's in this repo

| File | What it is | Edit? |
|------|-----------|-------|
| `.env.example` | Template for your credentials and paths | **Yes — copy to `.env` first** |
| `docker-compose.yml` | Defines the container, ports, and volumes | **Yes — add your shares here** |
| `navidrome-compose-example.yml` | Ready Navidrome config with correct mounts | Copy and adapt if you use Navidrome |
| `musiclink.sh` | The app itself — works standalone too | No |
| `Dockerfile` | Builds the container image | No |
| `entrypoint.sh` | Container startup — cert, nginx, ttyd | No |
| `unraid-template.xml` | Unraid Community Apps template | No |
| `README.md` | Full documentation | Reference |


* * *

## 2. Edits before first run


* * *

### Edits Step 1 — create your env file
```bash
cp .env.example .env
```


* * *

### Edits Step 2 — set your password in .env
```
TTYD_CREDENTIAL=admin:yourpasswordhere
```
Anyone on your network can reach the web UI. Change this before you start.


* * *

### Edits Step 3 — add your shares to docker-compose.yml

Find the `volumes:` section and replace the example names with your real share paths. The paths will differ by platform — see the examples below.

**Unraid**
```yaml
volumes:
  - musiclink-config:/config
  - /mnt/user/FlacLibrary:/mnt/user/FlacLibrary:ro
  - /mnt/user/NewDownloads:/mnt/user/NewDownloads:ro
  - /mnt/user/Soundtracks:/mnt/user/Soundtracks:ro
  - /mnt/user/CuratedMusic:/mnt/user/CuratedMusic
```

**TrueNAS**
```yaml
volumes:
  - musiclink-config:/config
  - /mnt/tank/FlacLibrary:/mnt/tank/FlacLibrary:ro
  - /mnt/tank/NewDownloads:/mnt/tank/NewDownloads:ro
  - /mnt/tank/Soundtracks:/mnt/tank/Soundtracks:ro
  - /mnt/tank/CuratedMusic:/mnt/tank/CuratedMusic
```

**OpenMediaVault**
```yaml
volumes:
  - musiclink-config:/config
  - /srv/dev-disk-by-uuid-XXXX/FlacLibrary:/srv/dev-disk-by-uuid-XXXX/FlacLibrary:ro
  - /srv/dev-disk-by-uuid-XXXX/NewDownloads:/srv/dev-disk-by-uuid-XXXX/NewDownloads:ro
  - /srv/dev-disk-by-uuid-XXXX/Soundtracks:/srv/dev-disk-by-uuid-XXXX/Soundtracks:ro
  - /srv/dev-disk-by-uuid-XXXX/CuratedMusic:/srv/dev-disk-by-uuid-XXXX/CuratedMusic
```
> Replace `XXXX` with your actual disk UUID. Find it with `ls /srv/` or check **Storage → File Systems** in the OMV web panel.

**Debian (or any standard Linux)**
```yaml
volumes:
  - musiclink-config:/config
  - /home/username/Music/FlacLibrary:/home/username/Music/FlacLibrary:ro
  - /home/username/Music/NewDownloads:/home/username/Music/NewDownloads:ro
  - /home/username/Music/Soundtracks:/home/username/Music/Soundtracks:ro
  - /home/username/Music/CuratedMusic:/home/username/Music/CuratedMusic
```
> Replace `username` with your actual username. If your music lives on a separately mounted drive, use its mount point under `/mnt` instead.

In your `.env` file, set `TARGET_DIR` to match your output share path:
```
TARGET_DIR="/mnt/user/CuratedMusic"        # Unraid
TARGET_DIR="/mnt/tank/CuratedMusic"        # TrueNAS
TARGET_DIR="/srv/dev-disk-by-uuid-XXXX/CuratedMusic"   # OMV
TARGET_DIR="/home/username/Music/CuratedMusic"     # Debian / standard Linux
```


* * *

## 3. The volume same-path rule

Symlinks are sticky notes. A note saying "file is at `/mnt/user/Music/Artist/Album`" only works if `/mnt/user/Music` is visible where you're reading it.

**The path on the left must equal the path on the right. Always.**

```yaml
# Correct
- /mnt/user/Music:/mnt/user/Music:ro

# Wrong — every symlink MusicLink creates will be dead outside Docker
- /mnt/user/Music:/music:ro
```

> This applies to MusicLink and every other container — Jellyfin, Plex, Navidrome, anything that reads your output share.


* * *

## 4. Bring it up

**Docker Compose (all platforms):**
```bash
docker compose up -d
docker compose logs -f    # wait for "[musiclink] Web UI →" then open browser
```

Open `https://SERVER_IP:7681` in your browser — accept the self-signed cert warning once — then log in.

| Platform | Finding your server's IP |
|----------|--------------------------|
| Unraid | Shown on the main dashboard, or **Settings → Network Settings** |
| TrueNAS | **Network → Interfaces**, or the address you use for the web UI |
| OpenMediaVault | **Network → Interfaces**, or `hostname -I` in the shell |
| Debian | `ip a` or `hostname -I` in the terminal |

> **Unraid users:** MusicLink is also available in Community Apps. Install it from there and fill in the template fields — no manual Compose editing needed.

**Without Docker (any Linux):**
```bash
./musiclink.sh
```


* * *

## 5. The menu

```
[1]  Add link       browse shares → pick folder or album → place symlink
[2]  Remove link    pick from numbered list → removes link
[3]  List links     all your links, short path view
[4]  List links     full paths
[5]  Inspect link   date added, source, destination, live status
[6]  Sync           rebuilds missing or dead links from manifest — safe anytime
[7]  Verify         health check — shows OK / DEAD / MISSING / CONFLICT per link
[8]  New folder     create an organising folder in your output share
[9]  Config         set source and target directories
[10] Edit manifest  open the raw tracking file in nano
[0]  Quit
```

**Adding an album — step by step:**

1. Press `1` → Enter
2. File browser opens — type a number to enter a folder, `0` to go up
3. Navigate to the album
4. Press `S` → Enter to select it
5. Navigate to where you want the symlink in your output share
6. Press `S` → Enter to confirm destination
7. Confirm — link created, logged in manifest with timestamp


* * *

## 6. Navidrome (or Plex, Jellyfin, any music app)

Symlinks in your output share point back to your source shares. Any container reading that share needs those same source paths mounted — same rule, same paths.

Add your source shares to Navidrome's volumes alongside your output share:

```yaml
volumes:
  - /mnt/user/CuratedMusic:/CuratedMusic:ro
  - /mnt/user/FlacLibrary:/mnt/user/FlacLibrary:ro
  - /mnt/user/Soundtracks:/mnt/user/Soundtracks:ro
  - /mnt/user/ultimate_music:/mnt/user/ultimate_music:ro
```

See `navidrome-compose-example.yml` for a full ready-to-use config.
Restart Navidrome and trigger a rescan after updating.


* * *

## 7. SMB / Windows network shares showing empty folders

Samba blocks symlinks across share boundaries by default. Your files exist — Samba just refuses to follow the links.

Add these lines to your Samba global configuration, then restart the Samba service.

---

**Unraid — Settings → SMB → SMB Extra Configuration:**
```
[global]
follow symlinks = yes
wide links = yes
```
**Settings → SMB → Restart SMB.** Done.

---

**TrueNAS — Shares → Windows (SMB) Shares → Edit → Advanced Options → Auxiliary Parameters:**
```
follow symlinks = yes
wide links = yes
```
Save the share, then **Services → SMB → Restart.**

---

**OpenMediaVault — Services → SMB/CIFS → Settings → Extra Options:**
```
follow symlinks = yes
wide links = yes
```
Click **Save**, then apply pending changes. OMV will restart Samba automatically.

---

**Debian (or any standard Linux) — edit `/etc/samba/smb.conf` directly:**

Find the `[global]` section and add:
```
[global]
follow symlinks = yes
wide links = yes
```
Then restart Samba:
```bash
sudo systemctl restart smbd
```

---

SSH and Docker containers are not affected by this setting — they follow symlinks natively.


* * *

## 8. Where does persistent data live?

| What | Where |
|------|-------|
| Symlink manifest | `musiclink-config` Docker named volume |
| App config (source/target dirs) | Same named volume |
| The symlinks | Your output share |
| Your actual music | Source shares — MusicLink never writes there |

**Backup:**
```bash
docker run --rm \
  -v musiclink-config:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/musiclink-backup.tar.gz -C /data .
```

**Restore:**
```bash
docker run --rm \
  -v musiclink-config:/data \
  -v $(pwd):/backup \
  alpine tar xzf /backup/musiclink-backup.tar.gz -C /data
```
