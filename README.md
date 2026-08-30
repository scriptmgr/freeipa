# freeipa

Full [FreeIPA](https://www.freeipa.org/) + [Keycloak](https://www.keycloak.org/) SSO bootstrap for any major Linux distribution — installs FreeIPA with DNS, NTP, and firewall configuration, then deploys Keycloak via Docker and federates it against FreeIPA LDAP for centralized single sign-on. Also configures Postfix and Dovecot for LDAP/TLS-authenticated mail against the same FreeIPA directory. Idempotent and non-interactive.

---

## 📦 Install

Run as root on the target machine. The script auto-detects the host distribution and handles everything.

> **Security note:** review the script at the URL above before piping to bash, or use the clone method below.

```bash
curl -q -LSsf https://raw.githubusercontent.com/scriptmgr/freeipa/main/install.sh \
  | bash
```

Or clone and run locally:

```bash
git clone https://github.com/scriptmgr/freeipa.git
cd freeipa
bash install.sh
```

### What it does

1. **Detects your distro family** — RHEL/Fedora/CentOS, Debian/Ubuntu, or openSUSE
2. **Checks requirements** — 2 GB+ RAM (4 GB+ recommended), 10 GB+ free disk, valid FQDN
3. **Installs prerequisites** — Docker CE and `jq`, skipped if already present
4. **Configures `/etc/hosts`, NTP/Chrony, and DNS forwarders** automatically
5. **Selects SSL certificates** — reuses an existing Let's Encrypt certificate if found, otherwise falls back to FreeIPA's built-in CA
6. **Configures the firewall** — `firewalld` or `ufw`, opening SSH/HTTP/HTTPS, LDAP/LDAPS, Kerberos, NTP, DNS (if integrated DNS is enabled), the FreeIPA reverse-proxy port, and the Keycloak port
7. **Installs and configures FreeIPA** (`ipa-server-install --unattended`), generating and saving the admin and Directory Manager passwords
8. **Configures Apache for reverse-proxy use** on a random high port so an external reverse proxy can front FreeIPA
9. **Federates Keycloak against FreeIPA LDAP** — creates a `keycloak` LDAP bind account, an `HTTP` Kerberos service principal, and exports a keytab plus the IPA CA certificate
10. **Deploys Keycloak via Docker Compose** — Postgres + Keycloak, with Kerberos SPNEGO wired to FreeIPA
11. **Configures the Keycloak realm over its REST API** — creates the realm, the LDAP user federation component, triggers a full sync, and promotes the admin user to `realm-admin`
12. **Writes an nginx vhost for Keycloak**, if nginx is installed
13. **Installs and configures Postfix and Dovecot** — LDAP-authenticated virtual mailboxes backed by FreeIPA, with an IPA-issued, certmonger-tracked TLS certificate shared by both. Postfix accepts mail for `FREEIPA_MAIL_DOMAIN` and any `*.FREEIPA_MAIL_DOMAIN` subdomain (via a `regexp:` virtual-domain map — Postfix has no native glob syntax). Dovecot also supports a Unix/PAM local-account fallback (tried when a user isn't found in LDAP) and Keycloak OAUTHBEARER/XOAUTH2 via token introspection for IMAP/POP3 clients that support it — both on by default, each independently toggleable
14. Prints an installation summary with access URLs, credential locations, and next steps

All steps are idempotent — re-running the script detects existing installs (FreeIPA, the Keycloak container, generated credentials) and skips them.

### Supported distributions

| Family | Package manager |
|--------|------------------|
| RHEL, Fedora, CentOS | `dnf` / `yum` |
| Debian, Ubuntu | `apt-get` |
| openSUSE | `zypper` |

### Options

```
-h, --help        Show help and exit
-v, --version     Show version and exit
    --debug       Enable debug output
    --color       Force color output
    --no-color    Disable color output
```

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `FREEIPA_FQDN` | auto-detected | Override the detected hostname |
| `FREEIPA_DOMAIN` | auto-detected | Override the detected domain |
| `FREEIPA_CRED_FILE` | `/root/.freeipa-install.conf` | Generated-credentials file path |
| `FREEIPA_KEYCLOAK_PORT` | random, 62000–64999 | Keycloak HTTP port |
| `FREEIPA_KEYCLOAK_REALM` | domain name | Keycloak realm name |
| `FREEIPA_COMPOSE_DIR` | `/opt/keycloak` | Docker Compose directory |
| `FREEIPA_KEYCLOAK_CONFIG_DIR` | `/etc/keycloak` | Keycloak keytab/CA config directory |
| `FREEIPA_MAIL_DOMAIN` | `FREEIPA_DOMAIN` | Mail domain for virtual mailboxes |
| `FREEIPA_MAIL_BASE_DIR` | `/var/mail/vhosts` | Maildir storage root |
| `FREEIPA_MAIL_VUSER` | `vmail` | System user/group owning mailbox storage |
| `FREEIPA_MAIL_VUID` | `5000` | UID for `FREEIPA_MAIL_VUSER` |
| `FREEIPA_MAIL_VGID` | `5000` | GID for `FREEIPA_MAIL_VUSER` |
| `FREEIPA_MAIL_LOCAL_FALLBACK` | `true` | Add a Unix/PAM passdb tried when a user isn't found in LDAP |
| `FREEIPA_MAIL_KEYCLOAK_AUTH` | `true` | Add a Keycloak OAUTHBEARER/XOAUTH2 passdb (IMAP/POP3 only) |
| `NO_COLOR` | unset | Disable color output when set |

**Keycloak mail client note:** the confidential `dovecot-mail` client created for
token introspection only authenticates Dovecot to Keycloak — it does not issue
user tokens. A mail client (MUA) must obtain its access token through its own
Keycloak client, and that client needs an **audience mapper** targeting
`FREEIPA_MAIL_KEYCLOAK_CLIENT_ID` (`dovecot-mail` by default) so the token's
`aud` claim includes it — Keycloak's introspection endpoint reports tokens
without a matching audience as inactive.

---

## 🔗 Client enrollment

`client.sh` joins the current host to the FreeIPA realm built by `install.sh`. It
detects the distro, sets a fully-qualified hostname, installs the client packages,
and runs `ipa-client-install` — which registers the host's directory entry and
keytab and configures SSSD/Kerberos.

```bash
FREEIPA_SERVER=ipa.example.com \
FREEIPA_OTP="$(ipa host-add client.example.com --random | grep -oP '(?<=Random password: )\S+')" \
  bash client.sh
```

Prefer `FREEIPA_OTP` (a single-use host password from `ipa host-add --random`,
generated on the server) over `FREEIPA_ADMIN_PASSWORD` — `ipa-client-install`
has no stdin input for its password flag, so whichever secret is used is briefly
visible via process arguments; an OTP only grants that one host's enrollment.

### Supported distributions

| Family | Mechanism |
|--------|-----------|
| RHEL, Fedora, CentOS | `freeipa-client` + `ipa-client-install` |
| Debian, Ubuntu | `freeipa-client` + `ipa-client-install` |
| openSUSE | `freeipa-client` + `ipa-client-install` |
| Alpine | Best-effort only — see below |

**Alpine Linux has no `freeipa-client` package**, and musl libc cannot load NSS
modules, so directory-integrated identity (`getent`/`id`/login) is not possible
there regardless of backend (confirmed against both `nss-pam-ldapd` and `sssd`
— see `TODO.AI.md`). `client.sh` installs what actually works: `krb5` (`kinit`
always works), and on Alpine `edge` only, `sssd` for `pam_sss`-based PAM
authentication (not NSS-based lookups).

### `client.sh` options

```
-h, --help              Show help and exit
-v, --version           Show version and exit
    --server=HOST       FreeIPA server FQDN (required)
    --domain=DOMAIN     Override auto-detected domain
    --realm=REALM       Override auto-detected Kerberos realm
    --principal=USER    Enrollment principal (default: admin)
    --force             Pass --force-join to ipa-client-install
    --no-mkhomedir      Do not create home directories on login
    --no-ntp            Skip time sync (needed in containers without CAP_SYS_TIME)
    --debug             Enable debug output
    --color             Force color output
    --no-color          Disable color output
```

### `client.sh` environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `FREEIPA_SERVER` | — | FreeIPA server FQDN (required) |
| `FREEIPA_SERVER_IP` | unset | Server IP, if not DNS-resolvable |
| `FREEIPA_FQDN` | auto-detected | Override this host's FQDN |
| `FREEIPA_DOMAIN` | auto-detected | Override the detected domain |
| `FREEIPA_REALM` | auto-detected | Override the detected Kerberos realm |
| `FREEIPA_CRED_FILE` | `/root/.freeipa-client.conf` | Enrollment record path |
| `FREEIPA_ADMIN_PRINCIPAL` | `admin` | Enrollment principal |
| `FREEIPA_ADMIN_PASSWORD` | unset | Enrollment principal's password (prompted if unset) |
| `FREEIPA_OTP` | unset | One-time host password — recommended over the admin password |
| `FREEIPA_CA_SHA256` | unset | Expected CA cert SHA-256 fingerprint (Alpine path only) |
| `NO_COLOR` | unset | Disable color output when set |

---

## 🛠️ Development

The project is a single shell script. No build step required.

```bash
git clone https://github.com/scriptmgr/freeipa.git
cd freeipa

# Syntax-check
bash -n install.sh

# Test help output
bash install.sh --help
```

### Files

| Path | Purpose |
|------|---------|
| `install.sh` | Full installer — distro detection, FreeIPA, Keycloak, and LDAP federation |
| `client.sh` | Client enrollment — distro-agnostic `ipa-client-install` wrapper |

---

## 📄 License

MIT — see [LICENSE.md](LICENSE.md)
