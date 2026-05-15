#!/bin/bash
# thx flyingsausages and swizzin team
# based on the overseerr install script

# --- Privilege detection -----------------------------------------------------
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
    echo "  - configure nginx so seerr is reachable at https://<host>/seerr"
    echo "  - add seerr to the swizzin dashboard"
    echo ""
    read -r -p "Type 'continue' to install seerr without those steps, or anything else to exit: " sudo_choice
    if [[ "$sudo_choice" != "continue" ]]; then
        echo "Aborting."
        exit 0
    fi
fi

export user="$target_user"
mkdir -p "$target_home/.logs/"
touch "$target_home/.logs/seerr.log"
if $SUDO_MODE; then
    chown -R "$target_user:$target_user" "$target_home/.logs"
fi
export log="$target_home/.logs/seerr.log"

# --- Helpers to run things as the target user -------------------------------
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

# --- Install steps -----------------------------------------------------------
function _deps() {
    if [[ ! -d "$target_home/.nvm" ]]; then
        echo "Installing node"
        run_as_user 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/refs/heads/master/install.sh | bash' >> "$log" 2>&1
        echo "nvm installed."
    else
        echo "nvm is already installed."
    fi
    run_as_user '
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        nvm install --lts
    ' >> "$log" 2>&1 || {
        echo "node failed to install"
        exit 1
    }
    echo "Node LTS installed."
    echo "Installing pnpm"
    run_as_user '
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        npm install -g pnpm
    ' >> "$log" 2>&1 || {
        echo "pnpm failed to install"
        exit 1
    }
    echo "pnpm installed."
}

function _seerr_install() {
    echo "Downloading and extracting source code"
    dlurl="$(curl -sS https://api.github.com/repos/seerr-team/seerr/releases/latest | jq .tarball_url -r)"
    run_as_user "wget '$dlurl' -q -O '$target_home/seerr.tar.gz'" >> "$log" 2>&1 || {
        echo "Download failed"
        exit 1
    }
    run_as_user "mkdir -p '$target_home/seerr' && tar --strip-components=1 -C '$target_home/seerr' -xzvf '$target_home/seerr.tar.gz' && rm '$target_home/seerr.tar.gz'" >> "$log" 2>&1
    echo "Code extracted"

    # When we are wiring nginx, build seerr with /seerr as its base URL.
    if $SUDO_MODE; then
        SEERR_BASEURL_BUILD='export seerr_BASEURL="/seerr";'
    else
        SEERR_BASEURL_BUILD=''
    fi

    # Bypass Node version requirement, build with latest LTS.
    run_as_user "sed -i 's|engine-strict=true|engine-strict=false|g' '$target_home/seerr/.npmrc'"

    echo "Installing dependencies via pnpm (this might take a while)"
    run_as_user "
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
        pnpm install --prefix '$target_home/seerr'
    " >> "$log" 2>&1 || {
        echo "Failed to install dependencies"
        exit 1
    }
    echo "Dependencies installed"

    echo "Building seerr (this might take a while)"
    # Limit CPU
    run_as_user "sed -i 's|256000,|256000,\n    cpus: 6,|g' '$target_home/seerr/next.config.js'"
    run_as_user "
        $SEERR_BASEURL_BUILD
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
        pnpm --prefix '$target_home/seerr' build
    " >> "$log" 2>&1 || {
        echo "Failed to build seerr"
        exit 1
    }
    echo "Succesfully built"
}

function _port() {
    LOW_BOUND=$1
    UPPER_BOUND=$2
    comm -23 <(seq "${LOW_BOUND}" "${UPPER_BOUND}" | sort) <(ss -Htan | awk '{print $4}' | cut -d':' -f2 | sort -u) | shuf | head -n 1
}

function _service() {
    run_as_user "mkdir -p '$target_home/.config/systemd/user' '$target_home/.install' '$target_home/.config/seerr'"

    node_path="$(run_as_user 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; which node' | tail -n1)"

    tmp_unit="$(mktemp)"
    cat > "$tmp_unit" << EOF
[Unit]
Description=seerr Service
Wants=network-online.target
After=network-online.target
[Service]
EnvironmentFile=%h/seerr/env.conf
Environment=NODE_ENV=production
Type=exec
Restart=on-failure
WorkingDirectory=%h/seerr
ExecStart=$node_path dist/index.js
[Install]
WantedBy=default.target
EOF
    install -m 0644 -o "$target_user" -g "$target_user" "$tmp_unit" "$target_home/.config/systemd/user/seerr.service"
    rm -f "$tmp_unit"

    SEERR_PORT=$(_port 1000 18000)

    tmp_env="$(mktemp)"
    cat > "$tmp_env" << EOF
# specify on which port to listen
PORT=$SEERR_PORT
EOF
    install -m 0644 -o "$target_user" -g "$target_user" "$tmp_env" "$target_home/seerr/env.conf"
    rm -f "$tmp_env"

    systemctl_user daemon-reload
    systemctl_user enable --now -q seerr
    run_as_user "touch '$target_home/.install/.seerr.lock'"

    if $SUDO_MODE; then
        echo "seerr listening on 127.0.0.1:$SEERR_PORT (nginx will expose it at /seerr)"
    else
        echo "seerr is up and running on http://$(hostname -f):$SEERR_PORT"
    fi
}

