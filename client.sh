#!/usr/bin/env bash
# shellcheck shell=bash
# - - - - - - - - - - - - - - - - - - - - - - - - -
##@Version           :  202608301000-git
# @@Author           :  Jason Hempstead
# @@Contact          :  git-admin@casjaysdev.pro
# @@License          :  MIT or LICENSE.md
# @@ReadME           :  client.sh --help
# @@Copyright        :  Copyright: (c) 2026 Jason Hempstead, Casjays Developments
# @@Created          :  Sunday, August 30, 2026 10:00 UTC
# @@File             :  client.sh
# @@Description      :  Enroll this host as a FreeIPA client, distro-agnostic
# @@Changelog        :  Initial version
# @@TODO             :  None
# @@Other            :
# @@Resource         :  https://www.freeipa.org/page/Documentation
# @@Terminal App     :  yes
# @@sudo/root        :  yes
# @@Template         :  shell/bash
# - - - - - - - - - - - - - - - - - - - - - - - - -
# shellcheck disable=SC1001,SC1003,SC2001,SC2003,SC2016,SC2031,SC2034,SC2090,SC2115,SC2120,SC2155,SC2199,SC2229,SC2317,SC2329
# - - - - - - - - - - - - - - - - - - - - - - - - -
VERSION="202608301000-git"
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
FREEIPA_SERVER="${FREEIPA_SERVER:-}"
FREEIPA_SERVER_IP="${FREEIPA_SERVER_IP:-}"
FREEIPA_CRED_FILE="${FREEIPA_CRED_FILE:-/root/.freeipa-client.conf}"
INSTALL_ADMIN_PRINCIPAL="${INSTALL_ADMIN_PRINCIPAL:-admin}"
INSTALL_ADMIN_PASSWORD="${INSTALL_ADMIN_PASSWORD:-}"
FREEIPA_OTP="${FREEIPA_OTP:-}"
FREEIPA_CA_SHA256="${FREEIPA_CA_SHA256:-}"
INSTALL_FORCE_JOIN="false"
INSTALL_MKHOMEDIR="true"
INSTALL_NO_NTP="false"
FREEIPA_DEBUG="${FREEIPA_DEBUG:-0}"
# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Standard Utility Functions ──────────────────────────────────────────────

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
  fi
  \chmod 600 "${file}"
  \chown root:root "${file}"
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
  printf 'Enroll this host as a FreeIPA client — distro-agnostic.\n'
  printf 'Sets a fully-qualified hostname, installs the client packages,\n'
  printf 'joins the realm (registering this machine'"'"'s host entry and\n'
  printf 'keytab in the FreeIPA directory), and verifies the join.\n\n'
  printf 'Options:\n'
  printf '  -h, --help              Show this help and exit\n'
  printf '  -v, --version           Show version and exit\n'
  printf '      --server=HOST       FreeIPA server FQDN (required)\n'
  printf '      --domain=DOMAIN     Override auto-detected domain\n'
  printf '      --realm=REALM       Override auto-detected Kerberos realm\n'
  printf '      --principal=USER    Enrollment principal (default: admin)\n'
  printf '      --force             Pass --force-join to ipa-client-install\n'
  printf '      --no-mkhomedir      Do not create home directories on login\n'
  printf '      --no-ntp            Skip time sync (needed in containers without CAP_SYS_TIME)\n'
  printf '      --debug             Enable debug output\n'
  printf '      --color             Force color output\n'
  printf '      --no-color          Disable color output\n\n'
  printf 'Environment:\n'
  printf '  FREEIPA_SERVER           FreeIPA server FQDN (required, or --server)\n'
  printf '  FREEIPA_SERVER_IP        Server IP, if not DNS-resolvable (adds /etc/hosts entry)\n'
  printf '  FREEIPA_FQDN             Override this host'"'"'s auto-detected FQDN\n'
  printf '  FREEIPA_DOMAIN           Override auto-detected domain\n'
  printf '  FREEIPA_REALM            Override auto-detected Kerberos realm\n'
  printf '  FREEIPA_CRED_FILE        Enrollment record path (default: /root/.freeipa-client.conf)\n'
  printf '  INSTALL_ADMIN_PRINCIPAL  Enrollment principal (default: admin)\n'
  printf '  INSTALL_ADMIN_PASSWORD   Enrollment principal'"'"'s password (prompted if unset)\n'
  printf '  FREEIPA_OTP              One-time host password (recommended over the admin\n'
  printf '                           password — generate on the server with:\n'
  printf '                           ipa host-add <fqdn> --random)\n'
  printf '  FREEIPA_CA_SHA256        Expected SHA-256 fingerprint of the server'"'"'s CA cert\n'
  printf '                           (Alpine path only; obtain out-of-band with:\n'
  printf '                           openssl x509 -noout -fingerprint -sha256 -in /etc/ipa/ca.crt)\n'
  printf '  NO_COLOR                 Disable color output when set\n\n'
  printf 'Notes:\n'
  printf '  Alpine Linux has no ipa-client-install package, and musl libc cannot\n'
  printf '  load NSS modules, so full directory-integrated identity (getent/id/login)\n'
  printf '  is not possible there. On Alpine this script installs krb5 (kinit works)\n'
  printf '  and, only on Alpine edge, sssd for pam_sss-based PAM authentication.\n'
  printf '  See TODO.AI.md for details.\n'
}

