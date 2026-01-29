#!/bin/bas

set -euo pipefail

# Configuration
readonly VERSION="3.0.0"
readonly LOG="/tmp/airlink.log"
readonly NODE_VER="20"
readonly TEMP="/tmp/airlink-tmp"
readonly PRISMA_VER="6.19.1"
# Colors
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' N='\033[0m'

# Logging
log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }
info() { echo -e "${C}[INFO]${N} $*"; log "INFO: $*"; }
ok() { echo -e "${G}[OK]${N} $*"; log "OK: $*"; }
warn() { echo -e "${Y}[WARN]${N} $*"; log "WARN: $*"; }
err() { echo -e "${R}[ERROR]${N} $*"; log "ERROR: $*"; exit 1; }

# Detect OS
detect_os() {
    [[ -f /etc/os-release ]] && . /etc/os-release || err "Cannot detect OS"
    OS=$ID; VER=$VERSION_ID
    
    case "$OS" in
        ubuntu|debian|linuxmint|pop) FAM="debian"; PKG="apt";;
        fedora|centos|rhel|rocky|almalinux) FAM="redhat"; PKG=$(command -v dnf &>/dev/null && echo "dnf" || echo "yum");;
        arch|manjaro) FAM="arch"; PKG="pacman";;
        alpine) FAM="alpine"; PKG="apk";;
        *) err "Unsupported OS: $OS";;
    esac
    info "Detected: $OS ($FAM)"
}

# Package installation
pkg_install() {
    case "$PKG" in
        apt) apt-get update -qq && apt-get install -y -qq "$@";;
        dnf|yum) $PKG install -y -q "$@";;
        pacman) pacman -Sy --noconfirm --quiet "$@";;
        apk) apk add --no-cache -q "$@";;
    esac
}

# Check root
[[ $EUID -eq 0 ]] || { dialog --msgbox "Run as root/sudo" 6 30 2>/dev/null || echo "Run as root"; exit 1; }

# Detect system
detect_os

# Install dependencies
deps=(curl wget dialog git jq)
missing=()
for d in "${deps[@]}"; do command -v "$d" &>/dev/null || missing+=("$d"); done
[[ ${#missing[@]} -gt 0 ]] && { info "Installing: ${missing[*]}"; pkg_install "${missing[@]}"; }

# Node.js setup
setup_node() {
    if command -v node &>/dev/null; then
        INSTALLED_VER=$(node -v | sed 's/v//' | cut -d. -f1)
        if [ "$INSTALLED_VER" = "$NODE_VER" ]; then
            ok "Node.js $NODE_VER already installed, skipping"
            return
        else
            info "Node.js version mismatch (found $(node -v)), reinstalling $NODE_VER"
        fi
    else
        info "Node.js not found, installing $NODE_VER"
    fi
    case "$FAM" in
        debian)
            curl -fsSL "https://deb.nodesource.com/setup_${NODE_VER}.x" | bash - &>/dev/null
            pkg_install nodejs
            ;;
        redhat)
            curl -fsSL "https://rpm.nodesource.com/setup_${NODE_VER}.x" | bash - &>/dev/null
            pkg_install nodejs
            ;;
        arch) pkg_install nodejs npm ;;
        alpine) pkg_install nodejs npm ;;
    esac
    if command -v node &>/dev/null; then
        ok "Node.js $(node -v) installed"
    else
        err "Node.js install failed"
    fi
    npm list -g typescript &>/dev/null || \
        npm install -g typescript &>/dev/null && ok "TypeScript installed"
}

# Docker setup
setup_docker() {
    info "Checking for Docker..."
    command -v docker &>/dev/null && { info "Docker already installed"; return 0; }
    info "Installing Docker..."
    case "$FAM" in
        debian|redhat) curl -fsSL https://get.docker.com | sh &>/dev/null;;
        arch) pkg_install docker;;
        alpine) pkg_install docker; rc-update add docker boot &>/dev/null;;
    esac
    systemctl enable --now docker &>/dev/null
    command -v docker &>/dev/null && ok "Docker installed" || err "Docker install failed"
}

