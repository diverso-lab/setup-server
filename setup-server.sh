#!/bin/bash
#
# setup-server.sh — DiversoLab VM bootstrap
#
# Two modes:
#  * Interactive (default): show a menu and prompt for each value.
#  * Non-interactive:       export SETUP_NONINTERACTIVE=1 plus the relevant
#                           SETUP_* vars and run the script. Used by vm.sh
#                           via cloud-init for fully automated provisioning.
#
# Always run as root (sudo). The script does NOT prefix commands with sudo;
# it assumes EUID=0.
#
# Non-interactive env vars:
#   SETUP_USER             primary OS user (added to docker group)
#   SETUP_SERVICES         space-separated list, e.g. "docker portainer cockpit"
#                          values: docker portainer fail2ban cockpit filebrowser
#   SETUP_SKIP_STATIC_IP   if "1", skip the netplan rewrite (cloud-init handles it)
#   SETUP_INTERFACE        default: enp1s0
#   SETUP_STATIC_IP        e.g. 192.168.100.21/24
#   SETUP_GATEWAY          default: 192.168.100.1
#   SETUP_DNS1 / SETUP_DNS2
#   SETUP_FB_SUBDOMAIN     FileBrowser baseURL key (/filebrowser/<X>)
#   SETUP_FB_SYSUSER       OS user FileBrowser runs as (default: $SETUP_USER)
#   SETUP_FB_USER          FileBrowser admin login    (default: admin)
#   SETUP_FB_PASS          FileBrowser admin password (default: $SETUP_PASS)
#   SETUP_FB_ROOT          FileBrowser root path      (default: /home/$SETUP_FB_SYSUSER)
#   SETUP_COCKPIT_URL      Cockpit baseURL key (/admin/<X>) (default: hostname)
#   SETUP_PORTAINER_USER   Portainer admin user       (default: admin)
#   SETUP_PORTAINER_PASS   Portainer admin password   (default: $SETUP_PASS)

set -e

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"; NC="\e[0m"
print_title() { echo -e "\n${CYAN}==> $1${NC}"; }
note()        { echo -e "${YELLOW}note:${NC} $*"; }

[ "$EUID" -eq 0 ] || { echo -e "${RED}Run as root (sudo).${NC}"; exit 1; }

export DEBIAN_FRONTEND=noninteractive

# ---------- Prompt helpers (env-var-first) ----------
ask()  {
    local var=$1 prompt=$2 default=${3:-}
    local current; current=$(eval "printf '%s' \"\${$var:-}\"")
    if [ -n "$current" ]; then return; fi
    if [ -n "$default" ]; then
        read -p "$prompt [$default]: " val; val=${val:-$default}
    else
        read -p "$prompt: " val
    fi
    eval "$var=\"\$val\""
}
asks() {
    local var=$1 prompt=$2
    local current; current=$(eval "printf '%s' \"\${$var:-}\"")
    if [ -n "$current" ]; then return; fi
    read -s -p "$prompt: " val; echo
    eval "$var=\"\$val\""
}

apt_install() {
    apt-get update
    apt-get install -y --no-install-recommends "$@"
}

# ============================================================
# Docker
# ============================================================
install_docker() {
    print_title "Installing Docker"
    if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
        echo "Docker already installed — skipping."
    else
        # Docker's official installer. Handles Debian/Ubuntu codenames including
        # brand-new releases (no need to maintain our own apt source list).
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
        systemctl enable --now docker
    fi

    # docker compose plugin comes with get.docker.com on supported distros, but
    # belt-and-braces install in case the convenience script skipped it.
    dpkg -s docker-compose-plugin >/dev/null 2>&1 || apt_install docker-compose-plugin || true

    # Add primary user to docker group.
    local target_user="${SETUP_USER:-${SUDO_USER:-}}"
    if [ -n "$target_user" ] && id "$target_user" >/dev/null 2>&1; then
        usermod -aG docker "$target_user" || true
    fi

    echo -e "${GREEN}Docker ready.${NC}"
}

# ============================================================
# Portainer
# ============================================================
install_portainer() {
    print_title "Installing Portainer"
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}Docker is required first.${NC}"; return 1
    fi
    if docker ps -a --format '{{.Names}}' | grep -qx portainer; then
        echo "Portainer container already exists — skipping."
        return
    fi

    : "${SETUP_PORTAINER_USER:=admin}"
    : "${SETUP_PORTAINER_PASS:=${SETUP_PASS:-}}"

    local docker_opts=( -d -p 9000:9000 --name portainer --restart=always
                        -v /var/run/docker.sock:/var/run/docker.sock
                        -v portainer_data:/data )
    local portainer_opts=()

    if [ -n "$SETUP_PORTAINER_PASS" ]; then
        # Pre-seed the admin password so the first visitor can't claim the account.
        command -v htpasswd >/dev/null 2>&1 || apt_install apache2-utils
        local pwfile=/var/lib/portainer_password
        htpasswd -nbB "$SETUP_PORTAINER_USER" "$SETUP_PORTAINER_PASS" \
            | cut -d: -f2 > "$pwfile"
        chmod 600 "$pwfile"
        docker_opts+=( -v "$pwfile:/tmp/portainer_password:ro" )
        portainer_opts+=( --admin-password-file /tmp/portainer_password )
    else
        note "No SETUP_PORTAINER_PASS — Portainer will let the first visitor set the admin account. Hit it ASAP."
    fi

    docker run "${docker_opts[@]}" portainer/portainer-ce:latest "${portainer_opts[@]}"
    echo -e "${GREEN}Portainer at http://<IP>:9000 (user: $SETUP_PORTAINER_USER)${NC}"
}

