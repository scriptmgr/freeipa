#!/bin/sh

# Full FreeIPA Server Installation Script - Distro Agnostic
# Complete standalone FreeIPA server with all features
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
            $PKG_MGR install -y ipa-server ipa-server-dns ipa-server-trust-ad \
                bind-utils chrony firewalld
            ;;
            
        *"debian"*|*"ubuntu"*)
            export DEBIAN_FRONTEND=noninteractive
            log "Installing FreeIPA packages using apt..."
            apt-get update
            apt-get install -y freeipa-server freeipa-server-dns freeipa-server-trust-ad \
                bind9-utils dnsutils chrony ufw
            ;;
            
        *"suse"*)
            log "Installing FreeIPA packages using zypper..."
            zypper refresh
            zypper install -y freeipa-server freeipa-server-dns freeipa-server-trust-ad \
                bind-utils chrony firewalld
            ;;
            
        *)
            error "Unsupported distribution family: $DISTRO_FAMILY"
            ;;
    esac
}

# Function to check system requirements
check_requirements() {
    log "Checking system requirements..."
    
    # Check memory (minimum 2GB recommended, 4GB for full features)
    MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEM_GB=$((MEM_KB / 1024 / 1024))
    
    if [ "$MEM_GB" -lt 2 ]; then
        error "System has less than 2GB RAM ($MEM_GB GB). FreeIPA requires at least 2GB."
    elif [ "$MEM_GB" -lt 4 ]; then
        warn "System has less than 4GB RAM ($MEM_GB GB). 4GB+ recommended for full features."
    fi
    
    # Check disk space (minimum 10GB recommended)
    DISK_AVAIL=$(df / | tail -1 | awk '{print $4}')
    DISK_GB=$((DISK_AVAIL / 1024 / 1024))
    
    if [ "$DISK_GB" -lt 10 ]; then
        warn "Less than 10GB disk space available ($DISK_GB GB). Consider freeing up space."
    fi
    
    # Check if hostname is properly configured
    if [ "$HOSTNAME" = "localhost" ] || [ "$HOSTNAME" = "localhost.localdomain" ]; then
        error "Hostname is set to localhost. Please configure a proper FQDN first."
    fi
    
    log "System requirements check completed"
}

