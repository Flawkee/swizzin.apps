# swizzin.apps

Custom install scripts for apps not offered by swizzin's panel out of the box, targeting shared seedbox environments (rootless systemd `--user`, older GLIBC).

Each script handles download, build/config (auto-picked free port), and a systemd user service. Scripts that need nginx + swizzin dashboard integration must be run with `sudo`.

## Available scripts

| Script | App | Notes |
| --- | --- | --- |
| [seerr.sh](seerr.sh) | Seerr | Builds from source via pnpm. Run with `sudo` to also configure nginx reverse proxy at `/seerr` and add to the swizzin dashboard. |

## Usage

**Remote install (user-level only):**
```bash
bash <(curl -sL "https://github.com/Flawkee/swizzin.apps/raw/main/seerr.sh")
```

**Remote install with nginx + swizzin dashboard:**
```bash
sudo bash -c "$(curl -sL 'https://github.com/Flawkee/swizzin.apps/raw/main/seerr.sh')"
```

Each installer prompts for `install` / `uninstall` / `exit`. On install it prints the bound URL.

## Service management

```bash
systemctl --user status seerr
systemctl --user restart seerr
```

Logs: `~/.logs/<app>.log`. Config: `~/.config/<app>/`. Binaries: `~/<app>/`.
