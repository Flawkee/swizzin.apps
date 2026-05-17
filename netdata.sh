#!/bin/bash
# Netdata installer for swizzin
# Full system-level installation via the official kickstart script.

# --- Privilege detection ---
# Netdata is a system service — install/uninstall/nginx all require root.
if [[ $EUID -eq 0 ]]; then
    SUDO_MODE=true
    # Prefer the original user for dashboard/log paths; fall back to root.
    if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
        target_user="$SUDO_USER"
    else
        target_user="root"
    fi
else
    SUDO_MODE=false
    target_user="$(whoami)"
fi
target_home="$(getent passwd "$target_user" | cut -d: -f6)"

if ! $SUDO_MODE; then
    echo ""
    echo "Not running with sudo."
    echo "Netdata is a system-level service — install, nginx, and dashboard all require sudo."
    echo ""
    read -r -p "Type 'continue' to show status only, or anything else to exit: " sudo_choice
    if [[ "$sudo_choice" != "continue" ]]; then
        echo "Aborting."
        exit 0
    fi
fi

mkdir -p "$target_home/.logs/"
touch "$target_home/.logs/netdata.log"
export log="$target_home/.logs/netdata.log"

# --- Helpers ---

_netdata_port() {
    local conf="/etc/netdata/netdata.conf"
    if [[ -f "$conf" ]]; then
        local port
        port=$(grep -oP '(?<=bind to = 127\.0\.0\.1:)\d+' "$conf" 2>/dev/null | head -1)
        [[ -n "$port" ]] && echo "$port" && return
        port=$(grep -oP '(?<=bind to = )\S+' "$conf" 2>/dev/null | grep -oP '\d+$' | head -1)
        [[ -n "$port" ]] && echo "$port" && return
    fi
    echo "19999"
}

# --- Security ---

function _secure() {
    local token="$1"
    local conf="/etc/netdata/netdata.conf"

    echo "Claiming agent to Netdata Cloud..."
    local claim_script
    for p in \
            "/opt/netdata/usr/sbin/netdata-claim.sh" \
            "/usr/sbin/netdata-claim.sh" \
            "/usr/lib/netdata/netdata-claim.sh"; do
        [[ -x "$p" ]] && claim_script="$p" && break
    done

    if [[ -z "$claim_script" ]]; then
        echo "Could not find netdata-claim.sh. Skipping cloud claim."
        echo "Claim manually: https://learn.netdata.cloud/docs/netdata-cloud/connect-agent"
        return 1
    fi

    if "$claim_script" -token="$token" -url=https://app.netdata.cloud >> "$log" 2>&1; then
        echo "Agent claimed to Netdata Cloud."
    else
        echo "Claiming failed. Check: $log"
        echo "You can retry manually:"
        echo "  sudo $claim_script -token=<your-token> -url=https://app.netdata.cloud"
        return 1
    fi

    echo "Enabling Bearer Token Protection..."
    if grep -q '^\s*bearer token protection' "$conf" 2>/dev/null; then
        sed -i 's|^\s*bearer token protection\s*=.*|	bearer token protection = yes|' "$conf"
    elif grep -q '^\[web\]' "$conf" 2>/dev/null; then
        sed -i '/^\[web\]/a\\tbearer token protection = yes' "$conf"
    else
        printf '\n[web]\n\tbearer token protection = yes\n' >> "$conf"
    fi

    systemctl restart netdata
    echo "Bearer Token Protection enabled. Dashboard requires Netdata Cloud sign-in."
}

# --- Install steps ---

