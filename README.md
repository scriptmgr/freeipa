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

1. **Detects your distro family** — RHEL/Fedora/CentOS (see [Supported distributions](#supported-distributions))
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
13. **Configures AD trust support** (`ipa-adtrust-install --add-sids`), unconditionally — RHEL-family and Fedora only, since no working `freeipa-server` package exists for Debian/Ubuntu/openSUSE (see [Supported distributions](#supported-distributions))
14. **Installs and configures Postfix and Dovecot** — LDAP-authenticated virtual mailboxes backed by FreeIPA, with an IPA-issued, certmonger-tracked TLS certificate shared by both. Postfix accepts mail for `FREEIPA_MAIL_DOMAIN` and any `*.FREEIPA_MAIL_DOMAIN` subdomain (via a `regexp:` virtual-domain map — Postfix has no native glob syntax). Dovecot also supports a Unix/PAM local-account fallback (tried when a user isn't found in LDAP) and Keycloak OAUTHBEARER/XOAUTH2 via token introspection for IMAP/POP3 clients that support it — both on by default, each independently toggleable
15. Prints an installation summary with access URLs, credential locations, and next steps

All steps are idempotent — re-running the script detects existing installs (FreeIPA, the Keycloak container, generated credentials) and skips them.

### Supported distributions

The FreeIPA **server** role only runs on RHEL-family and Fedora — verified empirically
(Docker testing, 2026-08): Debian bookworm has no installable `freeipa-server`
candidate even via its own `experimental` repo, Ubuntu has never shipped one
(blocked upstream by a `bind-dyndb-ldap`/bind9 packaging conflict, and its only
PPA has been dead since 2014), and openSUSE's `security:idm` OBS project ships
`freeipa-client` only. `install.sh` errors out early with an explanatory message
on Debian/Ubuntu/openSUSE rather than attempting a broken install.

| Family | Package manager |
|--------|------------------|
| RHEL, CentOS, AlmaLinux, Rocky | `dnf` / `yum` (`ipa-server`) |
| Fedora | `dnf` (`freeipa-server`) |

`client.sh` (enrollment only) remains cross-distro — see its own
[Supported distributions](#supported-distributions-1) table below.

### Options

```
-h, --help        Show help and exit
-v, --version     Show version and exit
    --debug       Enable debug output
    --no-ntp      Skip time sync (needed in containers without CAP_SYS_TIME)
    --color       Force color output
    --no-color    Disable color output
```

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `FREEIPA_FQDN` | auto-detected | Override the detected hostname |
| `FREEIPA_DOMAIN` | auto-detected | Override the detected domain |
| `FREEIPA_REALM` | auto-detected | Override the detected Kerberos realm |
| `FREEIPA_PORT` | auto-detected | Override the detected reverse-proxy port |
| `FREEIPA_CRED_FILE` | `/etc/ipa/creds.conf` | Generated-credentials file path |
| `FREEIPA_DEBUG` | `0` | Enable debug output when set to `1` (same as `--debug`) |
| `FREEIPA_KEYCLOAK_PORT` | random, 62000–64999 | Keycloak HTTP port |
| `FREEIPA_KEYCLOAK_REALM` | domain name | Keycloak realm name |
| `FREEIPA_COMPOSE_DIR` | `/opt/keycloak` | Docker Compose directory |
| `FREEIPA_KEYCLOAK_CONFIG_DIR` | `/etc/keycloak` | Keycloak keytab/CA config directory |
| `FREEIPA_MAIL_DOMAIN` | `FREEIPA_DOMAIN` | Mail domain for virtual mailboxes |
| `FREEIPA_MAIL_BASE_DIR` | `/var/mail/vhosts` | Maildir storage root |
| `FREEIPA_MAIL_VUSER` | `vmail` | System user/group owning mailbox storage |
| `FREEIPA_MAIL_VID` | `5000` | UID and GID for `FREEIPA_MAIL_VUSER` (single ID shared by both) |
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

**Alpine Linux support is a confirmed platform limitation, not a config gap.**
Tested via Incus (Alpine 3.21 stable) and a diagnostic Docker `alpine:edge`
container against a live FreeIPA server built by `install.sh`:

- No `freeipa-client` / `ipa-client-install` package exists on Alpine (stable
  or edge).
- `sssd` does not exist on Alpine 3.21 stable (main/community/testing) — only
  on `edge/testing`, which is not ABI-safe to mix onto a stable base.
- On Alpine `edge` (self-consistent repo set), `sssd` installs and its
  Kerberos layer works fully (`kinit -k -t /etc/krb5.keytab host/...`
  succeeds against the real KDC), but `getent passwd`/`id`/`login` never
  resolve LDAP-backed users — musl's libc does not call into NSS modules for
  the `passwd`/`group` databases (only `hosts` gets limited third-party
  support). This is a musl limitation, not a config or package problem:
  `nss-pam-ldapd` (Alpine stable) fails identically for the same reason.
- No PAM Kerberos module (`pam_krb5` or equivalent) exists on Alpine stable,
  so there is also no packaged path to make login/su prompt for and validate
  a Kerberos password via plain krb5 alone.
- On Alpine `edge`, `sssd`'s own PAM module (`pam_sss.so`, bundled in the
  single `sssd` package — Alpine has no separate `sssd-client` package,
  unlike RHEL/Fedora's split packaging) DOES work correctly for direct
  authentication: verified with `pamtester` against a custom PAM service
  (`auth required pam_sss.so` / `account required pam_sss.so`) — correct
  FreeIPA password authenticates successfully, wrong password is rejected
  (RC=1). This works because PAM modules are loaded via `dlopen()` by
  `libpam` independently of libc's NSS mechanism, so `pam_sss` doesn't need
  `getpwnam()` to resolve the user first.
- `sssd.conf`/PAM config verified against upstream docs (sssd-ipa(5),
  sssd.conf(5)): the `id_provider = ipa` config used
  (`ipa_server`/`ipa_domain`/`ipa_hostname`/`krb5_realm`/`ldap_tls_cacert`/
  `cache_credentials`/`enumerate = False`) has no missing mandatory keys.
  musl's inability to consume `libnss_sss.so.2` (a glibc-only dynamic NSS
  plugin) is a confirmed, documented architectural gap (matches upstream
  SSSD issue #6586) — not a config or package problem — so
  `getent passwd`/`id`/`login` remain permanently unavailable on musl
  regardless of sssd/nss-pam-ldapd config, while `pam_sss`-based
  authentication remains available.
- Ceiling of what's achievable on stock Alpine (3.21 stable): plain `krb5`
  client package + manual `kinit <user>` succeeds against the FreeIPA KDC
  (verified with a real user and its FreeIPA password).
- Ceiling of what's achievable on Alpine `edge` (self-consistent repo set
  only — not mixable onto a stable base): `pam_sss`-based PAM authentication
  against the FreeIPA/SSSD backend works and is documented-correct.
  Directory-integrated identity resolution (`getent passwd`/`id`/`login`,
  i.e. NSS-based user/group lookup) is not possible on any Alpine release
  without compiling custom musl-compatible NSS glue, which is out of scope
  for this installer.

`install.sh` is a server-only script and never targeted Alpine as an
enrollable client. `client.sh` installs what actually works on Alpine:
`krb5` (`kinit` always works), and on Alpine `edge` only, `sssd` for
`pam_sss`-based PAM authentication (not NSS-based lookups) — so client
enrollment is fully directory-integrated on 3/4 target distro families
(RHEL/Fedora/CentOS, Debian/Ubuntu, openSUSE), with Alpine capable only of
`kinit`-level (stable) or `pam_sss`-level (edge) authentication, never full
NSS-based identity resolution.

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
| `FREEIPA_CRED_FILE` | `/etc/ipa/creds.conf` | Enrollment record path |
| `FREEIPA_ADMIN_PRINCIPAL` | `admin` | Enrollment principal |
| `FREEIPA_ADMIN_PASSWORD` | unset | Enrollment principal's password (prompted if unset) |
| `FREEIPA_OTP` | unset | One-time host password — recommended over the admin password |
| `FREEIPA_CA_SHA256` | unset | Expected CA cert SHA-256 fingerprint (Alpine path only) |
| `FREEIPA_DEBUG` | `0` | Enable debug output when set to `1` (same as `--debug`) |
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
