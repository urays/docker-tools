#!/bin/bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Detected OS type: "arch" or "ubuntu"
OS_TYPE=""

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
print_security() { echo -e "${CYAN}[SECURITY]${NC} $1"; }

detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        case "${ID}" in
            manjaro|arch|endeavouros|garuda)
                OS_TYPE="arch"
                ;;
            ubuntu|debian|linuxmint|pop)
                OS_TYPE="ubuntu"
                ;;
            *)
                # Try to detect by package manager
                if command -v pacman &>/dev/null; then
                    OS_TYPE="arch"
                elif command -v apt &>/dev/null; then
                    OS_TYPE="ubuntu"
                else
                    print_error "Unsupported distribution: ${ID}"
                    print_info "Supported: Manjaro, Arch, Ubuntu, Debian, Linux Mint, Pop!_OS"
                    exit 1
                fi
                ;;
        esac
    else
        # Fallback: detect by package manager
        if command -v pacman &>/dev/null; then
            OS_TYPE="arch"
        elif command -v apt &>/dev/null; then
            OS_TYPE="ubuntu"
        else
            print_error "Cannot detect OS type. No /etc/os-release and no known package manager."
            exit 1
        fi
    fi
    
    print_info "Detected OS type: ${OS_TYPE}"
}

check_rootless_active() {
    [[ -S "/run/user/$(id -u)/docker.sock" ]] && \
    systemctl --user is-active docker.service &>/dev/null
}

install_dependencies_arch() {
    local pkgs=()
    pacman -Qi docker &>/dev/null || pkgs+=("docker")
    pacman -Qi fuse-overlayfs &>/dev/null || pkgs+=("fuse-overlayfs")
    pacman -Qi slirp4netns &>/dev/null || pkgs+=("slirp4netns")
    
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        print_info "Installing: ${pkgs[*]}"
        sudo pacman -S --needed --noconfirm "${pkgs[@]}"
    else
        print_info "All dependencies installed."
    fi
}

install_dependencies_ubuntu() {
    local pkgs=()
    
    # Check and add required packages
    dpkg -l docker.io &>/dev/null 2>&1 || pkgs+=("docker.io")
    dpkg -l fuse-overlayfs &>/dev/null 2>&1 || pkgs+=("fuse-overlayfs")
    dpkg -l slirp4netns &>/dev/null 2>&1 || pkgs+=("slirp4netns")
    dpkg -l uidmap &>/dev/null 2>&1 || pkgs+=("uidmap")  # Provides newuidmap/newgidmap
    dpkg -l dbus-user-session &>/dev/null 2>&1 || pkgs+=("dbus-user-session")
    
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        print_info "Updating package list..."
        sudo apt update
        print_info "Installing: ${pkgs[*]}"
        sudo apt install -y "${pkgs[@]}"
    else
        print_info "All dependencies installed."
    fi
    
    # Disable system-wide Docker daemon if running (recommended for rootless)
    if systemctl is-active docker.service &>/dev/null; then
        print_warn "System Docker daemon is running."
        print_warn "For rootless Docker, it's recommended to disable it."
        read -p "Disable system Docker daemon? [y/N] " -n 1 -r
        echo
        if [[ ${REPLY} =~ ^[Yy]$ ]]; then
            sudo systemctl disable --now docker.service docker.socket
            print_info "System Docker daemon disabled."
        fi
    fi
}

install_dependencies() {
    print_step "1/6 Installing dependencies..."
    
    case "${OS_TYPE}" in
        arch)
            install_dependencies_arch
            ;;
        ubuntu)
            install_dependencies_ubuntu
            ;;
    esac
}

