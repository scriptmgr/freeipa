#!/usr/bin/env bash
# shellcheck shell=bash
# - - - - - - - - - - - - - - - - - - - - - - - - -
##@Version           :  202605221532-git
# @@Author           :  Jason Hempstead
# @@Contact          :  git-admin@casjaysdev.pro
# @@License          :  MIT or LICENSE.md
# @@ReadME           :  install.sh --help
# @@Copyright        :  Copyright: (c) 2026 Jason Hempstead, Casjays Developments
# @@Created          :  Thursday, May 22, 2026 14:29 UTC
# @@File             :  install.sh
# @@Description      :  Full FreeIPA + Keycloak SSO bootstrap script, distro-agnostic
# @@Changelog        :  Add Keycloak SSO phases 3-6
# @@TODO             :  None
# @@Other            :
# @@Resource         :  https://www.freeipa.org/page/Documentation
# @@Terminal App     :  yes
# @@sudo/root        :  yes
# @@Template         :  shell/bash
# - - - - - - - - - - - - - - - - - - - - - - - - -
# shellcheck disable=SC1001,SC1003,SC2001,SC2003,SC2016,SC2031,SC2034,SC2090,SC2115,SC2120,SC2155,SC2199,SC2229,SC2317,SC2329
# - - - - - - - - - - - - - - - - - - - - - - - - -
VERSION="202605221532-git"
# - - - - - - - - - - - - - - - - - - - - - - - - -
APPNAME="${0##*/}"
RUN_USER="${SUDO_USER:-$USER}"
SET_UID="${UID}"
SCRIPT_SRC_DIR="${BASH_SOURCE%/*}"
# - - - - - - - - - - - - - - - - - - - - - - - - -
set -euo pipefail
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Color output — suppressed when NO_COLOR is set
INSTALL_COLOR_RED='\e[0;31m'
INSTALL_COLOR_GREEN='\e[0;32m'
INSTALL_COLOR_YELLOW='\e[1;33m'
INSTALL_COLOR_BLUE='\e[0;34m'
INSTALL_COLOR_RESET='\e[0m'
if [[ -n "${NO_COLOR:-}" ]]; then
  INSTALL_COLOR_RED=""
  INSTALL_COLOR_GREEN=""
  INSTALL_COLOR_YELLOW=""
  INSTALL_COLOR_BLUE=""
  INSTALL_COLOR_RESET=""
fi
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Global state — populated by sub-functions, consumed by later stages
INSTALL_DISTRO=""
INSTALL_DISTRO_FAMILY=""
INSTALL_DISTRO_VERSION=""
INSTALL_FQDN="${INSTALL_FQDN:-}"
INSTALL_DOMAIN="${INSTALL_DOMAIN:-}"
INSTALL_REALM="${INSTALL_REALM:-}"
INSTALL_FREEIPA_PORT="${INSTALL_FREEIPA_PORT:-}"
INSTALL_CRED_FILE="${INSTALL_CRED_FILE:-/root/.freeipa-install.conf}"
INSTALL_DNS="false"
INSTALL_USE_AUTO_FORWARDERS="false"
INSTALL_DNS_FORWARDERS=""
INSTALL_CONFIGURE_REVERSE_ZONE="false"
INSTALL_USE_LETSENCRYPT="false"
INSTALL_USE_FREEIPA_CA="false"
INSTALL_USE_SELFSIGNED="false"
INSTALL_CERT_PATH=""
INSTALL_KEY_PATH=""
INSTALL_CHAIN_PATH=""
INSTALL_FULLCHAIN_PATH=""
INSTALL_ADMIN_PASSWORD=""
INSTALL_DM_PASSWORD=""
INSTALL_DEBUG="${INSTALL_DEBUG:-0}"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Keycloak / LDAP globals
INSTALL_LDAP_BASE_DN=""
INSTALL_KEYCLOAK_PORT="${INSTALL_KEYCLOAK_PORT:-}"
INSTALL_KEYCLOAK_REALM="${INSTALL_KEYCLOAK_REALM:-}"
INSTALL_KEYCLOAK_ADMIN_PASSWORD=""
INSTALL_KEYCLOAK_LDAP_PASSWORD=""
INSTALL_KEYCLOAK_DB_PASSWORD=""
INSTALL_COMPOSE_DIR="${INSTALL_COMPOSE_DIR:-/opt/keycloak}"
INSTALL_KEYCLOAK_CONFIG_DIR="${INSTALL_KEYCLOAK_CONFIG_DIR:-/etc/keycloak}"
INSTALL_LDIF_TMP=""
# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Standard Utility Functions ──────────────────────────────────────────────

__random_password() {
  local length="${1:-32}"
  \tr -dc 'A-Za-z0-9!@#$%^&*_+-' </dev/urandom | \head -c "${length}"
}

__random_port() {
  local port
  while :; do
    port=$(( 62000 + RANDOM % 3000 ))
    if ! \ss -tlnp 2>/dev/null | \grep -q -- ":${port} "; then
      printf '%s\n' "${port}"
      return 0
    fi
  done
}

__save_credential() {
  local file="${1:?Usage: __save_credential <file> <key> <value>}"
  local key="${2:?}"
  local value="${3:?}"
  \mkdir -p "$(\dirname -- "${file}")"
  if [[ -f "${file}" ]] && \grep -q -- "^${key}=" "${file}"; then
    local tmp
    tmp="$(\mktemp)"
    \grep -v -- "^${key}=" "${file}" > "${tmp}"
    printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
    \mv "${tmp}" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
    printf 'Generated %s (saved to %s)\n' "${key}" "${file}"
  fi
  \chmod 600 "${file}"
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    \chown root:root "${file}"
  else
    \chown "${RUN_USER}:${RUN_USER}" "${file}"
  fi
}

__load_credential() {
  local file="${1:?Usage: __load_credential <file> <key>}"
  local key="${2:?}"
  [[ -f "${file}" ]] || return 1
  local val
  val="$(\grep -- "^${key}=" "${file}" | \tail -n1 | \cut -d= -f2-)"
  [[ -n "${val}" ]] || return 1
  printf '%s\n' "${val}"
}

__determine_domain_name() {
  local domain
  domain="$(\hostname -d 2>/dev/null)"
  if [[ -n "${domain}" ]]; then
    printf '%s\n' "${domain}"
    return 0
  fi
  local fqdn
  fqdn="$(\hostname -f 2>/dev/null)"
  if [[ -n "${fqdn}" && "${fqdn}" == *.* ]]; then
    printf '%s\n' "${fqdn#*.}"
    return 0
  fi
  return 1
}

