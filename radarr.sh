#!/bin/bash
# thx flyingsausages and swizzin team
# based on the seerr.sh install script by brettpetch
# adapted for Radarr 5.28.0.10274 — last .NET 6 release (GLIBC 2.17+ compatible)
# pinned to this version intentionally: newer Radarr requires GLIBC 2.33+

export user=$(whoami)
mkdir -p "$HOME/.logs/"
touch "$HOME/.logs/radarr.log"
export log="$HOME/.logs/radarr.log"

RADARR_VERSION="5.28.0.10274"
RADARR_URL="https://github.com/Radarr/Radarr/releases/download/v${RADARR_VERSION}/Radarr.master.${RADARR_VERSION}.linux-core-x64.tar.gz"

function _install() {
    echo "Downloading Radarr v${RADARR_VERSION}..."
    wget "${RADARR_URL}" -q -O "/tmp/radarr.tar.gz" >> "${log}" 2>&1 || {
        echo "Download failed. Check ${log} for details."
        exit 1
    }
    echo "Extracting Radarr..."
    mkdir -p "${HOME}/radarr"
    tar --strip-components=1 -C "${HOME}/radarr" -xzf "/tmp/radarr.tar.gz" >> "${log}" 2>&1
    rm -f "/tmp/radarr.tar.gz"
    chmod +x "${HOME}/radarr/Radarr"
    echo "Radarr extracted successfully."
}

function _port() {
    LOW_BOUND=$1
    UPPER_BOUND=$2
    comm -23 <(seq "${LOW_BOUND}" "${UPPER_BOUND}" | sort) <(ss -Htan | awk '{print $4}' | cut -d':' -f2 | sort -u) | shuf | head -n 1
}

function _service() {
    mkdir -p "${HOME}/.config/systemd/user/"
    mkdir -p "${HOME}/.install/"
    mkdir -p "${HOME}/.config/radarr/"

    port=$(_port 1000 18000)
    apikey=$(cat /proc/sys/kernel/random/uuid | tr -d '-')

    # Pre-create config.xml so Radarr binds to the chosen port on first launch.
    # UpdateMechanism=External disables the built-in updater to prevent an
    # automatic upgrade to a newer release that requires GLIBC 2.33+.
    cat > "${HOME}/.config/radarr/config.xml" << XMLEOF
<Config>
  <BindAddress>*</BindAddress>
  <Port>${port}</Port>
  <SslPort>9898</SslPort>
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

    cat > "${HOME}/.config/systemd/user/radarr.service" << EOF
[Unit]
Description=Radarr Service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Restart=on-failure
WorkingDirectory=%h/radarr
ExecStart=%h/radarr/Radarr -nobrowser -data=%h/.config/radarr/

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now -q radarr
    touch "${HOME}/.install/.radarr.lock"
    echo ""
    echo "Radarr is running at: http://$(hostname -f):${port}"
    echo "API Key: ${apikey}"
}

function _remove() {
    systemctl --user disable --now radarr >> "${log}" 2>&1
    sleep 2
    rm -rf "${HOME}/radarr"
    rm -rf "${HOME}/.config/radarr"
    rm -rf "${HOME}/.config/systemd/user/radarr.service"
    rm -rf "${HOME}/.install/.radarr.lock"
    echo "Radarr has been removed."
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

echo "Welcome to the Radarr installer..."
echo ""
echo "What would you like to do?"
echo ""
echo "install   = Install Radarr"
echo "uninstall = Completely removes Radarr"
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