# Panel installation
install_panel() {
    info "Installing Panel..."
    
     # Get configuration
    PANEL_PORT=$(dialog --inputbox "Panel Port" 8 40 "3000" 3>&1 1>&2 2>&3) || PANEL_PORT=3000
    
    # Clone and setup
    info "Cloning Repo"
    cd /var/www || err "Cannot access /var/www"
    rm -rf panel
    git clone -q --depth 1 https://github.com/thavanish/panel.git || err "Clone failed"
    cd panel

    # Set permissions
    info "Setting permissions"
    chown -R www-data:www-data /var/www/panel
    chmod -R 755 /var/www/panel
    
    info "Creating .env"
    rm example.env
    # Create .env
    cat > .env << EOF
NODE_ENV=production
PORT=${PANEL_PORT}
DATABASE_URL="file:./dev.db"" 
JWT_SECRET=$(openssl rand -hex 32)
SESSION_SECRET=$(openssl rand -hex 32)
EOF
    
    # Install and build
    info "Installing dependencies..."
    npm install --omit=dev &>/dev/null || err "npm install failed"
    
    if command -v prisma &>/dev/null; then
        INSTALLED_VER=$(prisma -v | grep "prisma" | head -n1 | awk '{print $2}')
        if [ "$INSTALLED_VER" = "$PRISMA_VER" ]; then
            ok "Prisma $PRISMA_VER already installed, skipping"
        else
            info "Prisma version mismatch (found $INSTALLED_VER), reinstalling $PRISMA_VER"
            npm uninstall -g prisma &>/dev/null
            npm uninstall prisma @prisma/client &>/dev/null
            npm cache clean --force &>/dev/null
            npm install prisma@$PRISMA_VER @prisma/client@$PRISMA_VER &>/dev/null || err "Prisma install failed"
        fi
    else
        info "Prisma not found, installing $PRISMA_VER"
        npm install prisma@$PRISMA_VER @prisma/client@$PRISMA_VER &>/dev/null || err "Prisma install failed"
    fi

    info "Running migrations..."
    CI=true npm run migrate:dev &>/dev/null || err "Migration failed"
    
    info "Building Panel..."
    npm run build  || err "Build failed"
    
    
    # Create systemd service
    info "Creating and starting Systemd service..."
    cat > /etc/systemd/system/airlink-panel.service << EOF
[Unit]
Description=Airlink Panel
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/var/www/panel
ExecStart=/usr/bin/node dist/app.js
Restart=always
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable --now airlink-panel &>/dev/null
    
    ok "Panel installed on port ${PANEL_PORT}"
    
}

# Daemon installation
install_daemon() {
    info "Installing Daemon..."
    
    DAEMON_PORT=$(dialog --inputbox "Daemon Port" 8 40 "3002" 3>&1 1>&2 2>&3) || DAEMON_PORT=3002
    DAEMON_KEY=$(dialog --passwordbox "Daemon Auth Key" 8 40 3>&1 1>&2 2>&3) || DAEMON_KEY="get from panel's node setup page"
    info "Cloning Repo..."
    cd /var/www || err "Cannot access /var/www"
    rm -rf daemon
    git clone -q --depth 1 https://github.com/airlinklabs/daemon.git || err "Clone failed"
    cd daemon
    info "Creating .env"
    # Create .env
    cat > .env << EOF
NODE_ENV=production
PORT=${DAEMON_PORT}
AUTH_KEY=${DAEMON_KEY}
DOCKER_SOCKET=/var/run/docker.sock
EOF
    info "Installing dependencies..."
    npm install --omit=dev &>/dev/null || err "npm install failed"
    info "Building Dameon"
    npm run build &>/dev/null || err "Build failed"
    info "Setting permissions"
    chown -R www-data:www-data /var/www/daemon
    info "Creating and starting systemd Service"
    # Create systemd service
    cat > /etc/systemd/system/airlink-daemon.service << EOF
[Unit]
Description=Airlink Daemon
After=network.target docker.service

[Service]
Type=simple
User=root
WorkingDirectory=/var/www/daemon
ExecStart=/usr/bin/node dist/index.js
Restart=always
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable --now airlink-daemon &>/dev/null
    
    ok "Daemon installed on port ${DAEMON_PORT}"
    info "Daemon Key: ${DAEMON_KEY}"
    dialog --msgbox "Daemon Key (save this):\n\n${DAEMON_KEY}" 10 60
}

