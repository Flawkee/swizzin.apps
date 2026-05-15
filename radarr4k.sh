#!/bin/bash
# Radarr 4K installer for swizzin

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
    echo "  - configure nginx so Radarr 4K is reachable at https://<host>/radarr4k"
    echo "  - add Radarr 4K to the swizzin dashboard"
    echo ""
    read -r -p "Type 'continue' to install without those steps, or anything else to exit: " sudo_choice
    if [[ "$sudo_choice" != "continue" ]]; then
        echo "Aborting."
        exit 0
    fi
fi

export user="$target_user"
mkdir -p "$target_home/.logs/"
touch "$target_home/.logs/radarr4k.log"
if $SUDO_MODE; then
    chown -R "$target_user:$target_user" "$target_home/.logs"
fi
export log="$target_home/.logs/radarr4k.log"

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

function _systemd() {
    run_as_user "mkdir -p '$target_home/.config/systemd/user/'"
    tmp_unit="$(mktemp)"
    cat > "$tmp_unit" << SERVICE
[Unit]
Description=Radarr4k
After=syslog.target network.target

[Service]
Type=simple
Environment="TMPDIR=%h/.tmp"
ExecStart=%h/Radarr/Radarr -nobrowser -data=%h/.config/Radarr4k
TimeoutStopSec=20
KillMode=process
Restart=on-failure
WorkingDirectory=%h

[Install]
WantedBy=default.target
SERVICE
    install -m 0644 -o "$target_user" -g "$target_user" "$tmp_unit" "$target_home/.config/systemd/user/radarr4k.service"
    rm -f "$tmp_unit"
}

function _install() {
    if [[ ! -f "$target_home/.install/.radarr.lock" ]]; then
        echo "Radarr is not installed. Exiting..."
        exit 1
    fi

    run_as_user "mkdir -p '$target_home/.config/systemd/user/' '$target_home/.config/Radarr4k/'"
    echo "Installing the service"

    RADARR4K_PORT=$(_port 12000 14000)
    _systemd

    echo "Installing configuration"
    tmp_config="$(mktemp)"
    cat > "$tmp_config" << EOF
<Config>
  <Port>${RADARR4K_PORT}</Port>
  <UrlBase>radarr4k</UrlBase>
  <BindAddress>*</BindAddress>
  <SslPort>8787</SslPort>
  <EnableSsl>False</EnableSsl>
  <LogLevel>Info</LogLevel>
  <Branch>develop</Branch>
  <LaunchBrowser>False</LaunchBrowser>
  <UpdateMechanism>BuiltIn</UpdateMechanism>
  <AnalyticsEnabled>False</AnalyticsEnabled>
  <SslCertPath></SslCertPath>
  <AuthenticationMethod>None</AuthenticationMethod>
</Config>
EOF
    install -m 0644 -o "$target_user" -g "$target_user" "$tmp_config" "$target_home/.config/Radarr4k/config.xml"
    rm -f "$tmp_config"

    echo "Starting the service"
    systemctl_user daemon-reload
    systemctl_user enable --now -q radarr4k
    sleep 45

    apikey=$(grep -oPm1 "(?<=<ApiKey>)[^<]+" "$target_home/.config/Radarr4k/config.xml")
    if ! timeout 45 bash -c -- "while ! curl -fL \"http://127.0.0.1:${RADARR4K_PORT}/radarr4k/api/v3/system/status?apiKey=${apikey}\" >> \"$log\" 2>&1; do sleep 5; done"; then
        echo "Radarr 4K API did not respond. Make sure Radarr is installed and on v3."
        exit 1
    fi

    read -rep "Please set a password for your radarr4k user ${target_user}> " -i "" password
    echo "Applying authentication"
    payload=$(curl -sL "http://127.0.0.1:${RADARR4K_PORT}/radarr4k/api/v3/config/host?apikey=${apikey}" | jq ".authenticationMethod = \"forms\" | .username = \"${target_user}\" | .password = \"${password}\"")
    curl -s "http://127.0.0.1:${RADARR4K_PORT}/radarr4k/api/v3/config/host?apikey=${apikey}" -X PUT \
        -H 'Accept: application/json, text/javascript, */*; q=0.01' --compressed \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        --data-raw "${payload}" >> "$log"
    sleep 15

    echo "Restarting Radarr 4K"
    systemctl_user restart radarr4k

    run_as_user "mkdir -p '$target_home/.install/' && touch '$target_home/.install/.radarr4k.lock'"

    if $SUDO_MODE; then
        echo "Radarr 4K is up on http://$(hostname -f):${RADARR4K_PORT}/radarr4k (nginx will expose it at /radarr4k)"
    else
        echo "Radarr 4K is up and running at http://$(hostname -f):${RADARR4K_PORT}/radarr4k"
    fi
}