configure_subuid() {
    print_step "2/6 Configuring subuid/subgid..."
    
    local user=$(whoami)
    
    # On Ubuntu, also ensure /etc/subuid and /etc/subgid exist
    if [[ "${OS_TYPE}" == "ubuntu" ]]; then
        [[ -f /etc/subuid ]] || sudo touch /etc/subuid
        [[ -f /etc/subgid ]] || sudo touch /etc/subgid
    fi
    
    if ! grep -q "^${user}:" /etc/subuid 2>/dev/null; then
        sudo sh -c "echo '${user}:100000:65536' >> /etc/subuid"
        print_info "Added ${user} to /etc/subuid"
    else
        print_info "/etc/subuid already configured."
    fi
    
    if ! grep -q "^${user}:" /etc/subgid 2>/dev/null; then
        sudo sh -c "echo '${user}:100000:65536' >> /etc/subgid"
        print_info "Added ${user} to /etc/subgid"
    else
        print_info "/etc/subgid already configured."
    fi
}

enable_linger() {
    print_step "3/6 Enabling user linger..."
    sudo loginctl enable-linger $(whoami) 2>/dev/null || true
    print_info "User linger enabled."
}

create_systemd_service() {
    print_step "4/6 Creating systemd user service..."
    
    local service_dir="${HOME}/.config/systemd/user"
    local service_file="${service_dir}/docker.service"
    
    mkdir -p "${service_dir}"
    
    # Find dockerd-rootless.sh path (may differ between distros)
    local dockerd_rootless_path="/usr/bin/dockerd-rootless.sh"
    if [[ ! -x "${dockerd_rootless_path}" ]]; then
        # Try alternative locations
        for path in /usr/local/bin/dockerd-rootless.sh /usr/libexec/docker/dockerd-rootless.sh; do
            if [[ -x "${path}" ]]; then
                dockerd_rootless_path="${path}"
                break
            fi
        done
    fi
    
    if [[ ! -x "${dockerd_rootless_path}" ]]; then
        print_error "dockerd-rootless.sh not found!"
        print_info "Searching for it..."
        find /usr -name "dockerd-rootless.sh" 2>/dev/null || true
        return 1
    fi
    
    print_info "Using: ${dockerd_rootless_path}"
    
    cat > "${service_file}" << EOF
[Unit]
Description=Docker Application Container Engine (Rootless)
Documentation=https://docs.docker.com/engine/security/rootless/

[Service]
Environment=PATH=/usr/bin:/usr/local/bin
ExecStart=${dockerd_rootless_path}
ExecReload=/bin/kill -s HUP \$MAINPID
TimeoutSec=0
RestartSec=2
Restart=always
StartLimitBurst=3
StartLimitInterval=60s
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
Type=notify
NotifyAccess=all
KillMode=mixed

[Install]
WantedBy=default.target
EOF
    
    print_info "Created ${service_file}"
    systemctl --user daemon-reload
}

start_rootless_daemon() {
    print_step "5/6 Starting rootless Docker daemon..."
    
    systemctl --user enable docker.service
    systemctl --user start docker.service
    
    sleep 3
    
    if systemctl --user is-active docker.service &>/dev/null; then
        print_info "Rootless Docker daemon is running."
    else
        print_error "Failed to start daemon. Check: journalctl --user -u docker.service"
        return 1
    fi
}

configure_shell() {
    print_step "6/6 Configuring shell environment..."
    
    local shell_rc="${HOME}/.bashrc"
    [[ -f "${HOME}/.zshrc" ]] && shell_rc="${HOME}/.zshrc"
    
    local marker="# Rootless Docker"
    
    if ! grep -q "${marker}" "${shell_rc}" 2>/dev/null; then
        cat >> "${shell_rc}" << 'EOF'

# Rootless Docker - container isolation from other users
export DOCKER_HOST=unix://${XDG_RUNTIME_DIR}/docker.sock
EOF
        print_info "Added DOCKER_HOST to ${shell_rc}"
    else
        print_info "Shell already configured."
    fi
    
    export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
}

