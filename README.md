# hostingbydesign-custom-installs

Custom per-user install scripts for apps not offered by hostingbydesign's panel, targeting their shared seedbox environment (rootless, systemd `--user`, older GLIBC).

Each script handles download, config (with an auto-picked free port and generated API key), and a systemd user service. All run as the unprivileged shell user — no `sudo` required.

## Available scripts

| Script | App | Version strategy |
| --- | --- | --- |
| [radarr.sh](radarr.sh) | Radarr | Pinned to **5.28.0.10274** — last .NET 6 release compatible with GLIBC 2.17+. Newer Radarr requires GLIBC 2.33+. |
| [prowlarr.sh](prowlarr.sh) | Prowlarr | Fetches latest release from the GitHub API. Override with `PROWLARR_VERSION=x.y.z.nnnn`. |

## Usage

```bash
bash radarr.sh      # or prowlarr.sh
```

Each installer prompts for `install` / `uninstall` / `exit`. On install it prints the bound URL and API key.

Services are managed via `systemctl --user`:

```bash
systemctl --user status radarr
systemctl --user restart prowlarr
```

Logs: `~/.logs/<app>.log`. Config: `~/.config/<app>/`. Binaries: `~/<app>/`.

The built-in updater is disabled (`UpdateMechanism=External`) so the installed version stays in lockstep with what the script pulled — rerun the script to upgrade.
