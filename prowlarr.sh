#!/bin/bash
# thx flyingsausages and swizzin team
# based on the seerr.sh install script by brettpetch
# adapted for Prowlarr — fetches the latest release from GitHub by default
# override with: PROWLARR_VERSION=2.3.5.5327 ./prowlarr.sh

export user=$(whoami)
mkdir -p "$HOME/.logs/"
touch "$HOME/.logs/prowlarr.log"
export log="$HOME/.logs/prowlarr.log"

if [[ -z "${PROWLARR_VERSION}" ]]; then
    PROWLARR_VERSION=$(wget -qO- "https://api.github.com/repos/Prowlarr/Prowlarr/releases/latest" \
        | grep '"tag_name"' \
        | sed -E 's/.*"v([^"]+)".*/\1/')
fi

if [[ -z "${PROWLARR_VERSION}" ]]; then
    echo "Failed to resolve latest Prowlarr version. Set PROWLARR_VERSION manually and retry."
    exit 1
fi

PROWLARR_URL="https://github.com/Prowlarr/Prowlarr/releases/download/v${PROWLARR_VERSION}/Prowlarr.master.${PROWLARR_VERSION}.linux-core-x64.tar.gz"

function _install() {
    echo "Downloading Prowlarr v${PROWLARR_VERSION}..."
    wget "${PROWLARR_URL}" -q -O "/tmp/prowlarr.tar.gz" >> "${log}" 2>&1 || {
        echo "Download failed. Check ${log} for details."
        exit 1
    }
    echo "Extracting Prowlarr..."
    mkdir -p "${HOME}/prowlarr"
    tar --strip-components=1 -C "${HOME}/prowlarr" -xzf "/tmp/prowlarr.tar.gz" >> "${log}" 2>&1
    rm -f "/tmp/prowlarr.tar.gz"
    chmod +x "${HOME}/prowlarr/Prowlarr"
    echo "Prowlarr extracted successfully."
}

function _port() {
    LOW_BOUND=$1
    UPPER_BOUND=$2
    comm -23 <(seq "${LOW_BOUND}" "${UPPER_BOUND}" | sort) <(ss -Htan | awk '{print $4}' | cut -d':' -f2 | sort -u) | shuf | head -n 1
}

function _service() {
    mkdir -p "${HOME}/.config/systemd/user/"
    mkdir -p "${HOME}/.install/"
    mkdir -p "${HOME}/.config/prowlarr/"

    port=$(_port 1000 18000)
    apikey=$(cat /proc/sys/kernel/random/uuid | tr -d '-')

    # Pre-create config.xml so Prowlarr binds to the chosen port on first launch.
    # UpdateMechanism=External disables the built-in updater so the installed
    # version stays in lockstep with whatever this script pulled.
    cat > "${HOME}/.config/prowlarr/config.xml" << XMLEOF
<Config>
  <BindAddress>*</BindAddress>
  <Port>${port}</Port>
  <SslPort>6969</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <ApiKey>${apikey}</ApiKey>
  <AuthenticationMethod>None</AuthenticationMethod>
  <AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>
  <Branch>master</Branch>
  <LogLevel>info</LogLevel>
  <UrlBase></UrlBase>
  <UpdateMechanism>External</UpdateMechanism>
</Config>
XMLEOF

    cat > "${HOME}/.config/systemd/user/prowlarr.service" << EOF
[Unit]
Description=Prowlarr Service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Restart=on-failure
WorkingDirectory=%h/prowlarr
ExecStart=%h/prowlarr/Prowlarr -nobrowser -data=%h/.config/prowlarr/

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now -q prowlarr
    touch "${HOME}/.install/.prowlarr.lock"
    echo ""
    echo "Prowlarr is running at: http://$(hostname -f):${port}"
    echo "API Key: ${apikey}"
}

function _remove() {
    systemctl --user disable --now prowlarr >> "${log}" 2>&1
    sleep 2
    rm -rf "${HOME}/prowlarr"
    rm -rf "${HOME}/.config/prowlarr"
    rm -rf "${HOME}/.config/systemd/user/prowlarr.service"
    rm -rf "${HOME}/.install/.prowlarr.lock"
    echo "Prowlarr has been removed."
}

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

echo "Welcome to the Prowlarr installer..."
echo ""
echo "What would you like to do?"
echo ""
echo "install   = Install Prowlarr"
echo "uninstall = Completely removes Prowlarr"
echo "exit      = Exit installer"
while true; do
    read -r -p "Enter choice: " choice
    case $choice in
        "install")
            clear
            _install
            _service
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
            echo "Unknown option."
            ;;
    esac
done
exit