# ============================================================
# Fail2Ban
# ============================================================
install_fail2ban() {
    print_title "Installing Fail2Ban"
    if dpkg -s fail2ban >/dev/null 2>&1; then
        echo "Fail2Ban already installed — refreshing config."
    else
        apt_install fail2ban
    fi

    # The Debian package ships with /etc/fail2ban/jail.d/defaults-debian.conf
    # that enables the [sshd] jail. These VMs have SSH disabled, so fail2ban
    # would just churn over nothing. Override with a minimal jail.local.
    cat > /etc/fail2ban/jail.local <<'EOF'
# DiversoLab default — no jails enabled.
# These VMs don't expose SSH; nginx terminates TLS on the host.
# Add jail definitions here or under /etc/fail2ban/jail.d/ when you start
# exposing services from the VM that need brute-force protection.

[sshd]
enabled = false
EOF

    systemctl enable --now fail2ban
    systemctl restart fail2ban
    echo -e "${GREEN}Fail2Ban running (idle, no jails enabled).${NC}"
}

# ============================================================
# Cockpit
# ============================================================
install_cockpit() {
    print_title "Installing Cockpit"
    if ! dpkg -s cockpit >/dev/null 2>&1; then
        apt_install cockpit
    fi
    ask SETUP_COCKPIT_URL "Value for /admin/X" "$(hostname)"

    install -m 0644 /dev/stdin /etc/cockpit/cockpit.conf <<EOF
[WebService]
AllowUnencrypted=true
UrlRoot=/admin/${SETUP_COCKPIT_URL}/
ProtocolHeader = X-Forwarded-Proto
ForwardedForHeader = X-Forwarded-For

[Log]
Fatal = /var/log/cockpit.log
EOF

    # NOTE: We deliberately do NOT install NetworkManager or add the
    # dummy-interface workaround that older versions of this script used.
    # Cloud-init VMs use systemd-networkd via netplan; Cockpit's network
    # panel won't work without NM, but everything else (services, logs,
    # terminal, updates) is fine.

    systemctl restart cockpit
    echo -e "${GREEN}Cockpit at http://<IP>:9090/admin/${SETUP_COCKPIT_URL} (login: any system user)${NC}"
}

# ============================================================
# FileBrowser
# ============================================================
install_filebrowser() {
    print_title "Installing File Browser"
    : "${SETUP_FB_SYSUSER:=${SETUP_USER:-}}"
    ask  SETUP_FB_SUBDOMAIN "Subdomain name (for /filebrowser/X)" "$(hostname)"
    ask  SETUP_FB_SYSUSER   "System user to run File Browser"
    ask  SETUP_FB_USER      "File Browser admin user" "admin"
    asks SETUP_FB_PASS      "File Browser admin password"

    : "${SETUP_FB_ROOT:=/home/${SETUP_FB_SYSUSER}}"

    if [ ! -x /usr/local/bin/filebrowser ]; then
        local fb_version arch fb_arch
        fb_version=$(curl -fsSL "https://api.github.com/repos/filebrowser/filebrowser/releases/latest" \
            | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
        arch=$(uname -m)
        case "$arch" in
            x86_64)  fb_arch="linux-amd64" ;;
            aarch64) fb_arch="linux-arm64" ;;
            armv7l)  fb_arch="linux-armv7" ;;
            *)       echo -e "${RED}Unsupported architecture: $arch${NC}"; return 1 ;;
        esac
        curl -fsSL "https://github.com/filebrowser/filebrowser/releases/download/v${fb_version}/${fb_arch}-filebrowser.tar.gz" \
            -o /tmp/filebrowser.tar.gz
        tar -xzf /tmp/filebrowser.tar.gz -C /usr/local/bin filebrowser
        chmod +x /usr/local/bin/filebrowser
        rm -f /tmp/filebrowser.tar.gz
    fi

    mkdir -p /etc/filebrowser
    cat > /etc/filebrowser/default.json <<EOL
{
  "port": 4201,
  "baseURL": "/filebrowser/${SETUP_FB_SUBDOMAIN}",
  "address": "",
  "log": "stdout",
  "database": "/etc/filebrowser/filebrowser.db",
  "root": "${SETUP_FB_ROOT}",
  "auth": true
}
EOL

    if [ ! -f /etc/filebrowser/filebrowser.db ]; then
        /usr/local/bin/filebrowser config init -d /etc/filebrowser/filebrowser.db
        /usr/local/bin/filebrowser users add "$SETUP_FB_USER" "$SETUP_FB_PASS" \
            --perm.admin -d /etc/filebrowser/filebrowser.db
    fi

    cat > /etc/systemd/system/filebrowser.service <<EOL
