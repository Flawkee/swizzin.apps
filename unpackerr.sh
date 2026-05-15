#!/bin/bash
# Unpackerr installer for swizzin

# --- Privilege detection ---
if [[ $EUID -eq 0 ]]; then
    if [[ -z "${SUDO_USER:-}" ]] || [[ "$SUDO_USER" == "root" ]]; then
        echo "Run this script with sudo from your normal user account (not directly as root)."
        exit 1
    fi
    SUDO_MODE=true
    target_user="$SUDO_USER"
else
    SUDO_MODE=false
    target_user="$(whoami)"
fi
target_home="$(getent passwd "$target_user" | cut -d: -f6)"
target_uid="$(id -u "$target_user")"

if ! $SUDO_MODE; then
    echo ""
    echo "Not running with sudo."
    echo "Without sudo this installer cannot:"
    echo "  - configure nginx so Unpackerr is reachable at https://<host>/unpackerr"
    echo "  - add Unpackerr to the swizzin dashboard"
    echo ""
    read -r -p "Type 'continue' to install without those steps, or anything else to exit: " sudo_choice
    if [[ "$sudo_choice" != "continue" ]]; then
        echo "Aborting."
        exit 0
    fi
fi

export user="$target_user"
mkdir -p "$target_home/.logs/"
touch "$target_home/.logs/unpackerr.log"
if $SUDO_MODE; then
    chown -R "$target_user:$target_user" "$target_home/.logs"
fi
export log="$target_home/.logs/unpackerr.log"
app="unpackerr"

run_as_user() {
    if $SUDO_MODE; then
        sudo -u "$target_user" -H bash -lc "$1"
    else
        bash -lc "$1"
    fi
}

systemctl_user() {
    if $SUDO_MODE; then
        sudo -u "$target_user" \
            XDG_RUNTIME_DIR="/run/user/$target_uid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$target_uid/bus" \
            systemctl --user "$@"
    else
        systemctl --user "$@"
    fi
}

function _port() {
    LOW_BOUND=$1
    UPPER_BOUND=$2
    comm -23 <(seq "${LOW_BOUND}" "${UPPER_BOUND}" | sort) <(ss -Htan | awk '{print $4}' | cut -d':' -f2 | sort -u) | shuf | head -n 1
}

# Check if an app is installed via lock file (user or system level) or running process.
# Usage: _app_is_installed <lockname> <process-search-term>
_app_is_installed() {
    local lockname="$1"
    local proc="$2"
    [[ -f "$target_home/.install/.${lockname}.lock" ]] && return 0
    [[ -f "/install/.${lockname}.lock" ]] && return 0
    pgrep -fa "$proc" > /dev/null 2>&1 && return 0
    return 1
}

function _get_latest_release() {
    case "$(dpkg --print-architecture)" in
        "amd64") arch='amd64' ;;
        "arm64") arch="arm64" ;;
        "armhf") arch="armhf" ;;
        "i386")  arch="i386"  ;;
        *)
            echo "Arch not supported"
            exit 1
            ;;
    esac
    latest=$(curl -sL https://api.github.com/repos/davidnewhall/unpackerr/releases/latest \
        | grep "${arch}.linux" | grep browser_download_url | cut -d \" -f4) || {
        echo "Failed to query GitHub for latest version"
        exit 1
    }
    if ! curl "$latest" -L -o "/tmp/unpackerr.gz" >> "$log" 2>&1; then
        echo "Download failed, exiting"
        exit 1
    fi
    gzip -d "/tmp/unpackerr.gz" || {
        echo "Failed to extract"
        exit 1
    }
    run_as_user "mkdir -p '$target_home/.local/bin/'"
    install -m 0755 -o "$target_user" -g "$target_user" /tmp/unpackerr "$target_home/.local/bin/unpackerr"
    rm -f /tmp/unpackerr /tmp/unpackerr.gz
    echo "Archive extracted."
}

