#!/bin/bash
set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Configuration
readonly DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR="$(cd "${DOCKER_DIR}/.." && pwd)"
readonly ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly IMAGE_NAME="ubuntu:22041311"
readonly CONTAINER_NAME="urays_dev"
readonly IMAGE_DIR="${ROOT_DIR}/.docker"
readonly IMAGE_FILE="${IMAGE_DIR}/${IMAGE_NAME//:/-}.${CONTAINER_NAME}.backup.tar"
readonly WORKSPACE_PATH="${ROOT_DIR}"

# User configuration - must match Dockerfile ARG defaults
readonly URAYS_USERNAME="urays"
readonly URAYS_UID=42752
readonly URAYS_GID=42752

# Rootless Docker Support & Security Configuration
ROOTLESS_MODE=false
SECURITY_WARNING=false

# Check for Rootless Docker
if [[ -S "/run/user/$(id -u)/docker.sock" ]]; then
    export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
    DOCKER_CMD="docker"
    ROOTLESS_MODE=true
elif [[ -n "${DOCKER_HOST:-}" ]] && [[ "${DOCKER_HOST}" == *"run/user"* ]]; then
    DOCKER_CMD="docker"
    ROOTLESS_MODE=true
else
    # System Docker - other users CAN access your containers!
    DOCKER_CMD="sudo docker"
    SECURITY_WARNING=true
fi

# Security warning function
print_security_warning() {
    if [[ "${SECURITY_WARNING}" == "true" ]]; then
        echo
        echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  ⚠️  SECURITY WARNING: Using system-level Docker                  ║${NC}"
        echo -e "${RED}║  Run ./setup-rootless.sh to enable container isolation          ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo
    fi
}
# ============================================================================

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Check Functions
check_prerequisites() {
    print_info "Checking prerequisites..."
    
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed."
        return 1
    fi
    
    # Use Rootless Docker?
    if [[ -n "${DOCKER_HOST:-}" ]] && [[ "${DOCKER_HOST}" == *"run/user"* ]]; then
        print_info "Using Rootless Docker"
    fi
    
    if ! ${DOCKER_CMD} info 2>/dev/null | grep -q "nvidia"; then
        print_warn "NVIDIA Docker runtime may not be installed."
    fi
    
    if ! command -v nvidia-smi &> /dev/null; then
        print_error "NVIDIA driver not found."
        return 1
    fi
    
    print_info "Prerequisites check passed."
    return 0
}

image_exists() {
    ${DOCKER_CMD} images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${IMAGE_NAME}$"
}

container_running() {
    ${DOCKER_CMD} ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"
}

container_exists() {
    ${DOCKER_CMD} ps -a --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"
}

# Build Functions
build_image() {
    print_step "Building Docker image: ${IMAGE_NAME}..."
    
    local dockerfile="${DOCKER_DIR}/Dockerfile"
    if [[ ! -f "${dockerfile}" ]]; then
        print_error "Dockerfile not found: ${dockerfile}"
        return 1
    fi
    
    # Build with user configuration
    ${DOCKER_CMD} build \
        --build-arg USERNAME="${URAYS_USERNAME}" \
        --build-arg USER_UID="${URAYS_UID}" \
        --build-arg USER_GID="${URAYS_GID}" \
        -t "${IMAGE_NAME}" \
        -f "${dockerfile}" \
        "${SCRIPT_DIR}" || {
        print_error "Build failed."
        return 1
    }
    
    print_info "Build completed successfully."
    return 0
}

save_image() {
    print_step "Saving Docker image to file..."
    
    if ! image_exists; then
        print_error "Image ${IMAGE_NAME} not found. Please build it first."
        return 1
    fi
    
    mkdir -p "${IMAGE_DIR}"
    
    print_info "Saving image to: ${IMAGE_FILE}"
    print_warn "This may take several minutes depending on image size..."
    
    ${DOCKER_CMD} save -o "${IMAGE_FILE}" "${IMAGE_NAME}" || {
        print_error "Failed to save image."
        return 1
    }
    
    chmod 777 "${IMAGE_FILE}"  
    
    local size
    size=$(du -h "${IMAGE_FILE}" | cut -f1)
    print_info "Image saved successfully. Size: ${size}"
    print_info "Location: ${IMAGE_FILE}"
    return 0
}

load_image() {
    print_step "Loading Docker image from file..."
    
    if [[ ! -f "${IMAGE_FILE}" ]]; then
        print_error "Image file not found: ${IMAGE_FILE}"
        print_info "Please build the image first with: $0 build"
        return 1
    fi
    
    print_info "Loading image from: ${IMAGE_FILE}"
    print_warn "This may take several minutes..."
    
    ${DOCKER_CMD} load -i "${IMAGE_FILE}" || {
        print_error "Failed to load image."
        return 1
    }
    
    print_info "Image loaded successfully."
    return 0
}