function _nginx() {
    htpasswd_file="/etc/htpasswd.d/htpasswd.${target_user}"
    auth_block=""
    if [[ -f "$htpasswd_file" ]]; then
        auth_block="    auth_basic              \"What's the password?\";
    auth_basic_user_file    ${htpasswd_file};"
    fi

    mkdir -p /etc/nginx/apps
    cat > /etc/nginx/apps/radarr4k.conf << EOF
location /radarr4k {
    return 301 \$scheme://\$host/radarr4k/;
}

location /radarr4k/ {
    proxy_pass              http://127.0.0.1:${RADARR4K_PORT}/radarr4k/;
    proxy_set_header        X-Real-IP               \$remote_addr;
    proxy_set_header        Host                    \$http_host;
    proxy_set_header        X-Forwarded-For         \$proxy_add_x_forwarded_for;
    proxy_set_header        X-Forwarded-Proto       \$scheme;
    proxy_http_version      1.1;
    proxy_set_header        Upgrade                 \$http_upgrade;
    proxy_set_header        Connection              "Upgrade";
    proxy_redirect          off;

${auth_block}

    location /radarr4k/api {
        auth_request off;
        proxy_pass http://127.0.0.1:${RADARR4K_PORT}/radarr4k/api;
    }
}
EOF

    if nginx -t >> "$log" 2>&1; then
        systemctl reload nginx
        echo "nginx configured. Radarr 4K reachable at https://$(hostname -f)/radarr4k"
    else
        echo "nginx config test failed. Check $log and /etc/nginx/apps/radarr4k.conf."
        return 1
    fi
}

function _dashboard() {
    profiles="/opt/swizzin/core/custom/profiles.py"
    mkdir -p "$(dirname "$profiles")"
    [[ -f "$profiles" ]] || touch "$profiles"

    if ! grep -q "^class radarr4k_meta:" "$profiles"; then
        cat >> "$profiles" << 'EOF'


class radarr4k_meta:
    name = "radarr4k"
    pretty_name = "Radarr 4K"
    baseurl = "/radarr4k"
    systemd = "radarr4k"
    img = "radarr"
    runas = "user"
EOF
        echo "Appended radarr4k_meta to $profiles"
    else
        echo "radarr4k_meta already present in $profiles"
    fi

    mkdir -p /install
    touch /install/.radarr4k.lock
    systemctl restart panel
    echo "swizzin dashboard updated."
}

function _show() {
    lock="$target_home/.install/.radarr4k.lock"
    if [[ ! -f "$lock" ]]; then
        echo "Radarr 4K is not installed. Run 'install' first."
        return
    fi

    port=""
    config="$target_home/.config/Radarr4k/config.xml"
    if [[ -f "$config" ]]; then
        port="$(grep -oPm1 '(?<=<Port>)[^<]+' "$config")"
    fi

    svc_status="$(systemctl_user is-active radarr4k 2>/dev/null || echo 'unknown')"

    nginx_conf="/etc/nginx/apps/radarr4k.conf"
    if [[ -f "$nginx_conf" ]]; then
        nginx_status="configured  ($nginx_conf)"
        url="https://$(hostname -f)/radarr4k"
    else
        nginx_status="not configured"
        url="http://$(hostname -f):${port:-?}/radarr4k"
    fi

    if [[ -f "/install/.radarr4k.lock" ]] && grep -q "^class radarr4k_meta:" /opt/swizzin/core/custom/profiles.py 2>/dev/null; then
        panel_status="configured"
    else
        panel_status="not configured"
    fi

    echo ""
    echo "=============================="
    echo "  Radarr 4K installation summary"
    echo "=============================="
    echo "  Service name  : radarr4k"
    echo "  Service status: $svc_status"
    echo "  Port          : ${port:-unknown}"
    echo "  URL           : $url"
    echo "  nginx         : $nginx_status"
    echo "  swizzin panel : $panel_status"
    echo ""
    echo "  Useful commands:"
    echo "    systemctl --user status radarr4k"
    echo "    systemctl --user restart radarr4k"
    echo "    journalctl --user -u radarr4k -f"
    echo "    tail -f $target_home/.logs/radarr4k.log"
    echo "=============================="
    echo ""
}