# Install both
install_all() {
    setup_node
    setup_docker
    install_panel
    install_daemon
    
    dialog --msgbox "Installation Complete!\n\nPanel: http://$(hostname -I | awk '{print $1}'):3000\nDaemon: Running on port 3002\n\nCheck logs: journalctl -u airlink-panel -f" 14 60
}

# Uninstall functions
remove_panel() {
    info "Removing Panel..."
    systemctl stop airlink-panel &>/dev/null || true
    systemctl disable airlink-panel &>/dev/null || true
    rm -f /etc/systemd/system/airlink-panel.service
    rm -rf /var/www/panel
    systemctl daemon-reload
    ok "Panel removed"
}

remove_daemon() {
    info "Removing Daemon..."
    systemctl stop airlink-daemon &>/dev/null || true
    systemctl disable airlink-daemon &>/dev/null || true
    rm -f /etc/systemd/system/airlink-daemon.service
    rm -rf /var/www/daemon
    systemctl daemon-reload
    ok "Daemon removed"
}

remove_deps() {
    info "Removing dependencies..."
    case "$FAM" in
        debian) apt-get remove -y nodejs npm docker.io &>/dev/null;;
        redhat) $PKG remove -y nodejs npm docker &>/dev/null;;
        arch) pacman -R --noconfirm nodejs npm docker &>/dev/null;;
        alpine) apk del nodejs npm docker &>/dev/null;;
    esac
    ok "Dependencies removed"
}

# Status check
show_status() {
    PANEL_STATUS=$(systemctl is-active airlink-panel 2>/dev/null || echo "not installed")
    DAEMON_STATUS=$(systemctl is-active airlink-daemon 2>/dev/null || echo "not installed")
    NODE_VER=$(node -v 2>/dev/null || echo "not installed")
    DOCKER_VER=$(docker --version 2>/dev/null | cut -d' ' -f3 | sed 's/,//' || echo "not installed")
    
    dialog --msgbox "=== Airlink Status ===\n\nPanel: ${PANEL_STATUS}\nDaemon: ${DAEMON_STATUS}\n\nNode.js: ${NODE_VER}\nDocker: ${DOCKER_VER}\n\nOS: ${OS} ${VER}\nPackage Manager: ${PKG}" 16 50
}

# Main menu
main_menu() {
    while true; do
        choice=$(dialog --title "Airlink Installer v${VERSION}" --menu "Choose action:" 20 60 13 \
            1 "Install Both" \
            2 "Install Panel" \
            3 "Install Daemon" \
            4 "Setup Dependencies Only" \
            5 "Remove Panel" \
            6 "Remove Daemon" \
            7 "Remove Dependencies" \
            8 "Remove Everything" \
            9 "Show Status" \
            10 "View Logs" \
            0 "Exit" 3>&1 1>&2 2>&3) || break
        
        case $choice in
            1) install_all;;
            2) install_panel;;
            3) install_daemon;;
            4) setup_node; setup_docker;;
            5) 
                dialog --yesno "Remove Panel?" 6 30 && remove_panel
                ;;
            6) 
                dialog --yesno "Remove Daemon?" 6 30 && remove_daemon
                ;;
            7) 
                dialog --yesno "Remove Dependencies?" 6 30 && remove_deps
                ;;
            8) 
                dialog --yesno "Remove EVERYTHING?" 7 40 && {
                    remove_panel
                    remove_daemon
                    remove_deps
                }
                ;;
            9) show_status;;
            10) 
                [[ -f "$LOG" ]] && dialog --textbox "$LOG" 20 80 || dialog --msgbox "No logs found" 6 30
                ;;
            0) 
                clear
                echo -e "${G}Thanks for using Airlink Installer!${N}"
                exit 0
                ;;
        esac
    done
}

# Cleanup on exit
trap 'rm -rf "$TEMP"' EXIT

# Start
touch "$LOG"
log "=== Airlink Installer v${VERSION} started ==="
main_menu
