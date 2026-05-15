# swizzin.apps

Custom install scripts for apps not offered by swizzin's panel out of the box, targeting shared seedbox environments (rootless systemd `--user`, older GLIBC).

Each script handles download, build/config (auto-picked free port), and a systemd user service. Scripts that need nginx + swizzin dashboard integration must be run with `sudo`.

## Available scripts

| Script | App | Notes |
| --- | --- | --- |
| [radarr.sh](radarr.sh) | Radarr | Pinned to **5.28.0.10274** — last .NET 6 release compatible with GLIBC 2.17+. Newer Radarr requires GLIBC 2.33+. |
| [prowlarr.sh](prowlarr.sh) | Prowlarr | Fetches latest release from the GitHub API. Override with `PROWLARR_VERSION=x.y.z.nnnn`. |
| [seerr.sh](seerr.sh) | Seerr | Builds from source via pnpm. Run with `sudo` to also configure nginx reverse proxy at `/seerr` and add to the swizzin dashboard. |

## Usage

**Basic install (user-level only):**
```bash
bash seerr.sh
```

**Full install with nginx + swizzin dashboard:**
```bash
sudo bash seerr.sh
```

Each installer prompts for `install` / `uninstall` / `exit`. On install it prints the bound URL.

## Service management

Services are managed via `systemctl --user`:

```bash
systemctl --user status seerr
systemctl --user restart seerr
```

For radarr/prowlarr (no sudo required):
```bash
systemctl --user status radarr
systemctl --user restart prowlarr
```

Logs: `~/.logs/<app>.log`. Config: `~/.config/<app>/`. Binaries: `~/<app>/`.

The built-in updater is disabled (`UpdateMechanism=External`) so the installed version stays in lockstep with what the script pulled — rerun the script to upgrade.
