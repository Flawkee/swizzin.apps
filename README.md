# swizzin.apps

Custom install scripts for apps not offered by swizzin's panel out of the box, targeting shared seedbox environments.

Most apps run as rootless systemd `--user` services. **Netdata** is an exception — it installs system-wide and runs as a system service; its script always requires `sudo`.

Each script handles download, build/config, and a systemd service. Run with `sudo` to also configure an nginx reverse proxy and add the app to the swizzin dashboard.

## Available scripts

| Script | App | nginx path | Notes |
| --- | --- | --- | --- |
| [seerr.sh](seerr.sh) | Seerr | `/seerr` | Builds from source via pnpm. No native base URL support — nginx redirects `/seerr` to the app's direct port. |
| [sonarr4k.sh](sonarr4k.sh) | Sonarr 4K | `/sonarr4k` | Second Sonarr instance for 4K content. Requires Sonarr already installed. |
| [radarr4k.sh](radarr4k.sh) | Radarr 4K | `/radarr4k` | Second Radarr instance for 4K content. Requires Radarr already installed. |
| [bazarr4k.sh](bazarr4k.sh) | Bazarr 4K | `/bazarr4k` | Second Bazarr instance for 4K content. Requires Bazarr already installed. |
| [flaresolverr.sh](flaresolverr.sh) | FlareSolverr | N/A | Downloads pre-built binary. No nginx or dashboard support — runs as a simple API service on localhost. |
| [netdata.sh](netdata.sh) | Netdata | `/netdata` | System-wide monitoring. Installs via official kickstart.sh. **Always requires sudo.** |
| [translarr.sh](translarr.sh) | Translarr | `/translarr` | Rootless Bazarr AI subtitle translator with persistent SQLite state, health-checked upgrades, and rollback. |

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

Each installer prompts for a menu action:

| Option | Description |
| --- | --- |
| `show` | Print current status: service state, port, URL, nginx and swizzin panel setup |
| `install` | Configure and start the app |
| `upgrade` | Available on Sonarr 4K, Radarr 4K, Bazarr 4K, Netdata, and Translarr. Translarr preserves state and rolls back automatically if its health check fails. |
| `secure` | Available on Netdata only. Claims the agent to Netdata Cloud and enables Bearer Token Protection. |
| `uninstall` | Stop service, remove files, and (if sudo) remove nginx config and dashboard entry |
| `exit` | Quit without doing anything |

When run with `sudo`, `install` will pause after the app is up and ask whether to proceed with nginx + dashboard setup, explaining what it will write before making any changes.

## How nginx integration works

| App | Approach |
| --- | --- |
| Sonarr 4K, Radarr 4K, Bazarr 4K | App natively serves under its `UrlBase` — nginx proxies straight through with `proxy_redirect off`. No path rewriting needed. |
| Netdata | No native subpath support. nginx uses a regex capture group (`~ /netdata/(?<ndpath>.*)`) to strip the prefix and proxy to `http://127.0.0.1:19999/$ndpath` — Netdata's documented reverse-proxy pattern. |
| Seerr | No native base URL support. nginx issues a `return 301` redirect from `/seerr` to the app's direct `http://host:port`. |
| FlareSolverr | No nginx integration. Listens on `localhost:8191` (or a custom port) for internal API use. Intended as a backend service, not exposed through nginx. |

## Service management

**User-level apps** (Seerr, Sonarr 4K, Radarr 4K, Bazarr 4K, FlareSolverr):
```bash
systemctl --user status <app>
systemctl --user restart <app>
journalctl --user -u <app> -f
```

**System-level apps** (Netdata):
```bash
systemctl status netdata
systemctl restart netdata
journalctl -u netdata -f
```

**Logs:**
- User apps: `~/.logs/<app>.log` (e.g. `~/.logs/seerr.log`, `~/.logs/flaresolverr.log`)
- Netdata: `/var/log/netdata/`

**Config:**
- User apps: `~/.config/<App>/` (e.g. `~/.config/Sonarr4k/`, `~/.config/bazarr4k/`, `~/flaresolverr/env.conf`)
- Netdata: `/etc/netdata/`