# Function to configure hosts file
configure_hosts() {
    log "Configuring /etc/hosts..."
    
    # Get primary IP address
    PRIMARY_IP=$(hostname -I | awk '{print $1}')
    
    if [ -z "$PRIMARY_IP" ]; then
        warn "Could not detect primary IP address. Using 127.0.0.1"
        PRIMARY_IP="127.0.0.1"
    fi
    
    log "Using IP address: $PRIMARY_IP"
    
    # Remove existing entries for hostname
    sed -i "/$HOSTNAME/d" /etc/hosts
    
    # Add new entry
    echo "$PRIMARY_IP $HOSTNAME $(echo "$HOSTNAME" | cut -d'.' -f1)" >> /etc/hosts
    
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

# Function to configure SSL certificates
configure_ssl_certs() {
    log "Setting up SSL certificate options..."
    
    # First check for Let's Encrypt certificates
    if check_letsencrypt_certs; then
        log "Found existing Let's Encrypt certificate!"
        log "Certificate: $CERT_PATH"
        log "Will use Let's Encrypt certificate"
        USE_LETSENCRYPT=true
        USE_SELFSIGNED=false
        USE_FREEIPA_CA=false
        return
    fi
    
    USE_LETSENCRYPT=false
    
    # Default to FreeIPA's built-in CA
    log "No Let's Encrypt certificates found, using FreeIPA's built-in CA"
    USE_FREEIPA_CA=true
    USE_SELFSIGNED=false
}

# Function to configure DNS settings
configure_dns_settings() {
    log "Auto-detecting DNS configuration..."
    
    # Check if DNS is needed by checking if hostname is resolvable
    if ! nslookup "$HOSTNAME" >/dev/null 2>&1; then
        log "Hostname not resolvable via DNS, will install integrated DNS server"
        INSTALL_DNS=true
        
        # Auto-detect forwarders from /etc/resolv.conf
        USE_AUTO_FORWARDERS=true
        DNS_FORWARDERS=""
        
        # Auto-configure reverse zone
        CONFIGURE_REVERSE_ZONE=true
    else
        log "Hostname is resolvable, integrated DNS not required"
        INSTALL_DNS=false
        USE_AUTO_FORWARDERS=false
        DNS_FORWARDERS=""
        CONFIGURE_REVERSE_ZONE=false
    fi
    
    log "DNS configuration: Integrated DNS=$([ "$INSTALL_DNS" = true ] && echo "Yes" || echo "No")"
}

# Function to configure NTP settings
configure_ntp_settings() {
    log "Configuring NTP/Chrony..."
    
    # Enable and start chrony
    if systemctl list-unit-files | grep -q chronyd; then
        systemctl enable chronyd
        systemctl start chronyd
        log "Chrony service enabled and started"
    elif systemctl list-unit-files | grep -q chrony; then
        systemctl enable chrony
        systemctl start chrony
        log "Chrony service enabled and started"
    else
        warn "Chrony service not found, skipping NTP configuration"
    fi
}

# Function to configure firewall
configure_firewall() {
    log "Configuring firewall automatically..."
    
    # Detect firewall type
    if command -v firewall-cmd >/dev/null 2>&1; then
        log "Detected firewalld, configuring..."
        systemctl enable firewalld
        systemctl start firewalld
        
        # Add FreeIPA service
        firewall-cmd --permanent --add-service=freeipa-ldap
        firewall-cmd --permanent --add-service=freeipa-ldaps
        firewall-cmd --permanent --add-service=freeipa-replication
        
        # Add DNS if configured
        if [ "$INSTALL_DNS" = true ]; then
            firewall-cmd --permanent --add-service=dns
        fi
        
        # Add custom HTTPS port for reverse proxy
        firewall-cmd --permanent --add-port=$FREEIPA_PORT/tcp
        
        # Add Kerberos
        firewall-cmd --permanent --add-service=kerberos
        
        # Add NTP
        firewall-cmd --permanent --add-service=ntp
        
        # Reload firewall
        firewall-cmd --reload
        
        log "Firewalld configured successfully"
        
    elif command -v ufw >/dev/null 2>&1; then
        log "Detected UFW, configuring..."
        
        # Enable UFW
        ufw --force enable
        
        # Add FreeIPA ports
        ufw allow $FREEIPA_PORT/tcp  # Custom HTTPS port
        ufw allow 389/tcp   # LDAP
        ufw allow 636/tcp   # LDAPS
        ufw allow 88/tcp    # Kerberos
        ufw allow 88/udp    # Kerberos
        ufw allow 464/tcp   # Kerberos kpasswd
        ufw allow 464/udp   # Kerberos kpasswd
        ufw allow 123/udp   # NTP
        
        # Add DNS if configured
        if [ "$INSTALL_DNS" = true ]; then
            ufw allow 53/tcp
            ufw allow 53/udp
        fi
        
        log "UFW configured successfully"
    else
        log "No supported firewall found, skipping firewall configuration"
    fi
}

# Function to install and configure FreeIPA
install_freeipa() {
    log "Starting FreeIPA server installation..."
    
    # Generate admin password
    log "Generating random admin password..."
    ADMIN_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    log "Generated admin password (save this!): $ADMIN_PASSWORD"
    
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
    
    # Add DNS configuration
    if [ "$INSTALL_DNS" = true ]; then
        INSTALL_CMD="$INSTALL_CMD --setup-dns"
        
        if [ "$USE_AUTO_FORWARDERS" = true ]; then
            INSTALL_CMD="$INSTALL_CMD --auto-forwarders"
        elif [ -n "$DNS_FORWARDERS" ]; then
            for forwarder in $DNS_FORWARDERS; do
                INSTALL_CMD="$INSTALL_CMD --forwarder=$forwarder"
            done
        else
            INSTALL_CMD="$INSTALL_CMD --no-forwarders"
        fi
        
        if [ "$CONFIGURE_REVERSE_ZONE" = true ]; then
            INSTALL_CMD="$INSTALL_CMD --auto-reverse"
        else
            INSTALL_CMD="$INSTALL_CMD --no-reverse"
        fi
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
    
    log "Running FreeIPA installation (this may take 10-20 minutes)..."
    log "Installation command prepared, starting now..."
    
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

# Function to configure Let's Encrypt renewal
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

# Install certificate in FreeIPA
if [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ]; then
    # Stop services
    ipactl stop
    
    # Update certificates
    cp "$CERT_PATH" /etc/httpd/alias/server.crt
    cp "$KEY_PATH" /etc/httpd/alias/server.key
    
    # Start services
    ipactl start
    
    logger -t letsencrypt "FreeIPA certificates renewed for $CERT_DOMAIN"
fi
EOF

    chmod +x "$RENEWAL_HOOK_DIR/freeipa-renew.sh"
    log "Created Let's Encrypt renewal hook at $RENEWAL_HOOK_DIR/freeipa-renew.sh"
}

# Function to configure for reverse proxy
configure_reverse_proxy() {
    log "Configuring FreeIPA for reverse proxy setup..."
    
    # Configure Apache to listen on custom port
    APACHE_CONF_DIR=""
    if [ -d "/etc/httpd/conf.d" ]; then
        APACHE_CONF_DIR="/etc/httpd/conf.d"
    elif [ -d "/etc/apache2/conf-available" ]; then
        APACHE_CONF_DIR="/etc/apache2/conf-available"
    else
        warn "Could not find Apache configuration directory"
        return
    fi
    
    APACHE_PORT_CONF="$APACHE_CONF_DIR/freeipa-port.conf"
    
    cat > "$APACHE_PORT_CONF" << EOF
# Custom port configuration for FreeIPA behind reverse proxy
Listen $FREEIPA_PORT https

<VirtualHost *:$FREEIPA_PORT>
    ServerName $HOSTNAME
    
    # SSL Configuration
    SSLEngine on
    SSLCertificateFile /var/lib/ipa/certs/httpd.crt
    SSLCertificateKeyFile /var/lib/ipa/private/httpd.key
    SSLCertificateChainFile /var/lib/ipa/certs/ca.crt
    
    # Proxy headers
    RequestHeader set X-Forwarded-Proto "https"
    RequestHeader set X-Forwarded-Port "$FREEIPA_PORT"
    
    # Include FreeIPA configuration
EOF

    if [ -f "/etc/httpd/conf.d/ipa.conf" ]; then
        echo "    Include /etc/httpd/conf.d/ipa.conf" >> "$APACHE_PORT_CONF"
    elif [ -f "/etc/apache2/conf-available/ipa.conf" ]; then
        echo "    Include /etc/apache2/conf-available/ipa.conf" >> "$APACHE_PORT_CONF"
    fi
    
    echo "</VirtualHost>" >> "$APACHE_PORT_CONF"
    
    # Enable the configuration if using Apache2
    if [ -d "/etc/apache2/conf-enabled" ]; then
        ln -sf "$APACHE_PORT_CONF" /etc/apache2/conf-enabled/freeipa-port.conf
    fi
    
    # Update main SSL configuration to use custom port
    if [ -f "/etc/httpd/conf.d/ssl.conf" ]; then
        # Comment out the default Listen 443 if it exists
        sed -i 's/^Listen 443/#Listen 443/' /etc/httpd/conf.d/ssl.conf 2>/dev/null || true
    fi
    
    if [ -f "/etc/apache2/ports.conf" ]; then
        # Comment out the default Listen 443 if it exists
        sed -i 's/^Listen 443/#Listen 443/' /etc/apache2/ports.conf 2>/dev/null || true
    fi
    
    log "Configured Apache to listen on port $FREEIPA_PORT"
    
    # Restart Apache to apply changes
    if systemctl list-unit-files | grep -q "^httpd.service"; then
        systemctl restart httpd
    elif systemctl list-unit-files | grep -q "^apache2.service"; then
        systemctl restart apache2
    fi
}

# Function to configure AD trust (optional)
configure_ad_trust() {
    log "Skipping Active Directory Trust support (can be configured later with ipa-adtrust-install)"
    # AD trust can be added later manually if needed
    return
}

# Function to create initial users/groups (optional)
create_initial_objects() {
    log "Skipping initial object creation (can be done via web UI or CLI later)"
    # Users and groups can be created via the web interface after installation
    return
}

# Function to display configuration summary
display_summary() {
    log "FreeIPA Installation Summary"
    echo "=========================================="
    printf "Hostname: %s\n" "$HOSTNAME"
    printf "Domain: %s\n" "$DOMAIN"
    printf "Realm: %s\n" "$REALM"
    printf "Admin Port: %s\n" "$FREEIPA_PORT"
    printf "Admin Username: admin\n"
    printf "Admin Password: %s\n" "$ADMIN_PASSWORD"
    printf "Directory Manager Password: %s\n" "$DM_PASSWORD"
    printf "Integrated DNS: %s\n" "$([ "$INSTALL_DNS" = true ] && echo "Yes" || echo "No")"
    
    if [ "$USE_LETSENCRYPT" = true ]; then
        printf "SSL Certificate: Let's Encrypt\n"
        printf "Certificate Path: %s\n" "$CERT_PATH"
        printf "Auto-renewal: Configured\n"
    elif [ "$USE_FREEIPA_CA" = true ]; then
        printf "SSL Certificate: FreeIPA CA\n"
    elif [ "$USE_SELFSIGNED" = true ]; then
        printf "SSL Certificate: Self-signed\n"
    else
        printf "SSL Certificate: Manual configuration required\n"
    fi
    
    echo "=========================================="
    echo ""
    echo "Access FreeIPA:"
    echo "  Internal URL: https://$HOSTNAME:$FREEIPA_PORT/ipa/ui"
    echo "  (Configure your reverse proxy to forward to this URL)"
    echo ""
    echo "Service Management:"
    echo "  ipactl status    - Check all services"
    echo "  ipactl start     - Start all services"
    echo "  ipactl stop      - Stop all services"
    echo "  ipactl restart   - Restart all services"
    echo ""
    echo "Next Steps:"
    echo "1. Configure your external reverse proxy to forward to https://$HOSTNAME:$FREEIPA_PORT"
    echo "2. Access the admin interface and complete initial setup"
    echo "3. Save the admin and Directory Manager passwords securely"
    
    if [ "$USE_LETSENCRYPT" = true ]; then
        echo "4. Let's Encrypt certificates will auto-renew (renewal hook configured)"
    fi
    
    if [ "$INSTALL_DNS" = true ]; then
        echo ""
        echo "DNS Configuration:"
        echo "  Set nameserver to: $(hostname -I | awk '{print $1}')"
        echo "  Test DNS: dig $HOSTNAME @$(hostname -I | awk '{print $1}')"
    fi
    
    echo ""
    echo "Reverse Proxy Configuration Example (Nginx):"
    echo "    location / {"
    echo "        proxy_pass https://$HOSTNAME:$FREEIPA_PORT;"
    echo "        proxy_set_header Host \$host;"
    echo "        proxy_set_header X-Real-IP \$remote_addr;"
    echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
    echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
    echo "        proxy_set_header X-Forwarded-Port \$server_port;"
    echo "        proxy_ssl_verify off;"
    echo "    }"
    echo ""
    echo "Kerberos:"
    echo "  kinit admin      - Get Kerberos ticket for admin"
    echo "  klist            - List active tickets"
    echo "  kdestroy         - Destroy tickets"
    echo ""
    echo "Important Files:"
    echo "  /etc/ipa/default.conf - IPA configuration"
    echo "  /var/log/ipaserver-install.log - Installation log"
    echo "  /var/log/httpd/ - Web server logs"
    echo "  /var/log/dirsrv/ - Directory server logs"
}

# Main execution
main() {
    log "Starting Full FreeIPA Server installation script"
    
    check_root
    detect_distro
    detect_domain
    check_requirements
    
    # Find unused port for reverse proxy
    FREEIPA_PORT=$(find_unused_port)
    log "Selected FreeIPA port: $FREEIPA_PORT"
    
    configure_hosts
    install_packages
    configure_ntp_settings
    configure_ssl_certs
    configure_dns_settings
    configure_firewall
    install_freeipa
    configure_reverse_proxy
    configure_ad_trust
    create_initial_objects
    display_summary
    
    log "FreeIPA installation and configuration completed successfully!"
    log "You can now access the web interface through your reverse proxy"
}

# Execute main function
main "$@"
