#!/bin/bash
# Bazarr 4K installer for swizzin
# Separate Bazarr instance — reuses the base Bazarr installation with a different config directory.

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
    echo "  - configure nginx so Bazarr 4K is reachable at https://<host>/bazarr4k"
    echo "  - add Bazarr 4K to the swizzin dashboard"
    echo ""
    read -r -p "Type 'continue' to install without those steps, or anything else to exit: " sudo_choice
    if [[ "$sudo_choice" != "continue" ]]; then
        echo "Aborting."
        exit 0
    fi
fi

export user="$target_user"
mkdir -p "$target_home/.logs/"
touch "$target_home/.logs/bazarr4k.log"
if $SUDO_MODE; then
    chown -R "$target_user:$target_user" "$target_home/.logs"
fi
export log="$target_home/.logs/bazarr4k.log"

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

# Ensure systemd --user services survive logout.
_check_linger() {
    if loginctl show-user "$target_user" 2>/dev/null | grep -q 'Linger=yes'; then
        return 0
    fi
    echo "Linger is not enabled for $target_user — enabling now..."
    loginctl enable-linger "$target_user"
    echo "Linger enabled for $target_user."
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

# Locate the Bazarr Python interpreter and script by inspecting the existing
# bazarr service, then falling back to common install paths.
# Sets globals: _bazarr_exec, _bazarr_workdir
_find_bazarr_info() {
    local svc_content exec_line python_bin script_path workdir

    # System-level service (swizzin box install)
    svc_content=$(systemctl cat bazarr 2>/dev/null)
    if [[ -n "$svc_content" ]]; then
        exec_line=$(echo "$svc_content" | grep -oP '(?<=ExecStart=)\S.*' | head -1)
        if [[ -n "$exec_line" ]]; then
            python_bin=$(echo "$exec_line" | awk '{print $1}')
            script_path=$(echo "$exec_line" | awk '{print $2}')
            if [[ -x "$python_bin" ]] && [[ -f "$script_path" ]]; then
                _bazarr_exec="$python_bin $script_path"
                workdir=$(echo "$svc_content" | grep -oP '(?<=WorkingDirectory=)\S+' | head -1)
                _bazarr_workdir="${workdir:-$(dirname "$script_path")}"
                return 0
            fi
        fi
    fi

    # User-level service
    local user_svc="$target_home/.config/systemd/user/bazarr.service"
    if [[ -f "$user_svc" ]]; then
        exec_line=$(grep -oP '(?<=ExecStart=)\S.*' "$user_svc" | head -1)
        exec_line="${exec_line//%h/$target_home}"
        python_bin=$(echo "$exec_line" | awk '{print $1}')
        script_path=$(echo "$exec_line" | awk '{print $2}')
        if [[ -x "$python_bin" ]] && [[ -f "$script_path" ]]; then
            _bazarr_exec="$python_bin $script_path"
            workdir=$(grep -oP '(?<=WorkingDirectory=)\S+' "$user_svc" | head -1)
            workdir="${workdir//%h/$target_home}"
            _bazarr_workdir="${workdir:-$(dirname "$script_path")}"
            return 0
        fi
    fi

    # Common paths
    local bazarr_py="/opt/bazarr/bazarr.py"
    for python in "/opt/bazarr/venv/bin/python3" "/opt/bazarr/venv/bin/python" "$(command -v python3 2>/dev/null)"; do
        if [[ -x "$python" ]] && [[ -f "$bazarr_py" ]]; then
            _bazarr_exec="$python $bazarr_py"
            _bazarr_workdir="/opt/bazarr"
            return 0
        fi
    done

    return 1
}

function _systemd() {
    if ! _find_bazarr_info; then
        echo "Cannot locate Bazarr installation. Is Bazarr installed and running?"
        exit 1
    fi
    echo "Using Bazarr exec: $_bazarr_exec"
    echo "Working directory: $_bazarr_workdir"

    run_as_user "mkdir -p '$target_home/.config/systemd/user/'"
    tmp_unit="$(mktemp)"
    cat > "$tmp_unit" << SERVICE
[Unit]
Description=Bazarr4k
After=syslog.target network.target

[Service]
Type=simple
ExecStart=$_bazarr_exec --config %h/.config/bazarr4k --port ${BAZARR4K_PORT} --no-update
WorkingDirectory=$_bazarr_workdir
TimeoutStopSec=20
KillMode=process
Restart=on-failure

[Install]
WantedBy=default.target
SERVICE
    install -m 0644 -o "$target_user" -g "$target_user" "$tmp_unit" "$target_home/.config/systemd/user/bazarr4k.service"
    rm -f "$tmp_unit"
}

function _install() {
    _check_linger
    if ! _app_is_installed "bazarr" "bazarr"; then
        echo "Bazarr is not installed. Exiting..."
        exit 1
    fi

    run_as_user "mkdir -p '$target_home/.config/bazarr4k/config'"

    BAZARR4K_PORT=$(_port 18000 20000)

    # Pre-seed config.ini so Bazarr 4K starts with the correct base URL and port.
    tmp_config="$(mktemp)"
    cat > "$tmp_config" << EOF
[general]
ip = 127.0.0.1
port = ${BAZARR4K_PORT}
base_url = /bazarr4k
EOF
    install -m 0644 -o "$target_user" -g "$target_user" "$tmp_config" "$target_home/.config/bazarr4k/config/config.ini"
    rm -f "$tmp_config"

    _systemd

    systemctl_user daemon-reload
    systemctl_user enable --now bazarr4k
    sleep 10

    if ! systemctl_user is-active --quiet bazarr4k; then
        echo "bazarr4k service failed to start. Check with:"
        echo "  journalctl --user -u bazarr4k -n 50"
        exit 1
    fi

    echo "Waiting for Bazarr 4K to initialise..."
    if ! timeout 60 bash -c -- "while ! curl -fsL \"http://127.0.0.1:${BAZARR4K_PORT}/bazarr4k\" >> \"$log\" 2>&1; do sleep 5; done"; then
        echo "Bazarr 4K did not respond. Check: journalctl --user -u bazarr4k -n 50"
        exit 1
    fi

    run_as_user "mkdir -p '$target_home/.install/' && touch '$target_home/.install/.bazarr4k.lock'"

    if $SUDO_MODE; then
        echo "Bazarr 4K is up on http://$(hostname -f):${BAZARR4K_PORT}/bazarr4k (nginx will expose it at /bazarr4k)"
    else
        echo "Bazarr 4K is up and running at http://$(hostname -f):${BAZARR4K_PORT}/bazarr4k"
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
    cat > /etc/nginx/apps/bazarr4k.conf << EOF
location /bazarr4k {
    return 301 \$scheme://\$host/bazarr4k/;
}

location /bazarr4k/ {
    proxy_pass              http://127.0.0.1:${BAZARR4K_PORT}/bazarr4k/;
    proxy_set_header        X-Real-IP               \$remote_addr;
    proxy_set_header        Host                    \$http_host;
    proxy_set_header        X-Forwarded-For         \$proxy_add_x_forwarded_for;
    proxy_set_header        X-Forwarded-Proto       \$scheme;
    proxy_http_version      1.1;
    proxy_set_header        Upgrade                 \$http_upgrade;
    proxy_set_header        Connection              "Upgrade";
    proxy_redirect          off;

${auth_block}

    location /bazarr4k/api {
        auth_request off;
        proxy_pass http://127.0.0.1:${BAZARR4K_PORT}/bazarr4k/api;
    }
}
EOF

    if nginx -t >> "$log" 2>&1; then
        systemctl reload nginx
        echo "nginx configured. Bazarr 4K reachable at https://$(hostname -f)/bazarr4k"
    else
        echo "nginx config test failed. Check $log and /etc/nginx/apps/bazarr4k.conf."
        return 1
    fi
}

function _dashboard() {
    icon_dir="/opt/swizzin/static/img/apps"
    icon_url="https://raw.githubusercontent.com/Flawkee/swizzin.apps/main/bazarr4k.png"
    if curl -fsSL -o "$icon_dir/bazarr4k.png" "$icon_url" 2>>"$log"; then
        echo "Icon installed to $icon_dir/bazarr4k.png"
    else
        echo "Could not download bazarr4k icon from $icon_url (continuing without custom icon)."
    fi

    profiles="/opt/swizzin/core/custom/profiles.py"
    mkdir -p "$(dirname "$profiles")"
    [[ -f "$profiles" ]] || touch "$profiles"

    if ! grep -q "^class bazarr4k_meta:" "$profiles"; then
        cat >> "$profiles" << 'EOF'


class bazarr4k_meta:
    name = "bazarr4k"
    pretty_name = "Bazarr 4K"
    baseurl = "/bazarr4k"
    systemd = "bazarr4k"
    img = "bazarr4k"
    runas = "user"
EOF
        echo "Appended bazarr4k_meta to $profiles"
    else
        echo "bazarr4k_meta already present in $profiles"
    fi

    mkdir -p /install
    touch /install/.bazarr4k.lock
    systemctl restart panel
    echo "swizzin dashboard updated."
}

function _show() {
    lock="$target_home/.install/.bazarr4k.lock"
    if [[ ! -f "$lock" ]]; then
        echo "Bazarr 4K is not installed. Run 'install' first."
        return
    fi

    port=""
    config="$target_home/.config/bazarr4k/config/config.ini"
    if [[ -f "$config" ]]; then
        port="$(grep -oP '(?<=^port = )\d+' "$config")"
    fi

    svc_status="$(systemctl_user is-active bazarr4k 2>/dev/null || echo 'unknown')"

    nginx_conf="/etc/nginx/apps/bazarr4k.conf"
    if [[ -f "$nginx_conf" ]]; then
        nginx_status="configured  ($nginx_conf)"
        url="https://$(hostname -f)/bazarr4k"
    else
        nginx_status="not configured"
        url="http://$(hostname -f):${port:-?}/bazarr4k"
    fi

    if [[ -f "/install/.bazarr4k.lock" ]] && grep -q "^class bazarr4k_meta:" /opt/swizzin/core/custom/profiles.py 2>/dev/null; then
        panel_status="configured"
    else
        panel_status="not configured"
    fi

    echo ""
    echo "=============================="
    echo "  Bazarr 4K installation summary"
    echo "=============================="
    echo "  Service name  : bazarr4k"
    echo "  Service status: $svc_status"
    echo "  Port          : ${port:-unknown}"
    echo "  URL           : $url"
    echo "  nginx         : $nginx_status"
    echo "  swizzin panel : $panel_status"
    echo ""
    echo "  Useful commands:"
    echo "    systemctl --user status bazarr4k"
    echo "    systemctl --user restart bazarr4k"
    echo "    journalctl --user -u bazarr4k -f"
    echo "    tail -f $target_home/.logs/bazarr4k.log"
    echo "=============================="
    echo ""
}

function _remove() {
    systemctl_user stop bazarr4k 2>/dev/null || true
    systemctl_user disable bazarr4k 2>/dev/null || true
    # Base Bazarr installation is shared — only remove 4K-specific files
    run_as_user "rm -rf '$target_home/.config/bazarr4k' '$target_home/.config/systemd/user/bazarr4k.service' '$target_home/.install/.bazarr4k.lock'"

    if $SUDO_MODE; then
        rm -f /etc/nginx/apps/bazarr4k.conf
        nginx -t >> "$log" 2>&1 && systemctl reload nginx || true
        rm -f /install/.bazarr4k.lock
        if [[ -f /opt/swizzin/core/custom/profiles.py ]]; then
            python3 - << 'PY'
import re
p = "/opt/swizzin/core/custom/profiles.py"
with open(p) as f:
    t = f.read()
t = re.sub(r"\n*class bazarr4k_meta:.*?(?=\nclass |\Z)", "", t, flags=re.S)
with open(p, "w") as f:
    f.write(t.rstrip() + "\n")
PY
        fi
        systemctl restart panel 2>/dev/null || true
    fi
    echo "Bazarr 4K removed."
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

echo "Welcome to the Bazarr 4K installer..."
echo ""
echo "What do you like to do?"
echo ""
echo "show      = Show current installation status and configuration"
echo "install   = Install Bazarr 4K"
echo "upgrade   = Upgrade Bazarr 4K systemd service"
echo "uninstall = Completely removes Bazarr 4K"
echo "exit      = Exits Installer"
while true; do
    read -r -p "Enter it here: " choice
    case $choice in
        "show")
            _show
            ;;
        "install")
            if [[ -f "$target_home/.install/.bazarr4k.lock" ]]; then
                echo "Bazarr 4K is already installed."
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
                    echo "  1. /etc/nginx/apps/bazarr4k.conf"
                    echo "     - Proxies https://<host>/bazarr4k/ → Bazarr 4K on port $BAZARR4K_PORT"
                    echo "     - Bazarr natively handles the /bazarr4k base URL, no path rewriting needed."
                    echo ""
                    echo "  2. /opt/swizzin/core/custom/profiles.py"
                    echo "     - Appends bazarr4k_meta so Bazarr 4K appears in the swizzin panel sidebar."
                    echo ""
                    echo "  3. /install/.bazarr4k.lock + panel restart"
                    echo ""
                    read -r -p "  Proceed with nginx + dashboard setup? [yes/skip]: " nginx_confirm
                    if [[ "$nginx_confirm" == "yes" ]]; then
                        _nginx
                        _dashboard
                    else
                        echo "  Skipped. Bazarr 4K is running at http://$(hostname -f):$BAZARR4K_PORT/bazarr4k"
                        echo "  Re-run the installer and choose 'install' again to configure later."
                    fi
                    echo ""
                fi
            fi
            break
            ;;
        "upgrade")
            if [[ -f "$target_home/.install/.bazarr4k.lock" ]]; then
                echo "Upgrading Bazarr 4K systemd service"
                BAZARR4K_PORT=$(grep -oP '(?<=^port = )\d+' "$target_home/.config/bazarr4k/config/config.ini" 2>/dev/null || echo "")
                if [[ -z "$BAZARR4K_PORT" ]]; then
                    echo "Could not determine port from config. Try reinstalling."
                    break
                fi
                _systemd
                systemctl_user daemon-reload
                systemctl_user try-restart bazarr4k
            else
                echo "Bazarr 4K is not installed."
                break
            fi
            ;;
        "uninstall")
            if [[ ! -f "$target_home/.install/.bazarr4k.lock" ]]; then
                echo "Bazarr 4K is not installed."
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
