#!/bin/bash

set -euo pipefail

# Configuration
readonly VERSION="2.5.87-beta"
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

# Loading spinner
show_loading() {
    local pid=$1
    local spin='-\|/'
    local i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r${spin:$i:1}"
        sleep .1
    done
    printf "\r"
}

# Run command with loading indicator
run_with_loading() {
    local message=$1
    shift
    info "$message"
    "$@" &>/dev/null &
    local pid=$!
    show_loading $pid
    wait $pid
    local status=$?
    if [ $status -eq 0 ]; then
        ok "$message completed"
    else
        err "$message failed"
    fi
}
# Detect OS
detect_os() {
    info "Detecting operating system..."
    if [[ -f /etc/os-release ]]; then
        # Read os-release without sourcing VERSION variable
        OS=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
        VER=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    else
        err "Cannot detect OS"
    fi
    
    case "$OS" in
        ubuntu|debian|linuxmint|pop) FAM="debian"; PKG="apt";;
        fedora|centos|rhel|rocky|almalinux) FAM="redhat"; PKG=$(command -v dnf &>/dev/null && echo "dnf" || echo "yum");;
        arch|manjaro) FAM="arch"; PKG="pacman";;
        alpine) FAM="alpine"; PKG="apk";;
        *) err "Unsupported OS: $OS";;
    esac
    ok "Detected: $OS ($FAM)"
}
# Package installation
pkg_install() {
    info "Installing packages: $*"
    case "$PKG" in
        apt) apt-get update -qq && apt-get install -y -qq "$@";;
        dnf|yum) $PKG install -y -q "$@";;
        pacman) pacman -Sy --noconfirm --quiet "$@";;
        apk) apk add --no-cache -q "$@";;
    esac
    ok "Packages installed: $*"
}

# Check root
[[ $EUID -eq 0 ]] || { dialog --msgbox "Run as root/sudo" 6 30 2>/dev/null || echo "Run as root"; exit 1; }
clear

# Detect system
detect_os

# Install dependencies
info "Checking dependencies..."
deps=(curl wget dialog git jq)
missing=()
for d in "${deps[@]}"; do command -v "$d" &>/dev/null || missing+=("$d"); done
if [[ ${#missing[@]} -gt 0 ]]; then
    info "Installing missing dependencies: ${missing[*]}"
    pkg_install "${missing[@]}"
else
    ok "All dependencies already installed"
fi

# Node.js setup
setup_node() {
    info "Setting up Node.js..."
    if command -v node &>/dev/null; then
        INSTALLED_VER=$(node -v | sed 's/v//' | cut -d. -f1)
        if [ "$INSTALLED_VER" = "$NODE_VER" ]; then
            ok "Node.js $NODE_VER already installed, skipping"
            return
        else
            warn "Node.js version mismatch (found $(node -v)), reinstalling $NODE_VER"
        fi
    else
        info "Node.js not found, installing $NODE_VER"
    fi
    
    case "$FAM" in
        debian)
            run_with_loading "Adding NodeSource repository" bash -c "curl -fsSL 'https://deb.nodesource.com/setup_${NODE_VER}.x' | bash -"
            pkg_install nodejs
            ;;
        redhat)
            run_with_loading "Adding NodeSource repository" bash -c "curl -fsSL 'https://rpm.nodesource.com/setup_${NODE_VER}.x' | bash -"
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
    
    info "Checking TypeScript..."
    if npm list -g typescript &>/dev/null; then
        ok "TypeScript already installed"
    else
        run_with_loading "Installing TypeScript globally" npm install -g typescript
    fi
}

# Docker setup
setup_docker() {
    info "Checking for Docker..."
    if command -v docker &>/dev/null; then
        ok "Docker already installed"
        return 0
    fi
    
    info "Installing Docker..."
    case "$FAM" in
        debian|redhat) 
            run_with_loading "Downloading and installing Docker" bash -c "curl -fsSL https://get.docker.com | sh";;
            
        arch) pkg_install docker;;
        
        alpine) 
            pkg_install docker
            info "Adding Docker to boot..."
            rc-update add docker boot &>/dev/null
            ;;
    esac
    
    info "Enabling Docker service..."
    systemctl enable --now docker &>/dev/null
    
    if command -v docker &>/dev/null; then
        ok "Docker installed successfully"
    else
        err "Docker install failed"
    fi
}