__determine_hostname_name() {
  local fqdn
  fqdn="$(\hostname -f 2>/dev/null)"
  if [[ -n "${fqdn}" ]]; then
    printf '%s\n' "${fqdn}"
    return 0
  fi
  return 1
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Logging ─────────────────────────────────────────────────────────────────

__log() {
  printf "${INSTALL_COLOR_GREEN}[%s] %s${INSTALL_COLOR_RESET}\n" "$(\date +'%Y-%m-%d %H:%M:%S')" "$1"
}

__warn() {
  printf "${INSTALL_COLOR_YELLOW}[WARN] %s${INSTALL_COLOR_RESET}\n" "$1" >&2
}

__error() {
  printf "${INSTALL_COLOR_RED}[ERROR] %s${INSTALL_COLOR_RESET}\n" "$1" >&2
  exit 1
}

__debug() {
  if [[ "${INSTALL_DEBUG}" -eq 1 ]]; then
    printf "${INSTALL_COLOR_BLUE}[DEBUG] %s${INSTALL_COLOR_RESET}\n" "$1" >&2
  fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Help / Version ──────────────────────────────────────────────────────────

__help() {
  printf 'Usage: %s [OPTIONS]\n\n' "${APPNAME}"
  printf 'Full FreeIPA + Keycloak SSO bootstrap script — distro-agnostic.\n'
  printf 'Installs FreeIPA with DNS, NTP, firewall, optional Let'"'"'s Encrypt,\n'
  printf 'and deploys Keycloak SSO federated against FreeIPA LDAP.\n\n'
  printf 'Options:\n'
  printf '  -h, --help        Show this help and exit\n'
  printf '  -v, --version     Show version and exit\n'
  printf '      --debug       Enable debug output\n'
  printf '      --no-color    Disable color output\n\n'
  printf 'Environment:\n'
  printf '  INSTALL_FQDN             Override auto-detected hostname\n'
  printf '  INSTALL_DOMAIN           Override auto-detected domain\n'
  printf '  INSTALL_CRED_FILE        Credentials file path (default: /root/.freeipa-install.conf)\n'
  printf '  INSTALL_KEYCLOAK_PORT    Override Keycloak port (default: random in 62000-64999)\n'
  printf '  INSTALL_KEYCLOAK_REALM   Override Keycloak realm (default: domain name)\n'
  printf '  INSTALL_COMPOSE_DIR      Docker Compose directory (default: /opt/keycloak)\n'
  printf '  INSTALL_KEYCLOAK_CONFIG_DIR  Keycloak config directory (default: /etc/keycloak)\n'
  printf '  NO_COLOR                 Disable color output when set\n'
}

__version() {
  printf '%s version %s\n' "${APPNAME}" "${VERSION}"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Cleanup ─────────────────────────────────────────────────────────────────

__cleanup() {
  [[ -n "${INSTALL_LDIF_TMP}" && -f "${INSTALL_LDIF_TMP}" ]] && \rm -f "${INSTALL_LDIF_TMP}" 2>/dev/null || true
}
trap '__cleanup' EXIT

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Pre-flight checks ───────────────────────────────────────────────────────

__check_root() {
  if [[ "$(\id -u)" -ne 0 ]]; then
    __error "This script must be run as root (exit 77)"
    exit 77
  fi
}

__check_requirements() {
  __log "Checking system requirements..."

  local mem_kb mem_gb disk_avail disk_gb
  mem_kb="$(\grep -- "MemTotal" /proc/meminfo | \awk '{print $2}')"
  mem_gb=$(( mem_kb / 1024 / 1024 ))

  if [[ "${mem_gb}" -lt 2 ]]; then
    __error "System has less than 2 GB RAM (${mem_gb} GB). FreeIPA requires at least 2 GB."
  elif [[ "${mem_gb}" -lt 4 ]]; then
    __warn "System has less than 4 GB RAM (${mem_gb} GB). 4 GB+ recommended for full features."
  fi

  disk_avail="$(\df / | \tail -1 | \awk '{print $4}')"
  disk_gb=$(( disk_avail / 1024 / 1024 ))

  if [[ "${disk_gb}" -lt 10 ]]; then
    __warn "Less than 10 GB disk space available (${disk_gb} GB). Consider freeing up space."
  fi

  if [[ "${INSTALL_FQDN}" == "localhost" || "${INSTALL_FQDN}" == "localhost.localdomain" ]]; then
    __error "Hostname is set to localhost. Configure a proper FQDN first."
  fi

  __log "System requirements check passed"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Distro detection ────────────────────────────────────────────────────────

__detect_distro() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    INSTALL_DISTRO="${ID:-unknown}"
    INSTALL_DISTRO_FAMILY="${ID_LIKE:-unknown}"
    INSTALL_DISTRO_VERSION="${VERSION_ID:-unknown}"
  elif [[ -f /etc/redhat-release ]]; then
    INSTALL_DISTRO="rhel"
    INSTALL_DISTRO_FAMILY="rhel fedora"
    INSTALL_DISTRO_VERSION="unknown"
  elif [[ -f /etc/debian_version ]]; then
    INSTALL_DISTRO="debian"
    INSTALL_DISTRO_FAMILY="debian"
    INSTALL_DISTRO_VERSION="unknown"
  else
    __error "Cannot detect distribution"
  fi

  __log "Detected distribution: ${INSTALL_DISTRO} ${INSTALL_DISTRO_VERSION} (family: ${INSTALL_DISTRO_FAMILY})"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Domain / hostname detection ─────────────────────────────────────────────

__detect_domain() {
  INSTALL_FQDN="${INSTALL_FQDN:-$(__determine_hostname_name 2>/dev/null || \hostname)}"

  if [[ "${INSTALL_FQDN}" == *.* ]]; then
    # Extract domain from FQDN (everything after first label)
    INSTALL_DOMAIN="${INSTALL_DOMAIN:-${INSTALL_FQDN#*.}}"
    INSTALL_REALM="${INSTALL_REALM:-${INSTALL_DOMAIN^^}}"

    # For complex domains (>2 labels), note the primary domain
    local domain_parts
    domain_parts="${INSTALL_DOMAIN//[^.]}"
    if [[ ${#domain_parts} -gt 1 ]]; then
      local primary_domain
      primary_domain="${INSTALL_DOMAIN##*.}"
      primary_domain="${INSTALL_DOMAIN%.*}.${primary_domain}"
      __log "Complex domain detected; primary domain: ${primary_domain}"
    fi
  else
    if [[ -t 0 ]]; then
      __warn "No domain found in hostname. Enter domain manually:"
      printf 'Enter domain (e.g., example.com): '
      read -r INSTALL_DOMAIN
    else
      __error "Non-interactive mode and no domain in hostname. Set INSTALL_DOMAIN env var."
    fi
    INSTALL_REALM="${INSTALL_DOMAIN^^}"
    INSTALL_FQDN="${INSTALL_FQDN}.${INSTALL_DOMAIN}"
  fi

  __log "Using hostname: ${INSTALL_FQDN}"
  __log "Using domain:   ${INSTALL_DOMAIN}"
  __log "Using realm:    ${INSTALL_REALM}"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Package installation ────────────────────────────────────────────────────

__install_packages() {
  local pkg_mgr

  case "${INSTALL_DISTRO_FAMILY}" in
    *rhel*|*fedora*|*centos*)
      if \command -v dnf >/dev/null 2>&1; then
        pkg_mgr="dnf"
      else
        pkg_mgr="yum"
      fi
      __log "Installing FreeIPA packages via ${pkg_mgr}..."
      "${pkg_mgr}" update -y
      "${pkg_mgr}" install -y ipa-server ipa-server-dns ipa-server-trust-ad bind-utils chrony firewalld openldap-clients
      ;;

    *debian*|*ubuntu*)
      __log "Installing FreeIPA packages via apt-get..."
      INSTALL_DEBIAN_FRONTEND="noninteractive"
      export DEBIAN_FRONTEND="${INSTALL_DEBIAN_FRONTEND}"
      \apt-get update
      \apt-get install -y freeipa-server freeipa-server-dns freeipa-server-trust-ad bind9-utils dnsutils chrony ufw ldap-utils
      ;;

    *suse*)
      __log "Installing FreeIPA packages via zypper..."
      \zypper refresh
      \zypper install -y freeipa-server freeipa-server-dns freeipa-server-trust-ad bind-utils chrony firewalld openldap2-client
      ;;

    *)
      __error "Unsupported distribution family: ${INSTALL_DISTRO_FAMILY}"
      ;;
  esac
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── /etc/hosts ──────────────────────────────────────────────────────────────

__configure_hosts() {
  __log "Configuring /etc/hosts..."

  local primary_ip short_hostname
  primary_ip="$(\hostname -I | \awk '{print $1}')"
  if [[ -z "${primary_ip}" ]]; then
    __warn "Could not detect primary IP address; falling back to 127.0.0.1"
    primary_ip="127.0.0.1"
  fi

  __log "Using IP address: ${primary_ip}"

  # Remove any existing entries for this FQDN then re-add with correct IP
  \sed -i "/${INSTALL_FQDN}/d" /etc/hosts
  short_hostname="${INSTALL_FQDN%%.*}"
  printf '%s %s %s\n' "${primary_ip}" "${INSTALL_FQDN}" "${short_hostname}" >> /etc/hosts

  __log "Updated /etc/hosts"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Let's Encrypt certificate detection ─────────────────────────────────────

__check_letsencrypt_certs() {
  local le_live_dir="/etc/letsencrypt/live"
  [[ -d "${le_live_dir}" ]] || return 1

  __log "Checking for Let's Encrypt certificates..."

  local cert_dirs="" cert_count=0
  local cert_dir cert_name

  for cert_dir in "${le_live_dir}"/*; do
    [[ -d "${cert_dir}" ]] || continue
    [[ -f "${cert_dir}/cert.pem" ]] || continue
    [[ -f "${cert_dir}/privkey.pem" ]] || continue
    cert_name="${cert_dir##*/}"
    # Skip the README file that certbot places in the directory
    [[ "${cert_name}" == "README" ]] && continue
    cert_dirs="${cert_dirs} ${cert_dir}"
    cert_count=$(( cert_count + 1 ))
  done

  if [[ "${cert_count}" -eq 0 ]]; then
    __log "No Let's Encrypt certificates found in ${le_live_dir}"
    return 1
  fi

  local selected_dir=""

  if [[ "${cert_count}" -eq 1 ]]; then
    selected_dir="${cert_dirs# }"
    cert_name="${selected_dir##*/}"
    __log "Found 1 Let's Encrypt certificate: ${cert_name}"
  else
    __log "Found ${cert_count} Let's Encrypt certificates:"
    local i=1
    for cert_dir in ${cert_dirs}; do
      cert_name="${cert_dir##*/}"
      printf '  %d) %s\n' "${i}" "${cert_name}"
      i=$(( i + 1 ))
    done

    local cert_choice
    if [[ -t 0 ]]; then
      printf 'Select certificate to use (1-%d, 0 to skip): ' "${cert_count}"
      read -r cert_choice
    else
      # Non-interactive: auto-select the first certificate
      cert_choice=1
      __log "Non-interactive mode: auto-selecting first certificate"
    fi

    if [[ "${cert_choice}" -eq 0 ]] 2>/dev/null; then
      __log "Skipping Let's Encrypt certificates"
      return 1
    elif [[ "${cert_choice}" -ge 1 && "${cert_choice}" -le "${cert_count}" ]] 2>/dev/null; then
      i=1
      for cert_dir in ${cert_dirs}; do
        if [[ "${i}" -eq "${cert_choice}" ]]; then
          selected_dir="${cert_dir}"
          break
        fi
        i=$(( i + 1 ))
      done
    else
      __warn "Invalid selection; skipping Let's Encrypt certificates"
      return 1
    fi
  fi

  if [[ -f "${selected_dir}/cert.pem" && -f "${selected_dir}/privkey.pem" ]]; then
    INSTALL_CERT_PATH="${selected_dir}/cert.pem"
    INSTALL_KEY_PATH="${selected_dir}/privkey.pem"
    INSTALL_CHAIN_PATH="${selected_dir}/chain.pem"
    INSTALL_FULLCHAIN_PATH="${selected_dir}/fullchain.pem"
    __log "Using certificate: ${selected_dir##*/}"
    __log "  Certificate:  ${INSTALL_CERT_PATH}"
    __log "  Private key:  ${INSTALL_KEY_PATH}"
    __log "  Chain:        ${INSTALL_CHAIN_PATH}"
    __log "  Full chain:   ${INSTALL_FULLCHAIN_PATH}"
    return 0
  fi

  __warn "Certificate directory found but required files are missing"
  return 1
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── SSL certificate selection ───────────────────────────────────────────────

__configure_ssl_certs() {
  __log "Setting up SSL certificate options..."

  if __check_letsencrypt_certs; then
    __log "Using existing Let's Encrypt certificate"
    INSTALL_USE_LETSENCRYPT="true"
    INSTALL_USE_SELFSIGNED="false"
    INSTALL_USE_FREEIPA_CA="false"
    return
  fi

  # Fall back to FreeIPA's built-in CA
  __log "No Let's Encrypt certificates found; using FreeIPA built-in CA"
  INSTALL_USE_LETSENCRYPT="false"
  INSTALL_USE_FREEIPA_CA="true"
  INSTALL_USE_SELFSIGNED="false"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── DNS settings ────────────────────────────────────────────────────────────

__configure_dns_settings() {
  __log "Auto-detecting DNS configuration..."

  if ! \nslookup "${INSTALL_FQDN}" >/dev/null 2>&1; then
    __log "Hostname not resolvable via DNS; will install integrated DNS server"
    INSTALL_DNS="true"
    INSTALL_USE_AUTO_FORWARDERS="true"
    INSTALL_CONFIGURE_REVERSE_ZONE="true"
  else
    __log "Hostname is resolvable; integrated DNS not required"
    INSTALL_DNS="false"
    INSTALL_USE_AUTO_FORWARDERS="false"
    INSTALL_CONFIGURE_REVERSE_ZONE="false"
  fi

  if [[ "${INSTALL_DNS}" == "true" ]]; then
    __log "DNS configuration: integrated DNS=Yes"
  else
    __log "DNS configuration: integrated DNS=No"
  fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── NTP / Chrony ────────────────────────────────────────────────────────────

__configure_ntp_settings() {
  __log "Configuring NTP/Chrony..."

  if \systemctl list-unit-files | \grep -q -- "chronyd"; then
    \systemctl enable chronyd
    \systemctl start chronyd
    __log "Chrony (chronyd) service enabled and started"
  elif \systemctl list-unit-files | \grep -q -- "chrony"; then
    \systemctl enable chrony
    \systemctl start chrony
    __log "Chrony service enabled and started"
  else
    __warn "Chrony service not found; skipping NTP configuration"
  fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Firewall ────────────────────────────────────────────────────────────────

__configure_firewall() {
  __log "Configuring firewall..."

  if \command -v firewall-cmd >/dev/null 2>&1; then
    __log "Detected firewalld; configuring..."
    \systemctl enable firewalld
    \systemctl start firewalld

    \firewall-cmd --permanent --add-service=freeipa-ldap
    \firewall-cmd --permanent --add-service=freeipa-ldaps
    \firewall-cmd --permanent --add-service=freeipa-replication

    if [[ "${INSTALL_DNS}" == "true" ]]; then
      \firewall-cmd --permanent --add-service=dns
    fi

    # Custom HTTPS port for the FreeIPA reverse proxy
    \firewall-cmd --permanent --add-port="${INSTALL_FREEIPA_PORT}/tcp"

    \firewall-cmd --permanent --add-service=kerberos
    \firewall-cmd --permanent --add-service=ntp

    # Keycloak port (internal Docker bridge — open for reverse proxy reach)
    \firewall-cmd --permanent --add-port="${INSTALL_KEYCLOAK_PORT}/tcp"

    \firewall-cmd --reload

    __log "firewalld configured"

  elif \command -v ufw >/dev/null 2>&1; then
    __log "Detected UFW; configuring..."
    \ufw --force enable

    # Custom HTTPS port for the FreeIPA reverse proxy
    \ufw allow "${INSTALL_FREEIPA_PORT}/tcp"
    # LDAP
    \ufw allow 389/tcp
    # LDAPS
    \ufw allow 636/tcp
    # Kerberos TCP
    \ufw allow 88/tcp
    # Kerberos UDP
    \ufw allow 88/udp
    # Kerberos kpasswd TCP
    \ufw allow 464/tcp
    # Kerberos kpasswd UDP
    \ufw allow 464/udp
    # NTP
    \ufw allow 123/udp

    if [[ "${INSTALL_DNS}" == "true" ]]; then
      \ufw allow 53/tcp
      \ufw allow 53/udp
    fi

    # Keycloak port
    \ufw allow "${INSTALL_KEYCLOAK_PORT}/tcp"

    __log "UFW configured"
  else
    __log "No supported firewall found; skipping firewall configuration"
  fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Let's Encrypt renewal hook ──────────────────────────────────────────────

__configure_letsencrypt_renewal() {
  __log "Configuring Let's Encrypt certificate renewal hook..."

  local renewal_hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
  \mkdir -p "${renewal_hook_dir}"

  \cat > "${renewal_hook_dir}/freeipa-renew.sh" << 'EOF'
#!/usr/bin/env sh
# FreeIPA certificate renewal hook for Let's Encrypt
# Triggered automatically by certbot after successful renewal.

CERT_PATH="${RENEWED_LINEAGE}/fullchain.pem"
KEY_PATH="${RENEWED_LINEAGE}/privkey.pem"

if [ -f "${CERT_PATH}" ] && [ -f "${KEY_PATH}" ]; then
  ipactl stop
  cp "${CERT_PATH}" /etc/httpd/alias/server.crt
  cp "${KEY_PATH}" /etc/httpd/alias/server.key
  ipactl start
  logger -t letsencrypt "FreeIPA certificates renewed for ${RENEWED_DOMAINS}"
fi
EOF

  \chmod +x "${renewal_hook_dir}/freeipa-renew.sh"
  __log "Renewal hook created: ${renewal_hook_dir}/freeipa-renew.sh"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── FreeIPA installation ────────────────────────────────────────────────────

__install_freeipa() {
  __log "Starting FreeIPA server installation..."

  # Load or generate admin password
  INSTALL_ADMIN_PASSWORD="$(__load_credential "${INSTALL_CRED_FILE}" INSTALL_ADMIN_PASSWORD)" || {
    INSTALL_ADMIN_PASSWORD="$(__random_password 25)"
    __save_credential "${INSTALL_CRED_FILE}" INSTALL_ADMIN_PASSWORD "${INSTALL_ADMIN_PASSWORD}"
  }

  # Load or generate Directory Manager password
  INSTALL_DM_PASSWORD="$(__load_credential "${INSTALL_CRED_FILE}" INSTALL_DM_PASSWORD)" || {
    INSTALL_DM_PASSWORD="$(__random_password 25)"
    __save_credential "${INSTALL_CRED_FILE}" INSTALL_DM_PASSWORD "${INSTALL_DM_PASSWORD}"
  }

  # Build installation command as an array to avoid quoting/eval issues
  local -a install_cmd
  install_cmd=(
    \ipa-server-install
    --unattended
    "--realm=${INSTALL_REALM}"
    "--domain=${INSTALL_DOMAIN}"
    "--hostname=${INSTALL_FQDN}"
    "--admin-password=${INSTALL_ADMIN_PASSWORD}"
    "--ds-password=${INSTALL_DM_PASSWORD}"
  )

  if [[ "${INSTALL_DNS}" == "true" ]]; then
    install_cmd+=( --setup-dns )
    if [[ "${INSTALL_USE_AUTO_FORWARDERS}" == "true" ]]; then
      install_cmd+=( --auto-forwarders )
    elif [[ -n "${INSTALL_DNS_FORWARDERS}" ]]; then
      for _fwd in ${INSTALL_DNS_FORWARDERS}; do
        install_cmd+=( "--forwarder=${_fwd}" )
      done
    else
      install_cmd+=( --no-forwarders )
    fi
    if [[ "${INSTALL_CONFIGURE_REVERSE_ZONE}" == "true" ]]; then
      install_cmd+=( --auto-reverse )
    else
      install_cmd+=( --no-reverse )
    fi
  fi

  if [[ "${INSTALL_USE_LETSENCRYPT}" == "true" ]]; then
    __log "Using Let's Encrypt certificates"
    install_cmd+=(
      "--http-cert-file=${INSTALL_FULLCHAIN_PATH}"
      "--http-key-file=${INSTALL_KEY_PATH}"
      "--dirsrv-cert-file=${INSTALL_FULLCHAIN_PATH}"
      "--dirsrv-key-file=${INSTALL_KEY_PATH}"
      "--dirsrv-pin="
    )
  fi

  __log "Running FreeIPA installation (may take 10–20 minutes)..."
  "${install_cmd[@]}"

  # If using Let's Encrypt, wire up the auto-renewal hook
  if [[ "${INSTALL_USE_LETSENCRYPT}" == "true" ]]; then
    __configure_letsencrypt_renewal
  fi

  __log "FreeIPA server installation completed"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Reverse proxy Apache configuration ──────────────────────────────────────

__configure_reverse_proxy() {
  __log "Configuring FreeIPA for reverse proxy setup..."

  local apache_conf_dir=""
  if [[ -d "/etc/httpd/conf.d" ]]; then
    apache_conf_dir="/etc/httpd/conf.d"
  elif [[ -d "/etc/apache2/conf-available" ]]; then
    apache_conf_dir="/etc/apache2/conf-available"
  else
    __warn "Could not find Apache configuration directory; skipping reverse proxy config"
    return
  fi

  local apache_port_conf="${apache_conf_dir}/freeipa-port.conf"

  \cat > "${apache_port_conf}" << EOF
# Custom port configuration for FreeIPA behind reverse proxy
Listen ${INSTALL_FREEIPA_PORT} https

<VirtualHost *:${INSTALL_FREEIPA_PORT}>
    ServerName ${INSTALL_FQDN}

    SSLEngine on
    SSLCertificateFile /var/lib/ipa/certs/httpd.crt
    SSLCertificateKeyFile /var/lib/ipa/private/httpd.key
    SSLCertificateChainFile /var/lib/ipa/certs/ca.crt

    RequestHeader set X-Forwarded-Proto "https"
    RequestHeader set X-Forwarded-Port "${INSTALL_FREEIPA_PORT}"

    # Include FreeIPA vhost configuration
EOF

  if [[ -f "/etc/httpd/conf.d/ipa.conf" ]]; then
    printf '    Include /etc/httpd/conf.d/ipa.conf\n' >> "${apache_port_conf}"
  elif [[ -f "/etc/apache2/conf-available/ipa.conf" ]]; then
    printf '    Include /etc/apache2/conf-available/ipa.conf\n' >> "${apache_port_conf}"
  fi

  printf '</VirtualHost>\n' >> "${apache_port_conf}"

  # Enable the configuration if using Apache2's conf-enabled mechanism
  if [[ -d "/etc/apache2/conf-enabled" ]]; then
    \ln -sf "${apache_port_conf}" /etc/apache2/conf-enabled/freeipa-port.conf
  fi

  # Comment out the default Listen 443 from ssl.conf if present
  if [[ -f "/etc/httpd/conf.d/ssl.conf" ]]; then
    \sed -i 's/^Listen 443/#Listen 443/' /etc/httpd/conf.d/ssl.conf 2>/dev/null || true
  fi

  if [[ -f "/etc/apache2/ports.conf" ]]; then
    \sed -i 's/^Listen 443/#Listen 443/' /etc/apache2/ports.conf 2>/dev/null || true
  fi

  __log "Configured Apache to listen on port ${INSTALL_FREEIPA_PORT}"

  if \systemctl list-unit-files | \grep -q -- "^httpd.service"; then
    \systemctl restart httpd
  elif \systemctl list-unit-files | \grep -q -- "^apache2.service"; then
    \systemctl restart apache2
  fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── LDAP base DN derivation ─────────────────────────────────────────────────

__derive_ldap_base_dn() {
  local dn="" part
  local IFS='.'
  for part in ${INSTALL_DOMAIN}; do
    dn="${dn},dc=${part}"
  done
  INSTALL_LDAP_BASE_DN="${dn#,}"
  INSTALL_KEYCLOAK_REALM="${INSTALL_KEYCLOAK_REALM:-${INSTALL_DOMAIN}}"
  __log "LDAP base DN: ${INSTALL_LDAP_BASE_DN}"
  __log "Keycloak realm: ${INSTALL_KEYCLOAK_REALM}"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Docker installation ─────────────────────────────────────────────────────

__install_docker() {
  if \command -v docker >/dev/null 2>&1; then
    __log "Docker already installed; skipping"
    return 0
  fi

  __log "Installing Docker CE..."

  case "${INSTALL_DISTRO_FAMILY}" in
    *rhel*|*fedora*|*centos*)
      local repo_distro
      case "${INSTALL_DISTRO}" in
        fedora) repo_distro="fedora" ;;
        centos) repo_distro="centos" ;;
        *)      repo_distro="rhel"   ;;
      esac
      \dnf install -y dnf-plugins-core
      \dnf config-manager --add-repo "https://download.docker.com/linux/${repo_distro}/docker-ce.repo"
      \dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
      ;;

    *debian*|*ubuntu*)
      \apt-get install -y ca-certificates curl gnupg
      \mkdir -p /etc/apt/keyrings
      \curl -fsSL "https://download.docker.com/linux/${INSTALL_DISTRO}/gpg" | \gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      \chmod a+r /etc/apt/keyrings/docker.gpg
      local arch codename
      arch="$(\dpkg --print-architecture)"
      # Source os-release to get VERSION_CODENAME
      # shellcheck source=/dev/null
      . /etc/os-release
      codename="${VERSION_CODENAME:-}"
      printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
        "${arch}" "${INSTALL_DISTRO}" "${codename}" > /etc/apt/sources.list.d/docker.list
      \apt-get update && \apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
      ;;

    *)
      __error "Unsupported distribution family for Docker install: ${INSTALL_DISTRO_FAMILY}"
      ;;
  esac

  \systemctl enable docker && \systemctl start docker
  __log "Docker installed and started"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── jq installation ─────────────────────────────────────────────────────────

__install_jq() {
  if \command -v jq >/dev/null 2>&1; then
    __log "jq already installed; skipping"
    return 0
  fi

  __log "Installing jq..."

  case "${INSTALL_DISTRO_FAMILY}" in
    *rhel*|*fedora*|*centos*)
      if \command -v dnf >/dev/null 2>&1; then
        \dnf install -y jq
      else
        \yum install -y jq
      fi
      ;;
    *debian*|*ubuntu*)
      \apt-get install -y jq
      ;;
    *suse*)
      \zypper install -y jq
      ;;
    *)
      __error "Unsupported distribution family for jq install: ${INSTALL_DISTRO_FAMILY}"
      ;;
  esac

  __log "jq installed"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Prerequisites ───────────────────────────────────────────────────────────

__install_prerequisites() {
  __log "Installing prerequisites..."
  __install_docker
  __install_jq
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── FreeIPA post-config for Keycloak ────────────────────────────────────────

__setup_freeipa_for_keycloak() {
  __log "Configuring FreeIPA for Keycloak LDAP federation..."

  # Load or generate Keycloak LDAP bind password
  INSTALL_KEYCLOAK_LDAP_PASSWORD="$(__load_credential "${INSTALL_CRED_FILE}" INSTALL_KEYCLOAK_LDAP_PASSWORD)" || {
    INSTALL_KEYCLOAK_LDAP_PASSWORD="$(__random_password 32)"
    __save_credential "${INSTALL_CRED_FILE}" INSTALL_KEYCLOAK_LDAP_PASSWORD "${INSTALL_KEYCLOAK_LDAP_PASSWORD}"
  }

  \mkdir -p "${INSTALL_KEYCLOAK_CONFIG_DIR}"

  # Obtain a Kerberos ticket for the admin user
  printf '%s\n' "${INSTALL_ADMIN_PASSWORD}" | \kinit "admin@${INSTALL_REALM}"

  # Create temp dir before mktemp to ensure parent exists
  \mkdir -p "${TMPDIR:-/tmp}/scriptmgr"
  INSTALL_LDIF_TMP="$(\mktemp "${TMPDIR:-/tmp}/scriptmgr/freeipa-XXXXXX.ldif")"

  # Write LDIF for the Keycloak sysaccount bind user
  {
    printf 'dn: uid=keycloak,cn=sysaccounts,cn=etc,%s\n' "${INSTALL_LDAP_BASE_DN}"
    printf 'objectClass: account\n'
    printf 'objectClass: simplesecurityobject\n'
    printf 'uid: keycloak\n'
    printf 'userPassword: {cleartext}%s\n' "${INSTALL_KEYCLOAK_LDAP_PASSWORD}"
    printf 'passwordExpirationTime: 20380119031407Z\n'
    printf 'nsIdleTimeout: 0\n'
  } > "${INSTALL_LDIF_TMP}"

  \ldapadd -Y GSSAPI -H "ldap://localhost" -f "${INSTALL_LDIF_TMP}" || true

  # Remove LDIF immediately — it contained a cleartext password
  \rm -f "${INSTALL_LDIF_TMP}"
  INSTALL_LDIF_TMP=""

  # Create HTTP service principal for Kerberos SPNEGO
  \ipa service-add "HTTP/${INSTALL_FQDN}" 2>/dev/null || true

  # Export keytab for Keycloak
  \ipa-getkeytab -p "HTTP/${INSTALL_FQDN}@${INSTALL_REALM}" -k "${INSTALL_KEYCLOAK_CONFIG_DIR}/keycloak.keytab"
  \chmod 600 "${INSTALL_KEYCLOAK_CONFIG_DIR}/keycloak.keytab"

  # Export IPA CA certificate so Keycloak can trust LDAPS
  \cp /etc/ipa/ca.crt "${INSTALL_KEYCLOAK_CONFIG_DIR}/ipa-ca.crt"
  \chmod 644 "${INSTALL_KEYCLOAK_CONFIG_DIR}/ipa-ca.crt"

  # Destroy Kerberos ticket — no longer needed
  \kdestroy 2>/dev/null || true

  __log "FreeIPA configured for Keycloak federation"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Docker Compose helper ───────────────────────────────────────────────────

__compose() {
  if \docker compose version >/dev/null 2>&1; then
    \docker compose "$@"
  else
    \docker-compose "$@"
  fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Keycloak Docker deployment ──────────────────────────────────────────────

__install_keycloak_docker() {
  __log "Deploying Keycloak via Docker Compose..."

  # Load or generate Keycloak admin password
  INSTALL_KEYCLOAK_ADMIN_PASSWORD="$(__load_credential "${INSTALL_CRED_FILE}" INSTALL_KEYCLOAK_ADMIN_PASSWORD)" || {
    INSTALL_KEYCLOAK_ADMIN_PASSWORD="$(__random_password 32)"
    __save_credential "${INSTALL_CRED_FILE}" INSTALL_KEYCLOAK_ADMIN_PASSWORD "${INSTALL_KEYCLOAK_ADMIN_PASSWORD}"
  }

  # Load or generate Keycloak database password
  INSTALL_KEYCLOAK_DB_PASSWORD="$(__load_credential "${INSTALL_CRED_FILE}" INSTALL_KEYCLOAK_DB_PASSWORD)" || {
    INSTALL_KEYCLOAK_DB_PASSWORD="$(__random_password 32)"
    __save_credential "${INSTALL_CRED_FILE}" INSTALL_KEYCLOAK_DB_PASSWORD "${INSTALL_KEYCLOAK_DB_PASSWORD}"
  }

  # Load or generate stable Keycloak port
  INSTALL_KEYCLOAK_PORT="$(__load_credential "${INSTALL_CRED_FILE}" INSTALL_KEYCLOAK_PORT)" || {
    INSTALL_KEYCLOAK_PORT="$(__random_port)"
    __save_credential "${INSTALL_CRED_FILE}" INSTALL_KEYCLOAK_PORT "${INSTALL_KEYCLOAK_PORT}"
  }

  local primary_ip
  primary_ip="$(\hostname -I | \awk '{print $1}')"

  \mkdir -p "${INSTALL_COMPOSE_DIR}"

  # Generate docker-compose.yml with all values hardcoded — no .env required
  \cat > "${INSTALL_COMPOSE_DIR}/docker-compose.yml" << EOF
# Generated by install.sh — do not edit manually
# Regenerate by re-running install.sh

services:
  postgres:
    image: postgres:16-alpine
    container_name: keycloak-db
    restart: unless-stopped
    pull_policy: missing
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: "${INSTALL_KEYCLOAK_DB_PASSWORD}"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - keycloak
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U keycloak"]
      interval: 10s
      timeout: 5s
      retries: 5

  keycloak:
    image: quay.io/keycloak/keycloak:latest
    container_name: keycloak
    restart: unless-stopped
    pull_policy: missing
    command: start
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: "${INSTALL_KEYCLOAK_DB_PASSWORD}"
      KC_HTTP_ENABLED: "true"
      KC_HTTP_PORT: "8080"
      KC_HOSTNAME_STRICT: "false"
      KC_PROXY: edge
      KC_TRUSTSTORE_PATHS: /etc/keycloak/ipa-ca.crt
      KEYCLOAK_ADMIN: admin
      KEYCLOAK_ADMIN_PASSWORD: "${INSTALL_KEYCLOAK_ADMIN_PASSWORD}"
      KC_LOG_LEVEL: INFO
      JAVA_OPTS_APPEND: -Djava.security.krb5.conf=/etc/krb5.conf
    volumes:
      - "${INSTALL_KEYCLOAK_CONFIG_DIR}/keycloak.keytab:/etc/keycloak/keycloak.keytab:ro"
      - "${INSTALL_KEYCLOAK_CONFIG_DIR}/ipa-ca.crt:/etc/keycloak/ipa-ca.crt:ro"
      - "/etc/krb5.conf:/etc/krb5.conf:ro"
      - keycloak_data:/opt/keycloak/data
    ports:
      - "172.17.0.1:${INSTALL_KEYCLOAK_PORT}:8080"
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - keycloak
    extra_hosts:
      - "${INSTALL_FQDN}:${primary_ip}"
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8080/health/ready || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 90s

networks:
  keycloak:
    name: keycloak
    driver: bridge

volumes:
  postgres_data:
  keycloak_data:
EOF

  \chmod 600 "${INSTALL_COMPOSE_DIR}/docker-compose.yml"

  __compose -f "${INSTALL_COMPOSE_DIR}/docker-compose.yml" up -d

  __log "Keycloak containers started"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Wait for Keycloak readiness ─────────────────────────────────────────────

__wait_for_keycloak() {
  __log "Waiting for Keycloak to become ready (up to 300 s)..."
  local elapsed=0
  while [[ "${elapsed}" -lt 300 ]]; do
    if \curl -q -LSs --max-time 5 "http://172.17.0.1:${INSTALL_KEYCLOAK_PORT}/health/ready" >/dev/null 2>&1; then
      __log "Keycloak is ready"
      return 0
    fi
    __log "  ... waiting (${elapsed}s elapsed)"
    sleep 10
    elapsed=$(( elapsed + 10 ))
  done
  __error "Keycloak did not become ready within 300 seconds (exit 69)"
  exit 69
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Keycloak admin token helper ─────────────────────────────────────────────

__keycloak_admin_token() {
  local kc_url="http://172.17.0.1:${INSTALL_KEYCLOAK_PORT}"
  \curl -q -LSs --max-time 10 -X POST \
    "${kc_url}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=admin-cli" \
    --data-urlencode "username=admin" \
    --data-urlencode "password=${INSTALL_KEYCLOAK_ADMIN_PASSWORD}" \
    | \jq -r '.access_token'
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Keycloak REST API configuration ─────────────────────────────────────────

__configure_keycloak() {
  __log "Configuring Keycloak realm and LDAP federation..."

  local kc_url="http://172.17.0.1:${INSTALL_KEYCLOAK_PORT}"
  local token

  # Step 1 — Create realm
  token="$(__keycloak_admin_token)"
  \curl -q -LSs --max-time 10 -X POST \
    "${kc_url}/admin/realms" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$(\jq -n --arg r "${INSTALL_KEYCLOAK_REALM}" --arg d "${INSTALL_DOMAIN}" \
      '{realm: $r, enabled: true, displayName: ("SSO — " + $d), sslRequired: "external", registrationAllowed: false, bruteForceProtected: true}')"

  __log "Realm ${INSTALL_KEYCLOAK_REALM} created"

  # Step 2 — Create LDAP user federation component
  token="$(__keycloak_admin_token)"

  local ldap_body
  ldap_body="$(\jq -n \
    --arg fqdn "${INSTALL_FQDN}" \
    --arg base_dn "${INSTALL_LDAP_BASE_DN}" \
    --arg ldap_pass "${INSTALL_KEYCLOAK_LDAP_PASSWORD}" \
    --arg realm "${INSTALL_REALM}" \
    --arg keytab "/etc/keycloak/keycloak.keytab" \
    '{
      name: "freeipa-ldap",
      providerId: "ldap",
      providerType: "org.keycloak.storage.UserStorageProvider",
      config: {
        enabled: ["true"],
        priority: ["0"],
        importEnabled: ["true"],
        editMode: ["READ_ONLY"],
        syncRegistrations: ["false"],
        vendor: ["rhds"],
        usernameLDAPAttribute: ["uid"],
        rdnLDAPAttribute: ["uid"],
        uuidLDAPAttribute: ["ipaUniqueID"],
        userObjectClasses: ["inetOrgPerson, organizationalPerson"],
        connectionUrl: [("ldaps://" + $fqdn + ":636")],
        usersDn: [("cn=users,cn=accounts," + $base_dn)],
        authType: ["simple"],
        bindDn: [("uid=keycloak,cn=sysaccounts,cn=etc," + $base_dn)],
        bindCredential: [$ldap_pass],
        searchScope: ["1"],
        pagination: ["true"],
        connectionPooling: ["true"],
        connectionTimeout: ["5000"],
        readTimeout: ["10000"],
        useTruststoreSpi: ["ldapsOnly"],
        kerberosIntegration: ["true"],
        serverPrincipal: [("HTTP/" + $fqdn + "@" + $realm)],
        keyTab: [$keytab],
        kerberosRealm: [$realm],
        allowKerberosAuthentication: ["true"],
        useKerberosForPasswordAuthentication: ["false"],
        updateProfileFirstLogin: ["false"],
        cachePolicy: ["DEFAULT"],
        batchSizeForSync: ["1000"],
        fullSyncPeriod: ["-1"],
        changedSyncPeriod: ["86400"]
      }
    }')"

  local ldap_response component_id
  ldap_response="$(\curl -q -LSs --max-time 10 -X POST -D - \
    "${kc_url}/admin/realms/${INSTALL_KEYCLOAK_REALM}/components" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${ldap_body}")"
  component_id="$(printf '%s\n' "${ldap_response}" | \grep -i -- "^[Ll]ocation:" | \sed 's|.*/||' | \tr -d '\r\n')"

  __log "LDAP federation component created (id: ${component_id})"

  # Step 3 — Trigger full LDAP sync
  \curl -q -LSs --max-time 30 -X POST \
    "${kc_url}/admin/realms/${INSTALL_KEYCLOAK_REALM}/user-storage/${component_id}/sync?action=triggerFullSync" \
    -H "Authorization: Bearer ${token}" >/dev/null

  __log "LDAP full sync triggered"

  # Step 4 — Wait for admin user to appear after sync (up to 60 s)
  token="$(__keycloak_admin_token)"
  local admin_user_id="" attempt=0
  while [[ -z "${admin_user_id}" || "${admin_user_id}" == "null" ]] && [[ "${attempt}" -lt 12 ]]; do
    sleep 5
    admin_user_id="$(\curl -q -LSs --max-time 10 \
      "${kc_url}/admin/realms/${INSTALL_KEYCLOAK_REALM}/users?username=admin&exact=true" \
      -H "Authorization: Bearer ${token}" \
      | \jq -r '.[0].id // empty')"
    attempt=$(( attempt + 1 ))
  done

  if [[ -z "${admin_user_id}" || "${admin_user_id}" == "null" ]]; then
    __warn "Could not find admin user in Keycloak after LDAP sync — realm-admin role not assigned"
    return 0
  fi

  # Step 5 — Assign realm-admin role to admin user

  # Get realm-management client ID
  local rm_client_id
  rm_client_id="$(\curl -q -LSs --max-time 10 \
    "${kc_url}/admin/realms/${INSTALL_KEYCLOAK_REALM}/clients?clientId=realm-management" \
    -H "Authorization: Bearer ${token}" \
    | \jq -r '.[0].id')"

  # Get realm-admin role details
  local role_info role_id role_name
  role_info="$(\curl -q -LSs --max-time 10 \
    "${kc_url}/admin/realms/${INSTALL_KEYCLOAK_REALM}/clients/${rm_client_id}/roles/realm-admin" \
    -H "Authorization: Bearer ${token}")"
  role_id="$(printf '%s\n' "${role_info}" | \jq -r '.id')"
  role_name="$(printf '%s\n' "${role_info}" | \jq -r '.name')"

  # Assign realm-admin role to the admin user
  \curl -q -LSs --max-time 10 -X POST \
    "${kc_url}/admin/realms/${INSTALL_KEYCLOAK_REALM}/users/${admin_user_id}/role-mappings/clients/${rm_client_id}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "[$(\jq -n --arg id "${role_id}" --arg name "${role_name}" '{id: $id, name: $name}')]" >/dev/null

  __log "Keycloak realm configured. Admin promoted to realm-admin."
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Keycloak nginx vhost ─────────────────────────────────────────────────────

__configure_keycloak_nginx() {
  if ! \command -v nginx >/dev/null 2>&1; then
    __log "nginx not found; skipping Keycloak nginx vhost"
    return 0
  fi

  __log "Configuring nginx vhost for Keycloak..."

  \mkdir -p /etc/nginx/vhosts.d

  local vhost_file="/etc/nginx/vhosts.d/${INSTALL_FQDN}-keycloak.conf"

  if [[ "${INSTALL_USE_LETSENCRYPT}" == "true" ]]; then
    \cat > "${vhost_file}" << EOF
# Keycloak SSO reverse proxy — generated by install.sh
server {
    listen 443 ssl;
    server_name ${INSTALL_FQDN};

    ssl_certificate     /etc/letsencrypt/live/domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/domain/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    access_log /var/log/nginx/${INSTALL_FQDN}-keycloak.access.log combined;
    error_log  /var/log/nginx/${INSTALL_FQDN}-keycloak.error.log warn;

    location / {
        proxy_pass http://172.17.0.1:${INSTALL_KEYCLOAK_PORT};

        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port  \$server_port;

        proxy_connect_timeout 3600;
        proxy_send_timeout    3600;
        proxy_read_timeout    3600;
        send_timeout          3600;

        proxy_buffer_size        128k;
        proxy_buffers            4 256k;
        proxy_busy_buffers_size  256k;
    }
}
EOF
  else
    \cat > "${vhost_file}" << EOF
# Keycloak SSO reverse proxy — generated by install.sh
# NOTE: TLS is not configured — add ssl_certificate / ssl_certificate_key directives
#       and change the listen directive to 'listen 443 ssl;' once certificates are in place.
server {
    listen 80;
    server_name ${INSTALL_FQDN};

    access_log /var/log/nginx/${INSTALL_FQDN}-keycloak.access.log combined;
    error_log  /var/log/nginx/${INSTALL_FQDN}-keycloak.error.log warn;

    location / {
        proxy_pass http://172.17.0.1:${INSTALL_KEYCLOAK_PORT};

        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port  \$server_port;

        proxy_connect_timeout 3600;
        proxy_send_timeout    3600;
        proxy_read_timeout    3600;
        send_timeout          3600;

        proxy_buffer_size        128k;
        proxy_buffers            4 256k;
        proxy_busy_buffers_size  256k;
    }
}
EOF
  fi

  __log "nginx vhost written: ${vhost_file}"

  \nginx -t 2>/dev/null && \systemctl reload nginx 2>/dev/null || \systemctl reload nginx 2>/dev/null || __warn "nginx reload failed — check config manually"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Post-install stubs ───────────────────────────────────────────────────────

__configure_ad_trust() {
  __log "AD trust skipped — run 'ipa-adtrust-install' manually if needed"
}

__create_initial_objects() {
  __log "Initial user/group creation skipped — use the web UI or CLI after installation"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Summary ─────────────────────────────────────────────────────────────────

__display_summary() {
  local primary_ip
  primary_ip="$(\hostname -I | \awk '{print $1}')"

  __log "FreeIPA + Keycloak Installation Summary"
  printf '==========================================\n'
  printf 'Hostname:                  %s\n' "${INSTALL_FQDN}"
  printf 'Domain:                    %s\n' "${INSTALL_DOMAIN}"
  printf 'Realm:                     %s\n' "${INSTALL_REALM}"
  printf 'Admin port:                %s\n' "${INSTALL_FREEIPA_PORT}"
  printf 'Admin username:            admin\n'
  printf 'Admin password:            (saved to %s)\n' "${INSTALL_CRED_FILE}"
  printf 'Directory Manager pass:    (saved to %s)\n' "${INSTALL_CRED_FILE}"
  if [[ "${INSTALL_DNS}" == "true" ]]; then
    printf 'Integrated DNS:            Yes\n'
  else
    printf 'Integrated DNS:            No\n'
  fi
  if [[ "${INSTALL_USE_LETSENCRYPT}" == "true" ]]; then
    printf 'SSL Certificate:           Let'"'"'s Encrypt\n'
    printf 'Certificate path:          %s\n' "${INSTALL_CERT_PATH}"
    printf 'Auto-renewal:              Configured\n'
  elif [[ "${INSTALL_USE_FREEIPA_CA}" == "true" ]]; then
    printf 'SSL Certificate:           FreeIPA built-in CA\n'
  elif [[ "${INSTALL_USE_SELFSIGNED}" == "true" ]]; then
    printf 'SSL Certificate:           Self-signed\n'
  else
    printf 'SSL Certificate:           Manual configuration required\n'
  fi
  printf '==========================================\n\n'

  printf 'Access FreeIPA:\n'
  printf '  Internal URL: https://%s:%s/ipa/ui\n' "${INSTALL_FQDN}" "${INSTALL_FREEIPA_PORT}"
  printf '  (Configure your reverse proxy to forward to this URL)\n\n'

  printf 'Service management:\n'
  printf '  ipactl status    — check all services\n'
  printf '  ipactl start     — start all services\n'
  printf '  ipactl stop      — stop all services\n'
  printf '  ipactl restart   — restart all services\n\n'

  printf 'Next steps:\n'
  printf '  1. Configure your external reverse proxy to forward to https://%s:%s\n' "${INSTALL_FQDN}" "${INSTALL_FREEIPA_PORT}"
  printf '  2. Access the admin interface and complete initial setup\n'
  printf '  3. Retrieve admin and Directory Manager passwords from %s\n' "${INSTALL_CRED_FILE}"
  if [[ "${INSTALL_USE_LETSENCRYPT}" == "true" ]]; then
    printf '  4. Let'"'"'s Encrypt certificates will auto-renew via the installed hook\n'
  fi

  if [[ "${INSTALL_DNS}" == "true" ]]; then
    printf '\nDNS configuration:\n'
    printf '  Set nameserver to: %s\n' "${primary_ip}"
    printf '  Test DNS: dig %s @%s\n' "${INSTALL_FQDN}" "${primary_ip}"
  fi

  printf '\nNginx reverse proxy snippet:\n'
  printf '    location / {\n'
  printf '        proxy_pass https://%s:%s;\n' "${INSTALL_FQDN}" "${INSTALL_FREEIPA_PORT}"
  printf '        proxy_set_header Host $host;\n'
  printf '        proxy_set_header X-Real-IP $remote_addr;\n'
  printf '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
  printf '        proxy_set_header X-Forwarded-Proto $scheme;\n'
  printf '        proxy_set_header X-Forwarded-Port $server_port;\n'
  printf '        proxy_ssl_verify off;\n'
  printf '    }\n\n'

  printf 'Kerberos:\n'
  printf '  kinit admin   — get Kerberos ticket for admin\n'
  printf '  klist         — list active tickets\n'
  printf '  kdestroy      — destroy tickets\n\n'

  printf 'Important files:\n'
  printf '  /etc/ipa/default.conf             — IPA configuration\n'
  printf '  /var/log/ipaserver-install.log    — installation log\n'
  printf '  /var/log/httpd/                   — web server logs\n'
  printf '  /var/log/dirsrv/                  — directory server logs\n'
  printf '  %s        — generated credentials\n' "${INSTALL_CRED_FILE}"

  printf '\nKeycloak SSO:\n'
  printf '  Admin console:  http://172.17.0.1:%s (internal)\n' "${INSTALL_KEYCLOAK_PORT}"
  printf '  Admin user:     admin (Keycloak master realm)\n'
  printf '  Admin pass:     (saved to %s)\n' "${INSTALL_CRED_FILE}"
  printf '  Realm:          %s\n' "${INSTALL_KEYCLOAK_REALM}"
  printf '  LDAP sync:      FreeIPA → Keycloak federation active\n'
  printf '  Kerberos SPNEGO: HTTP/%s@%s\n' "${INSTALL_FQDN}" "${INSTALL_REALM}"
  printf '  Docker compose: %s/docker-compose.yml\n' "${INSTALL_COMPOSE_DIR}"
  printf '  Credentials:    %s\n' "${INSTALL_CRED_FILE}"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Argument parsing ─────────────────────────────────────────────────────────

__parse_args() {
  local _opts
  _opts="$(getopt -o hv -l help,version,debug,no-color -n "${APPNAME}" -- "$@")" || { __help; exit 2; }
  eval set -- "${_opts}"
  while true; do
    case "$1" in
      -h|--help)
        __help
        exit 0
        ;;
      -v|--version)
        __version
        exit 0
        ;;
      --debug)
        INSTALL_DEBUG=1
        shift
        ;;
      --no-color)
        NO_COLOR=1
        INSTALL_COLOR_RED=""
        INSTALL_COLOR_GREEN=""
        INSTALL_COLOR_YELLOW=""
        INSTALL_COLOR_BLUE=""
        INSTALL_COLOR_RESET=""
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Main ────────────────────────────────────────────────────────────────────

__main() {
  __parse_args "$@"

  __log "Starting Full FreeIPA + Keycloak SSO installation"

  __check_root
  __detect_distro
  __detect_domain
  __check_requirements

  # Load or pick a stable reverse-proxy port for this installation
  INSTALL_FREEIPA_PORT="$(__load_credential "${INSTALL_CRED_FILE}" INSTALL_FREEIPA_PORT)" || {
    INSTALL_FREEIPA_PORT="$(__random_port)"
    __save_credential "${INSTALL_CRED_FILE}" INSTALL_FREEIPA_PORT "${INSTALL_FREEIPA_PORT}"
  }
  __log "Selected FreeIPA port: ${INSTALL_FREEIPA_PORT}"

  __install_prerequisites
  __configure_hosts
  __install_packages
  __configure_ntp_settings
  __configure_ssl_certs
  __configure_dns_settings
  __configure_firewall
  __install_freeipa
  __configure_reverse_proxy
  __derive_ldap_base_dn
  __setup_freeipa_for_keycloak
  __install_keycloak_docker
  __wait_for_keycloak
  __configure_keycloak
  __configure_keycloak_nginx
  __configure_ad_trust
  __create_initial_objects
  __display_summary

  __log "FreeIPA + Keycloak installation and configuration completed"
  __log "Access the web interface through your reverse proxy"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# Run main only when executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  __main "$@"
fi

# ex: ts=2 sw=2 et filetype=sh