__version() {
  printf '%s version %s\n' "${APPNAME}" "${VERSION}"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Pre-flight checks ───────────────────────────────────────────────────────

__check_root() {
  if [[ "$(\id -u)" -ne 0 ]]; then
    __error "This script must be run as root (exit 77)"
    exit 77
  fi
}

__check_args() {
  if [[ -z "${FREEIPA_SERVER}" ]]; then
    __error "FREEIPA_SERVER (or --server=HOST) is required"
  fi
  if [[ -n "${FREEIPA_OTP}" ]]; then
    return 0
  fi
  if [[ -z "${INSTALL_ADMIN_PASSWORD}" ]]; then
    if [[ -t 0 ]]; then
      read -r -s -p "Password for ${INSTALL_ADMIN_PRINCIPAL}@${FREEIPA_SERVER}: " INSTALL_ADMIN_PASSWORD
      printf '\n'
    else
      __error "INSTALL_ADMIN_PASSWORD or FREEIPA_OTP is required in non-interactive mode"
    fi
  fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Distro detection ────────────────────────────────────────────────────────

__detect_distro() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    INSTALL_DISTRO="${ID:-unknown}"
    INSTALL_DISTRO_FAMILY="${ID_LIKE:-${ID:-unknown}}"
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

# ─── Hostname / hosts configuration ──────────────────────────────────────────

__configure_hostname() {
  FREEIPA_FQDN="${FREEIPA_FQDN:-$(__determine_hostname_name 2>/dev/null || \hostname)}"

  if [[ "${FREEIPA_FQDN}" != *.* ]]; then
    if [[ -n "${FREEIPA_DOMAIN}" ]]; then
      FREEIPA_FQDN="${FREEIPA_FQDN}.${FREEIPA_DOMAIN}"
    else
      FREEIPA_FQDN="${FREEIPA_FQDN}.$(__determine_domain_name 2>/dev/null || printf '%s' "${FREEIPA_SERVER#*.}")"
    fi
    __log "Hostname was not fully qualified; using ${FREEIPA_FQDN}"
    \hostnamectl set-hostname "${FREEIPA_FQDN}"
  fi

  FREEIPA_DOMAIN="${FREEIPA_DOMAIN:-${FREEIPA_FQDN#*.}}"
  FREEIPA_REALM="${FREEIPA_REALM:-$(printf '%s' "${FREEIPA_DOMAIN}" | \tr '[:lower:]' '[:upper:]')}"

  __log "Using hostname: ${FREEIPA_FQDN}"
  __log "Using domain:   ${FREEIPA_DOMAIN}"
  __log "Using realm:    ${FREEIPA_REALM}"

  local short_hostname
  short_hostname="${FREEIPA_FQDN%%.*}"
  \sed -i "/[[:space:]]${FREEIPA_FQDN}\$/d" /etc/hosts
  printf '127.0.1.1 %s %s\n' "${FREEIPA_FQDN}" "${short_hostname}" >> /etc/hosts

  if ! \getent hosts "${FREEIPA_SERVER}" >/dev/null 2>&1; then
    if [[ -n "${FREEIPA_SERVER_IP}" ]]; then
      __warn "${FREEIPA_SERVER} is not DNS-resolvable; adding /etc/hosts entry using FREEIPA_SERVER_IP"
      \sed -i "/[[:space:]]${FREEIPA_SERVER}\$/d" /etc/hosts
      printf '%s %s\n' "${FREEIPA_SERVER_IP}" "${FREEIPA_SERVER}" >> /etc/hosts
    else
      __error "${FREEIPA_SERVER} is not DNS-resolvable; set FREEIPA_SERVER_IP to add an /etc/hosts entry"
    fi
  fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Client package installation ─────────────────────────────────────────────

__install_client_packages() {
  case "${INSTALL_DISTRO_FAMILY}" in
    *rhel*|*fedora*|*centos*)
      __log "Installing FreeIPA client packages via dnf..."
      local pkg_mgr="dnf"
      \command -v dnf >/dev/null 2>&1 || pkg_mgr="yum"
      "${pkg_mgr}" install -y freeipa-client krb5-workstation
      ;;

    *debian*|*ubuntu*)
      __log "Installing FreeIPA client packages via apt-get..."
      export DEBIAN_FRONTEND="noninteractive"
      \apt-get update
      \apt-get install -y freeipa-client krb5-user
      ;;

    *suse*)
      __log "Installing FreeIPA client packages via zypper..."
      \zypper refresh
      \zypper install -y freeipa-client krb5-client
      ;;

    *alpine*)
      __install_alpine_client_packages
      return 0
      ;;

    *)
      __error "Unsupported distribution family: ${INSTALL_DISTRO_FAMILY}"
      ;;
  esac
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Enrollment ───────────────────────────────────────────────────────────────

