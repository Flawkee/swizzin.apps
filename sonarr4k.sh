#!/bin/bash
# Sonarr 4K installer for swizzin

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
    echo "  - configure nginx so Sonarr 4K is reachable at https://<host>/sonarr4k"
    echo "  - add Sonarr 4K to the swizzin dashboard"
    echo ""
    read -r -p "Type 'continue' to install without those steps, or anything else to exit: " sudo_choice
    if [[ "$sudo_choice" != "continue" ]]; then
        echo "Aborting."
        exit 0
    fi
fi

export user="$target_user"
mkdir -p "$target_home/.logs/"
touch "$target_home/.logs/sonarr4k.log"
if $SUDO_MODE; then
    chown -R "$target_user:$target_user" "$target_home/.logs"
fi
export log="$target_home/.logs/sonarr4k.log"

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

# Locate the Sonarr binary by inspecting the existing sonarr service,
# then falling back to common install paths.
_find_sonarr_binary() {
    local bin

    # System-level service (swizzin box install)
    bin=$(systemctl cat sonarr 2>/dev/null | grep -oP '(?<=ExecStart=)\S+' | head -1)
    [[ -x "$bin" ]] && echo "$bin" && return 0

    # User-level service (installed by these scripts)
    local user_svc="$target_home/.config/systemd/user/sonarr.service"
    if [[ -f "$user_svc" ]]; then
        bin=$(grep -oP '(?<=ExecStart=)\S+' "$user_svc" | head -1)
        bin="${bin//%h/$target_home}"
        [[ -x "$bin" ]] && echo "$bin" && return 0
    fi

    # Common paths
    for p in "/opt/Sonarr/Sonarr" "$target_home/Sonarr/Sonarr" "/usr/bin/sonarr"; do
        [[ -x "$p" ]] && echo "$p" && return 0
    done

    return 1
}

function _systemd() {
    local sonarr_bin
    sonarr_bin=$(_find_sonarr_binary) || {
        echo "Cannot locate Sonarr binary. Is Sonarr installed and running?"
        exit 1
    }
    echo "Using Sonarr binary: $sonarr_bin"

    run_as_user "mkdir -p '$target_home/.config/systemd/user/'"
    tmp_unit="$(mktemp)"
    cat > "$tmp_unit" << SERVICE
[Unit]
Description=Sonarr4k
After=syslog.target network.target

[Service]
Type=simple
Environment="TMPDIR=%h/.tmp"
ExecStart=$sonarr_bin -nobrowser -data=%h/.config/Sonarr4k
WorkingDirectory=%h
Restart=on-failure

[Install]
WantedBy=default.target
SERVICE
    install -m 0644 -o "$target_user" -g "$target_user" "$tmp_unit" "$target_home/.config/systemd/user/sonarr4k.service"
    rm -f "$tmp_unit"
}