# --- Nginx + swizzin dashboard (root only) ----------------------------------
function _nginx() {
    if [[ -z "${SEERR_PORT:-}" ]]; then
        echo "SEERR_PORT not set, skipping nginx config."
        return 1
    fi

    htpasswd_file="/etc/htpasswd.d/htpasswd.${target_user}"
    auth_block=""
    if [[ -f "$htpasswd_file" ]]; then
        auth_block="    auth_basic              \"What's the password?\";
    auth_basic_user_file    ${htpasswd_file};"
    fi

    mkdir -p /etc/nginx/apps
    cat > /etc/nginx/apps/seerr.conf << EOF
location /seerr {
    return 301 \$scheme://\$host/seerr/;
}

location /seerr/ {
    proxy_pass              http://127.0.0.1:${SEERR_PORT}/seerr/;
    proxy_set_header        X-Real-IP               \$remote_addr;
    proxy_set_header        Host                    \$http_host;
    proxy_set_header        X-Forwarded-For         \$proxy_add_x_forwarded_for;
    proxy_set_header        X-Forwarded-Proto       \$scheme;
    proxy_http_version      1.1;
    proxy_set_header        Upgrade                 \$http_upgrade;
    proxy_set_header        Connection              "Upgrade";
    proxy_redirect          off;

${auth_block}

    # Allow the seerr API through if you enable Auth on the block above
    location /seerr/api {
        auth_request off;
        proxy_pass http://127.0.0.1:${SEERR_PORT}/seerr/api;
    }
}
EOF

    if nginx -t >> "$log" 2>&1; then
        systemctl reload nginx
        echo "nginx configured. seerr reachable at https://$(hostname -f)/seerr"
    else
        echo "nginx config test failed. Check $log and /etc/nginx/apps/seerr.conf."
        return 1
    fi
}

function _dashboard() {
    # Drop the icon next to the other dashboard icons. We try to mirror an
    # existing app's icon directory so we land in the right place regardless
    # of swizzin layout differences.
    icon_dir=""
    for candidate in /srv/panel/static/img/dashboard /opt/swizzin/core/static/img/dashboard /srv/panel/static/img; do
        if [[ -d "$candidate" ]]; then
            icon_dir="$candidate"
            break
        fi
    done

    icon_url="https://raw.githubusercontent.com/Flawkee/hostingbydesign-custom-apps/main/seerr.png"
    if [[ -n "$icon_dir" ]]; then
        if curl -fsSL -o "$icon_dir/seerr.png" "$icon_url" 2>>"$log"; then
            echo "Icon installed to $icon_dir/seerr.png"
        else
            echo "Could not download seerr icon from $icon_url (continuing without custom icon)."
        fi
    else
        echo "Could not locate swizzin dashboard image dir; skipping icon."
    fi

    profiles="/opt/swizzin/core/custom/profiles.py"
    mkdir -p "$(dirname "$profiles")"
    [[ -f "$profiles" ]] || touch "$profiles"

    if ! grep -q "^class seerr_meta:" "$profiles"; then
        cat >> "$profiles" << 'EOF'


class seerr_meta:
    name = "seerr"
    pretty_name = "Seerr"
    baseurl = "/seerr"
    systemd = "seerr"
    img = "seerr"
    runas = "user"
EOF
        echo "Appended seerr_meta to $profiles"
    else
        echo "seerr_meta already present in $profiles"
    fi

    mkdir -p /install
    touch /install/.seerr.lock
    systemctl restart panel
    echo "swizzin dashboard updated."
}

function _remove() {
    systemctl_user disable --now seerr 2>/dev/null || true
    sleep 2
    run_as_user "rm -rf '$target_home/seerr' '$target_home/.config/seerr' '$target_home/.config/systemd/user/seerr.service' '$target_home/.install/.seerr.lock'"

    if $SUDO_MODE; then
        rm -f /etc/nginx/apps/seerr.conf
        if nginx -t >> "$log" 2>&1; then
            systemctl reload nginx
        fi

        rm -f /install/.seerr.lock
        if [[ -f /opt/swizzin/core/custom/profiles.py ]]; then
            python3 - << 'PY'
import re
p = "/opt/swizzin/core/custom/profiles.py"
with open(p) as f:
    t = f.read()
t = re.sub(r"\n*class seerr_meta:.*?(?=\nclass |\Z)", "", t, flags=re.S)
with open(p, "w") as f:
    f.write(t.rstrip() + "\n")
PY
        fi
        for candidate in /srv/panel/static/img/dashboard /opt/swizzin/core/static/img/dashboard /srv/panel/static/img; do
            rm -f "$candidate/seerr.png"
        done
        systemctl restart panel 2>/dev/null || true
    fi
}

# --- Entry point -------------------------------------------------------------
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

echo "Welcome to the seerr installer..."
echo ""
echo "What do you like to do?"
echo ""
echo "install = Install seerr"
echo "uninstall = Completely removes seerr"
echo "exit = Exits Installer"
while true; do
    read -r -p "Enter it here: " choice
    case $choice in
        "install")
            clear
            _deps
            _seerr_install
            _service
            if $SUDO_MODE; then
                _nginx
                _dashboard
            fi
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