function _install() {
    echo "Running Netdata kickstart installer..."
    if ! bash <(curl -sSL https://my-netdata.io/kickstart.sh) \
            --non-interactive \
            --stable-channel \
            --no-updates \
            --disable-telemetry >> "$log" 2>&1; then
        echo "Netdata kickstart failed. Check: $log"
        exit 1
    fi
    echo "Netdata installed."

    # Restrict to localhost only — nginx will be the public entry point.
    local conf="/etc/netdata/netdata.conf"
    if [[ -f "$conf" ]]; then
        if grep -q '^\s*bind to' "$conf"; then
            sed -i 's|^\s*bind to\s*=.*|	bind to = 127.0.0.1:19999|' "$conf"
        elif grep -q '^\[web\]' "$conf"; then
            sed -i '/^\[web\]/a\\tbind to = 127.0.0.1:19999' "$conf"
        else
            printf '\n[web]\n\tbind to = 127.0.0.1:19999\n' >> "$conf"
        fi
        systemctl restart netdata
        echo "Netdata configured to listen on 127.0.0.1:19999."
    fi

    touch /install/.netdata.lock
    echo "Netdata is up on http://127.0.0.1:19999 (nginx will expose it at /netdata)"

    # --- Security setup ---
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Security — your metrics are currently unprotected"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Anyone who can reach this server can view your metrics."
    echo "  The recommended way to lock this down is a two-step process:"
    echo ""
    echo "  1. Claim this agent to a Netdata Cloud space"
    echo "     → creates a signed session token tied to your Cloud account"
    echo "  2. Enable Bearer Token Protection in netdata.conf"
    echo "     → forces every browser/client to present that token; without"
    echo "       it the dashboard is rejected even over nginx"
    echo ""
    echo "  Get your claim token at https://app.netdata.cloud"
    echo "  (Space settings → Nodes → Connect a new node → copy the token)"
    echo ""
    echo "  Docs: https://learn.netdata.cloud/docs/netdata-agent/configuration/securing-agents"
    echo ""
    read -r -p "  Enter your Netdata Cloud claim token (press Enter to skip): " claim_token
    if [[ -n "$claim_token" ]]; then
        _secure "$claim_token"
    else
        echo ""
        echo "  WARNING: security setup skipped. Dashboard is accessible to anyone"
        echo "  who can reach https://$(hostname -f)/netdata (once nginx is configured)."
        echo "  Re-run this installer and choose 'secure' to set it up later."
    fi
    echo ""
}

function _nginx() {
    local port
    port=$(_netdata_port)

    mkdir -p /etc/nginx/apps
    cat > /etc/nginx/apps/netdata.conf << EOF
# Netdata — strip the /netdata/ prefix before proxying.
# Uses Netdata's documented nginx subpath pattern.
location = /netdata {
    return 301 \$scheme://\$host/netdata/;
}

location ~ /netdata/(?<ndpath>.*) {
    proxy_redirect      off;
    proxy_set_header    Host                    \$host;
    proxy_set_header    X-Forwarded-Host        \$host;
    proxy_set_header    X-Forwarded-Server      \$host;
    proxy_set_header    X-Forwarded-For         \$proxy_add_x_forwarded_for;
    proxy_set_header    X-Real-IP               \$remote_addr;
    proxy_http_version  1.1;
    proxy_pass_request_headers on;
    proxy_set_header    Connection              "keep-alive";
    proxy_pass          http://127.0.0.1:${port}/\$ndpath\$is_args\$args;
}
EOF

    if nginx -t >> "$log" 2>&1; then
        systemctl reload nginx
        echo "nginx configured. Netdata reachable at https://$(hostname -f)/netdata"
    else
        echo "nginx config test failed. Check $log and /etc/nginx/apps/netdata.conf."
        return 1
    fi
}

function _dashboard() {
    icon_dir="/opt/swizzin/static/img/apps"
    icon_url="https://raw.githubusercontent.com/Flawkee/swizzin.apps/main/netdata.png"
    if curl -fsSL -o "$icon_dir/netdata.png" "$icon_url" 2>>"$log"; then
        echo "Icon installed to $icon_dir/netdata.png"
    else
        echo "Could not download netdata icon (continuing without custom icon)."
    fi

    profiles="/opt/swizzin/core/custom/profiles.py"
    mkdir -p "$(dirname "$profiles")"
    [[ -f "$profiles" ]] || touch "$profiles"

    if ! grep -q "^class netdata_meta:" "$profiles"; then
        cat >> "$profiles" << 'EOF'


class netdata_meta:
    name = "netdata"
    pretty_name = "Netdata"
    baseurl = "/netdata"
    systemd = "netdata"
    img = "netdata"
    runas = "root"
EOF
        echo "Appended netdata_meta to $profiles"
    else
        echo "netdata_meta already present in $profiles"
    fi

    systemctl restart panel
    echo "swizzin dashboard updated."
}

function _show() {
    local port
    port=$(_netdata_port)

    local svc_status
    svc_status="$(systemctl is-active netdata 2>/dev/null || echo 'not installed')"

    local nginx_conf="/etc/nginx/apps/netdata.conf"
    local nginx_status url
    if [[ -f "$nginx_conf" ]]; then
        nginx_status="configured  ($nginx_conf)"
        url="https://$(hostname -f)/netdata"
    else
        nginx_status="not configured"
        url="http://127.0.0.1:${port}"
    fi

    local panel_status="not configured"
    if [[ -f "/install/.netdata.lock" ]] && grep -q "^class netdata_meta:" /opt/swizzin/core/custom/profiles.py 2>/dev/null; then
        panel_status="configured"
    fi

    local netdata_version=""
    netdata_version=$(netdata -v 2>/dev/null | awk '{print $2}')

    local bearer_status="disabled (dashboard is unprotected)"
    if grep -q 'bearer token protection\s*=\s*yes' /etc/netdata/netdata.conf 2>/dev/null; then
        bearer_status="enabled (requires Netdata Cloud sign-in)"
    fi

    local cloud_status="not claimed"
    if [[ -f "/var/lib/netdata/cloud.d/claimed_id" ]] || \
       [[ -f "/opt/netdata/var/lib/netdata/cloud.d/claimed_id" ]]; then
        cloud_status="claimed"
    fi

    echo ""
    echo "=============================="
    echo "  Netdata installation summary"
    echo "=============================="
    echo "  Service name  : netdata"
    echo "  Service status: $svc_status"
    echo "  Version       : ${netdata_version:-unknown}"
    echo "  Port          : $port"
    echo "  URL           : $url"
    echo "  nginx         : $nginx_status"
    echo "  swizzin panel : $panel_status"
    echo "  Cloud claim   : $cloud_status"
    echo "  Bearer token  : $bearer_status"
    echo ""
    echo "  Useful commands:"
    echo "    systemctl status netdata"
    echo "    systemctl restart netdata"
    echo "    journalctl -u netdata -f"
    echo "    tail -f /var/log/netdata/error.log"
    echo "=============================="
    echo ""
}

function _remove() {
    echo "Uninstalling Netdata..."

    # Official recommended method: re-run kickstart with --uninstall.
    # It auto-detects the install type (native pkg vs static build) and
    # locates the correct uninstaller, downloading it from GitHub if needed.
    if bash <(curl -sSL https://my-netdata.io/kickstart.sh) --uninstall >> "$log" 2>&1; then
        echo "Netdata uninstalled."
    else
        # Offline / download-failed fallback: try known local uninstaller paths.
        local env_file="/etc/netdata/.environment"
        local uninstalled=false
        for script in \
                "/opt/netdata/usr/libexec/netdata/netdata-uninstaller.sh" \
                "/usr/libexec/netdata/netdata-uninstaller.sh"; do
            if [[ -f "$script" ]]; then
                bash "$script" --yes --force --env "$env_file" >> "$log" 2>&1 \
                    && uninstalled=true && break
            fi
        done
        if ! $uninstalled; then
            echo "Could not run the Netdata uninstaller automatically."
            echo "Stopping the service. Remove Netdata packages manually if needed."
            echo "Check $log for details."
            systemctl stop netdata 2>/dev/null || true
            systemctl disable netdata 2>/dev/null || true
        fi
    fi

    rm -f /etc/nginx/apps/netdata.conf
    nginx -t >> "$log" 2>&1 && systemctl reload nginx || true

    rm -f /install/.netdata.lock
    if [[ -f /opt/swizzin/core/custom/profiles.py ]]; then
        python3 - << 'PY'
import re
p = "/opt/swizzin/core/custom/profiles.py"
with open(p) as f:
    t = f.read()
t = re.sub(r"\n*class netdata_meta:.*?(?=\nclass |\Z)", "", t, flags=re.S)
with open(p, "w") as f:
    f.write(t.rstrip() + "\n")
PY
    fi
    systemctl restart panel 2>/dev/null || true
    echo "Netdata removed."
}

function _upgrade() {
    echo "Upgrading Netdata via kickstart..."
    if ! bash <(curl -sSL https://my-netdata.io/kickstart.sh) \
            --non-interactive \
            --stable-channel \
            --no-updates \
            --disable-telemetry >> "$log" 2>&1; then
        echo "Netdata upgrade failed. Check: $log"
        exit 1
    fi
    systemctl restart netdata
    echo "Netdata upgraded and restarted."
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

echo "Welcome to the Netdata installer..."
echo ""
echo "What do you like to do?"
echo ""
echo "show      = Show current installation status and configuration"
echo "install   = Install Netdata"
echo "secure    = Claim agent to Netdata Cloud + enable Bearer Token Protection"
echo "upgrade   = Upgrade Netdata to latest stable"
echo "uninstall = Completely removes Netdata"
echo "exit      = Exits Installer"
while true; do
    read -r -p "Enter it here: " choice
    case $choice in
        "show")
            _show
            ;;
        "secure")
            if ! $SUDO_MODE; then
                echo "secure requires sudo."
                break
            fi
            if ! systemctl is-active --quiet netdata 2>/dev/null; then
                echo "Netdata is not running. Install it first."
                break
            fi
            echo ""
            echo "  Get your claim token at https://app.netdata.cloud"
            echo "  (Space settings → Nodes → Connect a new node → copy the token)"
            echo ""
            read -r -p "  Enter your Netdata Cloud claim token: " claim_token
            if [[ -n "$claim_token" ]]; then
                _secure "$claim_token"
            else
                echo "No token entered. Aborted."
            fi
            break
            ;;
        "install")
            if [[ -f "/install/.netdata.lock" ]] || systemctl is-active --quiet netdata 2>/dev/null; then
                echo "Netdata is already installed."
            else
                if ! $SUDO_MODE; then
                    echo "install requires sudo. Re-run with: sudo bash -c \"\$(curl -sL ...)\""
                    break
                fi
                clear
                _install
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  nginx + swizzin dashboard setup — please read before continuing"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo "  The following will be configured:"
                echo ""
                echo "  1. /etc/nginx/apps/netdata.conf"
                echo "     - Strips the /netdata/ prefix and proxies to Netdata on port 19999."
                echo "     - Uses Netdata's documented nginx subpath pattern (regex capture group)."
                echo ""
                echo "  2. /opt/swizzin/core/custom/profiles.py"
                echo "     - Appends netdata_meta so Netdata appears in the swizzin panel sidebar."
                echo ""
                read -r -p "  Proceed with nginx + dashboard setup? [yes/skip]: " nginx_confirm
                if [[ "$nginx_confirm" == "yes" ]]; then
                    _nginx
                    _dashboard
                else
                    echo "  Skipped. Netdata is running at http://127.0.0.1:19999"
                    echo "  Re-run the installer and choose 'install' again to configure later."
                fi
                echo ""
            fi
            break
            ;;
        "upgrade")
            if ! $SUDO_MODE; then
                echo "upgrade requires sudo."
                break
            fi
            _upgrade
            break
            ;;
        "uninstall")
            if ! $SUDO_MODE; then
                echo "uninstall requires sudo."
                break
            fi
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
