# freeipa

Full [FreeIPA](https://www.freeipa.org/) + [Keycloak](https://www.keycloak.org/) SSO bootstrap for any major Linux distribution — installs FreeIPA with DNS, NTP, and firewall configuration, then deploys Keycloak via Docker and federates it against FreeIPA LDAP for centralized single sign-on. Idempotent and non-interactive.

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
13. Prints an installation summary with access URLs, credential locations, and next steps

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

---

## 📄 License

MIT — see [LICENSE.md](LICENSE.md)