verify_setup() {
    echo
    print_step "Verifying setup..."
    
    export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
    
    if docker info &>/dev/null; then
        echo
        echo -e "${GREEN}============================================${NC}"
        echo -e "${GREEN}   Rootless Docker Setup Complete!${NC}"
        echo -e "${GREEN}============================================${NC}"
        echo
        print_security "Your containers are now INVISIBLE to other users."
        echo
        echo "Socket: /run/user/$(id -u)/docker.sock"
        echo
        print_warn "Next steps:"
        echo "  1. Run: source ~/.bashrc  (or open new terminal)"
        echo "  2. Use your docker.sh as normal (no sudo needed)"
        echo
        return 0
    else
        print_error "Verification failed!"
        echo "Debug commands:"
        echo "  systemctl --user status docker.service"
        echo "  journalctl --user -u docker.service -n 30"
        return 1
    fi
}

show_help() {
    cat << EOF
Rootless Docker Setup for Manjaro/Arch/Ubuntu/Debian

Usage: $0 [command]

Commands:
  install   - Full installation (default)
  status    - Check rootless Docker status
  start     - Start rootless daemon
  stop      - Stop rootless daemon
  restart   - Restart rootless daemon
  uninstall - Remove rootless Docker setup
  help      - Show this help

Supported distributions:
  - Arch-based: Manjaro, Arch Linux, EndeavourOS, Garuda
  - Debian-based: Ubuntu, Debian, Linux Mint, Pop!_OS

After installation, use your original docker.sh without sudo.
EOF
}

show_status() {
    echo "=== Rootless Docker Status ==="
    echo
    
    echo -n "OS Type: "
    detect_os 2>/dev/null || echo "unknown"
    
    echo -n "Socket: "
    if [[ -S "/run/user/$(id -u)/docker.sock" ]]; then
        echo -e "${GREEN}EXISTS${NC}"
    else
        echo -e "${RED}NOT FOUND${NC}"
    fi
    
    echo -n "Service: "
    if systemctl --user is-active docker.service &>/dev/null; then
        echo -e "${GREEN}RUNNING${NC}"
    else
        echo -e "${RED}STOPPED${NC}"
    fi
    
    echo -n "DOCKER_HOST: "
    echo "${DOCKER_HOST:-not set}"
    
    echo
    if check_rootless_active; then
        export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
        echo "Docker version: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'N/A')"
        echo
        echo "Containers:"
        docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>/dev/null || echo "  (none)"
    fi
}

uninstall_rootless() {
    print_warn "Uninstalling Rootless Docker setup..."
    
    systemctl --user stop docker.service 2>/dev/null || true
    systemctl --user disable docker.service 2>/dev/null || true
    rm -f "${HOME}/.config/systemd/user/docker.service"
    systemctl --user daemon-reload
    
    read -p "Remove rootless Docker data (~/.local/share/docker)? [y/N] " -n 1 -r
    echo
    if [[ ${REPLY} =~ ^[Yy]$ ]]; then
        rm -rf "${HOME}/.local/share/docker"
        print_info "Data removed."
    fi
    
    print_info "Rootless Docker uninstalled."
    print_warn "You may want to remove DOCKER_HOST from your ~/.bashrc"
}

main() {
    local cmd="${1:-install}"
    
    case "${cmd}" in
        install)
            echo
            echo -e "${CYAN}========================================${NC}"
            echo -e "${CYAN}  Rootless Docker Setup${NC}"
            echo -e "${CYAN}========================================${NC}"
            echo
            
            detect_os
            
            if check_rootless_active; then
                print_info "Rootless Docker is already configured and running!"
                show_status
                exit 0
            fi
            
            install_dependencies
            configure_subuid
            enable_linger
            create_systemd_service
            start_rootless_daemon
            configure_shell
            verify_setup
            ;;
        
        status)
            show_status
            ;;
        
        start)
            systemctl --user start docker.service
            print_info "Started."
            ;;
        
        stop)
            systemctl --user stop docker.service
            print_info "Stopped."
            ;;
        
        restart)
            systemctl --user restart docker.service
            print_info "Restarted."
            ;;
        
        uninstall)
            uninstall_rootless
            ;;
        
        help|--help|-h)
            show_help
            ;;
        
        *)
            print_error "Unknown command: ${cmd}"
            show_help
            exit 1
            ;;
    esac
}

main "$@"