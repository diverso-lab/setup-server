#!/bin/bash

set -e

### Messages color
RED="\e[31m"
GREEN="\e[32m"
CYAN="\e[36m"
NC="\e[0m"

print_title() {
    echo -e "\n${CYAN}==> $1${NC}"
}

### File Browser
install_filebrowser() {
    print_title "Installing File Browser"

    read -p "Subdomain name (for /filebrowser/X): " subdomain
    read -p "System user to run File Browser: " sys_user
    read -p "File Browser admin user: " fb_user
    read -s -p "File Browser admin password: " fb_pass
    echo

    curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

    sudo mkdir -p /etc/filebrowser
    sudo tee /etc/filebrowser/default.json > /dev/null <<EOL
{
  "port": 4201,
  "baseURL": "/filebrowser/$subdomain",
  "address": "",
  "log": "stdout",
  "database": "/etc/filebrowser/filebrowser.db",
  "root": "/",
  "auth": true
}
EOL

    sudo /usr/local/bin/filebrowser -d /etc/filebrowser/filebrowser.db config init
    cd /etc/filebrowser
    sudo /usr/local/bin/filebrowser users add "$fb_user" "$fb_pass" --perm.admin

    sudo tee /etc/systemd/system/filebrowser.service > /dev/null <<EOL
[Unit]
Description=File browser
After=network.target

[Service]
User=$sys_user
Group=$sys_user
ExecStart=/usr/local/bin/filebrowser -c /etc/filebrowser/default.json

[Install]
WantedBy=multi-user.target
EOL

    sudo chown -R $sys_user:$sys_user /etc/filebrowser
    sudo systemctl enable filebrowser
    sudo systemctl start filebrowser

    echo -e "${GREEN}File Browser installed on http://<IP>:4201/filebrowser/$subdomain${NC}"
}

### Docker + Docker Compose
install_docker() {
    print_title "Installing Docker and Docker Compose"

    sudo apt update
    sudo apt install -y apt-transport-https ca-certificates curl software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt update
    sudo apt install -y docker-ce

    sudo usermod -aG docker ${USER}

    mkdir -p ~/.docker/cli-plugins/
    LATEST_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    curl -SL "https://github.com/docker/compose/releases/download/${LATEST_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o ~/.docker/cli-plugins/docker-compose
    chmod +x ~/.docker/cli-plugins/docker-compose

    echo -e "${GREEN}Docker and Docker Compose installed. You may need to log out and back in to use Docker without sudo.${NC}"
}

### Portainer
install_portainer() {
    print_title "Installing Portainer"

    sudo docker run -d -p 8000:8000 -p 9000:9000 --name portainer --restart=always \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        portainer/portainer-ce:latest

    echo -e "${GREEN}Portainer running at http://<IP>:9000${NC}"
}

### Fail2Ban
install_fail2ban() {
    print_title "Installing Fail2Ban"

    sudo apt update
    sudo apt install -y fail2ban
    sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban

    echo -e "${GREEN}Fail2Ban is running.${NC}"
}

### Cockpit
install_cockpit() {
    print_title "Installing Cockpit"

    sudo apt-get update
    sudo apt-get install -y cockpit

    read -p "Value for /admin/X: " cockpit_url

    sudo tee /etc/cockpit/cockpit.conf > /dev/null <<EOF
[WebService]
AllowUnencrypted=true
UrlRoot=/admin/$cockpit_url/
ProtocolHeader = X-Forwarded-Proto
ForwardedForHeader = X-Forwarded-For

[Log]
Fatal = /var/log/cockpit.log
EOF

    sudo tee /etc/NetworkManager/conf.d/10-globally-managed-devices.conf > /dev/null <<EOF
[keyfile]
unmanaged-devices=none
EOF

    sudo nmcli con add type dummy con-name fake ifname fake0 ip4 1.2.3.4/24 gw4 1.2.3.1

    sudo systemctl restart cockpit

    echo -e "${GREEN}Cockpit configured at http://<IP>:9090/admin/$cockpit_url${NC}"
}

### Shell In A Box
install_shellinabox() {
    print_title "Installing Shell In A Box"

    sudo apt-get update
    sudo apt-get install -y shellinabox
    sudo systemctl restart shellinabox
    sudo systemctl enable shellinabox

    echo -e "${GREEN}Shell In A Box running at https://<IP>:4200${NC}"
}

configure_static_ip() {
    print_title "Configuring Static IP"

    read -p "Interface name (default: enp1s0): " interface
    interface=${interface:-enp1s0}

    read -p "Static IP address (e.g. 192.168.100.21/24): " static_ip

    read -p "Gateway (default: 192.168.100.1): " gateway
    gateway=${gateway:-192.168.100.1}

    read -p "DNS 1 (default: 8.8.8.8): " dns1
    dns1=${dns1:-8.8.8.8}

    read -p "DNS 2 (default: 8.8.4.4): " dns2
    dns2=${dns2:-8.8.4.4}

    sudo tee /etc/netplan/00-installer-config.yaml > /dev/null <<EOF
# This is the network config written by the script
network:
  version: 2
  ethernets:
    $interface:
      dhcp4: no
      addresses:
        - $static_ip
      gateway4: $gateway
      nameservers:
        addresses: [$dns1, $dns2]
EOF

    sudo netplan apply

    echo -e "${GREEN}Static IP configured. New config:${NC}"
    cat /etc/netplan/00-installer-config.yaml
}


### INSTALL ALL
install_all() {
    install_shellinabox
    install_filebrowser
    install_docker
    install_portainer
    install_fail2ban
    install_cockpit
}

### MENU
while true; do
    echo -e "\n${CYAN}What do you want to install?${NC}"
    select opt in \
        "Shell In A Box" \
        "File Browser" \
        "Docker + Docker Compose" \
        "Portainer" \
        "Fail2Ban" \
        "Cockpit" \
        "Install EVERYTHING" \
        "Configure Static IP" \
        "Exit"; do

        case $REPLY in
            1) install_shellinabox; break ;;
            2) install_filebrowser; break ;;
            3) install_docker; break ;;
            4) install_portainer; break ;;
            5) install_fail2ban; break ;;
            6) install_cockpit; break ;;
            7) install_all; break ;;
            8) configure_static_ip; break ;;
            9) echo "Exiting..."; exit 0 ;;
            *) echo -e "${RED}Invalid option. Try again.${NC}" ;;
        esac
    done
done
