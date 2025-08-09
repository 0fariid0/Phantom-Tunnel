#!/bin/bash

# ==============================================================================
#           Phantom Tunnel Management Script (Install, Uninstall, Manage)
# ==============================================================================
# This script combines the installation and uninstallation logic into a single
# menu-driven tool for easy management of Phantom Tunnel.
# GitHub: https://github.com/0fariid0/Phantom-Tunnel
# ==============================================================================

# --- Script Configuration and Variables ---
set -e # Exit immediately if a command exits with a non-zero status.

# Installation variables
GITHUB_REPO="0fariid0/Phantom-Tunnel"

# Shared variables for both install and uninstall
EXECUTABLE_NAMES=("phantom" "phantom-tunnel")
INSTALL_PATH="/usr/local/bin"
SERVICE_NAME="phantom.service"
WORKING_DIR="/etc/phantom"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

# Uninstallation-specific variables (for legacy versions)
LEGACY_WORKING_DIR="/root"
LEGACY_FILES=(
 "credentials.json"
 "config.json"
 "phantom.db"
 "license.key"
 "server.crt"
 "server.key"
)

# --- Helper Functions for Colored Output ---
print_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
print_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
print_error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; }
print_warn() { echo -e "\e[33m[WARN]\e[0m $1"; }


# ==============================================================================
#                             UNINSTALL FUNCTION
# ==============================================================================
uninstall_phantom() {
    echo "----------------------------------------------"
    echo "--- Uninstalling Phantom Tunnel Completely ---"
    echo "----------------------------------------------"
    print_warn "WARNING: This will remove the binary, all configuration files, databases, and the systemd service. This cannot be undone."
    echo ""

    read -p "Are you sure you want to continue? [y/N]: " confirmation
    if [[ "$confirmation" != "y" && "$confirmation" != "Y" ]]; then
        echo "Uninstallation cancelled."
        return 0
    fi

    print_info "Stopping and disabling the Phantom service..."
    if systemctl list-units --full -all | grep -Fq "${SERVICE_NAME}"; then
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            systemctl stop "$SERVICE_NAME"
            print_info "Service stopped."
        fi
        if systemctl is-enabled --quiet "$SERVICE_NAME"; then
            systemctl disable "$SERVICE_NAME"
            print_info "Service disabled."
        fi
    else
        print_warn "Phantom service not found. Skipping."
    fi

    print_info "Killing any remaining 'phantom' processes..."
    for name in "${EXECUTABLE_NAMES[@]}"; do
        pkill -f "$name" || true # || true prevents script exit if no process is found
    done

    if [ -f "$SERVICE_FILE" ]; then
        print_info "Removing systemd service file..."
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        print_info "Systemd daemon reloaded."
    fi

    for name in "${EXECUTABLE_NAMES[@]}"; do
        EXECUTABLE_PATH="${INSTALL_PATH}/${name}"
        if [ -f "$EXECUTABLE_PATH" ]; then
            print_info "Removing executable: ${EXECUTABLE_PATH}"
            rm -f "$EXECUTABLE_PATH"
        fi
    done

    if [ -d "$WORKING_DIR" ]; then
        print_info "Removing new data directory and all its contents: ${WORKING_DIR}"
        rm -rf "$WORKING_DIR"
    fi

    print_info "Searching for and removing legacy files from ${LEGACY_WORKING_DIR}..."
    for file in "${LEGACY_FILES[@]}"; do
        if [ -f "${LEGACY_WORKING_DIR}/${file}" ];
        then
            print_info "  - Removing legacy file: ${LEGACY_WORKING_DIR}/${file}"
            rm -f "${LEGACY_WORKING_DIR}/${file}"
        fi
    done

    print_info "Cleaning up temporary files..."
    rm -f /tmp/phantom.pid
    rm -f /tmp/phantom-panel.log
    rm -f /tmp/phantom-tunnel.log

    echo ""
    print_success "Phantom Tunnel has been completely uninstalled from your system."
    echo "If you installed the executable in a non-standard path, please remove it manually."
}

