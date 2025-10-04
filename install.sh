#!/bin/sh

# FreeIPA Server Installation Script - Distro Agnostic
# Configures FreeIPA to run behind a reverse proxy
# POSIX compliant

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo "${YELLOW}[WARN] $1${NC}"
}

error() {
    echo "${RED}[ERROR] $1${NC}"
    exit 1
}

# Function to detect distribution
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO="$ID"
        DISTRO_FAMILY="$ID_LIKE"
        VERSION="$VERSION_ID"
    elif [ -f /etc/redhat-release ]; then
        DISTRO="rhel"
        DISTRO_FAMILY="rhel fedora"
    elif [ -f /etc/debian_version ]; then
        DISTRO="debian"
        DISTRO_FAMILY="debian"
    else
        error "Cannot detect distribution"
    fi
    
    log "Detected distribution: $DISTRO (family: $DISTRO_FAMILY)"
}

# Function to check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root"
    fi
}

# Function to find unused port in 64xxx range
find_unused_port() {
    PORT_START=64000
    PORT_END=64999
    
    for port in $(seq $PORT_START $PORT_END | shuf); do
        if ! netstat -tuln 2>/dev/null | grep -q ":$port " && \
           ! ss -tuln 2>/dev/null | grep -q ":$port "; then
            echo "$port"
            return
        fi
    done
    
    error "No unused ports found in range $PORT_START-$PORT_END"
}

# Function to detect domain intelligently
detect_domain() {
    HOSTNAME=$(hostname -f 2>/dev/null || hostname)
    
    # Try to get domain from hostname
    if echo "$HOSTNAME" | grep -q '\.'; then
        # Extract domain part (everything after first dot)
        DOMAIN=$(echo "$HOSTNAME" | cut -d'.' -f2-)
        REALM=$(echo "$DOMAIN" | tr '[:lower:]' '[:upper:]')
        
        # Handle cases like server.sso.example.co.uk
        if [ "$(echo "$DOMAIN" | tr '.' '\n' | wc -l)" -gt 2 ]; then
            # For complex domains, use last two parts as primary domain
            DOMAIN_PARTS=$(echo "$DOMAIN" | tr '.' '\n' | wc -l)
            if [ "$DOMAIN_PARTS" -gt 2 ]; then
                PRIMARY_DOMAIN=$(echo "$DOMAIN" | rev | cut -d'.' -f1-2 | rev)
                log "Detected complex domain structure. Using $PRIMARY_DOMAIN as primary domain"
            fi
        fi
    else
        warn "No domain detected in hostname. Please enter domain manually:"
        printf "Enter domain (e.g., example.com): "
        read -r DOMAIN
        REALM=$(echo "$DOMAIN" | tr '[:lower:]' '[:upper:]')
        HOSTNAME="$HOSTNAME.$DOMAIN"
    fi
    
    log "Using hostname: $HOSTNAME"
    log "Using domain: $DOMAIN"
    log "Using realm: $REALM"
}

# Function to install packages based on distribution
install_packages() {
    case "$DISTRO_FAMILY" in
        *"rhel"*|*"fedora"*|*"centos"*)
            if command -v dnf >/dev/null 2>&1; then
                PKG_MGR="dnf"
            else
                PKG_MGR="yum"
            fi
            
            log "Installing FreeIPA packages using $PKG_MGR..."
            $PKG_MGR update -y
            $PKG_MGR install -y ipa-server ipa-server-dns bind-utils
            
            # Check if we should install additional components
            if systemctl list-unit-files | grep -q chronyd; then
                $PKG_MGR install -y chrony
            fi
            ;;
            
        *"debian"*|*"ubuntu"*)
            export DEBIAN_FRONTEND=noninteractive
            log "Installing FreeIPA packages using apt..."
            apt-get update
            apt-get install -y freeipa-server freeipa-server-dns bind9-utils dnsutils
            
            # Install additional components
            apt-get install -y chrony
            ;;
            
        *"suse"*)
            log "Installing FreeIPA packages using zypper..."
            zypper refresh
            zypper install -y freeipa-server freeipa-server-dns bind-utils chrony
            ;;
            
        *)
            error "Unsupported distribution family: $DISTRO_FAMILY"
            ;;
    esac
}