# Collect all configuration upfront
collect_all_config() {
    info "Collecting configuration for all components..."
    
    # Panel configuration
    PANEL_NAME=$(dialog --inputbox "Panel name" 8 40 "Airlink" 3>&1 1>&2 2>&3) || PANEL_NAME="Airlink"
    PANEL_PORT=$(dialog --inputbox "Panel Port" 8 40 "3000" 3>&1 1>&2 2>&3) || PANEL_PORT=3000
    
    # Daemon configuration
    PANEL_ADDRESS=$(dialog --inputbox "Panel ip/hostname" 8 40 "127.0.0.1" 3>&1 1>&2 2>&3) || PANEL_ADDRESS="127.0.0.1"
    DAEMON_PORT=$(dialog --inputbox "Daemon Port" 8 40 "3002" 3>&1 1>&2 2>&3) || DAEMON_PORT=3002
    DAEMON_KEY=$(dialog --inputbox "Daemon Auth Key" 8 40 3>&1 1>&2 2>&3) || DAEMON_KEY="get from panel's node setup page"
    
    clear
    ok "Configuration collected"
}

# Panel installation
install_panel() {
    local skip_config=${1:-false}
    
    info "Starting Panel installation..."
    
    # Get configuration if not already collected
    if [ "$skip_config" = false ]; then
        PANEL_NAME=$(dialog --inputbox "Panel name" 8 40 "Airlink" 3>&1 1>&2 2>&3) || PANEL_NAME="Airlink"
        PANEL_PORT=$(dialog --inputbox "Panel Port" 8 40 "3000" 3>&1 1>&2 2>&3) || PANEL_PORT=3000
        clear
    fi
    
    # Clone and setup
    info "Preparing directories..."
    [ -d /var/www ] || mkdir /var/www
    cd /var/www || err "Cannot access /var/www"
    
    info "Deleting old panel folder if it exists (last warning)..."
    for i in {5..1}; do
        echo -ne "\rWaiting: $i seconds remaining..."
        sleep 1
    done
    echo -e "\rProceeding...                    "
    
    rm -rf panel
    info "Cloning Panel repository..."
    git clone https://github.com/airlinklabs/panel.git &>/dev/null &
    show_loading $! "Cloning Panel repository"
    ok "Repository cloned"
    
    cd panel

    # Set permissions
    info "Setting permissions..."
    chown -R www-data:www-data /var/www/panel
    chmod -R 755 /var/www/panel
    ok "Permissions set"
    
    # Create .env
    info "Creating .env file..."
    cat > .env << EOF
NAME=${PANEL_NAME}
NODE_ENV="development"
URL="http://localhost:${PANEL_PORT}"
PORT=${PANEL_PORT}
DATABASE_URL="file:./dev.db" 
SESSION_SECRET=$(openssl rand -hex 32)
EOF
    ok ".env file created"
    
    # Install dependencies
    run_with_loading "Installing npm dependencies (this may take a while)" npm install --omit=dev
    
    # Install Prisma
    info "Checking Prisma installation..."
    if command -v prisma &>/dev/null; then
        INSTALLED_VER=$(prisma -v | grep "prisma" | head -n1 | awk '{print $2}')
        if [ "$INSTALLED_VER" = "$PRISMA_VER" ]; then
            ok "Prisma $PRISMA_VER already installed"
        else
            warn "Prisma version mismatch (found $INSTALLED_VER), reinstalling $PRISMA_VER"
            info "Uninstalling old Prisma..."
            npm uninstall -g prisma &>/dev/null
            npm uninstall prisma @prisma/client &>/dev/null
            npm cache clean --force &>/dev/null
            run_with_loading "Installing Prisma $PRISMA_VER" npm install prisma@$PRISMA_VER @prisma/client@$PRISMA_VER
        fi
    else
        run_with_loading "Installing Prisma $PRISMA_VER" npm install prisma@$PRISMA_VER @prisma/client@$PRISMA_VER
    fi

    run_with_loading "Running database migrations" bash -c "CI=true npm run migrate:dev"
    
    info "Building Panel (this will show build output)..."
    npm run build || err "Build failed"
    ok "Panel build completed"
    
    run_with_loading "Seeding database with images" npm run seed
    
    # Create systemd service
    info "Creating systemd service..."
    cat > /etc/systemd/system/airlink-panel.service << EOF
[Unit]
Description=Airlink Panel
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/var/www/panel
ExecStart=/usr/bin/npm run start
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    ok "Systemd service created"
    
    info "Starting Panel service..."
    systemctl daemon-reload
    systemctl enable --now airlink-panel &>/dev/null
    ok "Panel service started"

    if [ "$skip_config" = false ]; then
        install_addons true  # Pass true when called from installation
    fi
    ok "Panel installation completed on port ${PANEL_PORT}"
}