__enroll_client() {
  __log "Joining ${FREEIPA_FQDN} to realm ${FREEIPA_REALM} via ${FREEIPA_SERVER}..."

  local force_flag=""
  [[ "${INSTALL_FORCE_JOIN}" == "true" ]] && force_flag="--force-join"
  local mkhomedir_flag=""
  [[ "${INSTALL_MKHOMEDIR}" == "true" ]] && mkhomedir_flag="--mkhomedir"
  local ntp_flag=""
  [[ "${INSTALL_NO_NTP}" == "true" ]] && ntp_flag="--no-ntp"

  # Prefer a single-use host OTP (ipa host-add --random on the server) over
  # the full admin credential — ipa-client-install has no stdin/file input
  # for --password (Python getpass() reads /dev/tty, not stdin), so either
  # value is briefly visible via /proc/<pid>/cmdline while the process runs;
  # an OTP only grants that one host's enrollment, unlike the admin password.
  local join_principal="${INSTALL_ADMIN_PRINCIPAL}"
  local join_secret="${INSTALL_ADMIN_PASSWORD}"
  if [[ -n "${FREEIPA_OTP}" ]]; then
    __log "Using a one-time host password for enrollment instead of the admin credential"
    join_principal=""
    join_secret="${FREEIPA_OTP}"
  fi

  if [[ -n "${join_principal}" ]]; then
    \ipa-client-install \
      --domain="${FREEIPA_DOMAIN}" \
      --realm="${FREEIPA_REALM}" \
      --server="${FREEIPA_SERVER}" \
      --principal="${join_principal}" \
      --password="${join_secret}" \
      --unattended \
      ${mkhomedir_flag} \
      ${ntp_flag} \
      ${force_flag}
  else
    \ipa-client-install \
      --domain="${FREEIPA_DOMAIN}" \
      --realm="${FREEIPA_REALM}" \
      --server="${FREEIPA_SERVER}" \
      --password="${join_secret}" \
      --unattended \
      ${mkhomedir_flag} \
      ${ntp_flag} \
      ${force_flag}
  fi

  __save_credential "${FREEIPA_CRED_FILE}" FREEIPA_SERVER "${FREEIPA_SERVER}"
  __save_credential "${FREEIPA_CRED_FILE}" FREEIPA_DOMAIN "${FREEIPA_DOMAIN}"
  __save_credential "${FREEIPA_CRED_FILE}" FREEIPA_REALM "${FREEIPA_REALM}"

  __log "Enrollment complete"
}

