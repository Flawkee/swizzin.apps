# swizzin.apps

Custom install scripts for apps not offered by swizzin's panel out of the box, targeting shared seedbox environments (rootless systemd `--user`, older GLIBC).

Each script handles download, build/config (auto-picked free port), and a systemd user service. Run with `sudo` to also configure an nginx reverse proxy and add the app to the swizzin dashboard.

## Available scripts

| Script | App | nginx path | Notes |
| --- | --- | --- | --- |
| [seerr.sh](seerr.sh) | Seerr | `/seerr` | Builds from source via pnpm. No native base URL support — nginx handles path rewriting via `sub_filter` + a dedicated `/api/` location. |
| [sonarr4k.sh](sonarr4k.sh) | Sonarr 4K | `/sonarr4k` | Second Sonarr instance for 4K content. Requires Sonarr already installed. |
| [radarr4k.sh](radarr4k.sh) | Radarr 4K | `/radarr4k` | Second Radarr instance for 4K content. Requires Radarr already installed. |
| [unpackerr.sh](unpackerr.sh) | Unpackerr | `/unpackerr` | Auto-detects installed arrs (Sonarr, Radarr, Lidarr) and wires their API keys into the config. |
| [unpackerr4k.sh](unpackerr4k.sh) | Unpackerr 4K | `/unpackerr4k` | Separate Unpackerr instance wired to sonarr4k + radarr4k. Separate binary, config, service and port from the standard Unpackerr. |

## Usage

Replace `<script>` with the filename (e.g. `seerr.sh`).

**Remote install — user level only (no nginx/dashboard):**
```bash
bash <(curl -sL -H 'Cache-Control: no-cache' "https://github.com/Flawkee/swizzin.apps/raw/main/<script>")
```

**Remote install — full (nginx reverse proxy + swizzin dashboard):**
```bash
sudo bash -c "$(curl -sL -H 'Cache-Control: no-cache' 'https://github.com/Flawkee/swizzin.apps/raw/main/<script>')"
```

> The `-H 'Cache-Control: no-cache'` header bypasses GitHub's CDN cache and ensures you always get the latest version of the script.

Each installer prompts for one of:

| Option | Description |
| --- | --- |
| `show` | Print current status: service state, port, URL, nginx and swizzin panel setup |
| `install` | Download, configure and start the app |
| `upgrade` | Pull the latest binary and restart (where supported) |
| `uninstall` | Stop service, remove files, and (if sudo) remove nginx config and dashboard entry |
| `exit` | Quit without doing anything |

When run with `sudo`, `install` will pause after the app is up and ask whether to proceed with nginx + dashboard setup, explaining what it will write before making any changes.

## How nginx integration works

| App | Approach |
| --- | --- |
| Sonarr 4K, Radarr 4K, Unpackerr, Unpackerr 4K | App natively serves under its `UrlBase` / `urlbase` — nginx proxies straight through with `proxy_redirect off`. No path rewriting needed. |
| Seerr | No native base URL support. nginx strips the `/seerr` prefix before forwarding (`proxy_pass .../`), rewrites redirect `Location` headers back (`proxy_redirect ~^/(.*) /seerr/$1`), rewrites absolute paths in HTML responses via `sub_filter`, and claims root-level `/api/` for seerr's hardcoded API calls. |

## Service management

```bash
systemctl --user status <app>
systemctl --user restart <app>
journalctl --user -u <app> -f
```

Logs: `~/.logs/<app>.log`  
Config: `~/.config/<App>/` (e.g. `~/.config/Sonarr4k/`)  
Binaries: `~/<App>/` for *arr apps, `~/.local/bin/<app>` for Unpackerr