# Daemon installation
install_daemon() {
    local skip_config=${1:-false}
    
    info "Starting Daemon installation..."
    
    # Get configuration if not already collected
    if [ "$skip_config" = false ]; then
        PANEL_ADDRESS=$(dialog --inputbox "Panel ip/hostname" 8 40 "127.0.0.1" 3>&1 1>&2 2>&3) || PANEL_ADDRESS="127.0.0.1"
        DAEMON_PORT=$(dialog --inputbox "Daemon Port" 8 40 "3002" 3>&1 1>&2 2>&3) || DAEMON_PORT=3002
        DAEMON_KEY=$(dialog --inputbox "Daemon Auth Key" 8 40 3>&1 1>&2 2>&3) || DAEMON_KEY="get from panel's node setup page"
        clear
    fi
    
    info "Preparing directories..."
    cd /etc || err "Cannot access /etc"
    
    info "Deleting old daemon folder if it exists (last warning)..."
    for i in {5..1}; do
        echo -ne "\rWaiting: $i seconds remaining..."
        sleep 1
    done
    echo -e "\rProceeding...                    "
    
    rm -rf daemon
    info "Cloning Daemon repository..."
    git clone -q --depth 1 https://github.com/airlinklabs/daemon.git &>/dev/null &
    show_loading $! "Cloning Daemon repository"
    ok "Repository cloned"
    
    cd daemon
    
    # Create .env
    info "Creating .env file..."
    cat > .env << EOF
remote="127.0.0.1"
key=key
port=${DAEMON_PORT}
DEBUG=false
version=1.0.0
environment=development
STATS_INTERVAL=10000
EOF
    ok ".env file created"
    
    run_with_loading "Installing npm dependencies (this may take a while)" npm install --omit=dev
    run_with_loading "Installing express" npm install express
    
    info "Building Daemon (this will show build output)..."
    npm run build || err "Build failed"
    ok "Daemon build completed"
    
    info "Building libs..."
    cd libs
    run_with_loading "Installing libs dependencies" npm install
    run_with_loading "Rebuilding native modules" npm rebuild
    cd ..
    
    info "Setting permissions..."
    chown -R www-data:www-data /etc/daemon
    ok "Permissions set"
    
    # Create systemd service
    info "Creating systemd service..."
    cat > /etc/systemd/system/airlink-daemon.service << EOF
[Unit]
Description=Airlink Daemon
After=network.target docker.service

[Service]
Type=simple
User=root
WorkingDirectory=/etc/daemon
ExecStart=/usr/bin/npm run start
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    ok "Systemd service created"
    
    info "Starting Daemon service..."
    systemctl daemon-reload
    systemctl enable --now airlink-daemon &>/dev/null
    ok "Daemon service started"
    
    ok "Daemon installation completed on port ${DAEMON_PORT}"
}