function _install() {
    echo "Downloading latest release"
    _get_latest_release
    echo "Latest release installed."

    echo "Configuring Unpackerr"
    subnet=$(cat "$target_home/.install/subnet.lock")
    UNPACKERR_PORT=$(_port 14000 16000)

    run_as_user "mkdir -p '$target_home/.config/unpackerr'"

    tmp_conf="$(mktemp)"
    cat > "$tmp_conf" << EOF
debug = false
quiet = false
log_file = "$target_home/.config/unpackerr/unpackerr.log"
log_files = 1
log_file_mb = 10
interval = "2m"
start_delay = "1m"
retry_delay = "5m"
parallel = 1
file_mode = "0644"
dir_mode = "0755"

[webserver]
listen_addr = "127.0.0.1:${UNPACKERR_PORT}"
urlbase = "/unpackerr"
EOF

    if _app_is_installed "sonarr" "Sonarr"; then
        sonarr_base=$(sed -n 's|.*<UrlBase>\(.*\)</UrlBase>|\1|p' "$target_home/.config/Sonarr/config.xml")
        sonarr_api=$(sed -n 's|.*<ApiKey>\(.*\)</ApiKey>|\1|p' "$target_home/.config/Sonarr/config.xml")
        sonarr_port=$(sed -n 's|.*<Port>\(.*\)</Port>|\1|p' "$target_home/.config/Sonarr/config.xml")
        cat >> "$tmp_conf" << EOF

[[sonarr]]
  url = "http://${subnet}:${sonarr_port}/${sonarr_base}"
  api_key = "${sonarr_api}"
  paths = ["$target_home/torrents/rtorrent/","$target_home/torrents/qbittorrent/","$target_home/torrents/deluge/"]
  protocols = "torrent"
  timeout = "10s"
  delete_delay = "5m"
  delete_orig = false
EOF
    fi

    if _app_is_installed "radarr" "Radarr"; then
        radarr_api=$(sed -n 's|.*<ApiKey>\(.*\)</ApiKey>|\1|p' "$target_home/.config/Radarr/config.xml")
        radarr_port=$(sed -n 's|.*<Port>\(.*\)</Port>|\1|p' "$target_home/.config/Radarr/config.xml")
        radarr_base=$(sed -n 's|.*<UrlBase>\(.*\)</UrlBase>|\1|p' "$target_home/.config/Radarr/config.xml")
        cat >> "$tmp_conf" << EOF

[[radarr]]
  url = "http://${subnet}:${radarr_port}/${radarr_base}"
  api_key = "${radarr_api}"
  paths = ["$target_home/torrents/rtorrent/","$target_home/torrents/qbittorrent/","$target_home/torrents/deluge/"]
  protocols = "torrent"
  timeout = "10s"
  delete_delay = "5m"
  delete_orig = false
EOF
    fi

    if _app_is_installed "lidarr" "Lidarr"; then
        lidarr_api=$(sed -n 's|.*<ApiKey>\(.*\)</ApiKey>|\1|p' "$target_home/.config/Lidarr/config.xml")
        lidarr_port=$(sed -n 's|.*<Port>\(.*\)</Port>|\1|p' "$target_home/.config/Lidarr/config.xml")
        lidarr_base=$(sed -n 's|.*<UrlBase>\(.*\)</UrlBase>|\1|p' "$target_home/.config/Lidarr/config.xml")
        cat >> "$tmp_conf" << EOF

[[lidarr]]
  url = "http://${subnet}:${lidarr_port}/${lidarr_base}"
  api_key = "${lidarr_api}"
  paths = ["$target_home/torrents/rtorrent/","$target_home/torrents/qbittorrent/","$target_home/torrents/deluge/"]
  protocols = "torrent"
  timeout = "10s"
  delete_delay = "5m"
  delete_orig = false
EOF
    fi

    install -m 0644 -o "$target_user" -g "$target_user" "$tmp_conf" "$target_home/.config/unpackerr/unpackerr.conf"
    rm -f "$tmp_conf"

    tmp_unit="$(mktemp)"
    cat > "$tmp_unit" << EOF
[Unit]
Description=Unpackerr - Extracts downloads so Radarr, Sonarr, Lidarr or Readarr may import them.

[Service]
ExecStart=$target_home/.local/bin/unpackerr --config $target_home/.config/unpackerr/unpackerr.conf
Restart=always
RestartSec=10
SyslogIdentifier=unpackerr
Type=simple
WorkingDirectory=/tmp

[Install]
WantedBy=default.target
EOF
    run_as_user "mkdir -p '$target_home/.config/systemd/user/'"
    install -m 0644 -o "$target_user" -g "$target_user" "$tmp_unit" "$target_home/.config/systemd/user/unpackerr.service"
    rm -f "$tmp_unit"

    systemctl_user daemon-reload
    systemctl_user enable --now unpackerr >> "$log" 2>&1
    run_as_user "touch '$target_home/.install/.unpackerr.lock'"
    echo "Unpackerr installed."
}