# ==============================================================================
#                             INSTALL/UPDATE FUNCTION
# ==============================================================================
install_or_update_phantom() {
    print_info "Starting Phantom Tunnel Installation/Update..."

    print_info "Checking for dependencies (curl, grep)..."
    if command -v apt-get &> /dev/null; then
        apt-get update -y > /dev/null && apt-get install -y -qq curl grep > /dev/null
    elif command -v yum &> /dev/null; then
        yum install -y curl grep > /dev/null
    else
        print_warn "Unsupported package manager. Assuming 'curl' and 'grep' are installed."
    fi
    print_success "Dependencies are satisfied."

    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ASSET_NAME="phantom-amd64" ;;
        aarch64 | arm64) ASSET_NAME="phantom-arm64" ;;
        *) print_error "Unsupported architecture: $ARCH."; return 1 ;;
    esac

    print_info "Fetching the latest version from GitHub..."
    LATEST_TAG=$(curl -s "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | grep -oP '"tag_name": "\K[^"]+')
    if [ -z "$LATEST_TAG" ]; then
        print_error "Failed to fetch the latest release tag from GitHub."
        return 1
    fi
    print_info "Latest version is ${LATEST_TAG}."

    DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${LATEST_TAG}/${ASSET_NAME}"

    print_info "Downloading the latest binary (${ASSET_NAME}) for ${ARCH}..."
    TMP_DIR=$(mktemp -d); trap 'rm -rf -- "$TMP_DIR"' EXIT;
    if ! curl -sSLf -o "$TMP_DIR/${EXECUTABLE_NAMES[0]}" "$DOWNLOAD_URL"; then
        print_error "Download failed. Please check the URL and your connection."
        return 1
    fi
    print_success "Binary downloaded successfully."

    if systemctl is-active --quiet $SERVICE_NAME; then
        print_warn "An existing Phantom service is running. It will be stopped for the update."
        systemctl stop $SERVICE_NAME
    fi

    print_info "Installing executable to ${INSTALL_PATH}..."
    mkdir -p "$WORKING_DIR"
    mv "$TMP_DIR/${EXECUTABLE_NAMES[0]}" "${INSTALL_PATH}/${EXECUTABLE_NAMES[0]}"
    chmod +x "${INSTALL_PATH}/${EXECUTABLE_NAMES[0]}"
    # Create a symlink for backward compatibility if needed
    ln -sf "${INSTALL_PATH}/${EXECUTABLE_NAMES[0]}" "${INSTALL_PATH}/${EXECUTABLE_NAMES[1]}"
    print_success "Phantom binary installed/updated."

    print_info "Configuring systemd service..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Phantom Tunnel Panel Service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${INSTALL_PATH}/${EXECUTABLE_NAMES[0]} --start-panel
WorkingDirectory=${WORKING_DIR}
Restart=always
RestartSec=5
LimitNOFILE=65536
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    print_success "Systemd service file created/updated."

    if [ ! -f "${WORKING_DIR}/config.db" ]; then
        print_info "First-time setup: Please provide initial configuration."
        read -p "Enter the port for the web panel (e.g., 8080): " PANEL_PORT
        if ! [[ "$PANEL_PORT" =~ ^[0-9]+$ ]]; then
            print_error "Invalid port number. Installation aborted."
            return 1
        fi

        read -p "Enter the admin username for the panel [default: admin]: " PANEL_USER
        PANEL_USER=${PANEL_USER:-admin}

        read -s -p "Enter the admin password for the panel [default: admin]: " PANEL_PASS
        echo
        PANEL_PASS=${PANEL_PASS:-admin}

        print_info "Running initial setup to configure the database..."
        "${INSTALL_PATH}/${EXECUTABLE_NAMES[0]}" --setup-port="$PANEL_PORT" --setup-user="$PANEL_USER" --setup-pass="$PANEL_PASS"
    else
        print_info "Existing configuration found, skipping initial setup questions."
    fi

    print_info "Enabling and starting the Phantom service..."
    systemctl enable --now ${SERVICE_NAME}
    print_success "Service has been enabled and started."

    echo ""
    print_success "Installation/Update complete!"
    echo "------------------------------------------------------------"
    sleep 2
    if systemctl is-active --quiet $SERVICE_NAME; then
        print_success "Phantom Tunnel is now RUNNING!"
    else
        print_error "The service failed to start. Please check logs with: journalctl -u ${SERVICE_NAME}"
    fi
    echo "------------------------------------------------------------"
}

# ==============================================================================
#                             SERVICE MANAGEMENT FUNCTIONS
# ==============================================================================
check_if_installed() {
    if [ ! -f "${INSTALL_PATH}/${EXECUTABLE_NAMES[0]}" ]; then
        print_error "Phantom Tunnel is not installed. Please install it first."
        return 1
    fi
    return 0
}

restart_service() {
    check_if_installed || return 1
    print_info "Restarting Phantom service..."
    systemctl restart ${SERVICE_NAME}
    print_success "Service restarted."
}

stop_service() {
    check_if_installed || return 1
    print_info "Stopping Phantom service..."
    systemctl stop ${SERVICE_NAME}
    print_success "Service stopped."
}

status_service() {
    check_if_installed || return 1
    print_info "Showing status for Phantom service..."
    systemctl status ${SERVICE_NAME}
}

view_logs() {
    check_if_installed || return 1
    print_info "Displaying live logs... (Press Ctrl+C to exit)"
    journalctl -u ${SERVICE_NAME} -f
}


# ==============================================================================
#                                  MAIN MENU
# ==============================================================================
show_menu() {
    clear
    echo "=========================================="
    echo "        Phantom Tunnel Manager"
    echo "=========================================="
    # Check status
    if [ -f "${INSTALL_PATH}/${EXECUTABLE_NAMES[0]}" ]; then
        echo -e "Status: \e[32mInstalled\e[0m"
        if systemctl is-active --quiet ${SERVICE_NAME}; then
            echo -e "Service: \e[32mRunning\e[0m"
        else
            echo -e "Service: \e[31mStopped\e[0m"
        fi
    else
        echo -e "Status: \e[31mNot Installed\e[0m"
    fi
    echo "------------------------------------------"
    echo "1. Install or Update Phantom Tunnel"
    echo "2. Uninstall Phantom Tunnel"
    echo "3. Restart Service"
    echo "4. Stop Service"
    echo "5. View Service Status"
    echo "6. View Live Logs"
    echo "7. Exit"
    echo "------------------------------------------"
}

# --- Main Script Execution Logic ---
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root. Please use 'sudo bash $0'."
    exit 1
fi

while true; do
    show_menu
    read -p "Please enter your choice [1-7]: " choice

    case $choice in
        1)
            install_or_update_phantom
            ;;
        2)
            uninstall_phantom
            ;;
        3)
            restart_service
            ;;
        4)
            stop_service
            ;;
        5)
            status_service
            ;;
        6)
            view_logs
            ;;
        7)
            echo "Exiting."
            exit 0
            ;;
        *)
            print_warn "Invalid option. Please try again."
            ;;
    esac
    echo ""
    read -n 1 -s -r -p "Press any key to return to the menu..."
done