# Container Functions
start_container() {
    print_step "Starting container: ${CONTAINER_NAME}..."
    
    # Display security warning if not using Rootless Docker
    print_security_warning
    
    if container_running; then
        print_warn "Container ${CONTAINER_NAME} is already running."
        return 0
    fi
    
    # Ensure image exists
    if ! image_exists; then
        print_warn "Image ${IMAGE_NAME} not found."
        if [[ -f "${IMAGE_FILE}" ]]; then
            print_info "Found saved image file. Loading..."
            load_image || return 1
        else
            print_error "No image found. Please run '$0 build' first."
            return 1
        fi
    fi
    
    # Setup workspace
    local workspace_abs
    workspace_abs=$(mkdir -p "${WORKSPACE_PATH}" && cd "${WORKSPACE_PATH}" && pwd)
    print_info "Workspace: ${workspace_abs}"
    
    # Allow X11 access for GUI applications
    xhost +local:docker 2>/dev/null || true
    
    # Remove existing stopped container
    ${DOCKER_CMD} rm "${CONTAINER_NAME}" 2>/dev/null || true
    
    # Start container
    print_info "Launching container..."
    ${DOCKER_CMD} run -d \
        --name "${CONTAINER_NAME}" \
        --user "${URAYS_UID}:${URAYS_GID}" \
        --gpus all \
        --network host \
        --restart unless-stopped \
        --shm-size=32g \
        --security-opt seccomp:unconfined \
        -e NVIDIA_VISIBLE_DEVICES=all \
        -e NVIDIA_DRIVER_CAPABILITIES=compute,utility \
        -e DISPLAY="${DISPLAY:-:0}" \
        -e HOME="/home/${URAYS_USERNAME}" \
        -v "${workspace_abs}:/home/${URAYS_USERNAME}/$(basename "${workspace_abs}")" \
        -v "${CONTAINER_NAME}-conda-pkgs:/opt/conda/pkgs" \
        -v "${CONTAINER_NAME}-pip-cache:/home/${URAYS_USERNAME}/.cache/pip" \
        -it \
        "${IMAGE_NAME}" || {
            print_error "Failed to start container."
            return 1
        }
    
    print_info "Container started successfully."
    print_info "Use '$0 run' to enter the container."
    print_info "Use '$0 logs' to view container logs."
    return 0
}

run_shell() {
    # Display security warning if not using Rootless Docker
    print_security_warning
    
    if ! container_running; then
        print_warn "Container not running. Starting..."
        start_container || return 1
        sleep 2
    fi
    
    print_info "Entering container shell..."
    ${DOCKER_CMD} exec -it --user "${URAYS_UID}:${URAYS_GID}" "${CONTAINER_NAME}" /bin/bash -l
}

stop_container() {
    print_step "Stopping container: ${CONTAINER_NAME}..."
    
    if container_running; then
        ${DOCKER_CMD} stop "${CONTAINER_NAME}" || {
            print_error "Failed to stop container."
            return 1
        }
        print_info "Container stopped."
    else
        print_warn "Container ${CONTAINER_NAME} is not running."
    fi
    
    # Ask to remove stopped container
    read -p "Remove stopped container? [y/N] " -n 1 -r
    echo
    if [[ ${REPLY} =~ ^[Yy]$ ]]; then
        ${DOCKER_CMD} rm "${CONTAINER_NAME}" 2>/dev/null || true
        print_info "Container removed."
    fi
    return 0
}

clean_all() {
    print_step "Cleaning up..."
    
    # Stop and remove container
    if container_exists; then
        print_info "Stopping and removing container..."
        ${DOCKER_CMD} stop "${CONTAINER_NAME}" 2>/dev/null || true
        ${DOCKER_CMD} rm "${CONTAINER_NAME}" 2>/dev/null || true
    fi
    
    # Remove Docker image
    if image_exists; then
        read -p "Remove Docker image ${IMAGE_NAME}? [y/N] " -n 1 -r
        echo
        if [[ ${REPLY} =~ ^[Yy]$ ]]; then
            ${DOCKER_CMD} rmi "${IMAGE_NAME}" 2>/dev/null || true
            print_info "Image removed."
        fi
    fi
    
    # # Remove saved image file
    # if [[ -f "${IMAGE_FILE}" ]]; then
    #     read -p "Remove saved image file? [y/N] " -n 1 -r
    #     echo
    #     if [[ ${REPLY} =~ ^[Yy]$ ]]; then
    #         rm -f "${IMAGE_FILE}"
    #         print_info "Image file removed."
    #     fi
    # fi
    
    # # Remove volumes
    # read -p "Remove Docker volumes (conda packages & pip cache)? [y/N] " -n 1 -r
    # echo
    # if [[ ${REPLY} =~ ^[Yy]$ ]]; then
    #     ${DOCKER_CMD} volume rm "${CONTAINER_NAME}-conda-pkgs" 2>/dev/null || true
    #     ${DOCKER_CMD} volume rm "${CONTAINER_NAME}-pip-cache" 2>/dev/null || true
    #     print_info "Volumes removed."
    # fi
    
    print_info "Cleanup completed."
}