function _nginx() {
    htpasswd_file="/etc/htpasswd.d/htpasswd.${target_user}"
    auth_block=""
    if [[ -f "$htpasswd_file" ]]; then
        auth_block="    auth_basic              \"What's the password?\";
    auth_basic_user_file    ${htpasswd_file};"
    fi

    mkdir -p /etc/nginx/apps
    cat > /etc/nginx/apps/unpackerr.conf << EOF
location /unpackerr {
    return 301 \$scheme://\$host/unpackerr/;
}

location /unpackerr/ {
    proxy_pass              http://127.0.0.1:${UNPACKERR_PORT}/unpackerr/;
    proxy_set_header        X-Real-IP               \$remote_addr;
    proxy_set_header        Host                    \$http_host;
    proxy_set_header        X-Forwarded-For         \$proxy_add_x_forwarded_for;
    proxy_set_header        X-Forwarded-Proto       \$scheme;
    proxy_http_version      1.1;
    proxy_set_header        Upgrade                 \$http_upgrade;
    proxy_set_header        Connection              "Upgrade";
    proxy_redirect          off;

${auth_block}
}
EOF

    if nginx -t >> "$log" 2>&1; then
        systemctl reload nginx
        echo "nginx configured. Unpackerr reachable at https://$(hostname -f)/unpackerr"
    else
        echo "nginx config test failed. Check $log and /etc/nginx/apps/unpackerr.conf."
        return 1
    fi
}

function _dashboard() {
    profiles="/opt/swizzin/core/custom/profiles.py"
    mkdir -p "$(dirname "$profiles")"
    [[ -f "$profiles" ]] || touch "$profiles"

    if ! grep -q "^class unpackerr_meta:" "$profiles"; then
        cat >> "$profiles" << 'EOF'


class unpackerr_meta:
    name = "unpackerr"
    pretty_name = "Unpackerr"
    baseurl = "/unpackerr"
    systemd = "unpackerr"
    img = "unpackerr"
    runas = "user"
EOF
        echo "Appended unpackerr_meta to $profiles"
    else
        echo "unpackerr_meta already present in $profiles"
    fi

    mkdir -p /install
    touch /install/.unpackerr.lock
    systemctl restart panel
    echo "swizzin dashboard updated."
}

function _show() {
    lock="$target_home/.install/.unpackerr.lock"
    if [[ ! -f "$lock" ]]; then
        echo "Unpackerr is not installed. Run 'install' first."
        return
    fi

    port=""
    conf="$target_home/.config/unpackerr/unpackerr.conf"
    if [[ -f "$conf" ]]; then
        port="$(grep -oP '(?<=listen_addr = "127\.0\.0\.1:)\d+' "$conf")"
    fi

    svc_status="$(systemctl_user is-active unpackerr 2>/dev/null || echo 'unknown')"

    nginx_conf="/etc/nginx/apps/unpackerr.conf"
    if [[ -f "$nginx_conf" ]]; then
        nginx_status="configured  ($nginx_conf)"
        url="https://$(hostname -f)/unpackerr"
    else
        nginx_status="not configured"
        url="http://$(hostname -f):${port:-?}/unpackerr"
    fi

    if [[ -f "/install/.unpackerr.lock" ]] && grep -q "^class unpackerr_meta:" /opt/swizzin/core/custom/profiles.py 2>/dev/null; then
        panel_status="configured"
    else
        panel_status="not configured"
    fi

    echo ""
    echo "=============================="
    echo "  Unpackerr installation summary"
    echo "=============================="
    echo "  Service name  : unpackerr"
    echo "  Service status: $svc_status"
    echo "  Port          : ${port:-unknown}"
    echo "  URL           : $url"
    echo "  nginx         : $nginx_status"
    echo "  swizzin panel : $panel_status"
    echo ""
    echo "  Useful commands:"
    echo "    systemctl --user status unpackerr"
    echo "    systemctl --user restart unpackerr"
    echo "    journalctl --user -u unpackerr -f"
    echo "    tail -f $target_home/.logs/unpackerr.log"
    echo "=============================="
    echo ""
}