**Binaries:**
- 4K variants (Sonarr 4K, Radarr 4K, Bazarr 4K): shared from base installs (`/opt/Sonarr/`, `/opt/Radarr/`, `/opt/bazarr/`)
- Seerr: built in place at `~/seerr/`
- FlareSolverr: pre-built at `~/flaresolverr/`
- Netdata: system-wide via official kickstart

## PitzotzStory installer

`pitzotzstory.sh` installs the React / ASP.NET Core 10 marketplace tracker as one rootless user service. It follows the Translarr lifecycle: staged self-contained builds, retained port/config/data, backups, health checks and rollback, an NGINX `/PitzotzStory/` path with WebSocket support, and a Swizzin panel icon/profile. Authentication is handled by the app (Emby and local user accounts).

`install` also creates and starts the separate `pitzotzstory-companion` marketplace companion. It reuses `~/flaresolverr` when its runtime is v3.5.2, otherwise prepares a private pinned runtime under the tracker's share directory. With sudo, missing Python/venv, Chromium and Xvfb packages are installed automatically; without sudo, missing dependencies are reported before activation. The existing ARR `flaresolverr` service is left alone. A new companion prefers loopback port 8199, falls back to a free port, and prints its URL for the marketplace companion fields in app Settings.

`upgrade` automatically backs up the existing companion modules/configuration, stops it, copies all three helpers from the newly published tracker, restarts it and checks `/health`. Existing service settings, ports, credentials and browser caches are preserved. Failed activation restores the previous companion together with the previous tracker; manual rollback also restores matching companion backups when available. Nonstandard companion entry points are reported before replacing anything. Uninstall removes both the tracker and its marketplace companion, including older manually installed `cozy-flaresolverr` units, their drop-ins, configuration, database, keys, backups, dedicated runtimes and browser state. It asks for `REMOVE` confirmation (`--yes` skips the prompt). Export a backup outside the app directories first. Separate FlareSolverr/ARR installations and shared system packages are retained.

```bash
sudo bash pitzotzstory.sh --source /path/to/meowdb-tracker install
```

For the private `Flawkee/meowdb-tracker` repository, create a fine-grained GitHub PAT granting **Contents: read** on that repository, then enter it without putting it in shell history:

```bash
read -rsp 'GitHub PAT: ' MEOWDB_GITHUB_TOKEN; echo
export MEOWDB_GITHUB_TOKEN
sudo --preserve-env=MEOWDB_GITHUB_TOKEN bash pitzotzstory.sh install
unset MEOWDB_GITHUB_TOKEN
```

Use the same command with `upgrade` for updates. The installer accepts `PITZOTZSTORY_GITHUB_TOKEN`, then `MEOWDB_GITHUB_TOKEN`, then `GH_TOKEN`, then `GITHUB_TOKEN`. With sudo, preserve the variable you use. Alternatively, save the PAT in a private file (`chmod 600`) and pass `--github-token-file /absolute/path/to/token` (or `MEOWDB_GITHUB_TOKEN_FILE`, preserved through sudo). The file takes priority over token environment variables. Tokens are used only for HTTPS clones from `github.com`, through a temporary mode-600 Git configuration removed after success or failure. They are not stored in the clone URL, the app environment file, or the service unit. Supply credentials for each install/upgrade. SSH URLs and `--source` remain supported.

Use `--repo OWNER/REPO` to select a different app repository. Other actions are `upgrade`, `rollback`, `show`, `uninstall` (complete removal of the app, companion and all saved state), and `purge` (alias for uninstall). Use `--no-proxy` to manage nginx and the dashboard separately. The server needs HTTPS for production cookies and Web Push. Read the setup-code file indicated by `show` to claim the first-run setup page. Full app, Emby, cookie export, and container/Ingress instructions are in the tracker project's README.

## PitzotzStory

The canonical installer is `pitzotzstory.sh`; `meowdb-tracker.sh` remains an identical compatibility entry point. Run `sudo bash pitzotzstory.sh upgrade` to migrate existing installations. Services: `pitzotzstory` and `pitzotzstory-companion`; URL: `/PitzotzStory/`; nginx: `/etc/nginx/apps/pitzotzstory.conf`. Original encrypted data, keys and service definitions are archived before migration. Legacy directory aliases preserve virtualenv paths and older rollback archives. Old services are disabled and replaced. Use the same GitHub repository and existing token variables.