[Unit]
Description=File Browser
After=network.target

[Service]
User=${SETUP_FB_SYSUSER}
Group=${SETUP_FB_SYSUSER}
ExecStart=/usr/local/bin/filebrowser -c /etc/filebrowser/default.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOL

    chown -R "$SETUP_FB_SYSUSER":"$SETUP_FB_SYSUSER" /etc/filebrowser
    systemctl daemon-reload
    systemctl enable --now filebrowser
    echo -e "${GREEN}File Browser at http://<IP>:4201/filebrowser/${SETUP_FB_SUBDOMAIN} (root: ${SETUP_FB_ROOT})${NC}"
}

# ============================================================
# Static IP (skipped under cloud-init — kept for legacy interactive use)
# ============================================================
configure_static_ip() {
    [ "${SETUP_SKIP_STATIC_IP:-0}" = "1" ] && { echo "Skipped (cloud-init handles networking)."; return; }
    print_title "Configuring Static IP"

    ask SETUP_INTERFACE "Interface name"        "enp1s0"
    ask SETUP_STATIC_IP "Static IP (e.g. 192.168.100.21/24)"
    ask SETUP_GATEWAY   "Gateway"                "192.168.100.1"
    ask SETUP_DNS1      "DNS 1"                  "8.8.8.8"
    ask SETUP_DNS2      "DNS 2"                  "8.8.4.4"

    cat > /etc/netplan/00-installer-config.yaml <<EOF
network:
  version: 2
  ethernets:
    ${SETUP_INTERFACE}:
      dhcp4: no
      addresses:
        - ${SETUP_STATIC_IP}
      routes:
        - to: 0.0.0.0/0
          via: ${SETUP_GATEWAY}
      nameservers:
        addresses: [${SETUP_DNS1}, ${SETUP_DNS2}]
EOF
    chmod 600 /etc/netplan/00-installer-config.yaml
    netplan apply
    echo -e "${GREEN}Static IP configured.${NC}"
}

install_all() {
    install_docker
    install_portainer
    install_fail2ban
    install_cockpit
    install_filebrowser
}

# ============================================================
# Entry point
# ============================================================
run_service() {
    case "$1" in
        docker)      install_docker ;;
        portainer)   install_portainer ;;
        fail2ban)    install_fail2ban ;;
        cockpit)     install_cockpit ;;
        filebrowser) install_filebrowser ;;
        static-ip)   configure_static_ip ;;
        all)         install_all ;;
        *)           echo -e "${RED}Unknown service: $1${NC}"; return 1 ;;
    esac
}

if [ "${SETUP_NONINTERACTIVE:-0}" = "1" ]; then
    : "${SETUP_SERVICES:=docker}"
    print_title "Non-interactive setup: ${SETUP_SERVICES}"
    for svc in $SETUP_SERVICES; do
        run_service "$svc" || echo -e "${RED}Service '$svc' failed, continuing.${NC}"
    done
    [ "${SETUP_SKIP_STATIC_IP:-0}" = "1" ] || configure_static_ip
    echo -e "${GREEN}setup-server.sh finished.${NC}"
    exit 0
fi

# Interactive menu
while true; do
    echo -e "\n${CYAN}What do you want to install?${NC}"
    select opt in \
        "Docker + Docker Compose" \
        "Portainer" \
        "Fail2Ban" \
        "Cockpit" \
        "File Browser" \
        "Install EVERYTHING" \
        "Configure Static IP" \
        "Exit"; do
        case $REPLY in
            1) install_docker;       break ;;
            2) install_portainer;    break ;;
            3) install_fail2ban;     break ;;
            4) install_cockpit;      break ;;
            5) install_filebrowser;  break ;;
            6) install_all;          break ;;
            7) configure_static_ip;  break ;;
            8) echo "Bye."; exit 0 ;;
            *) echo -e "${RED}Invalid option.${NC}" ;;
        esac
    done
done