function _remove() {
    systemctl_user stop radarr4k 2>/dev/null || true
    systemctl_user disable radarr4k 2>/dev/null || true
    run_as_user "rm -rf '$target_home/.config/Radarr4k' '$target_home/.config/systemd/user/radarr4k.service' '$target_home/.install/.radarr4k.lock'"

    if $SUDO_MODE; then
        rm -f /etc/nginx/apps/radarr4k.conf
        nginx -t >> "$log" 2>&1 && systemctl reload nginx || true
        rm -f /install/.radarr4k.lock
        if [[ -f /opt/swizzin/core/custom/profiles.py ]]; then
            python3 - << 'PY'
import re
p = "/opt/swizzin/core/custom/profiles.py"
with open(p) as f:
    t = f.read()
t = re.sub(r"\n*class radarr4k_meta:.*?(?=\nclass |\Z)", "", t, flags=re.S)
with open(p, "w") as f:
    f.write(t.rstrip() + "\n")
PY
        fi
        systemctl restart panel 2>/dev/null || true
    fi
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

echo "Welcome to the Radarr 4K installer..."
echo ""
echo "What do you like to do?"
echo ""
echo "show      = Show current installation status and configuration"
echo "install   = Install Radarr 4K"
echo "upgrade   = Upgrade Radarr 4K systemd service"
echo "uninstall = Completely removes Radarr 4K"
echo "exit      = Exits Installer"
while true; do
    read -r -p "Enter it here: " choice
    case $choice in
        "show")
            _show
            ;;
        "install")
            if [[ -f "$target_home/.install/.radarr4k.lock" ]]; then
                echo "Radarr 4K is already installed."
            else
                clear
                _install
                if $SUDO_MODE; then
                    echo ""
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  nginx + swizzin dashboard setup — please read before continuing"
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo ""
                    echo "  The following will be configured:"
                    echo ""
                    echo "  1. /etc/nginx/apps/radarr4k.conf"
                    echo "     - Proxies https://<host>/radarr4k/ → Radarr 4K on port $RADARR4K_PORT"
                    echo "     - Radarr natively handles the /radarr4k base URL, no path rewriting needed."
                    echo ""
                    echo "  2. /opt/swizzin/core/custom/profiles.py"
                    echo "     - Appends radarr4k_meta so Radarr 4K appears in the swizzin panel sidebar."
                    echo ""
                    echo "  3. /install/.radarr4k.lock + panel restart"
                    echo ""
                    read -r -p "  Proceed with nginx + dashboard setup? [yes/skip]: " nginx_confirm
                    if [[ "$nginx_confirm" == "yes" ]]; then
                        _nginx
                        _dashboard
                    else
                        echo "  Skipped. Radarr 4K is running at http://$(hostname -f):$RADARR4K_PORT/radarr4k"
                        echo "  Re-run the installer and choose 'install' again to configure later."
                    fi
                    echo ""
                fi
            fi
            break
            ;;
        "upgrade")
            if [[ -f "$target_home/.install/.radarr4k.lock" ]]; then
                echo "Upgrading Radarr 4K systemd service"
                _systemd
                systemctl_user daemon-reload
                systemctl_user try-restart radarr4k
            else
                echo "Radarr 4K is not installed."
                break
            fi
            ;;
        "uninstall")
            if [[ ! -f "$target_home/.install/.radarr4k.lock" ]]; then
                echo "Radarr 4K is not installed."
                break
            else
                _remove
            fi
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
