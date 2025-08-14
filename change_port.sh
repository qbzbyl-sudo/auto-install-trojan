#!/bin/bash

# ==============================================================================
# Trojan Port Changer Script
#
# This script automates the process of changing the listening port for an
# existing Trojan installation managed by the auto-install script.
# ==============================================================================

# --- Color Codes ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Function to print messages ---
info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# --- Pre-run Checks ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root. Please use 'sudo ./change_port.sh <new_port>'."
    fi
}

# --- Main Script Logic ---
main() {
    check_root

    # --- Validate Input ---
    NEW_PORT=$1
    if [ -z "$NEW_PORT" ]; then
        echo -e "${YELLOW}Usage: $0 <new_port>${NC}"
        error "You must provide a new port number as an argument."
    fi

    if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
        error "Invalid port number. Please provide a number between 1 and 65535."
    fi

    TROJAN_CONF="/etc/trojan/config.json"
    if [ ! -f "$TROJAN_CONF" ]; then
        error "Trojan config file not found at $TROJAN_CONF. Is Trojan installed correctly?"
    fi

    # --- Install jq if not present ---
    if ! command -v jq &> /dev/null; then
        info "jq (JSON processor) is not installed. Installing it now..."
        apt-get update > /dev/null 2>&1
        apt-get install -y jq > /dev/null 2>&1
    fi

    # --- Automatically Detect Old Configuration ---
    info "Detecting current configuration..."
    OLD_PORT=$(jq '.local_port' "$TROJAN_CONF")
    DOMAIN=$(jq -r '.ssl.cert' "$TROJAN_CONF" | sed -n 's|/etc/letsencrypt/live/\(.*\)/fullchain.pem|\1|p')

    if [ -z "$OLD_PORT" ] || [ -z "$DOMAIN" ]; then
        error "Could not automatically detect old port or domain from $TROJAN_CONF."
    fi
    
    if [ "$OLD_PORT" == "$NEW_PORT" ]; then
        error "The new port ($NEW_PORT) is the same as the current port ($OLD_PORT). No changes needed."
    fi

    info "Detected Domain: $DOMAIN"
    info "Changing port from $OLD_PORT to $NEW_PORT..."

    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    if [ ! -f "$NGINX_CONF" ]; then
        error "Nginx config file not found at $NGINX_CONF."
    fi

    # --- Step 1: Update Firewall ---
    info "Updating firewall rules..."
    ufw delete allow "$OLD_PORT"/tcp > /dev/null 2>&1
    ufw allow "$NEW_PORT"/tcp
    info "Firewall updated to allow port $NEW_PORT and deny port $OLD_PORT."

    # --- Step 2: Update Nginx Configuration ---
    info "Updating Nginx redirect rule..."
    # This regex handles both cases: with an existing port and without (implying 443)
    sed -i -E "s|(return 301 https://\\\$host)(:[0-9]+)?(\\\$request_uri;)|\\1:$NEW_PORT\\3|" "$NGINX_CONF"
    info "Nginx configuration at $NGINX_CONF updated."

    # --- Step 3: Update Trojan Configuration ---
    info "Updating Trojan listening port..."
    jq ".local_port = $NEW_PORT" "$TROJAN_CONF" > "${TROJAN_CONF}.tmp" && mv "${TROJAN_CONF}.tmp" "$TROJAN_CONF"
    info "Trojan configuration at $TROJAN_CONF updated."

    # --- Step 4: Restart Services ---
    info "Testing Nginx configuration..."
    nginx -t
    if [ $? -ne 0 ]; then
        error "Nginx configuration test failed. Please review your config files before proceeding."
    fi

    info "Reloading Nginx and restarting Trojan..."
    systemctl reload nginx
    systemctl restart trojan

    # --- Step 5: Final Verification ---
    sleep 2
    if systemctl is-active --quiet nginx && systemctl is-active --quiet trojan; then
        info "--------------------------------------------------"
        info "Port change successful!"
        info "Trojan is now listening on port ${GREEN}$NEW_PORT${NC}."
        info "--------------------------------------------------"
    else
        error "One or more services failed to restart. Please check their status:"
        error "systemctl status nginx"
        error "systemctl status trojan"
    fi
}

# --- Run the main function ---
main "$@"