# Status Functions
show_status() {
    print_info "System Status:"
    echo
    
    echo "=== Security ==="
    if [[ "${ROOTLESS_MODE}" == "true" ]]; then
        echo -e "${GREEN}✓ Rootless Docker: ACTIVE${NC}"
        echo "  Socket: ${DOCKER_HOST:-/run/user/$(id -u)/docker.sock}"
    else
        echo -e "${RED}✗ System-Level Docker${NC}"
        echo -e "${YELLOW}  Please run ./setup-rootless.sh${NC}"
    fi
    echo
    
    echo "=== Configuration ==="
    echo "Image name:      ${IMAGE_NAME}"
    echo "Container name:  ${CONTAINER_NAME}"
    echo "Workspace path:  ${WORKSPACE_PATH}"
    echo "Image save path: ${IMAGE_FILE}"
    echo "User:            ${URAYS_USERNAME} (${URAYS_UID}:${URAYS_GID})"
    echo
    
    echo "=== Container ==="
    if container_exists; then
        ${DOCKER_CMD} ps -a --filter "name=^${CONTAINER_NAME}$" \
            --format "table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.CreatedAt}}"
    else
        echo "No container found."
    fi
    echo
    
    echo "=== Image ==="
    if image_exists; then
        ${DOCKER_CMD} images "${IMAGE_NAME}" \
            --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"
    else
        echo "No image found in Docker."
    fi
    echo
    
    echo "=== Saved Image File ==="
    if [[ -f "${IMAGE_FILE}" ]]; then
        local size
        size=$(du -h "${IMAGE_FILE}" | cut -f1)
        echo "Found: ${IMAGE_FILE} (${size})"
    else
        echo "No saved image file found."
    fi
    echo
    
    echo "=== Volumes ==="
    ${DOCKER_CMD} volume ls --filter "name=${CONTAINER_NAME}" \
        --format "table {{.Name}}\t{{.Driver}}" 2>/dev/null || echo "No volumes found."
    echo
    
    echo "=== GPU ==="
    if command -v nvidia-smi &> /dev/null; then
        nvidia-smi --query-gpu=index,name,driver_version,memory.total,memory.used \
            --format=csv,noheader,nounits | \
        awk 'BEGIN {print "GPU\tName\t\t\tDriver\tMemory"} 
             {printf "%s\t%-20s\t%s\t%s/%s MB\n", $1, $2, $3, $5, $4}'
    else
        echo "NVIDIA driver not found."
    fi
}

show_logs() {
    if ! container_exists; then
        print_error "Container ${CONTAINER_NAME} not found."
        return 1
    fi
    
    print_info "Showing logs for ${CONTAINER_NAME} (Ctrl+C to exit)..."
    ${DOCKER_CMD} logs -f "${CONTAINER_NAME}"
}

# Help Function
show_help() {
    cat << EOF
Usage: $0 [command]

Docker Build & Run Management Script for ${IMAGE_NAME}

Build Commands:
  build   - Build Docker image from Dockerfile
  save    - Save Docker image to tar file
  load    - Load Docker image from tar file

Container Commands:
  run     - Enter container shell (will start if not running)
  stop    - Stop the running container
  clean   - Remove container, image, and volumes (interactive)

Info Commands:
  status  - Show detailed status of container, image, and GPU
  logs    - Show container logs (real-time)
  help    - Show this help message

Configuration:
  Image name:      ${IMAGE_NAME}
  Container name:  ${CONTAINER_NAME}
  User:            ${URAYS_USERNAME} (${URAYS_UID}:${URAYS_GID})
  Workspace path:  ${WORKSPACE_PATH} (host) -> /home/urays (container)
  Save location:   ${IMAGE_FILE}

Examples:
  $0 build         # Build Docker image
  $0 run           # Start and enter container
  $0 status        # Check system status
  $0 stop          # Stop container
  $0 clean         # Clean up all resources

Workflow:
  1. ./setup_rootless.sh  # One-time: enable isolation (optional)
  2. source ~/.bashrc     # Reload environment
  3. $0 build             # Build image (first time only)
  4. $0 run               # Use container
  5. $0 stop              # Stop when done

EOF
}

# Main Function
main() {
    local command="${1:-help}"
    
    case "${command}" in
        build)
            check_prerequisites || exit 1
            build_image || exit 1
            
            # Ask to save image
            read -p "Save image to file for future use? [Y/n] " -n 1 -r
            echo
            if [[ ! ${REPLY} =~ ^[Nn]$ ]]; then
                save_image || exit 1
            fi
            
            print_info "Build process completed."
            ;;
        
        save)
            save_image || exit 1
            ;;
        
        load)
            load_image || exit 1
            ;;
        
        run)
            check_prerequisites || exit 1
            run_shell || exit 1
            ;;
        
        stop)
            stop_container || exit 1
            ;;
        
        clean)
            clean_all
            ;;
        
        status)
            show_status
            ;;
        
        logs)
            show_logs || exit 1
            ;;
        
        help|--help|-h)
            show_help
            ;;
        
        *)
            print_error "Unknown command: ${command}"
            echo
            show_help
            exit 1
            ;;
    esac
}

main "$@"