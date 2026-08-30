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
FREEIPA_FQDN="${FREEIPA_FQDN:-}"
FREEIPA_DOMAIN="${FREEIPA_DOMAIN:-}"
FREEIPA_REALM="${FREEIPA_REALM:-}"
FREEIPA_PORT="${FREEIPA_PORT:-}"
FREEIPA_CRED_FILE="${FREEIPA_CRED_FILE:-/root/.freeipa-install.conf}"
INSTALL_DNS="false"
INSTALL_NO_NTP="false"
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
FREEIPA_DEBUG="${FREEIPA_DEBUG:-0}"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Keycloak / LDAP globals
INSTALL_LDAP_BASE_DN=""
FREEIPA_KEYCLOAK_PORT="${FREEIPA_KEYCLOAK_PORT:-}"
FREEIPA_KEYCLOAK_REALM="${FREEIPA_KEYCLOAK_REALM:-}"
INSTALL_KEYCLOAK_ADMIN_PASSWORD=""
INSTALL_KEYCLOAK_LDAP_PASSWORD=""
INSTALL_KEYCLOAK_DB_PASSWORD=""
FREEIPA_COMPOSE_DIR="${FREEIPA_COMPOSE_DIR:-/opt/keycloak}"
FREEIPA_KEYCLOAK_CONFIG_DIR="${FREEIPA_KEYCLOAK_CONFIG_DIR:-/etc/keycloak}"
INSTALL_LDIF_TMP=""
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Mail (Postfix/Dovecot) globals
FREEIPA_MAIL_DOMAIN="${FREEIPA_MAIL_DOMAIN:-}"
FREEIPA_MAIL_BASE_DIR="${FREEIPA_MAIL_BASE_DIR:-/var/mail/vhosts}"
FREEIPA_MAIL_VUSER="${FREEIPA_MAIL_VUSER:-vmail}"
FREEIPA_MAIL_VID="${FREEIPA_MAIL_VID:-5000}"
INSTALL_MAIL_LDAP_PASSWORD=""
INSTALL_MAIL_CERT_PATH=""
INSTALL_MAIL_KEY_PATH=""
FREEIPA_MAIL_LOCAL_FALLBACK="${FREEIPA_MAIL_LOCAL_FALLBACK:-true}"
FREEIPA_MAIL_KEYCLOAK_AUTH="${FREEIPA_MAIL_KEYCLOAK_AUTH:-true}"
FREEIPA_MAIL_KEYCLOAK_CLIENT_ID="${FREEIPA_MAIL_KEYCLOAK_CLIENT_ID:-dovecot-mail}"
INSTALL_MAIL_KEYCLOAK_SECRET=""
# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Standard Utility Functions ──────────────────────────────────────────────

__primary_ip() {
  # `hostname -I`'s first token is unreliable once Docker is installed (this
  # script installs it as a prerequisite): docker0/br-* bridge addresses can
  # sort before the real outbound interface. Ask the routing table which
  # source address it would actually use to reach the internet instead.
  local ip
  ip="$(\ip -4 route get 1.1.1.1 2>/dev/null | \awk '{for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1)}')"
  if [[ -z "${ip}" ]]; then
    ip="$(\hostname -I 2>/dev/null | \awk '{print $1}' || true)"
  fi
  printf '%s' "${ip}"
}

__random_password() {
  local length="${1:-32}"
  # tr reads /dev/urandom infinitely; head closes the pipe after N bytes, sending
  # SIGPIPE to tr. Run tr in a subshell and absorb the SIGPIPE with || true so
  # set -o pipefail does not propagate tr's exit 141 to the caller.
  ( \tr -dc 'A-Za-z0-9!@#$%^&*_+-' </dev/urandom 2>/dev/null || true ) | \head -c "${length}"
  printf '\n'
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
  local _dir="${file%/*}"
  [[ "${_dir}" == "${file}" ]] && _dir="."
  \mkdir -p "${_dir}"
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
  val="$(\grep -- "^${key}=" "${file}" | \tail -n1 | \cut -d= -f2- || true)"
  [[ -n "${val}" ]] || return 1
  printf '%s\n' "${val}"
}