__verify_enrollment() {
  __log "Verifying enrollment..."

  if \getent passwd "${INSTALL_ADMIN_PRINCIPAL}" >/dev/null 2>&1; then
    __log "SSSD resolves ${INSTALL_ADMIN_PRINCIPAL} via the directory"
  else
    __warn "getent could not resolve ${INSTALL_ADMIN_PRINCIPAL}; SSSD may still be starting"
  fi

  if \kinit -k "host/${FREEIPA_FQDN}" 2>/dev/null; then
    __log "Host keytab authenticates successfully"
    \kdestroy >/dev/null 2>&1 || true
  else
    __warn "Host keytab authentication check failed; inspect /var/log/sssd/ for details"
  fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Alpine (musl) best-effort path ───────────────────────────────────────────
#
# Alpine has no freeipa-client package, and musl libc cannot load NSS modules,
# so getent/id/login can never resolve directory-backed users regardless of
# backend (confirmed against nss-pam-ldapd and sssd — see TODO.AI.md). This
# path installs what actually works: krb5 (kinit) always, and on Alpine edge
# only, sssd for pam_sss-based PAM authentication (NOT NSS-based lookups).

__install_alpine_client_packages() {
  __warn "Alpine has no freeipa-client package and musl cannot load NSS modules"
  __warn "Directory-integrated identity (getent/id/login) is not possible here"
  __warn "Installing the best available path — see TODO.AI.md for details"

  \apk update
  \apk add krb5

  if \grep -q -- "/edge/" /etc/apk/repositories 2>/dev/null; then
    __log "Alpine edge detected; installing sssd for pam_sss-based PAM auth"
    \apk add sssd sssd-openrc linux-pam
  else
    __warn "Alpine stable detected; sssd is edge-only, skipping — kinit-only enrollment"
  fi
}

__fetch_alpine_ca_cert() {
  \mkdir -p /etc/ipa

  # HTTPS alone doesn't establish trust here — this is the client's first
  # contact with the server and it has no CA yet to validate the TLS cert
  # against, so a MITM could still serve a fake CA over a "valid" HTTPS
  # connection to itself. The actual trust anchor is FREEIPA_CA_SHA256,
  # a fingerprint the operator obtains out-of-band (e.g. `openssl x509
  # -noout -fingerprint -sha256 -in /etc/ipa/ca.crt` run on the server
  # itself) and passes in; without it this is trust-on-first-use only.
  \curl -q -LSsf -k --proto '=https' --tlsv1.2 \
    "https://${FREEIPA_SERVER}/ipa/config/ca.crt" \
    -o /etc/ipa/ca.crt \
    || \curl -q -LSsf --proto '=http' "http://${FREEIPA_SERVER}/ipa/config/ca.crt" -o /etc/ipa/ca.crt

  if [[ -n "${FREEIPA_CA_SHA256}" ]]; then
    local actual
    actual="$(\openssl x509 -noout -fingerprint -sha256 -in /etc/ipa/ca.crt 2>/dev/null | \cut -d= -f2- | \tr -d ':')"
    if [[ "${actual,,}" != "${FREEIPA_CA_SHA256,,}" ]]; then
      \rm -f /etc/ipa/ca.crt
      __error "FreeIPA CA cert fingerprint mismatch (got ${actual}, expected ${FREEIPA_CA_SHA256})"
    fi
    __log "FreeIPA CA cert fingerprint verified"
  else
    __warn "FREEIPA_CA_SHA256 not set; trusting the fetched CA cert on first use, unverified"
  fi
}

__enroll_alpine_client() {
  __fetch_alpine_ca_cert

  \cat > /etc/krb5.conf <<-EOF
	[libdefaults]
	  default_realm = ${FREEIPA_REALM}
	  dns_lookup_realm = false
	  dns_lookup_kdc = false

	[realms]
	  ${FREEIPA_REALM} = {
	    kdc = ${FREEIPA_SERVER}
	    admin_server = ${FREEIPA_SERVER}
	  }

	[domain_realm]
	  .${FREEIPA_DOMAIN} = ${FREEIPA_REALM}
	  ${FREEIPA_DOMAIN} = ${FREEIPA_REALM}
	EOF

  if \command -v sssd >/dev/null 2>&1; then
    \mkdir -p /etc/sssd
    \cat > /etc/sssd/sssd.conf <<-EOF
	[sssd]
	services = nss, pam
	domains = ${FREEIPA_DOMAIN}

	[domain/${FREEIPA_DOMAIN}]
	id_provider = ipa
	auth_provider = ipa
	access_provider = ipa
	chpass_provider = ipa
	ipa_server = ${FREEIPA_SERVER}
	ipa_domain = ${FREEIPA_DOMAIN}
	ipa_hostname = ${FREEIPA_FQDN}
	krb5_realm = ${FREEIPA_REALM}
	ldap_tls_cacert = /etc/ipa/ca.crt
	cache_credentials = True
	enumerate = False
	EOF
    \chmod 600 /etc/sssd/sssd.conf
    \rc-update add sssd default 2>/dev/null || true
    \rc-service sssd restart 2>/dev/null || true
    __log "sssd configured — wire pam_sss.so into /etc/pam.d/<service> for PAM auth"
    __log "NSS-based getent/id/login will not work on musl regardless of this config"
  fi

  __log "krb5 configured — 'kinit ${INSTALL_ADMIN_PRINCIPAL}' authenticates against ${FREEIPA_SERVER}"
  __save_credential "${FREEIPA_CRED_FILE}" FREEIPA_SERVER "${FREEIPA_SERVER}"
  __save_credential "${FREEIPA_CRED_FILE}" FREEIPA_DOMAIN "${FREEIPA_DOMAIN}"
  __save_credential "${FREEIPA_CRED_FILE}" FREEIPA_REALM "${FREEIPA_REALM}"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Summary ──────────────────────────────────────────────────────────────────

__display_summary() {
  __log "FreeIPA Client Enrollment Summary"
  printf '==========================================\n'
  printf 'Hostname: %s\n' "${FREEIPA_FQDN}"
  printf 'Domain:   %s\n' "${FREEIPA_DOMAIN}"
  printf 'Realm:    %s\n' "${FREEIPA_REALM}"
  printf 'Server:   %s\n' "${FREEIPA_SERVER}"
  printf '==========================================\n'
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# ─── Argument parsing ─────────────────────────────────────────────────────────

__parse_args() {
  local _opts
  _opts="$(getopt -o hv -l help,version,debug,color,no-color,force,no-mkhomedir,no-ntp,server:,domain:,realm:,principal: -n "${APPNAME}" -- "$@")" || { __help; exit 2; }
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
      --force)
        INSTALL_FORCE_JOIN="true"
        shift
        ;;
      --no-mkhomedir)
        INSTALL_MKHOMEDIR="false"
        shift
        ;;
      --no-ntp)
        INSTALL_NO_NTP="true"
        shift
        ;;
      --server)
        FREEIPA_SERVER="$2"
        shift 2
        ;;
      --domain)
        FREEIPA_DOMAIN="$2"
        shift 2
        ;;
      --realm)
        FREEIPA_REALM="$2"
        shift 2
        ;;
      --principal)
        INSTALL_ADMIN_PRINCIPAL="$2"
        shift 2
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

  __log "Starting FreeIPA client enrollment"

  __check_root
  __detect_distro
  __check_args
  __configure_hostname
  __install_client_packages

  if [[ "${INSTALL_DISTRO_FAMILY}" == *alpine* ]]; then
    __enroll_alpine_client
  else
    __enroll_client
    __verify_enrollment
  fi

  __display_summary

  __log "FreeIPA client enrollment completed"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -

# Run main only when executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  __main "$@"
fi

# ex: ts=2 sw=2 et filetype=sh