# Function to check system requirements
check_requirements() {
    log "Checking system requirements..."
    
    # Check memory (minimum 2GB recommended)
    MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEM_GB=$((MEM_KB / 1024 / 1024))
    
    if [ "$MEM_GB" -lt 2 ]; then
        warn "System has less than 2GB RAM ($MEM_GB GB). FreeIPA may not perform well."
    fi
    
    # Check disk space (minimum 10GB recommended)
    DISK_AVAIL=$(df / | tail -1 | awk '{print $4}')
    DISK_GB=$((DISK_AVAIL / 1024 / 1024))
    
    if [ "$DISK_GB" -lt 10 ]; then
        warn "Less than 10GB disk space available ($DISK_GB GB). Consider freeing up space."
    fi
    
    log "System requirements check completed"
}

# Function to configure hosts file
configure_hosts() {
    log "Configuring /etc/hosts..."
    
    # Remove existing entries for hostname
    sed -i "/$HOSTNAME/d" /etc/hosts
    
    # Add new entry
    echo "127.0.0.1 $HOSTNAME $(echo "$HOSTNAME" | cut -d'.' -f1)" >> /etc/hosts
    
    log "Updated /etc/hosts"
}

# Function to check for Let's Encrypt certificates
check_letsencrypt_certs() {
    LE_LIVE_DIR="/etc/letsencrypt/live"
    CERT_FOUND=false
    CERT_PATH=""
    KEY_PATH=""
    CHAIN_PATH=""
    
    if [ ! -d "$LE_LIVE_DIR" ]; then
        return 1
    fi
    
    log "Checking for Let's Encrypt certificates..."
    
    # Collect all valid certificate directories
    CERT_DIRS=""
    CERT_COUNT=0
    
    for cert_dir in "$LE_LIVE_DIR"/*; do
        if [ -d "$cert_dir" ] && [ -f "$cert_dir/cert.pem" ] && [ -f "$cert_dir/privkey.pem" ]; then
            cert_name=$(basename "$cert_dir")
            # Skip README files
            if [ "$cert_name" = "README" ]; then
                continue
            fi
            CERT_DIRS="$CERT_DIRS $cert_dir"
            CERT_COUNT=$((CERT_COUNT + 1))
        fi
    done
    
    # If no certificates found, return
    if [ "$CERT_COUNT" -eq 0 ]; then
        log "No Let's Encrypt certificates found in $LE_LIVE_DIR"
        return 1
    fi
    
    # If only one certificate found, use it
    if [ "$CERT_COUNT" -eq 1 ]; then
        CERT_DIR=$(echo "$CERT_DIRS" | tr -d ' ')
        cert_name=$(basename "$CERT_DIR")
        log "Found 1 Let's Encrypt certificate: $cert_name"
        CERT_FOUND=true
    else
        # Multiple certificates found - let user choose
        log "Found $CERT_COUNT Let's Encrypt certificates:"
        i=1
        for cert_dir in $CERT_DIRS; do
            cert_name=$(basename "$cert_dir")
            printf "  %d) %s\n" "$i" "$cert_name"
            i=$((i + 1))
        done
        
        printf "Select certificate to use (1-%d, 0 to skip): " "$CERT_COUNT"
        read -r CERT_CHOICE
        
        if [ "$CERT_CHOICE" -eq 0 ] 2>/dev/null; then
            log "Skipping Let's Encrypt certificates"
            return 1
        elif [ "$CERT_CHOICE" -ge 1 ] 2>/dev/null && [ "$CERT_CHOICE" -le "$CERT_COUNT" ]; then
            # Get the selected certificate directory
            i=1
            for cert_dir in $CERT_DIRS; do
                if [ "$i" -eq "$CERT_CHOICE" ]; then
                    CERT_DIR="$cert_dir"
                    CERT_FOUND=true
                    break
                fi
                i=$((i + 1))
            done
        else
            warn "Invalid selection, skipping Let's Encrypt certificates"
            return 1
        fi
    fi
    
    if [ "$CERT_FOUND" = true ]; then
        # Verify all required files exist
        if [ -f "$CERT_DIR/cert.pem" ] && [ -f "$CERT_DIR/privkey.pem" ]; then
            CERT_PATH="$CERT_DIR/cert.pem"
            KEY_PATH="$CERT_DIR/privkey.pem"
            CHAIN_PATH="$CERT_DIR/chain.pem"
            FULLCHAIN_PATH="$CERT_DIR/fullchain.pem"
            
            log "Using certificate: $(basename "$CERT_DIR")"
            log "Certificate files validated:"
            log "  - Certificate: $CERT_PATH"
            log "  - Private Key: $KEY_PATH"
            log "  - Fullchain: $FULLCHAIN_PATH"
            
            return 0
        else
            warn "Certificate directory found but required files missing"
            CERT_FOUND=false
        fi
    fi
    
    return 1
}

# Function to generate SSL certificates
generate_ssl_certs() {
    log "Setting up SSL certificate options..."
    
    # First check for Let's Encrypt certificates
    if check_letsencrypt_certs; then
        printf "\nFound existing Let's Encrypt certificate!\n"
        printf "Certificate: %s\n" "$CERT_PATH"
        printf "Use this certificate? (y/n): "
        read -r USE_LE
        
        if [ "$USE_LE" = "y" ] || [ "$USE_LE" = "Y" ]; then
            log "Will use Let's Encrypt certificate"
            USE_LETSENCRYPT=true
            USE_SELFSIGNED=false
            return
        fi
    fi
    
    USE_LETSENCRYPT=false
    
    printf "\nSSL Certificate setup:\n"
    printf "1) Generate self-signed certificate\n"
    printf "2) I will provide certificates later\n"
    printf "Choose option (1-2): "
    read -r SSL_CHOICE
    
    case "$SSL_CHOICE" in
        1)
            log "Will generate self-signed certificates during FreeIPA installation"
            USE_SELFSIGNED=true
            ;;
        2)
            log "SSL certificates will need to be configured manually after installation"
            USE_SELFSIGNED=false
            ;;
        *)
            warn "Invalid choice, defaulting to self-signed certificates"
            USE_SELFSIGNED=true
            ;;
    esac
}

# Function to autodetect services to install
detect_services() {
    log "Auto-detecting services to install..."
    
    INSTALL_DNS=false
    INSTALL_CA=true  # Always install CA
    
    # Check if DNS is needed
    if ! nslookup "$HOSTNAME" >/dev/null 2>&1; then
        log "Hostname not resolvable via DNS, will install integrated DNS server"
        INSTALL_DNS=true
    else
        log "Hostname is resolvable, integrated DNS not required"
    fi
    
    # Check available services
    SERVICES=""
    if [ "$INSTALL_DNS" = true ]; then
        SERVICES="$SERVICES --setup-dns"
    fi
    
    log "Services to install: CA=$([ "$INSTALL_CA" = true ] && echo "Yes" || echo "No"), DNS=$([ "$INSTALL_DNS" = true ] && echo "Yes" || echo "No")"
}

# Function to install and configure FreeIPA
install_freeipa() {
    log "Starting FreeIPA server installation..."
    
    # Generate admin password if not provided
    if [ -z "$ADMIN_PASSWORD" ]; then
        log "Generating random admin password..."
        ADMIN_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
        log "Generated admin password (save this!): $ADMIN_PASSWORD"
    fi
    
    # Generate directory manager password
    DM_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    log "Generated Directory Manager password: $DM_PASSWORD"
    
    # Prepare installation command
    INSTALL_CMD="ipa-server-install --unattended"
    INSTALL_CMD="$INSTALL_CMD --realm=$REALM"
    INSTALL_CMD="$INSTALL_CMD --domain=$DOMAIN"
    INSTALL_CMD="$INSTALL_CMD --hostname=$HOSTNAME"
    INSTALL_CMD="$INSTALL_CMD --admin-password=$ADMIN_PASSWORD"
    INSTALL_CMD="$INSTALL_CMD --ds-password=$DM_PASSWORD"
    
    if [ "$INSTALL_DNS" = true ]; then
        INSTALL_CMD="$INSTALL_CMD --setup-dns --auto-forwarders"
    fi
    
    # Add Let's Encrypt certificate options if available
    if [ "$USE_LETSENCRYPT" = true ]; then
        log "Using Let's Encrypt certificates for installation"
        INSTALL_CMD="$INSTALL_CMD --http-cert-file=$FULLCHAIN_PATH"
        INSTALL_CMD="$INSTALL_CMD --http-key-file=$KEY_PATH"
        INSTALL_CMD="$INSTALL_CMD --dirsrv-cert-file=$FULLCHAIN_PATH"
        INSTALL_CMD="$INSTALL_CMD --dirsrv-key-file=$KEY_PATH"
        INSTALL_CMD="$INSTALL_CMD --dirsrv-pin=''"
    fi
    
    log "Running FreeIPA installation (this may take several minutes)..."
    eval "$INSTALL_CMD"
    
    if [ $? -eq 0 ]; then
        log "FreeIPA server installation completed successfully"
        
        # If using Let's Encrypt, create symlinks for easier renewal
        if [ "$USE_LETSENCRYPT" = true ]; then
            configure_letsencrypt_renewal
        fi
    else
        error "FreeIPA installation failed"
    fi
}

# Function to configure Let's Encrypt certificate renewal
configure_letsencrypt_renewal() {
    log "Configuring Let's Encrypt certificate renewal integration..."
    
    # Create renewal hook script
    RENEWAL_HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
    mkdir -p "$RENEWAL_HOOK_DIR"
    
    cat > "$RENEWAL_HOOK_DIR/freeipa-renew.sh" << 'EOF'
#!/bin/sh
# FreeIPA Certificate Renewal Hook for Let's Encrypt

CERT_DOMAIN="$RENEWED_DOMAINS"
CERT_PATH="$RENEWED_LINEAGE/fullchain.pem"
KEY_PATH="$RENEWED_LINEAGE/privkey.pem"

# Restart FreeIPA services to pick up new certificate
if [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ]; then
    systemctl restart httpd
    systemctl restart dirsrv@*
    logger -t letsencrypt "FreeIPA certificates renewed for $CERT_DOMAIN"
fi
EOF

    chmod +x "$RENEWAL_HOOK_DIR/freeipa-renew.sh"
    log "Created Let's Encrypt renewal hook at $RENEWAL_HOOK_DIR/freeipa-renew.sh"
    
    # Update Apache configuration to use Let's Encrypt certs
    if [ -f "/etc/httpd/conf.d/ssl.conf" ]; then
        sed -i "s|SSLCertificateFile.*|SSLCertificateFile $FULLCHAIN_PATH|" /etc/httpd/conf.d/ssl.conf
        sed -i "s|SSLCertificateKeyFile.*|SSLCertificateKeyFile $KEY_PATH|" /etc/httpd/conf.d/ssl.conf
    fi
    
    log "Let's Encrypt certificate renewal configured"
}

# Function to configure for reverse proxy
configure_reverse_proxy() {
    log "Configuring FreeIPA for reverse proxy setup..."
    
    # Configure Apache to listen on custom port
    APACHE_PORT_CONF="/etc/httpd/conf.d/freeipa-port.conf"
    if [ ! -d "/etc/httpd" ]; then
        APACHE_PORT_CONF="/etc/apache2/conf-available/freeipa-port.conf"
    fi
    
    cat > "$APACHE_PORT_CONF" << EOF
# Custom port configuration for FreeIPA behind reverse proxy
Listen $FREEIPA_PORT
<VirtualHost *:$FREEIPA_PORT>
    ServerName $HOSTNAME
    DocumentRoot /usr/share/ipa/ui
    SSLEngine on
    SSLCertificateFile /var/lib/ipa/certs/httpd.crt
    SSLCertificateKeyFile /var/lib/ipa/private/httpd.key
    Include /etc/httpd/conf.d/ipa.conf
</VirtualHost>
EOF

    # Enable the configuration if using Apache2
    if [ -d "/etc/apache2" ]; then
        a2enconf freeipa-port 2>/dev/null || true
    fi
    
    # Update main Apache configuration
    if [ -f "/etc/httpd/conf.d/ssl.conf" ]; then
        sed -i "s/Listen 443/Listen $FREEIPA_PORT/" /etc/httpd/conf.d/ssl.conf 2>/dev/null || true
    fi
    
    # Create systemd override for httpd service
    mkdir -p /etc/systemd/system/httpd.service.d
    cat > /etc/systemd/system/httpd.service.d/freeipa-proxy.conf << EOF
[Service]
Environment="FREEIPA_PROXY_PORT=$FREEIPA_PORT"
EOF

    systemctl daemon-reload
    
    log "Configured Apache to listen on port $FREEIPA_PORT"
}

# Function to start and enable services
start_services() {
    log "Starting and enabling FreeIPA services..."
    
    systemctl enable ipa
    systemctl start ipa
    
    if [ "$INSTALL_DNS" = true ]; then
        systemctl enable named-pkcs11
        systemctl start named-pkcs11
    fi
    
    log "FreeIPA services started successfully"
}

# Function to display configuration summary
display_summary() {
    log "FreeIPA Installation Summary"
    echo "=========================="
    printf "Hostname: %s\n" "$HOSTNAME"
    printf "Domain: %s\n" "$DOMAIN"
    printf "Realm: %s\n" "$REALM"
    printf "Admin Port: %s\n" "$FREEIPA_PORT"
    printf "Admin Username: admin\n"
    printf "Admin Password: %s\n" "$ADMIN_PASSWORD"
    printf "Directory Manager Password: %s\n" "$DM_PASSWORD"
    printf "Services: CA=Yes, DNS=%s\n" "$([ "$INSTALL_DNS" = true ] && echo "Yes" || echo "No")"
    
    if [ "$USE_LETSENCRYPT" = true ]; then
        printf "SSL Certificate: Let's Encrypt\n"
        printf "Certificate Path: %s\n" "$CERT_PATH"
        printf "Auto-renewal: Configured\n"
    elif [ "$USE_SELFSIGNED" = true ]; then
        printf "SSL Certificate: Self-signed (generated by FreeIPA)\n"
    else
        printf "SSL Certificate: Manual configuration required\n"
    fi
    
    echo "=========================="
    echo ""
    echo "Next Steps:"
    echo "1. Configure your reverse proxy to forward to https://$HOSTNAME:$FREEIPA_PORT"
    echo "2. Access FreeIPA web UI through your reverse proxy"
    echo "3. Save the admin and Directory Manager passwords securely"
    
    if [ "$USE_LETSENCRYPT" = true ]; then
        echo "4. Let's Encrypt certificates will auto-renew (renewal hook configured)"
    fi
    
    echo ""
    echo "Reverse Proxy Configuration Example (Nginx):"
    echo "    location / {"
    echo "        proxy_pass https://$HOSTNAME:$FREEIPA_PORT;"
    echo "        proxy_set_header Host \$host;"
    echo "        proxy_set_header X-Real-IP \$remote_addr;"
    echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
    echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
    
    if [ "$USE_SELFSIGNED" = true ]; then
        echo "        proxy_ssl_verify off;"
    fi
    
    echo "    }"
}

# Main execution
main() {
    log "Starting FreeIPA installation script"
    
    check_root
    detect_distro
    detect_domain
    check_requirements
    
    # Find unused port
    FREEIPA_PORT=$(find_unused_port)
    log "Selected port: $FREEIPA_PORT"
    
    configure_hosts
    install_packages
    generate_ssl_certs
    detect_services
    install_freeipa
    configure_reverse_proxy
    start_services
    display_summary
    
    log "FreeIPA installation and configuration completed successfully!"
}

# Execute main function
main "$@"