# Older install.sh releases persisted the port credentials under their old
# INSTALL_* key names. On upgrade, the renamed FREEIPA_* keys used below would
# be absent from an existing credentials file, causing this script to
# generate and save a brand-new random port that doesn't match the port the
# already-deployed Keycloak container is actually bound to. Rename the
# legacy keys in place, once, so an upgraded script keeps reading the same
# port a previous run already committed to.
__migrate_legacy_credential_keys() {
  local file="${1:?Usage: __migrate_legacy_credential_keys <file>}"
  [[ -f "${file}" ]] || return 0
  local old new
  for pair in "INSTALL_FREEIPA_PORT:FREEIPA_PORT" "INSTALL_KEYCLOAK_PORT:FREEIPA_KEYCLOAK_PORT"; do
    old="${pair%%:*}"
    new="${pair##*:}"
    if \grep -q -- "^${old}=" "${file}" && ! \grep -q -- "^${new}=" "${file}"; then
      \sed -i "s/^${old}=/${new}=/" "${file}"
    fi
  done
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
  if [[ "${FREEIPA_DEBUG}" -eq 1 ]]; then
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
  printf '      --no-ntp      Skip time sync (needed in containers without CAP_SYS_TIME)\n'
  printf '      --color       Force color output\n'
  printf '      --no-color    Disable color output\n\n'
  printf 'Environment:\n'
  printf '  FREEIPA_FQDN             Override auto-detected hostname\n'
  printf '  FREEIPA_DOMAIN           Override auto-detected domain\n'
  printf '  FREEIPA_REALM            Override auto-detected Kerberos realm\n'
  printf '  FREEIPA_PORT             Override auto-detected reverse-proxy port\n'
  printf '  FREEIPA_CRED_FILE        Credentials file path (default: /root/.freeipa-install.conf)\n'
  printf '  FREEIPA_DEBUG            Enable debug output when set to 1 (same as --debug)\n'
  printf '  FREEIPA_KEYCLOAK_PORT    Override Keycloak port (default: random in 62000-64999)\n'
  printf '  FREEIPA_KEYCLOAK_REALM   Override Keycloak realm (default: domain name)\n'
  printf '  FREEIPA_COMPOSE_DIR      Docker Compose directory (default: /opt/keycloak)\n'
  printf '  FREEIPA_KEYCLOAK_CONFIG_DIR  Keycloak config directory (default: /etc/keycloak)\n'
  printf '  FREEIPA_MAIL_DOMAIN      Mail domain for virtual mailboxes (default: FREEIPA_DOMAIN)\n'
  printf '  FREEIPA_MAIL_BASE_DIR    Maildir storage root (default: /var/mail/vhosts)\n'
  printf '  FREEIPA_MAIL_VUSER       System user/group owning mailbox storage (default: vmail)\n'
  printf '  FREEIPA_MAIL_VID         UID/GID for FREEIPA_MAIL_VUSER (default: 5000)\n'
  printf '  FREEIPA_MAIL_LOCAL_FALLBACK   Add a Unix/PAM passdb fallback (default: true)\n'
  printf '  FREEIPA_MAIL_KEYCLOAK_AUTH    Add a Keycloak OAUTHBEARER passdb (default: true)\n'
  printf '  FREEIPA_MAIL_KEYCLOAK_CLIENT_ID  Keycloak client ID for token introspection (default: dovecot-mail)\n'
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
  mem_kb="$(\grep -- "MemTotal" /proc/meminfo | \awk '{print $2}' || true)"
  mem_gb=$(( mem_kb / 1024 / 1024 ))

  if [[ "${mem_gb}" -lt 2 ]]; then
    __error "System has less than 2 GB RAM (${mem_gb} GB). FreeIPA requires at least 2 GB."
  elif [[ "${mem_gb}" -lt 4 ]]; then
    __warn "System has less than 4 GB RAM (${mem_gb} GB). 4 GB+ recommended for full features."
  fi

  disk_avail="$(\df / | \tail -1 | \awk '{print $4}' || true)"
  disk_gb=$(( disk_avail / 1024 / 1024 ))

  if [[ "${disk_gb}" -lt 10 ]]; then
    __warn "Less than 10 GB disk space available (${disk_gb} GB). Consider freeing up space."
  fi

  if [[ "${FREEIPA_FQDN}" == "localhost" || "${FREEIPA_FQDN}" == "localhost.localdomain" ]]; then
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
  FREEIPA_FQDN="${FREEIPA_FQDN:-$(__determine_hostname_name 2>/dev/null || \hostname)}"

  if [[ "${FREEIPA_FQDN}" == *.* ]]; then
    # Extract domain from FQDN (everything after first label)
    FREEIPA_DOMAIN="${FREEIPA_DOMAIN:-${FREEIPA_FQDN#*.}}"
    FREEIPA_REALM="${FREEIPA_REALM:-${FREEIPA_DOMAIN^^}}"

    # For complex domains (>2 labels), note the primary domain
    local domain_parts
    domain_parts="${FREEIPA_DOMAIN//[^.]}"
    if [[ ${#domain_parts} -gt 1 ]]; then
      local primary_domain
      primary_domain="${FREEIPA_DOMAIN##*.}"
      primary_domain="${FREEIPA_DOMAIN%.*}.${primary_domain}"
      __log "Complex domain detected; primary domain: ${primary_domain}"
    fi
  else
    if [[ -t 0 ]]; then
      __warn "No domain found in hostname. Enter domain manually:"
      printf 'Enter domain (e.g., example.com): '
      read -r FREEIPA_DOMAIN
    else
      __error "Non-interactive mode and no domain in hostname. Set FREEIPA_DOMAIN env var."
    fi
    FREEIPA_REALM="${FREEIPA_DOMAIN^^}"
    FREEIPA_FQDN="${FREEIPA_FQDN}.${FREEIPA_DOMAIN}"
  fi

  # DNS/LDAP hostnames and domains are lowercase by convention (and Kerberos
  # realms uppercase) regardless of how the caller cased an env override
  FREEIPA_FQDN="${FREEIPA_FQDN,,}"
  FREEIPA_DOMAIN="${FREEIPA_DOMAIN,,}"
  FREEIPA_REALM="${FREEIPA_REALM^^}"

  __log "Using hostname: ${FREEIPA_FQDN}"
  __log "Using domain:   ${FREEIPA_DOMAIN}"
  __log "Using realm:    ${FREEIPA_REALM}"
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
      local INSTALL_DEBIAN_FRONTEND="noninteractive"
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
  primary_ip="$(__primary_ip)"
  if [[ -z "${primary_ip}" ]]; then
    __warn "Could not detect primary IP address; falling back to 127.0.0.1"
    primary_ip="127.0.0.1"
  fi

  __log "Using IP address: ${primary_ip}"

  # Remove any existing entries for this FQDN then re-add with correct IP
  \sed -i "/${FREEIPA_FQDN}/d" /etc/hosts
  short_hostname="${FREEIPA_FQDN%%.*}"
  printf '%s %s %s\n' "${primary_ip}" "${FREEIPA_FQDN}" "${short_hostname}" >> /etc/hosts

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
    return 0
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

  if ! \nslookup "${FREEIPA_FQDN}" >/dev/null 2>&1; then
    __log "Hostname not resolvable via DNS; will install integrated DNS server"
    INSTALL_DNS="true"
    INSTALL_CONFIGURE_REVERSE_ZONE="true"
    # Extract only IPv4 nameservers from resolv.conf — skip IPv6 link-local
    # (fe80::) and pure IPv6 addresses; ipa-server-install check_forwarders
    # times out trying to validate link-local addresses from inside the container
    local _ns _ipv4_fwds=""
    while IFS= read -r _ns; do
      _ipv4_fwds="${_ipv4_fwds:+${_ipv4_fwds} }${_ns}"
    done < <(\grep -E -- '^nameserver[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' /etc/resolv.conf | \awk '{print $2}')
    if [[ -n "${_ipv4_fwds}" ]]; then
      __log "Using IPv4 DNS forwarders: ${_ipv4_fwds}"
      INSTALL_DNS_FORWARDERS="${_ipv4_fwds}"
    else
      __log "No IPv4 DNS forwarders found; integrated DNS will run without forwarders"
    fi
    INSTALL_USE_AUTO_FORWARDERS="false"
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
  if [[ "${INSTALL_NO_NTP}" == "true" ]]; then
    __log "Skipping NTP/Chrony configuration (--no-ntp)"
    return 0
  fi

  __log "Configuring NTP/Chrony..."

  # Find the exact unit name (chronyd.service on RHEL, chrony.service on Debian)
  # Match ^chrony[^-] to exclude chrony-wait.service and chronyd-restricted.service
  local chrony_unit
  chrony_unit="$(\systemctl list-unit-files 2>/dev/null | \awk '$1 ~ /^chronyd?\.service$/{print $1; exit}' || true)"

  if [[ -n "${chrony_unit}" ]]; then
    # enable is best-effort — may be masked in containers
    \systemctl enable "${chrony_unit}" 2>/dev/null || true
    # start requires CAP_SYS_TIME — non-fatal in containers
    if ! \systemctl start "${chrony_unit}" 2>/dev/null; then
      __warn "${chrony_unit} could not start (no CAP_SYS_TIME? running in container); continuing"
    else
      __log "${chrony_unit} enabled and started"
    fi
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

    \firewall-cmd --permanent --add-service=ssh
    \firewall-cmd --permanent --add-service=http
    \firewall-cmd --permanent --add-service=https
    \firewall-cmd --permanent --add-service=freeipa-ldap
    \firewall-cmd --permanent --add-service=freeipa-ldaps
    \firewall-cmd --permanent --add-service=freeipa-replication

    if [[ "${INSTALL_DNS}" == "true" ]]; then
      \firewall-cmd --permanent --add-service=dns
    fi

    # Custom HTTPS port for the FreeIPA reverse proxy
    \firewall-cmd --permanent --add-port="${FREEIPA_PORT}/tcp"

    \firewall-cmd --permanent --add-service=kerberos
    \firewall-cmd --permanent --add-service=ntp

    # Keycloak port (internal Docker bridge — open for reverse proxy reach)
    \firewall-cmd --permanent --add-port="${FREEIPA_KEYCLOAK_PORT}/tcp"
    # Mail (Postfix/Dovecot)
    \firewall-cmd --permanent --add-service=smtp
    \firewall-cmd --permanent --add-port=587/tcp
    \firewall-cmd --permanent --add-port=465/tcp
    \firewall-cmd --permanent --add-service=imap
    \firewall-cmd --permanent --add-service=imaps
    \firewall-cmd --permanent --add-service=pop3
    \firewall-cmd --permanent --add-service=pop3s
    # Mosh server uses UDP 60000-61000 for encrypted remote terminal sessions
    \firewall-cmd --permanent --add-port=60000-61000/udp
    # Allow ICMP ping for monitoring
    \firewall-cmd --permanent --remove-icmp-block=echo-request 2>/dev/null || true
    \firewall-cmd --permanent --remove-icmp-block=echo-reply 2>/dev/null || true

    \firewall-cmd --reload

    __log "firewalld configured"

  elif \command -v ufw >/dev/null 2>&1; then
    __log "Detected UFW; configuring..."
    \ufw --force enable

    # SSH
    \ufw allow 22/tcp
    # HTTP / HTTPS
    \ufw allow 80/tcp
    \ufw allow 443/tcp
    # Custom HTTPS port for the FreeIPA reverse proxy
    \ufw allow "${FREEIPA_PORT}/tcp"
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
    \ufw allow "${FREEIPA_KEYCLOAK_PORT}/tcp"
    # Mail (Postfix/Dovecot)
    \ufw allow 25/tcp
    \ufw allow 587/tcp
    \ufw allow 465/tcp
    \ufw allow 143/tcp
    \ufw allow 993/tcp
    \ufw allow 110/tcp
    \ufw allow 995/tcp
    # Mosh server uses UDP 60000-61000 for encrypted remote terminal sessions
    \ufw allow 60000:61000/udp
    # Allow ICMP ping — inject into before.rules if not already present
    if [ -f /etc/ufw/before.rules ] && ! \grep -q -- "# ICMP ping allow" /etc/ufw/before.rules 2>/dev/null; then
      \sed -i \
        '/^COMMIT$/i # ICMP ping allow\n-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT\n-A ufw-before-input -p icmp --icmp-type echo-reply -j ACCEPT' \
        /etc/ufw/before.rules 2>/dev/null || true
    fi

    __log "UFW configured"
  else
    __log "No supported firewall found; skipping firewall configuration"
  fi

  # firewalld's --reload and ufw's enable/allow calls rewrite the host's
  # iptables/nftables ruleset, which wipes or reorders the DOCKER/DOCKER-*
  # forwarding chains Docker installed at daemon-start time. Left alone,
  # this silently drops inter-container traffic on Docker's bridge networks
  # (observed as Keycloak losing its Postgres connection). Restarting Docker
  # here makes it reinstall its rules on top of the final firewall state.
  if \systemctl is-active --quiet docker 2>/dev/null; then
    __log "Restarting Docker to reinstall its network rules after firewall changes..."
    \systemctl restart docker
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
  # Idempotency guard — skip if FreeIPA is already installed
  if [[ -f "/etc/ipa/default.conf" ]]; then
    __log "FreeIPA already installed (/etc/ipa/default.conf exists); skipping ipa-server-install"
    # Still load credentials so downstream functions have them
    INSTALL_ADMIN_PASSWORD="$(__load_credential "${FREEIPA_CRED_FILE}" INSTALL_ADMIN_PASSWORD)" || {
      __warn "FreeIPA installed but admin password not found in ${FREEIPA_CRED_FILE}"
    }
    INSTALL_DM_PASSWORD="$(__load_credential "${FREEIPA_CRED_FILE}" INSTALL_DM_PASSWORD)" || {
      __warn "FreeIPA installed but DM password not found in ${FREEIPA_CRED_FILE}"
    }
    return 0
  fi

  __log "Starting FreeIPA server installation..."

  # Load or generate admin password
  INSTALL_ADMIN_PASSWORD="$(__load_credential "${FREEIPA_CRED_FILE}" INSTALL_ADMIN_PASSWORD)" || {
    INSTALL_ADMIN_PASSWORD="$(__random_password 25)"
    __save_credential "${FREEIPA_CRED_FILE}" INSTALL_ADMIN_PASSWORD "${INSTALL_ADMIN_PASSWORD}"
  }

  # Load or generate Directory Manager password
  INSTALL_DM_PASSWORD="$(__load_credential "${FREEIPA_CRED_FILE}" INSTALL_DM_PASSWORD)" || {
    INSTALL_DM_PASSWORD="$(__random_password 25)"
    __save_credential "${FREEIPA_CRED_FILE}" INSTALL_DM_PASSWORD "${INSTALL_DM_PASSWORD}"
  }

  # Build installation command as an array to avoid quoting/eval issues
  local -a install_cmd
  install_cmd=(
    \ipa-server-install
    --unattended
    "--realm=${FREEIPA_REALM}"
    "--domain=${FREEIPA_DOMAIN}"
    "--hostname=${FREEIPA_FQDN}"
    "--admin-password=${INSTALL_ADMIN_PASSWORD}"
    "--ds-password=${INSTALL_DM_PASSWORD}"
  )

  if [[ "${INSTALL_NO_NTP}" == "true" ]]; then
    install_cmd+=( --no-ntp )
  fi

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
  local ssl_conf="" rewrite_conf=""
  if [[ -d "/etc/httpd/conf.d" ]]; then
    apache_conf_dir="/etc/httpd/conf.d"
    ssl_conf="/etc/httpd/conf.d/ssl.conf"
    rewrite_conf="/etc/httpd/conf.d/ipa-rewrite.conf"
  elif [[ -d "/etc/apache2/conf-available" ]]; then
    apache_conf_dir="/etc/apache2/conf-available"
    ssl_conf="/etc/apache2/conf-available/ssl.conf"
    rewrite_conf="/etc/apache2/conf-available/ipa-rewrite.conf"
  else
    __warn "Could not find Apache configuration directory; skipping reverse proxy config"
    return 0
  fi

  # Step 1: Write a minimal port-only config — just adds a Listen directive.
  # Do NOT create a duplicate VirtualHost; ipa.conf contains server-scope
  # directives (WSGISocketPrefix etc.) that cannot live inside <VirtualHost>.
  # The existing ssl.conf VirtualHost is extended below to also accept PORT.
  local apache_port_conf="${apache_conf_dir}/freeipa-port.conf"
  \cat > "${apache_port_conf}" << EOF
# FreeIPA custom port for reverse proxy — managed by install.sh
# Adds a second Listen so the ssl.conf VirtualHost also accepts FREEIPA_PORT.
Listen ${FREEIPA_PORT} https
EOF

  # Enable the configuration if using Apache2's conf-enabled mechanism
  if [[ -d "/etc/apache2/conf-enabled" ]]; then
    \ln -sf "${apache_port_conf}" /etc/apache2/conf-enabled/freeipa-port.conf
  fi

  # Step 2: Extend the existing SSL VirtualHost to also accept FREEIPA_PORT.
  # ssl.conf has <VirtualHost _default_:443> — change it to accept both ports.
  # This avoids duplicating any of the WSGI/SSL directives.
  if [[ -f "${ssl_conf}" ]]; then
    \sed -i "s|<VirtualHost _default_:443>|<VirtualHost _default_:443 _default_:${FREEIPA_PORT}>|" \
      "${ssl_conf}" 2>/dev/null || true
    __log "Extended ssl.conf VirtualHost to also listen on port ${FREEIPA_PORT}"
  fi

  # Step 3: Patch ipa-rewrite.conf so it does not redirect requests arriving on
  # FREEIPA_PORT back to port 443 (which would cause infinite redirect
  # loops when nginx proxies to our custom port).
  if [[ -f "${rewrite_conf}" ]]; then
    # Insert an extra RewriteCond to exclude our custom port, immediately after
    # the existing !^443$ condition line.
    if ! \grep -q -- "!^${FREEIPA_PORT}\$" "${rewrite_conf}" 2>/dev/null; then
      \sed -i "/RewriteCond %{SERVER_PORT}[[:space:]]*!\^443\\\$/a RewriteCond %{SERVER_PORT}  !^${FREEIPA_PORT}$" \
        "${rewrite_conf}" 2>/dev/null || true
      __log "Patched ipa-rewrite.conf to skip redirect for port ${FREEIPA_PORT}"
    fi
  fi

  __log "Configured Apache to listen on port ${FREEIPA_PORT}"

  local _web_units
  _web_units="$(\systemctl list-unit-files 2>/dev/null | \awk '{print $1}' || true)"
  if printf '%s\n' "${_web_units}" | \grep -q -- "^httpd.service$"; then
    \systemctl restart httpd
  elif printf '%s\n' "${_web_units}" | \grep -q -- "^apache2.service$"; then
    \systemctl restart apache2
  fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── LDAP base DN derivation ─────────────────────────────────────────────────

__derive_ldap_base_dn() {
  local dn="" part
  local IFS='.'
  for part in ${FREEIPA_DOMAIN}; do
    dn="${dn},dc=${part}"
  done
  INSTALL_LDAP_BASE_DN="${dn#,}"
  FREEIPA_KEYCLOAK_REALM="${FREEIPA_KEYCLOAK_REALM:-${FREEIPA_DOMAIN}}"
  __log "LDAP base DN: ${INSTALL_LDAP_BASE_DN}"
  __log "Keycloak realm: ${FREEIPA_KEYCLOAK_REALM}"
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
  INSTALL_KEYCLOAK_LDAP_PASSWORD="$(__load_credential "${FREEIPA_CRED_FILE}" INSTALL_KEYCLOAK_LDAP_PASSWORD)" || {
    INSTALL_KEYCLOAK_LDAP_PASSWORD="$(__random_password 32)"
    __save_credential "${FREEIPA_CRED_FILE}" INSTALL_KEYCLOAK_LDAP_PASSWORD "${INSTALL_KEYCLOAK_LDAP_PASSWORD}"
  }

  \mkdir -p "${FREEIPA_KEYCLOAK_CONFIG_DIR}"

  # Obtain a Kerberos ticket for the admin user
  printf '%s\n' "${INSTALL_ADMIN_PASSWORD}" | \kinit "admin@${FREEIPA_REALM}"

  # Create temp dir before mktemp to ensure parent exists
  \mkdir -p "${TMPDIR:-/tmp}/scriptmgr"
  INSTALL_LDIF_TMP="$(\mktemp "${TMPDIR:-/tmp}/scriptmgr/freeipa-XXXXXX.ldif")"

  # Write LDIF for the Keycloak sysaccount bind user
  {
    printf 'dn: uid=keycloak,cn=sysaccounts,cn=etc,%s\n' "${INSTALL_LDAP_BASE_DN}"
    printf 'objectClass: account\n'
    printf 'objectClass: simplesecurityobject\n'
    printf 'uid: keycloak\n'
    # 389-ds only recognizes its own registered storage-scheme prefixes;
    # {cleartext} is not one of them (the scheme is named "Clear", prefix
    # {CLEAR}) so a value tagged with it fails to verify on bind.
    printf 'userPassword: {CLEAR}%s\n' "${INSTALL_KEYCLOAK_LDAP_PASSWORD}"
    printf 'passwordExpirationTime: 20380119031407Z\n'
    printf 'nsIdleTimeout: 0\n'
  } > "${INSTALL_LDIF_TMP}"

  # Use FQDN — not localhost — so Kerberos resolves ldap/{FQDN}@REALM correctly
  # ldapadd is add-only: on a re-run the entry already exists and this fails,
  # which previously left userPassword un-synced with FREEIPA_CRED_FILE if it
  # was ever set incorrectly. Fall back to an explicit password replace so
  # the LDAP entry always converges on the saved credential.
  if ! \ldapadd -Y GSSAPI -H "ldap://${FREEIPA_FQDN}" -f "${INSTALL_LDIF_TMP}" 2>/dev/null; then
    {
      printf 'dn: uid=keycloak,cn=sysaccounts,cn=etc,%s\n' "${INSTALL_LDAP_BASE_DN}"
      printf 'changetype: modify\n'
      printf 'replace: userPassword\n'
      printf 'userPassword: {CLEAR}%s\n' "${INSTALL_KEYCLOAK_LDAP_PASSWORD}"
    } | \ldapmodify -Y GSSAPI -H "ldap://${FREEIPA_FQDN}" || true
  fi

  # Remove LDIF immediately — it contained a cleartext password
  \rm -f "${INSTALL_LDIF_TMP}"
  INSTALL_LDIF_TMP=""

  # Create HTTP service principal for Kerberos SPNEGO
  \ipa service-add "HTTP/${FREEIPA_FQDN}" 2>/dev/null || true

  # Export keytab for Keycloak
  \ipa-getkeytab -p "HTTP/${FREEIPA_FQDN}@${FREEIPA_REALM}" -k "${FREEIPA_KEYCLOAK_CONFIG_DIR}/keycloak.keytab"
  \chmod 600 "${FREEIPA_KEYCLOAK_CONFIG_DIR}/keycloak.keytab"

  # ipa-getkeytab generates a fresh random key each time it exports one for
  # this principal, bumping its kvno. Since HTTP/${FREEIPA_FQDN} is the same
  # principal Apache's own gssproxy keytab was provisioned with, the export
  # above just invalidated Apache's copy — breaking IPA's own web UI/CLI
  # SPNEGO auth. Re-sync gssproxy's keytab to the same new key immediately
  # so both consumers stay in sync, then restart gssproxy to pick it up.
  local _gssproxy_keytab="/var/lib/ipa/gssproxy/http.keytab"
  if [[ -f "${_gssproxy_keytab}" ]]; then
    \ipa-getkeytab -p "HTTP/${FREEIPA_FQDN}@${FREEIPA_REALM}" -k "${_gssproxy_keytab}"
    \chown root:root "${_gssproxy_keytab}"
    \chmod 600 "${_gssproxy_keytab}"
    \systemctl restart gssproxy
  fi

  # Export IPA CA certificate so Keycloak can trust LDAPS
  \cp /etc/ipa/ca.crt "${FREEIPA_KEYCLOAK_CONFIG_DIR}/ipa-ca.crt"
  \chmod 644 "${FREEIPA_KEYCLOAK_CONFIG_DIR}/ipa-ca.crt"

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
  # Idempotency guard — if Keycloak container is already running, just ensure
  # credentials are loaded and skip docker-compose regeneration.
  if \docker inspect keycloak >/dev/null 2>&1; then
    __log "Keycloak container already exists; loading credentials and skipping redeploy"
    INSTALL_KEYCLOAK_ADMIN_PASSWORD="$(__load_credential "${FREEIPA_CRED_FILE}" INSTALL_KEYCLOAK_ADMIN_PASSWORD)" || {
      __warn "Keycloak running but admin password not in ${FREEIPA_CRED_FILE}"
    }
    INSTALL_KEYCLOAK_DB_PASSWORD="$(__load_credential "${FREEIPA_CRED_FILE}" INSTALL_KEYCLOAK_DB_PASSWORD)" || true
    return 0
  fi

  __log "Deploying Keycloak via Docker Compose..."

  # Load or generate Keycloak admin password
  INSTALL_KEYCLOAK_ADMIN_PASSWORD="$(__load_credential "${FREEIPA_CRED_FILE}" INSTALL_KEYCLOAK_ADMIN_PASSWORD)" || {
    INSTALL_KEYCLOAK_ADMIN_PASSWORD="$(__random_password 32)"
    __save_credential "${FREEIPA_CRED_FILE}" INSTALL_KEYCLOAK_ADMIN_PASSWORD "${INSTALL_KEYCLOAK_ADMIN_PASSWORD}"
  }

  # Load or generate Keycloak database password
  INSTALL_KEYCLOAK_DB_PASSWORD="$(__load_credential "${FREEIPA_CRED_FILE}" INSTALL_KEYCLOAK_DB_PASSWORD)" || {
    INSTALL_KEYCLOAK_DB_PASSWORD="$(__random_password 32)"
    __save_credential "${FREEIPA_CRED_FILE}" INSTALL_KEYCLOAK_DB_PASSWORD "${INSTALL_KEYCLOAK_DB_PASSWORD}"
  }

  # Load or generate stable Keycloak port
  FREEIPA_KEYCLOAK_PORT="$(__load_credential "${FREEIPA_CRED_FILE}" FREEIPA_KEYCLOAK_PORT)" || {
    FREEIPA_KEYCLOAK_PORT="$(__random_port)"
    __save_credential "${FREEIPA_CRED_FILE}" FREEIPA_KEYCLOAK_PORT "${FREEIPA_KEYCLOAK_PORT}"
  }

  local primary_ip
  primary_ip="$(__primary_ip)"

  \mkdir -p "${FREEIPA_COMPOSE_DIR}"

  # Generate docker-compose.yml with all values hardcoded — no .env required
  \cat > "${FREEIPA_COMPOSE_DIR}/docker-compose.yml" << EOF
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
      KC_HTTP_PORT: "${FREEIPA_KEYCLOAK_PORT}"
      KC_HOSTNAME_STRICT: "false"
      KC_PROXY: edge
      KC_TRUSTSTORE_PATHS: /etc/keycloak/ipa-ca.crt
      KEYCLOAK_ADMIN: admin
      KEYCLOAK_ADMIN_PASSWORD: "${INSTALL_KEYCLOAK_ADMIN_PASSWORD}"
      KC_LOG_LEVEL: INFO
      JAVA_OPTS_APPEND: -Djava.security.krb5.conf=/etc/krb5.conf
    volumes:
      - "${FREEIPA_KEYCLOAK_CONFIG_DIR}/keycloak.keytab:/etc/keycloak/keycloak.keytab:ro"
      - "${FREEIPA_KEYCLOAK_CONFIG_DIR}/ipa-ca.crt:/etc/keycloak/ipa-ca.crt:ro"
      - "/etc/krb5.conf:/etc/krb5.conf:ro"
      - keycloak_data:/opt/keycloak/data
    ports:
      - "172.17.0.1:${FREEIPA_KEYCLOAK_PORT}:${FREEIPA_KEYCLOAK_PORT}"
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - keycloak
    extra_hosts:
      - "${FREEIPA_FQDN}:${primary_ip}"
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
    healthcheck:
      test:
        - CMD-SHELL
        - >
          exec 3<>/dev/tcp/localhost/${FREEIPA_KEYCLOAK_PORT} &&
          printf 'GET /realms/master/.well-known/openid-configuration HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' >&3 &&
          grep -q -- 'issuer' <&3
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

  \chmod 600 "${FREEIPA_COMPOSE_DIR}/docker-compose.yml"

  __compose -f "${FREEIPA_COMPOSE_DIR}/docker-compose.yml" up -d

  __log "Keycloak containers started"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Wait for Keycloak readiness ─────────────────────────────────────────────

__wait_for_keycloak() {
  __log "Waiting for Keycloak to become ready (up to 300 s)..."
  local elapsed=0
  while [[ "${elapsed}" -lt 300 ]]; do
    # Use the OIDC discovery document as the readiness probe — it is served only
    # after Keycloak's HTTP servlet is fully initialised and the master realm
    # exists. The /health/ready path returns 404 on the main port in KC 26
    # (health lives on the management port 9000 which is not host-bound here).
    if \curl -q -LSs --max-time 5 \
        "http://172.17.0.1:${FREEIPA_KEYCLOAK_PORT}/realms/master/.well-known/openid-configuration" \
        2>/dev/null | \grep -q -- '"issuer"'; then
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
  local kc_url="http://172.17.0.1:${FREEIPA_KEYCLOAK_PORT}"
  local token attempt=0
  # Retry up to 6 times (60 s total) — Keycloak may still be warming up its
  # HTTP servlet even after the OIDC discovery probe passes.
  while [[ "${attempt}" -lt 6 ]]; do
    token="$(\curl -q -LSs --max-time 10 -X POST \
      "${kc_url}/realms/master/protocol/openid-connect/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "grant_type=password" \
      --data-urlencode "client_id=admin-cli" \
      --data-urlencode "username=admin" \
      --data-urlencode "password=${INSTALL_KEYCLOAK_ADMIN_PASSWORD}" \
      2>/dev/null | \jq -r '.access_token // empty' 2>/dev/null)"
    if [[ -n "${token}" && "${token}" != "null" ]]; then
      printf '%s\n' "${token}"
      return 0
    fi
    attempt=$(( attempt + 1 ))
    sleep 10
  done
  __error "Could not obtain Keycloak admin token after ${attempt} attempts"
  return 1
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Keycloak REST API configuration ─────────────────────────────────────────

__configure_keycloak() {
  __log "Configuring Keycloak realm and LDAP federation..."

  local kc_url="http://172.17.0.1:${FREEIPA_KEYCLOAK_PORT}"
  local token

  # Step 1 — Create realm (idempotent: skip if realm already exists)
  token="$(__keycloak_admin_token)"
  local realm_exists
  realm_exists="$(\curl -q -LSs --max-time 10 \
    "${kc_url}/admin/realms/${FREEIPA_KEYCLOAK_REALM}" \
    -H "Authorization: Bearer ${token}" \
    2>/dev/null | \jq -r '.realm // empty' 2>/dev/null)"

  if [[ -z "${realm_exists}" ]]; then
    token="$(__keycloak_admin_token)"
    \curl -q -LSs --max-time 10 -X POST \
      "${kc_url}/admin/realms" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "$(\jq -n --arg r "${FREEIPA_KEYCLOAK_REALM}" --arg d "${FREEIPA_DOMAIN}" \
        '{realm: $r, enabled: true, displayName: ("SSO — " + $d), sslRequired: "external", registrationAllowed: false, bruteForceProtected: true}')"
    __log "Realm ${FREEIPA_KEYCLOAK_REALM} created"
  else
    __log "Realm ${FREEIPA_KEYCLOAK_REALM} already exists; skipping creation"
  fi

  # Step 2 — Create LDAP user federation component (idempotent — check first)
  token="$(__keycloak_admin_token)"

  # Check if freeipa-ldap component already exists
  local _existing_comp
  _existing_comp="$(\curl -q -LSs --max-time 10 \
    "${kc_url}/admin/realms/${FREEIPA_KEYCLOAK_REALM}/components?type=org.keycloak.storage.UserStorageProvider&name=freeipa-ldap" \
    -H "Authorization: Bearer ${token}" 2>/dev/null | \jq -r 'if type == "array" then .[0].id // empty else empty end' 2>/dev/null || true)"

  local ldap_body
  ldap_body="$(\jq -n \
    --arg fqdn "${FREEIPA_FQDN}" \
    --arg base_dn "${INSTALL_LDAP_BASE_DN}" \
    --arg ldap_pass "${INSTALL_KEYCLOAK_LDAP_PASSWORD}" \
    --arg realm "${FREEIPA_REALM}" \
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
        # FreeIPA user entries (including the built-in admin account) carry
        # person/posixaccount/inetuser/krbprincipalaux, NOT inetOrgPerson or
        # organizationalPerson — filtering on those classes matches zero
        # FreeIPA users, so LDAP sync silently imports nobody.
        userObjectClasses: ["person, posixaccount"],
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
  if [[ -n "${_existing_comp}" && "${_existing_comp}" != "null" ]]; then
    component_id="${_existing_comp}"
    # Update in place so config drift (e.g. a fixed bind password, a corrected
    # userObjectClasses filter after a script upgrade) is reconciled on every
    # re-run instead of being permanently frozen at whatever was first created.
    \curl -q -LSs --max-time 10 -X PUT \
      "${kc_url}/admin/realms/${FREEIPA_KEYCLOAK_REALM}/components/${component_id}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "$(printf '%s\n' "${ldap_body}" | \jq --arg id "${component_id}" '. + {id: $id}')" \
      >/dev/null 2>/dev/null || true
    __log "LDAP federation component already exists (id: ${component_id}); config updated"
  else
    ldap_response="$(\curl -q -LSs --max-time 10 -X POST -D - \
      "${kc_url}/admin/realms/${FREEIPA_KEYCLOAK_REALM}/components" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "${ldap_body}")"
    component_id="$(printf '%s\n' "${ldap_response}" | \grep -i -- "^[Ll]ocation:" | \sed 's|.*/||' | \tr -d '\r\n')"
    __log "LDAP federation component created (id: ${component_id})"
  fi

  if [[ -z "${component_id}" ]]; then
    __warn "Could not get LDAP federation component ID; skipping sync and role setup"
    return 0
  fi

  # Step 3 — Trigger full LDAP sync
  \curl -q -LSs --max-time 30 -X POST \
    "${kc_url}/admin/realms/${FREEIPA_KEYCLOAK_REALM}/user-storage/${component_id}/sync?action=triggerFullSync" \
    -H "Authorization: Bearer ${token}" >/dev/null 2>/dev/null || true

  __log "LDAP full sync triggered"

  # Step 4 — Wait for admin user to appear after sync (up to 60 s)
  # Refresh token — previous one may be stale after sync wait
  token="$(__keycloak_admin_token)"
  local admin_user_id="" attempt=0
  while [[ -z "${admin_user_id}" || "${admin_user_id}" == "null" ]] && [[ "${attempt}" -lt 12 ]]; do
    sleep 5
    # Refresh token every 3 attempts to avoid 401
    if [[ $(( attempt % 3 )) -eq 0 ]]; then
      token="$(__keycloak_admin_token)" || true
    fi
    local _users_resp
    _users_resp="$(\curl -q -LSs --max-time 10 \
      "${kc_url}/admin/realms/${FREEIPA_KEYCLOAK_REALM}/users?username=admin&exact=true" \
      -H "Authorization: Bearer ${token}" 2>/dev/null)"
    admin_user_id="$(printf '%s\n' "${_users_resp}" | \jq -r 'if type == "array" then .[0].id // empty else empty end' 2>/dev/null || true)"
    attempt=$(( attempt + 1 ))
  done

  if [[ -z "${admin_user_id}" || "${admin_user_id}" == "null" ]]; then
    __warn "Could not find admin user in Keycloak after LDAP sync — realm-admin role not assigned"
    return 0
  fi

  # Step 5 — Assign realm-admin role to admin user

  # Refresh token before role assignment
  token="$(__keycloak_admin_token)" || true

  # Get realm-management client ID
  local rm_client_id _clients_resp
  _clients_resp="$(\curl -q -LSs --max-time 10 \
    "${kc_url}/admin/realms/${FREEIPA_KEYCLOAK_REALM}/clients?clientId=realm-management" \
    -H "Authorization: Bearer ${token}" 2>/dev/null)"
  rm_client_id="$(printf '%s\n' "${_clients_resp}" | \jq -r 'if type == "array" then .[0].id // empty else empty end' 2>/dev/null || true)"

  if [[ -z "${rm_client_id}" || "${rm_client_id}" == "null" ]]; then
    __warn "Could not find realm-management client — skipping realm-admin role assignment"
    return 0
  fi

  # Get realm-admin role details
  local role_info role_id role_name
  role_info="$(\curl -q -LSs --max-time 10 \
    "${kc_url}/admin/realms/${FREEIPA_KEYCLOAK_REALM}/clients/${rm_client_id}/roles/realm-admin" \
    -H "Authorization: Bearer ${token}" 2>/dev/null)"
  role_id="$(printf '%s\n' "${role_info}" | \jq -r '.id // empty' 2>/dev/null || true)"
  role_name="$(printf '%s\n' "${role_info}" | \jq -r '.name // empty' 2>/dev/null || true)"

  if [[ -z "${role_id}" || "${role_id}" == "null" ]]; then
    __warn "Could not find realm-admin role — skipping role assignment"
    return 0
  fi

  # Assign realm-admin role to the admin user
  \curl -q -LSs --max-time 10 -X POST \
    "${kc_url}/admin/realms/${FREEIPA_KEYCLOAK_REALM}/users/${admin_user_id}/role-mappings/clients/${rm_client_id}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "[$(\jq -n --arg id "${role_id}" --arg name "${role_name}" '{id: $id, name: $name}')]" >/dev/null 2>/dev/null || true

  __log "Keycloak realm configured. Admin promoted to realm-admin."
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Keycloak confidential client for Dovecot OAuth2 introspection ───────────

__configure_keycloak_mail_client() {
  if [[ "${FREEIPA_MAIL_KEYCLOAK_AUTH}" != "true" ]]; then
    __log "Keycloak mail auth disabled (FREEIPA_MAIL_KEYCLOAK_AUTH=false); skipping"
    return 0
  fi

  __log "Configuring Keycloak confidential client for Dovecot token introspection..."

  local kc_url="http://172.17.0.1:${FREEIPA_KEYCLOAK_PORT}"
  local token
  token="$(__keycloak_admin_token)"

  INSTALL_MAIL_KEYCLOAK_SECRET="$(__load_credential "${FREEIPA_CRED_FILE}" INSTALL_MAIL_KEYCLOAK_SECRET)" || {
    INSTALL_MAIL_KEYCLOAK_SECRET="$(__random_password 32)"
    __save_credential "${FREEIPA_CRED_FILE}" INSTALL_MAIL_KEYCLOAK_SECRET "${INSTALL_MAIL_KEYCLOAK_SECRET}"
  }

  local existing_client_id
  existing_client_id="$(\curl -q -LSs --max-time 10 \
    "${kc_url}/admin/realms/${FREEIPA_KEYCLOAK_REALM}/clients?clientId=${FREEIPA_MAIL_KEYCLOAK_CLIENT_ID}" \
    -H "Authorization: Bearer ${token}" 2>/dev/null | \jq -r 'if type == "array" then .[0].id // empty else empty end' 2>/dev/null || true)"

  local client_body
  client_body="$(\jq -n \
    --arg cid "${FREEIPA_MAIL_KEYCLOAK_CLIENT_ID}" \
    --arg secret "${INSTALL_MAIL_KEYCLOAK_SECRET}" \
    '{
      clientId: $cid,
      enabled: true,
      protocol: "openid-connect",
      publicClient: false,
      standardFlowEnabled: false,
      directAccessGrantsEnabled: false,
      serviceAccountsEnabled: true,
      secret: $secret
    }')"

  if [[ -n "${existing_client_id}" && "${existing_client_id}" != "null" ]]; then
    \curl -q -LSs --max-time 10 -X PUT \
      "${kc_url}/admin/realms/${FREEIPA_KEYCLOAK_REALM}/clients/${existing_client_id}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "$(printf '%s\n' "${client_body}" | \jq --arg id "${existing_client_id}" '. + {id: $id}')" \
      >/dev/null 2>/dev/null || true
    __log "Keycloak mail client ${FREEIPA_MAIL_KEYCLOAK_CLIENT_ID} already exists; config updated"
  else
    \curl -q -LSs --max-time 10 -X POST \
      "${kc_url}/admin/realms/${FREEIPA_KEYCLOAK_REALM}/clients" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "${client_body}" >/dev/null 2>/dev/null || true
    __log "Keycloak mail client ${FREEIPA_MAIL_KEYCLOAK_CLIENT_ID} created"
  fi

  __log "Keycloak mail client configured"
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

  local vhost_file="/etc/nginx/vhosts.d/${FREEIPA_FQDN}-keycloak.conf"

  if [[ "${INSTALL_USE_LETSENCRYPT}" == "true" ]]; then
    \cat > "${vhost_file}" << EOF
# Keycloak SSO reverse proxy — generated by install.sh
server {
    listen 443 ssl;
    server_name ${FREEIPA_FQDN};

    ssl_certificate     /etc/letsencrypt/live/domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/domain/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    access_log /var/log/nginx/${FREEIPA_FQDN}-keycloak.access.log combined;
    error_log  /var/log/nginx/${FREEIPA_FQDN}-keycloak.error.log warn;

    location / {
        proxy_pass http://172.17.0.1:${FREEIPA_KEYCLOAK_PORT};

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
    server_name ${FREEIPA_FQDN};

    access_log /var/log/nginx/${FREEIPA_FQDN}-keycloak.access.log combined;
    error_log  /var/log/nginx/${FREEIPA_FQDN}-keycloak.error.log warn;

    location / {
        proxy_pass http://172.17.0.1:${FREEIPA_KEYCLOAK_PORT};

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

# ─── Mail (Postfix/Dovecot) package installation ─────────────────────────────

__install_mail_packages() {
  if \command -v postfix >/dev/null 2>&1 && \command -v dovecot >/dev/null 2>&1; then
    __log "Postfix and Dovecot already installed; skipping"
    return 0
  fi

  __log "Installing Postfix and Dovecot..."

  case "${INSTALL_DISTRO_FAMILY}" in
    *rhel*|*fedora*|*centos*)
      \dnf install -y postfix postfix-ldap dovecot dovecot-pigeonhole
      ;;
    *debian*|*ubuntu*)
      \apt-get install -y postfix postfix-ldap dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd dovecot-ldap
      ;;
    *suse*)
      \zypper install -y postfix postfix-ldap dovecot dovecot-backend-ldap
      ;;
    *)
      __error "Unsupported distribution family for mail package install: ${INSTALL_DISTRO_FAMILY}"
      ;;
  esac

  __log "Postfix and Dovecot installed"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── FreeIPA post-config for Mail ─────────────────────────────────────────────

__setup_freeipa_for_mail() {
  __log "Configuring FreeIPA for Postfix/Dovecot LDAP integration..."

  FREEIPA_MAIL_DOMAIN="${FREEIPA_MAIL_DOMAIN:-${FREEIPA_DOMAIN}}"

  # Load or generate the mail LDAP bind password — used only for read-only
  # LDAP lookups; actual user password checks happen via auth_bind against
  # the user's own DN, so FreeIPA's Kerberos-backed password stays authoritative
  INSTALL_MAIL_LDAP_PASSWORD="$(__load_credential "${FREEIPA_CRED_FILE}" INSTALL_MAIL_LDAP_PASSWORD)" || {
    INSTALL_MAIL_LDAP_PASSWORD="$(__random_password 32)"
    __save_credential "${FREEIPA_CRED_FILE}" INSTALL_MAIL_LDAP_PASSWORD "${INSTALL_MAIL_LDAP_PASSWORD}"
  }

  # Obtain a Kerberos ticket for the admin user
  printf '%s\n' "${INSTALL_ADMIN_PASSWORD}" | \kinit "admin@${FREEIPA_REALM}"

  \mkdir -p "${TMPDIR:-/tmp}/scriptmgr"
  INSTALL_LDIF_TMP="$(\mktemp "${TMPDIR:-/tmp}/scriptmgr/freeipa-mail-XXXXXX.ldif")"

  {
    printf 'dn: uid=mail,cn=sysaccounts,cn=etc,%s\n' "${INSTALL_LDAP_BASE_DN}"
    printf 'objectClass: account\n'
    printf 'objectClass: simplesecurityobject\n'
    printf 'uid: mail\n'
    printf 'userPassword: {CLEAR}%s\n' "${INSTALL_MAIL_LDAP_PASSWORD}"
    printf 'passwordExpirationTime: 20380119031407Z\n'
    printf 'nsIdleTimeout: 0\n'
  } > "${INSTALL_LDIF_TMP}"

  # ldapadd is add-only: on a re-run the entry already exists and this fails,
  # so fall back to an explicit password replace to converge on the saved
  # credential (same pattern as the Keycloak sysaccount above).
  if ! \ldapadd -Y GSSAPI -H "ldap://${FREEIPA_FQDN}" -f "${INSTALL_LDIF_TMP}" 2>/dev/null; then
    {
      printf 'dn: uid=mail,cn=sysaccounts,cn=etc,%s\n' "${INSTALL_LDAP_BASE_DN}"
      printf 'changetype: modify\n'
      printf 'replace: userPassword\n'
      printf 'userPassword: {CLEAR}%s\n' "${INSTALL_MAIL_LDAP_PASSWORD}"
    } | \ldapmodify -Y GSSAPI -H "ldap://${FREEIPA_FQDN}" || true
  fi

  # Remove LDIF immediately — it contained a cleartext password
  \rm -f "${INSTALL_LDIF_TMP}"
  INSTALL_LDIF_TMP=""

  # Service principals backing the shared Postfix/Dovecot TLS certificate
  \ipa service-add "smtp/${FREEIPA_FQDN}" 2>/dev/null || true
  \ipa service-add "imap/${FREEIPA_FQDN}" 2>/dev/null || true

  \kdestroy 2>/dev/null || true

  \mkdir -p /etc/mail/certs
  INSTALL_MAIL_CERT_PATH="/etc/mail/certs/mail.pem"
  INSTALL_MAIL_KEY_PATH="/etc/mail/certs/mail.key"

  # Request (or reuse) a single IPA-issued certificate shared by Postfix and
  # Dovecot — tracked and auto-renewed by certmonger. The request itself runs
  # under the host's own credentials (no admin kinit needed for this part).
  # -B/-C keep the key group-readable by postfix and reload both daemons
  # across every certmonger-driven renewal, not just the initial issuance.
  if ! \getcert list -f "${INSTALL_MAIL_CERT_PATH}" >/dev/null 2>&1; then
    \ipa-getcert request \
      -f "${INSTALL_MAIL_CERT_PATH}" \
      -k "${INSTALL_MAIL_KEY_PATH}" \
      -N "CN=${FREEIPA_FQDN}" \
      -K "smtp/${FREEIPA_FQDN}" \
      -D "${FREEIPA_FQDN}" \
      -B "chown root:postfix ${INSTALL_MAIL_KEY_PATH}; chmod 640 ${INSTALL_MAIL_KEY_PATH}" \
      -C "systemctl reload postfix dovecot 2>/dev/null || true" \
      -w
  fi

  # Wait for certmonger to finish issuing the certificate (local CA — fast)
  local elapsed=0
  while [[ "${elapsed}" -lt 60 ]]; do
    if \getcert list -f "${INSTALL_MAIL_CERT_PATH}" 2>/dev/null | \grep -q -- 'status: MONITORING'; then
      break
    fi
    sleep 2
    elapsed=$(( elapsed + 2 ))
  done
  if ! \getcert list -f "${INSTALL_MAIL_CERT_PATH}" 2>/dev/null | \grep -q -- 'status: MONITORING'; then
    __error "Mail TLS certificate was not issued within 60 seconds (exit 70)"
    exit 70
  fi

  \chown root:postfix "${INSTALL_MAIL_KEY_PATH}"
  \chmod 640 "${INSTALL_MAIL_KEY_PATH}"

  __log "FreeIPA configured for mail (Postfix/Dovecot) integration"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Mail storage (virtual mailboxes) ────────────────────────────────────────

__create_mail_storage() {
  __log "Preparing mail storage..."

  if ! \getent group "${FREEIPA_MAIL_VUSER}" >/dev/null 2>&1; then
    \groupadd -g "${FREEIPA_MAIL_VID}" "${FREEIPA_MAIL_VUSER}"
  fi
  if ! \getent passwd "${FREEIPA_MAIL_VUSER}" >/dev/null 2>&1; then
    \useradd -r -u "${FREEIPA_MAIL_VID}" -g "${FREEIPA_MAIL_VID}" \
      -d "${FREEIPA_MAIL_BASE_DIR}" -s /usr/sbin/nologin "${FREEIPA_MAIL_VUSER}"
  fi

  \mkdir -p "${FREEIPA_MAIL_BASE_DIR}/${FREEIPA_MAIL_DOMAIN}"
  \chown -R "${FREEIPA_MAIL_VUSER}:${FREEIPA_MAIL_VUSER}" "${FREEIPA_MAIL_BASE_DIR}"
  \chmod -R 750 "${FREEIPA_MAIL_BASE_DIR}"

  __log "Mail storage ready at ${FREEIPA_MAIL_BASE_DIR}/${FREEIPA_MAIL_DOMAIN}"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Postfix configuration ───────────────────────────────────────────────────

__configure_postfix() {
  __log "Configuring Postfix..."

  \mkdir -p /etc/postfix/ldap

  {
    printf 'server_host = %s\n' "${FREEIPA_FQDN}"
    printf 'server_port = 389\n'
    printf 'start_tls = yes\n'
    printf 'tls_ca_cert_file = /etc/ipa/ca.crt\n'
    printf 'version = 3\n'
    printf 'bind = yes\n'
    printf 'bind_dn = uid=mail,cn=sysaccounts,cn=etc,%s\n' "${INSTALL_LDAP_BASE_DN}"
    printf 'bind_pw = %s\n' "${INSTALL_MAIL_LDAP_PASSWORD}"
    printf 'search_base = cn=users,cn=accounts,%s\n' "${INSTALL_LDAP_BASE_DN}"
    printf 'scope = sub\n'
    printf 'query_filter = (&(objectClass=posixAccount)(mail=%%s))\n'
    printf 'result_attribute = uid\n'
  } > /etc/postfix/ldap/virtual-mailbox.cf
  \chown root:postfix /etc/postfix/ldap/virtual-mailbox.cf
  \chmod 640 /etc/postfix/ldap/virtual-mailbox.cf

  {
    printf 'server_host = %s\n' "${FREEIPA_FQDN}"
    printf 'server_port = 389\n'
    printf 'start_tls = yes\n'
    printf 'tls_ca_cert_file = /etc/ipa/ca.crt\n'
    printf 'version = 3\n'
    printf 'bind = yes\n'
    printf 'bind_dn = uid=mail,cn=sysaccounts,cn=etc,%s\n' "${INSTALL_LDAP_BASE_DN}"
    printf 'bind_pw = %s\n' "${INSTALL_MAIL_LDAP_PASSWORD}"
    printf 'search_base = cn=users,cn=accounts,%s\n' "${INSTALL_LDAP_BASE_DN}"
    printf 'scope = sub\n'
    printf 'query_filter = (&(objectClass=posixAccount)(mail=%%s))\n'
    printf 'result_attribute = mail\n'
  } > /etc/postfix/ldap/virtual-alias.cf
  \chown root:postfix /etc/postfix/ldap/virtual-alias.cf
  \chmod 640 /etc/postfix/ldap/virtual-alias.cf

  # Postfix's virtual_mailbox_domains takes a literal list or a lookup table —
  # it has no built-in glob/wildcard syntax — so a regexp: map is the correct
  # way to accept both the exact domain and any *.{domain} subdomain
  local mail_domain_regex="${FREEIPA_MAIL_DOMAIN//./\\.}"
  printf '/^([^@]+\\.)?%s$/    OK\n' "${mail_domain_regex}" > /etc/postfix/regexp-virtual-domains
  \chown root:postfix /etc/postfix/regexp-virtual-domains
  \chmod 640 /etc/postfix/regexp-virtual-domains

  local marker_begin="# --- scriptmgr-freeipa mail block (begin) ---"
  local marker_end="# --- scriptmgr-freeipa mail block (end) ---"

  # Remove any previously-written block so re-runs converge instead of duplicating
  \sed -i "/^${marker_begin}\$/,/^${marker_end}\$/d" /etc/postfix/main.cf

  # Comment out distro-default keys our block redefines, so postconf -n has one value each
  \sed -i -E \
    -e 's/^(smtpd_tls_cert_file[[:space:]]*=.*)$/# \1 (superseded by scriptmgr-freeipa mail block)/' \
    -e 's/^(smtpd_tls_key_file[[:space:]]*=.*)$/# \1 (superseded by scriptmgr-freeipa mail block)/' \
    -e 's/^(inet_interfaces[[:space:]]*=.*)$/# \1 (superseded by scriptmgr-freeipa mail block)/' \
    -e 's/^(mydestination[[:space:]]*=.*)$/# \1 (superseded by scriptmgr-freeipa mail block)/' \
    /etc/postfix/main.cf

  {
    printf '%s\n' "${marker_begin}"
    printf 'virtual_mailbox_domains = regexp:/etc/postfix/regexp-virtual-domains\n'
    printf 'virtual_mailbox_base = %s\n' "${FREEIPA_MAIL_BASE_DIR}"
    printf 'virtual_mailbox_maps = ldap:/etc/postfix/ldap/virtual-mailbox.cf\n'
    printf 'virtual_alias_maps = ldap:/etc/postfix/ldap/virtual-alias.cf\n'
    printf 'virtual_uid_maps = static:%s\n' "${FREEIPA_MAIL_VID}"
    printf 'virtual_gid_maps = static:%s\n' "${FREEIPA_MAIL_VID}"
    printf 'virtual_transport = lmtp:unix:private/dovecot-lmtp\n'
    printf 'smtpd_sasl_type = dovecot\n'
    printf 'smtpd_sasl_path = private/auth\n'
    printf 'smtpd_sasl_auth_enable = yes\n'
    printf 'smtpd_sasl_security_options = noanonymous\n'
    printf 'smtpd_recipient_restrictions = permit_sasl_authenticated,permit_mynetworks,reject_unauth_destination\n'
    printf 'smtpd_relay_restrictions = permit_sasl_authenticated,permit_mynetworks,reject_unauth_destination\n'
    printf 'smtpd_tls_cert_file = %s\n' "${INSTALL_MAIL_CERT_PATH}"
    printf 'smtpd_tls_key_file = %s\n' "${INSTALL_MAIL_KEY_PATH}"
    printf 'smtpd_tls_CAfile = /etc/ipa/ca.crt\n'
    printf 'smtpd_tls_security_level = may\n'
    printf 'smtpd_tls_auth_only = yes\n'
    printf 'smtp_tls_security_level = may\n'
    printf 'myhostname = %s\n' "${FREEIPA_FQDN}"
    printf 'mydomain = %s\n' "${FREEIPA_MAIL_DOMAIN}"
    printf 'myorigin = $mydomain\n'
    printf 'inet_interfaces = all\n'
    printf 'mydestination = localhost\n'
    printf '%s\n' "${marker_end}"
  } >> /etc/postfix/main.cf

  # Enable submission (587) and smtps (465) — idempotent, only append once
  if ! \grep -q -- '^submission ' /etc/postfix/master.cf; then
    {
      printf 'submission inet n       -       n       -       -       smtpd\n'
      printf '  -o syslog_name=postfix/submission\n'
      printf '  -o smtpd_tls_security_level=encrypt\n'
      printf '  -o smtpd_sasl_auth_enable=yes\n'
      printf '  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject\n'
    } >> /etc/postfix/master.cf
  fi
  if ! \grep -q -- '^smtps ' /etc/postfix/master.cf; then
    {
      printf 'smtps     inet  n       -       n       -       -       smtpd\n'
      printf '  -o syslog_name=postfix/smtps\n'
      printf '  -o smtpd_tls_wrappermode=yes\n'
      printf '  -o smtpd_sasl_auth_enable=yes\n'
      printf '  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject\n'
    } >> /etc/postfix/master.cf
  fi

  \systemctl enable postfix
  \systemctl restart postfix

  __log "Postfix configured"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Dovecot configuration ───────────────────────────────────────────────────

__configure_dovecot() {
  __log "Configuring Dovecot..."

  # Disable the distro-default system passdb/userdb include — our own block
  # below adds the local Unix fallback explicitly (via pam/passwd) instead,
  # so FreeIPA LDAP stays authoritative and tried first
  if [[ -f /etc/dovecot/conf.d/10-auth.conf ]]; then
    \sed -i 's/^!include auth-system.conf.ext/#!include auth-system.conf.ext/' \
      /etc/dovecot/conf.d/10-auth.conf
  fi

  if [[ "${FREEIPA_MAIL_LOCAL_FALLBACK}" == "true" && ! -f /etc/pam.d/dovecot ]]; then
    {
      printf '#%%PAM-1.0\n'
      printf 'auth    required        pam_unix.so\n'
      printf 'account required        pam_unix.so\n'
    } > /etc/pam.d/dovecot
  fi

  {
    printf 'hosts = %s\n' "${FREEIPA_FQDN}"
    printf 'tls = yes\n'
    printf 'tls_ca_cert_file = /etc/ipa/ca.crt\n'
    printf 'dn = uid=mail,cn=sysaccounts,cn=etc,%s\n' "${INSTALL_LDAP_BASE_DN}"
    printf 'dnpass = %s\n' "${INSTALL_MAIL_LDAP_PASSWORD}"
    # Validate the user's own password via a bind as their own DN — FreeIPA
    # locks down userPassword reads, so this is the supported check method
    printf 'auth_bind = yes\n'
    printf 'auth_bind_userdn = uid=%%n,cn=users,cn=accounts,%s\n' "${INSTALL_LDAP_BASE_DN}"
    printf 'ldap_version = 3\n'
    printf 'base = cn=users,cn=accounts,%s\n' "${INSTALL_LDAP_BASE_DN}"
    printf 'scope = subtree\n'
    printf 'user_filter = (&(objectClass=posixAccount)(uid=%%n))\n'
    printf 'pass_filter = (&(objectClass=posixAccount)(uid=%%n))\n'
    printf 'user_attrs = =home=%s/%s/%%n,=uid=%s,=gid=%s\n' \
      "${FREEIPA_MAIL_BASE_DIR}" "${FREEIPA_MAIL_DOMAIN}" "${FREEIPA_MAIL_VID}" "${FREEIPA_MAIL_VID}"
  } > /etc/dovecot/dovecot-ldap.conf.ext
  \chown root:dovecot /etc/dovecot/dovecot-ldap.conf.ext
  \chmod 640 /etc/dovecot/dovecot-ldap.conf.ext

  local auth_mechanisms="plain login"
  local passdb_blocks userdb_blocks
  # Command substitution strips trailing newlines, so each block ends with an
  # explicit newline appended outside $(...) — otherwise concatenated blocks
  # glue together onto one line and dovecot.conf fails to parse
  passdb_blocks="$(printf 'passdb {\n  driver = ldap\n  args = /etc/dovecot/dovecot-ldap.conf.ext\n}')"$'\n'
  userdb_blocks="$(printf 'userdb {\n  driver = ldap\n  args = /etc/dovecot/dovecot-ldap.conf.ext\n}')"$'\n'

  # Local Unix fallback — tried only when LDAP reports the user as unknown,
  # so FreeIPA-directory users always authenticate via LDAP first
  if [[ "${FREEIPA_MAIL_LOCAL_FALLBACK}" == "true" ]]; then
    passdb_blocks+="$(printf 'passdb {\n  driver = pam\n  args = dovecot\n}')"$'\n'
    userdb_blocks+="$(printf 'userdb {\n  driver = passwd\n  override_fields = mail=maildir:~/Maildir\n}')"$'\n'
  fi

  # Keycloak OAuth2 token introspection — scoped to oauthbearer/xoauth2 only,
  # so plain/login clients keep going through LDAP (and local) above
  if [[ "${FREEIPA_MAIL_KEYCLOAK_AUTH}" == "true" ]]; then
    auth_mechanisms+=" oauthbearer xoauth2"
    {
      printf 'introspection_url = http://172.17.0.1:%s/realms/%s/protocol/openid-connect/token/introspect\n' \
        "${FREEIPA_KEYCLOAK_PORT}" "${FREEIPA_KEYCLOAK_REALM}"
      printf 'introspection_mode = post\n'
      printf 'client_id = %s\n' "${FREEIPA_MAIL_KEYCLOAK_CLIENT_ID}"
      printf 'client_secret = %s\n' "${INSTALL_MAIL_KEYCLOAK_SECRET}"
      printf 'username_attribute = preferred_username\n'
      printf 'active_attribute = active\n'
      printf 'active_value = true\n'
    } > /etc/dovecot/dovecot-oauth2.conf.ext
    \chown root:dovecot /etc/dovecot/dovecot-oauth2.conf.ext
    \chmod 640 /etc/dovecot/dovecot-oauth2.conf.ext

    passdb_blocks+="$(printf 'passdb {\n  driver = oauth2\n  mechanisms = xoauth2 oauthbearer\n  args = /etc/dovecot/dovecot-oauth2.conf.ext\n}')"$'\n'
  fi

  local marker_begin="# --- scriptmgr-freeipa mail block (begin) ---"
  local marker_end="# --- scriptmgr-freeipa mail block (end) ---"

  \sed -i "/^${marker_begin}\$/,/^${marker_end}\$/d" /etc/dovecot/dovecot.conf

  {
    printf '%s\n' "${marker_begin}"
    printf 'mail_location = maildir:%s/%%d/%%n\n' "${FREEIPA_MAIL_BASE_DIR}"
    printf 'disable_plaintext_auth = yes\n'
    printf 'auth_mechanisms = %s\n' "${auth_mechanisms}"
    printf '%s' "${passdb_blocks}"
    printf '%s' "${userdb_blocks}"
    printf 'ssl = required\n'
    printf 'ssl_cert = <%s\n' "${INSTALL_MAIL_CERT_PATH}"
    printf 'ssl_key = <%s\n' "${INSTALL_MAIL_KEY_PATH}"
    printf 'protocols = imap pop3 lmtp\n'
    printf 'service lmtp {\n  unix_listener /var/spool/postfix/private/dovecot-lmtp {\n    mode = 0600\n    user = postfix\n    group = postfix\n  }\n}\n'
    printf 'service auth {\n  unix_listener /var/spool/postfix/private/auth {\n    mode = 0666\n    user = postfix\n    group = postfix\n  }\n}\n'
    printf '%s\n' "${marker_end}"
  } >> /etc/dovecot/dovecot.conf

  \systemctl enable dovecot
  \systemctl restart dovecot

  __log "Dovecot configured"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Summary ─────────────────────────────────────────────────────────────────

__display_summary() {
  local primary_ip
  primary_ip="$(__primary_ip)"

  __log "FreeIPA + Keycloak Installation Summary"
  printf '==========================================\n'
  printf 'Hostname:                  %s\n' "${FREEIPA_FQDN}"
  printf 'Domain:                    %s\n' "${FREEIPA_DOMAIN}"
  printf 'Realm:                     %s\n' "${FREEIPA_REALM}"
  printf 'Admin port:                %s\n' "${FREEIPA_PORT}"
  printf 'Admin username:            admin\n'
  printf 'Admin password:            (saved to %s)\n' "${FREEIPA_CRED_FILE}"
  printf 'Directory Manager pass:    (saved to %s)\n' "${FREEIPA_CRED_FILE}"
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
  printf '  Internal URL: https://%s:%s/ipa/ui\n' "${FREEIPA_FQDN}" "${FREEIPA_PORT}"
  printf '  (Configure your reverse proxy to forward to this URL)\n\n'

  printf 'Service management:\n'
  printf '  ipactl status    — check all services\n'
  printf '  ipactl start     — start all services\n'
  printf '  ipactl stop      — stop all services\n'
  printf '  ipactl restart   — restart all services\n\n'

  printf 'Next steps:\n'
  printf '  1. Configure your external reverse proxy to forward to https://%s:%s\n' "${FREEIPA_FQDN}" "${FREEIPA_PORT}"
  printf '  2. Access the admin interface and complete initial setup\n'
  printf '  3. Retrieve admin and Directory Manager passwords from %s\n' "${FREEIPA_CRED_FILE}"
  if [[ "${INSTALL_USE_LETSENCRYPT}" == "true" ]]; then
    printf '  4. Let'"'"'s Encrypt certificates will auto-renew via the installed hook\n'
  fi

  if [[ "${INSTALL_DNS}" == "true" ]]; then
    printf '\nDNS configuration:\n'
    printf '  Set nameserver to: %s\n' "${primary_ip}"
    printf '  Test DNS: dig %s @%s\n' "${FREEIPA_FQDN}" "${primary_ip}"
  fi

  printf '\nNginx reverse proxy snippet:\n'
  printf '    location / {\n'
  printf '        proxy_pass https://%s:%s;\n' "${FREEIPA_FQDN}" "${FREEIPA_PORT}"
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
  printf '  %s        — generated credentials\n' "${FREEIPA_CRED_FILE}"

  printf '\nKeycloak SSO:\n'
  printf '  Admin console:  http://172.17.0.1:%s (internal)\n' "${FREEIPA_KEYCLOAK_PORT}"
  printf '  Admin user:     admin (Keycloak master realm)\n'
  printf '  Admin pass:     (saved to %s)\n' "${FREEIPA_CRED_FILE}"
  printf '  Realm:          %s\n' "${FREEIPA_KEYCLOAK_REALM}"
  printf '  LDAP sync:      FreeIPA → Keycloak federation active\n'
  printf '  Kerberos SPNEGO: HTTP/%s@%s\n' "${FREEIPA_FQDN}" "${FREEIPA_REALM}"
  printf '  Docker compose: %s/docker-compose.yml\n' "${FREEIPA_COMPOSE_DIR}"
  printf '  Credentials:    %s\n' "${FREEIPA_CRED_FILE}"

  printf '\nMail (Postfix/Dovecot):\n'
  printf '  Domain:           %s (and *.%s)\n' "${FREEIPA_MAIL_DOMAIN}" "${FREEIPA_MAIL_DOMAIN}"
  printf '  SMTP (STARTTLS):  %s:587\n' "${FREEIPA_FQDN}"
  printf '  SMTPS:            %s:465\n' "${FREEIPA_FQDN}"
  printf '  IMAP (TLS):       %s:993\n' "${FREEIPA_FQDN}"
  printf '  POP3 (TLS):       %s:995\n' "${FREEIPA_FQDN}"
  printf '  Auth (LDAP):      FreeIPA LDAP bind — any posixAccount user with a mail attribute\n'
  if [[ "${FREEIPA_MAIL_LOCAL_FALLBACK}" == "true" ]]; then
    printf '  Auth (local):     Unix/PAM fallback for non-LDAP accounts (plain/login only)\n'
  fi
  if [[ "${FREEIPA_MAIL_KEYCLOAK_AUTH}" == "true" ]]; then
    printf '  Auth (Keycloak):  OAUTHBEARER/XOAUTH2 via token introspection (IMAP/POP3 only)\n'
  fi
  printf '  Mailbox storage:  %s/%s/<uid>\n' "${FREEIPA_MAIL_BASE_DIR}" "${FREEIPA_MAIL_DOMAIN}"
  printf '  TLS certificate:  FreeIPA-issued, tracked by certmonger (auto-renews)\n'
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Argument parsing ─────────────────────────────────────────────────────────

__parse_args() {
  local _opts
  _opts="$(getopt -o hv -l help,version,debug,color,no-color,no-ntp -n "${APPNAME}" -- "$@")" || { __help; exit 2; }
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
        FREEIPA_DEBUG=1
        shift
        ;;
      --no-ntp)
        INSTALL_NO_NTP="true"
        shift
        ;;
      --color)
        unset NO_COLOR
        INSTALL_COLOR_RED='\e[0;31m'
        INSTALL_COLOR_GREEN='\e[0;32m'
        INSTALL_COLOR_YELLOW='\e[1;33m'
        INSTALL_COLOR_BLUE='\e[0;34m'
        INSTALL_COLOR_RESET='\e[0m'
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

  __migrate_legacy_credential_keys "${FREEIPA_CRED_FILE}"

  # Load or pick stable ports for this installation — both must be set before __configure_firewall
  FREEIPA_PORT="$(__load_credential "${FREEIPA_CRED_FILE}" FREEIPA_PORT)" || {
    FREEIPA_PORT="$(__random_port)"
    __save_credential "${FREEIPA_CRED_FILE}" FREEIPA_PORT "${FREEIPA_PORT}"
  }
  __log "Selected FreeIPA port: ${FREEIPA_PORT}"

  FREEIPA_KEYCLOAK_PORT="$(__load_credential "${FREEIPA_CRED_FILE}" FREEIPA_KEYCLOAK_PORT)" || {
    FREEIPA_KEYCLOAK_PORT="$(__random_port)"
    __save_credential "${FREEIPA_CRED_FILE}" FREEIPA_KEYCLOAK_PORT "${FREEIPA_KEYCLOAK_PORT}"
  }
  __log "Selected Keycloak port: ${FREEIPA_KEYCLOAK_PORT}"

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
  __install_mail_packages
  __setup_freeipa_for_mail
  __configure_keycloak_mail_client
  __create_mail_storage
  __configure_postfix
  __configure_dovecot
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