# Install both
install_all() {
    info "Starting full installation (Node.js, Docker, Panel, Daemon)..."
    
    # Collect all configuration upfront
    collect_all_config
    
    # Setup dependencies
    setup_node
    setup_docker
    
    # Install components with skip_config flag
    install_panel true
    install_daemon true
    
    # Ask about addons at the end
    install_addons true
    
    dialog --msgbox "Installation Complete!\n\nPanel: http://$(hostname -I | awk '{print $1}'):3000\nDaemon: Running on port 3002\n\nCheck logs: journalctl -u airlink-panel -f" 14 60
    clear
    ok "Full installation completed successfully"
}

# Uninstall functions
remove_panel() {
    info "Removing Panel..."
    info "Stopping Panel service..."
    systemctl stop airlink-panel &>/dev/null || true
    info "Disabling Panel service..."
    systemctl disable airlink-panel &>/dev/null || true
    info "Removing service file..."
    rm -f /etc/systemd/system/airlink-panel.service
    info "Removing Panel directory..."
    rm -rf /var/www/panel
    info "Reloading systemd..."
    systemctl daemon-reload
    ok "Panel removed successfully"
}

remove_daemon() {
    info "Removing Daemon..."
    info "Stopping Daemon service..."
    systemctl stop airlink-daemon &>/dev/null || true
    info "Disabling Daemon service..."
    systemctl disable airlink-daemon &>/dev/null || true
    info "Removing service file..."
    rm -f /etc/systemd/system/airlink-daemon.service
    info "Removing Daemon directory..."
    rm -rf /etc/daemon
    info "Reloading systemd..."
    systemctl daemon-reload
    ok "Daemon removed successfully"
}

remove_deps() {
    info "Removing dependencies..."
    case "$FAM" in
        debian) 
            info "Removing Node.js, npm, and Docker..."
            apt-get remove -y nodejs npm docker.io &>/dev/null
            ;;
        redhat) 
            info "Removing Node.js, npm, and Docker..."
            $PKG remove -y nodejs npm docker &>/dev/null
            ;;
        arch) 
            info "Removing Node.js, npm, and Docker..."
            pacman -R --noconfirm nodejs npm docker &>/dev/null
            ;;
        alpine) 
            info "Removing Node.js, npm, and Docker..."
            apk del nodejs npm docker &>/dev/null
            ;;
    esac
    ok "Dependencies removed successfully"
}

# Status check
show_status() {
    info "Checking system status..."
    PANEL_STATUS=$(systemctl is-active airlink-panel 2>/dev/null || echo "not installed")
    DAEMON_STATUS=$(systemctl is-active airlink-daemon 2>/dev/null || echo "not installed")
    NODE_VER=$(node -v 2>/dev/null || echo "not installed")
    DOCKER_VER=$(docker --version 2>/dev/null | cut -d' ' -f3 | sed 's/,//' || echo "not installed")
    
    dialog --msgbox "=== Airlink Status ===\n\nPanel: ${PANEL_STATUS}\nDaemon: ${DAEMON_STATUS}\n\nNode.js: ${NODE_VER}\nDocker: ${DOCKER_VER}\n\nOS: ${OS} ${VER}\nPackage Manager: ${PKG}" 16 50
    clear
}