function _install() {
    if ! _app_is_installed "sonarr" "Sonarr"; then
        echo "Sonarr is not installed. Exiting..."
        exit 1
    fi

    run_as_user "mkdir -p '$target_home/.config/systemd/user/' '$target_home/.config/Sonarr4k/'"

    SONARR4K_PORT=$(_port 8000 11000)
    _systemd

    tmp_config="$(mktemp)"
    cat > "$tmp_config" << EOF
<Config>
  <LogLevel>info</LogLevel>
  <EnableSsl>False</EnableSsl>
  <Port>${SONARR4K_PORT}</Port>
  <SslPort>9898</SslPort>
  <UrlBase>sonarr4k</UrlBase>
  <BindAddress>*</BindAddress>
  <AuthenticationMethod>None</AuthenticationMethod>
  <UpdateMechanism>BuiltIn</UpdateMechanism>
  <Branch>main</Branch>
  <LaunchBrowser>False</LaunchBrowser>
  <SslCertHash></SslCertHash>
</Config>
EOF
    install -m 0644 -o "$target_user" -g "$target_user" "$tmp_config" "$target_home/.config/Sonarr4k/config.xml"
    rm -f "$tmp_config"

    systemctl_user daemon-reload
    systemctl_user enable --now sonarr4k
    sleep 10

    if ! systemctl_user is-active --quiet sonarr4k; then
        echo "sonarr4k service failed to start. Check with:"
        echo "  journalctl --user -u sonarr4k -n 50"
        exit 1
    fi

    echo "Waiting for Sonarr 4K to initialise..."
    sleep 35

    apikey=$(grep -oPm1 "(?<=<ApiKey>)[^<]+" "$target_home/.config/Sonarr4k/config.xml")
    if [[ -z "$apikey" ]]; then
        echo "ApiKey not yet written to config.xml — Sonarr 4K may still be starting."
        echo "Check: journalctl --user -u sonarr4k -n 50"
        exit 1
    fi
    if ! timeout 45 bash -c -- "while ! curl -fL \"http://127.0.0.1:${SONARR4K_PORT}/sonarr4k/api/v3/system/status?apiKey=${apikey}\" >> \"$log\" 2>&1; do sleep 5; done"; then
        echo "Sonarr 4K API did not respond. Check: journalctl --user -u sonarr4k -n 50"
        exit 1
    fi

    read -rep "Please set a password for your sonarr4k user ${target_user}> " -i "" password
    payload=$(curl -sL "http://127.0.0.1:${SONARR4K_PORT}/sonarr4k/api/v3/config/host?apikey=${apikey}" | jq ".authenticationMethod = \"forms\" | .username = \"${target_user}\" | .password = \"${password}\"")
    curl -s "http://127.0.0.1:${SONARR4K_PORT}/sonarr4k/api/v3/config/host?apikey=${apikey}" -X PUT \
        -H 'Accept: application/json, text/javascript, */*; q=0.01' --compressed \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        --data-raw "${payload}" >> "$log"
    sleep 15
    systemctl_user restart sonarr4k

    run_as_user "mkdir -p '$target_home/.install/' && touch '$target_home/.install/.sonarr4k.lock'"

    if $SUDO_MODE; then
        echo "Sonarr 4K is up on http://$(hostname -f):${SONARR4K_PORT}/sonarr4k (nginx will expose it at /sonarr4k)"
    else
        echo "Sonarr 4K is up and running at http://$(hostname -f):${SONARR4K_PORT}/sonarr4k"
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
    cat > /etc/nginx/apps/sonarr4k.conf << EOF
location /sonarr4k {
    return 301 \$scheme://\$host/sonarr4k/;
}

location /sonarr4k/ {
    proxy_pass              http://127.0.0.1:${SONARR4K_PORT}/sonarr4k/;
    proxy_set_header        X-Real-IP               \$remote_addr;
    proxy_set_header        Host                    \$http_host;
    proxy_set_header        X-Forwarded-For         \$proxy_add_x_forwarded_for;
    proxy_set_header        X-Forwarded-Proto       \$scheme;
    proxy_http_version      1.1;
    proxy_set_header        Upgrade                 \$http_upgrade;
    proxy_set_header        Connection              "Upgrade";
    proxy_redirect          off;

${auth_block}

    location /sonarr4k/api {
        auth_request off;
        proxy_pass http://127.0.0.1:${SONARR4K_PORT}/sonarr4k/api;
    }
}
EOF

    if nginx -t >> "$log" 2>&1; then
        systemctl reload nginx
        echo "nginx configured. Sonarr 4K reachable at https://$(hostname -f)/sonarr4k"
    else
        echo "nginx config test failed. Check $log and /etc/nginx/apps/sonarr4k.conf."
        return 1
    fi
}

function _dashboard() {
    profiles="/opt/swizzin/core/custom/profiles.py"
    mkdir -p "$(dirname "$profiles")"
    [[ -f "$profiles" ]] || touch "$profiles"

    if ! grep -q "^class sonarr4k_meta:" "$profiles"; then
        cat >> "$profiles" << 'EOF'


class sonarr4k_meta:
    name = "sonarr4k"
    pretty_name = "Sonarr 4K"
    baseurl = "/sonarr4k"
    systemd = "sonarr4k"
    img = "sonarr"
    runas = "user"
EOF
        echo "Appended sonarr4k_meta to $profiles"
    else
        echo "sonarr4k_meta already present in $profiles"
    fi

    mkdir -p /install
    touch /install/.sonarr4k.lock
    systemctl restart panel
    echo "swizzin dashboard updated."
}

