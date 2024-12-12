#!/bin/bash

GO_VERSION=$(curl -s "https://go.dev/dl/?mode=json" | jq -r '.[0].version')

# Check if the OS is Ubuntu
os_check() {
    if [[ "$(uname -a)" != *"Ubuntu"* ]]; then
        echo “Only Ubuntu is supported.”
        exit 1
    fi
}

# Function to update and install packages
install_packages() {
    sudo apt-get update -y && sudo apt-get upgrade -y
    sudo apt-get install -y sudo curl git make build-essential jq wget liblz4-tool aria2
}

# Function to set file handle limits
set_file_limits() {
    ulimit -n 655350
    sudo tee -a /etc/security/limits.conf > /dev/null << EOF
*               soft   nofile          655350
*               hard   nofile          655350
EOF
}

# Function to install or update Go
install_go() {
    local GO_INSTALLED=$(command -v go)
    if [ -z "$GO_INSTALLED" ] || [ "$($GO_INSTALLED version | awk '{print $3}' | sed 's/go//')" \< "$GO_VERSION" ]; then
        echo "Installing or updating Go to version $GO_VERSION..."
        cd $HOME
        sudo rm -rf /usr/local/go
        wget --prefer-family=ipv4 https://golang.org/dl/go${GO_VERSION}.linux-amd64.tar.gz
        tar -xvf go${GO_VERSION}.linux-amd64.tar.gz
        sudo mv go /usr/local
        mkdir -p $HOME/goApps/bin
    else
        echo "Go version $GO_VERSION or higher is already installed."
    fi
}

# Function to set Go environment variables
export GOROOT=/usr/local/go
export GOPATH=$HOME/goApps
export PATH=$GOPATH/bin:$GOROOT/bin:$PATH
setup_go_env() {
    cat << 'EOF' >> $HOME/.bashrc
export GOROOT=/usr/local/go
export GOPATH=$HOME/goApps
export PATH=$GOPATH/bin:$GOROOT/bin:$PATH
EOF
    source $HOME/.bashrc
}

# Function to disable IPv6
disable_ipv6() {
    sudo sed -i -e "s/IPV6=.*/IPV6=no/" /etc/default/ufw
    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
    sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
    sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1
    sudo tee -a /etc/sysctl.conf > /dev/null << EOF
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
}

configure_firewall() {
    echo "Configuring UFW..."
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    echo y | sudo ufw enable

    # SSH rules
    sudo ufw allow from "$OFFICE_IP" to any port "$SSH_PORT" proto tcp comment 'Office SSH'
    sudo ufw allow from "$BH_CONTROL_IP" to any port "$SSH_PORT" proto tcp comment 'BH Control'
    sudo ufw allow from "$ANSIBLE_IP" to any port "$SSH_PORT" proto tcp comment 'Ansible SSH'

    # Monitoring rules
    sudo ufw allow from "$MONITOR_IP" to any port "$GRPC_PORT" proto tcp comment 'Monitor gRPC'
    sudo ufw allow from "$MONITOR_IP" to any port "$RPC_PORT" proto tcp comment 'Monitor RPC'
    sudo ufw allow from "$MONITOR_IP" to any port "$API_PORT" proto tcp comment 'Monitor API'

    # P2P and exporter rules
    sudo ufw allow "$P2P_PORT"/tcp comment 'p2p port'
    sudo ufw allow from "$MONITOR_IP" to any port "$COSMOS_EXPORTER_PORT" comment 'cosmos exporter'
    sudo ufw allow from "$MONITOR_IP" to any port "$NODE_EXPORTER_PORT" comment 'node exporter'

    echo "UFW configuration complete."
}

setup_bashrc() {
    echo "Modifying .bashrc..."
    cat << 'EOF' >> $HOME/.bashrc
set -o vi
sudo journalctl --vacuum-time=2d
alias dreload='sudo systemctl daemon-reload'
EOF
    source $HOME/.bashrc
}
# Function to configure logrotate
configure_logrotate() {
    echo "Configuring logrotate..."

    # Update /etc/logrotate.d/rsyslog
    sudo tee /etc/logrotate.d/rsyslog > /dev/null << EOF
/var/log/syslog
{
        rotate 5
        maxsize 2G
        missingok
        notifempty
        delaycompress
        compress
        postrotate
                /usr/lib/rsyslog/rsyslog-rotate
        endscript
}

/var/log/mail.info
/var/log/mail.warn
/var/log/mail.err
/var/log/mail.log
/var/log/daemon.log
/var/log/kern.log
/var/log/auth.log
/var/log/user.log
/var/log/lpr.log
/var/log/cron.log
/var/log/debug
/var/log/messages
{
        rotate 5
        daily
        maxsize 15G
        missingok
        notifempty
        compress
        delaycompress
        sharedscripts
        postrotate
                /usr/lib/rsyslog/rsyslog-rotate
        endscript
}
EOF

    # Update /lib/systemd/system/logrotate.timer
    sudo tee /lib/systemd/system/logrotate.timer > /dev/null << EOF
[Unit]
Description=Run logrotate hourly
Documentation=man:logrotate(8) man:logrotate.conf(5)

[Timer]
OnCalendar=hourly
AccuracySec=1h

[Install]
WantedBy=timers.target
EOF

    echo "Logrotate configuration complete."
}

# Function to restart services
restart_services() {
    echo "Restarting services..."
    sudo systemctl daemon-reload
    sudo systemctl restart logrotate.timer logrotate.service rsyslog.service
    echo "Services restarted. Timer status:"
    sudo systemctl list-timers | grep logrotate.timer
}

# Install logic executed on entry #1
setup_instance() {
    os_check
    install_packages
    set_file_limits
    install_go
    setup_go_env
    disable_ipv6
    configure_firewall
    setup_bashrc
    configure_logrotate
    restart_services
}

setup_instance