#!/bin/bash

# ==============================================================================
# Trojan with Nginx and SSL Auto-Install Script
#
# Supported Systems: Debian, Ubuntu
#
# This script is for educational purposes only.
# ==============================================================================

# --- Color Codes ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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
        error "This script must be run as root. Please use 'sudo su' or 'sudo ./install_trojan.sh'."
    fi
}

# --- Main Script Logic ---
main() {
    check_root

    # --- User Input ---
    info "Starting the Trojan setup process."
    read -p "Please enter your domain name (e.g., mydomain.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        error "Domain name cannot be empty."
    fi

    read -p "Please enter your Trojan password (leave empty to generate a random one): " PASSWORD
    if [ -z "$PASSWORD" ]; then
        PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)
        info "Generated a random password: $PASSWORD"
    fi

    read -p "Please enter the listening port for Trojan (e.g., 8443, cannot be 80): " TROJAN_PORT
    if [ -z "$TROJAN_PORT" ] || [ "$TROJAN_PORT" -eq 80 ]; then
        error "Invalid port number. It cannot be empty or 80."
    fi
    
    read -p "Please enter your email address (for Let's Encrypt SSL renewal notices): " EMAIL
    if [ -z "$EMAIL" ]; then
        error "Email address is required for SSL certificate generation."
    fi


    # --- Step 1: System Update and Package Installation ---
    info "Updating system and installing necessary packages (Nginx, Trojan, Certbot)..."
    export DEBIAN_FRONTEND=noninteractive
    apt update > /dev/null 2>&1
    apt upgrade -y > /dev/null 2>&1
    apt install -y nginx trojan certbot python3-certbot-nginx curl > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        error "Package installation failed. Please check your system's repository."
    fi

    # --- Step 2: Firewall Configuration ---
    info "Configuring firewall..."
    ufw allow 80/tcp
    ufw allow "$TROJAN_PORT"/tcp
    ufw --force enable

    # --- Step 3: Obtain SSL Certificate with Certbot ---
    info "Stopping Nginx temporarily to obtain SSL certificate..."
    systemctl stop nginx

    info "Requesting SSL certificate for $DOMAIN..."
    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
    if [ $? -ne 0 ]; then
        error "Certbot failed to obtain an SSL certificate. Please check:"
        error "1. Your domain name is correct."
        error "2. Your domain is correctly pointed to this server's IP address."
        error "3. Port 80 is not being used by another application."
    fi

    # --- Step 4: Create Website Directory and Nginx Configuration ---
    info "Creating website directory and a placeholder page..."
    mkdir -p "/var/www/$DOMAIN"
    chown -R www-data:www-data "/var/www/$DOMAIN"
    echo "<h1>Welcome to My Server</h1>" > "/var/www/$DOMAIN/index.html"

    info "Configuring Nginx..."
    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    cat << EOF > "$NGINX_CONF"
# 1. HTTP -> HTTPS Redirect
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    # Redirect all HTTP requests to the custom HTTPS port
    return 301 https://\$host:$TROJAN_PORT\$request_uri;
}

# 2. Fallback server for non-Trojan traffic
server {
    listen 127.0.0.1:8080;
    listen [::1]:8080;
    server_name $DOMAIN;

    root /var/www/$DOMAIN;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    info "Enabling Nginx site configuration..."
    if [ -L "/etc/nginx/sites-enabled/$DOMAIN" ]; then
        rm "/etc/nginx/sites-enabled/$DOMAIN"
    fi
    ln -s "$NGINX_CONF" "/etc/nginx/sites-enabled/"
    
    # Remove default config if it exists
    if [ -L "/etc/nginx/sites-enabled/default" ]; then
        rm "/etc/nginx/sites-enabled/default"
    fi

    # --- Step 5: Configure Trojan ---
    info "Configuring Trojan..."
    TROJAN_CONF="/etc/trojan/config.json"
    cat << EOF > "$TROJAN_CONF"
{
    "run_type": "server",
    "local_addr": "::",
    "local_port": $TROJAN_PORT,
    "remote_addr": "127.0.0.1",
    "remote_port": 8080,
    "password": [
        "$PASSWORD"
    ],
    "ssl": {
        "cert": "/etc/letsencrypt/live/$DOMAIN/fullchain.pem",
        "key": "/etc/letsencrypt/live/$DOMAIN/privkey.pem",
        "fallback_port": 8080
    },
    "router": {
        "enabled": false
    }
}
EOF

    # --- Step 6: Create Trojan Systemd Service File ---
    info "Setting up Trojan systemd service..."
    TROJAN_SERVICE="/etc/systemd/system/trojan.service"
    cat << EOF > "$TROJAN_SERVICE"
[Unit]
Description=Trojan Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/trojan /etc/trojan/config.json
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    # --- Step 7: Start and Enable Services ---
    info "Reloading systemd, enabling and starting services..."
    systemctl daemon-reload
    
    # Test Nginx config before starting
    nginx -t
    if [ $? -ne 0 ]; then
        error "Nginx configuration test failed. Please check the config file at $NGINX_CONF."
    fi
    
    systemctl restart nginx
    systemctl enable trojan
    systemctl restart trojan

    # --- Step 8: Final Verification ---
    sleep 2 # Wait a moment for services to start
    nginx_status=$(systemctl is-active nginx)
    trojan_status=$(systemctl is-active trojan)

    if [ "$nginx_status" != "active" ] || [ "$trojan_status" != "active" ]; then
        error "One or more services failed to start. Check status with:"
        error "systemctl status nginx"
        error "systemctl status trojan"
    fi

    # --- Success Message ---
    info "--------------------------------------------------"
    info "Trojan Server Installation Complete!"
    info "--------------------------------------------------"
    echo -e "${YELLOW}Your Configuration Details:${NC}"
    echo -e "Domain:       ${GREEN}$DOMAIN${NC}"
    echo -e "Port:         ${GREEN}$TROJAN_PORT${NC}"
    echo -e "Password:     ${GREEN}$PASSWORD${NC}"
    echo -e "${YELLOW}--------------------------------------------------${NC}"
    info "Please use these details in your Trojan client."
    info "Your website is available at: http://$DOMAIN (will redirect to https)"
}

# --- Run the main function ---
main