function _remove() {
    echo "Removing Unpackerr."
    systemctl_user stop unpackerr 2>/dev/null || true
    systemctl_user disable unpackerr 2>/dev/null || true
    run_as_user "rm -rf '$target_home/.config/unpackerr' '$target_home/.local/bin/unpackerr' '$target_home/.config/systemd/user/unpackerr.service' '$target_home/.install/.unpackerr.lock'"

    if $SUDO_MODE; then
        rm -f /etc/nginx/apps/unpackerr.conf
        nginx -t >> "$log" 2>&1 && systemctl reload nginx || true
        rm -f /install/.unpackerr.lock
        if [[ -f /opt/swizzin/core/custom/profiles.py ]]; then
            python3 - << 'PY'
import re
p = "/opt/swizzin/core/custom/profiles.py"
with open(p) as f:
    t = f.read()
t = re.sub(r"\n*class unpackerr_meta:.*?(?=\nclass |\Z)", "", t, flags=re.S)
with open(p, "w") as f:
    f.write(t.rstrip() + "\n")
PY
        fi
        systemctl restart panel 2>/dev/null || true
    fi
    echo "Unpackerr removed."
}

function _upgrade() {
    echo "Upgrading Unpackerr."
    systemctl_user stop unpackerr
    _get_latest_release
    systemctl_user start unpackerr
    echo "Unpackerr upgraded."
}

# --- Entry point ---
echo 'This is unsupported software. You will not get help with this, please answer `yes` if you understand and wish to proceed'
if [[ -z ${eula} ]]; then
    read -r eula
fi
if ! [[ $eula =~ yes ]]; then
    echo "You did not accept the above. Exiting..."
    exit 1
else
    echo "Proceeding with installation"
fi

echo "Welcome to the Unpackerr installer..."
echo ""
echo "Logs are stored at ${log}"
echo ""
echo "What do you like to do?"
echo ""
echo "show      = Show current installation status and configuration"
echo "install   = Install Unpackerr"
echo "upgrade   = Upgrade Unpackerr to latest version"
echo "uninstall = Completely removes Unpackerr"
echo "exit      = Exits Installer"
while true; do
    read -r -p "Enter it here: " choice
    case $choice in
        "show")
            _show
            ;;
        "install")
            if [[ -f "$target_home/.install/.unpackerr.lock" ]]; then
                echo "Unpackerr is already installed."
            else
                _install
                if $SUDO_MODE; then
                    echo ""
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  nginx + swizzin dashboard setup — please read before continuing"
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo ""
                    echo "  1. /etc/nginx/apps/unpackerr.conf"
                    echo "     - Proxies https://<host>/unpackerr/ → Unpackerr on port $UNPACKERR_PORT"
                    echo ""
                    echo "  2. /opt/swizzin/core/custom/profiles.py"
                    echo "     - Appends unpackerr_meta for the swizzin panel sidebar."
                    echo ""
                    read -r -p "  Proceed with nginx + dashboard setup? [yes/skip]: " nginx_confirm
                    if [[ "$nginx_confirm" == "yes" ]]; then
                        _nginx
                        _dashboard
                    else
                        echo "  Skipped. Unpackerr webUI is at http://$(hostname -f):$UNPACKERR_PORT/unpackerr"
                    fi
                    echo ""
                fi
            fi
            break
            ;;
        "upgrade")
            _upgrade
            break
            ;;
        "uninstall")
            _remove
            break
            ;;
        "exit")
            break
            ;;
        *)
            echo "Unknown Option."
            ;;
    esac
done
exit