function _show() {
    lock="$target_home/.install/.sonarr4k.lock"
    if [[ ! -f "$lock" ]]; then
        echo "Sonarr 4K is not installed. Run 'install' first."
        return
    fi

    port=""
    config="$target_home/.config/Sonarr4k/config.xml"
    if [[ -f "$config" ]]; then
        port="$(grep -oPm1 '(?<=<Port>)[^<]+' "$config")"
    fi

    svc_status="$(systemctl_user is-active sonarr4k 2>/dev/null || echo 'unknown')"

    nginx_conf="/etc/nginx/apps/sonarr4k.conf"
    if [[ -f "$nginx_conf" ]]; then
        nginx_status="configured  ($nginx_conf)"
        url="https://$(hostname -f)/sonarr4k"
    else
        nginx_status="not configured"
        url="http://$(hostname -f):${port:-?}/sonarr4k"
    fi

    if [[ -f "/install/.sonarr4k.lock" ]] && grep -q "^class sonarr4k_meta:" /opt/swizzin/core/custom/profiles.py 2>/dev/null; then
        panel_status="configured"
    else
        panel_status="not configured"
    fi

    echo ""
    echo "=============================="
    echo "  Sonarr 4K installation summary"
    echo "=============================="
    echo "  Service name  : sonarr4k"
    echo "  Service status: $svc_status"
    echo "  Port          : ${port:-unknown}"
    echo "  URL           : $url"
    echo "  nginx         : $nginx_status"
    echo "  swizzin panel : $panel_status"
    echo ""
    echo "  Useful commands:"
    echo "    systemctl --user status sonarr4k"
    echo "    systemctl --user restart sonarr4k"
    echo "    journalctl --user -u sonarr4k -f"
    echo "    tail -f $target_home/.logs/sonarr4k.log"
    echo "=============================="
    echo ""
}

function _remove() {
    systemctl_user stop sonarr4k 2>/dev/null || true
    systemctl_user disable sonarr4k 2>/dev/null || true
    run_as_user "rm -rf '$target_home/.config/Sonarr4k' '$target_home/.config/systemd/user/sonarr4k.service' '$target_home/.install/.sonarr4k.lock'"

    if $SUDO_MODE; then
        rm -f /etc/nginx/apps/sonarr4k.conf
        nginx -t >> "$log" 2>&1 && systemctl reload nginx || true
        rm -f /install/.sonarr4k.lock
        if [[ -f /opt/swizzin/core/custom/profiles.py ]]; then
            python3 - << 'PY'
import re
p = "/opt/swizzin/core/custom/profiles.py"
with open(p) as f:
    t = f.read()
t = re.sub(r"\n*class sonarr4k_meta:.*?(?=\nclass |\Z)", "", t, flags=re.S)
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

echo "Welcome to the Sonarr 4K installer..."
echo ""
echo "What do you like to do?"
echo ""
echo "show      = Show current installation status and configuration"
echo "install   = Install Sonarr 4K"
echo "upgrade   = Upgrade Sonarr 4K systemd service"
echo "uninstall = Completely removes Sonarr 4K"
echo "exit      = Exits Installer"
while true; do
    read -r -p "Enter it here: " choice
    case $choice in
        "show")
            _show
            ;;
        "install")
            if [[ -f "$target_home/.install/.sonarr4k.lock" ]]; then
                echo "Sonarr 4K is already installed."
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
                    echo "  1. /etc/nginx/apps/sonarr4k.conf"
                    echo "     - Proxies https://<host>/sonarr4k/ → Sonarr 4K on port $SONARR4K_PORT"
                    echo "     - Sonarr natively handles the /sonarr4k base URL, no path rewriting needed."
                    echo ""
                    echo "  2. /opt/swizzin/core/custom/profiles.py"
                    echo "     - Appends sonarr4k_meta so Sonarr 4K appears in the swizzin panel sidebar."
                    echo ""
                    echo "  3. /install/.sonarr4k.lock + panel restart"
                    echo ""
                    read -r -p "  Proceed with nginx + dashboard setup? [yes/skip]: " nginx_confirm
                    if [[ "$nginx_confirm" == "yes" ]]; then
                        _nginx
                        _dashboard
                    else
                        echo "  Skipped. Sonarr 4K is running at http://$(hostname -f):$SONARR4K_PORT/sonarr4k"
                        echo "  Re-run the installer and choose 'install' again to configure later."
                    fi
                    echo ""
                fi
            fi
            break
            ;;
        "upgrade")
            if [[ -f "$target_home/.install/.sonarr4k.lock" ]]; then
                echo "Upgrading Sonarr 4K systemd service"
                _systemd
                systemctl_user daemon-reload
                systemctl_user try-restart sonarr4k
            else
                echo "Sonarr 4K is not installed."
                break
            fi
            ;;
        "uninstall")
            if [[ ! -f "$target_home/.install/.sonarr4k.lock" ]]; then
                echo "Sonarr 4K is not installed."
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