# Install addons
install_addons() {
    local from_install=${1:-false}
    
    if [ "$from_install" = true ]; then
        # Simplified menu when called from installation
        choice=$(dialog --title "Install Panel Addons?" --menu "Choose action:" 12 70 4 \
            1 "Install Modrinth (https://github.com/g-flame-oss/airlink-addons)" \
            2 "Install Parachute (https://github.com/g-flame-oss/airlink-addons)" \
            3 "Install Both" \
            4 "Skip" 3>&1 1>&2 2>&3) || return
        
        case $choice in
            1) install_modrinth;;
            2) install_parachute;;
            3) install_modrinth; install_parachute;;
            4) ;;  # Skip - do nothing
        esac
    else
        # Full menu when called from main menu
        while true; do
            choice=$(dialog --title "Install Panel Addons?" --menu "Choose action:" 15 70 4 \
                1 "Install Modrinth (https://github.com/g-flame-oss/airlink-addons)" \
                2 "Install Parachute (https://github.com/g-flame-oss/airlink-addons)" \
                3 "Install Both" \
                0 "Exit" 3>&1 1>&2 2>&3) || break
            
            case $choice in
                1) install_modrinth;;
                2) install_parachute;;
                3) install_modrinth; install_parachute;;
                0) clear; break;;
            esac
        done
    fi
    clear
}

install_modrinth() {
    info "Installing Modrinth addon..."
    cd /var/www/panel/storage/addons/
    info "Cloning Modrinth repository..."
    git clone --branch modrinth-addon https://github.com/g-flame-oss/airlink-addons.git modrinth-store &>/dev/null &
    show_loading $! "Cloning Modrinth repository"
    ok "Repository cloned"
    
    cd modrinth-store
    run_with_loading "Installing dependencies" npm install
    
    info "Building Modrinth addon (this will show build output)..."
    npm run build
    ok "Modrinth addon installed successfully"
}

install_parachute() {
    info "Installing Parachute addon..."
    cd /var/www/panel/storage/addons/
    info "Cloning Parachute repository..."
    git clone --branch parachute https://github.com/g-flame-oss/airlink-addons.git parachute &>/dev/null &
    show_loading $! "Cloning Parachute repository"
    ok "Repository cloned"
    
    cd parachute
    run_with_loading "Installing dependencies" npm install
    
    info "Building Parachute addon (this will show build output)..."
    npm run build
    ok "Parachute addon installed successfully"
}

# Main menu
main_menu() {
    while true; do
        choice=$(dialog --title "Airlink Installer v${VERSION}" --menu "Choose action:" 20 60 11 \
            1 "Install Both" \
            2 "Install Panel" \
            3 "Install Daemon" \
            4 "Install Addons" \
            5 "Setup Dependencies Only" \
            6 "Remove Panel" \
            7 "Remove Daemon" \
            8 "Remove Dependencies" \
            9 "Remove Everything" \
            10 "Show Status" \
            11 "View Logs" \
            0 "Exit" 3>&1 1>&2 2>&3) || break
        
        case $choice in
            1) install_all;;
            2) setup_node; setup_docker; install_panel false;;
            3) setup_node; setup_docker; install_daemon false;;
            4) install_addons false;;
            5) setup_node; setup_docker;;
            6) dialog --yesno "Remove Panel?" 6 30 && remove_panel;;
            7) dialog --yesno "Remove Daemon?" 6 30 && remove_daemon;;
            8) dialog --yesno "Remove Dependencies?" 6 30 && remove_deps;;
            9) dialog --yesno "Remove EVERYTHING?" 7 40 && {
                    remove_panel
                    remove_daemon
                    remove_deps
                };;
            10) show_status;;
            11) [[ -f "$LOG" ]] && dialog --textbox "$LOG" 20 80 || dialog --msgbox "No logs found" 6 30;;
            0) clear; echo -e "${G}Thanks for using Airlink Installer!${N}"; exit 0;;
        esac
    done
    clear
}

# Cleanup on exit
trap 'rm -rf "$TEMP"' EXIT

# Start
info "Starting Airlink Installer v${VERSION}..."
touch "$LOG"
log "=== Airlink Installer v${VERSION} started ==="
main_menu
