# TODO

## Alpine Linux client support — confirmed platform limitation

Tested via Incus (Alpine 3.21 stable) and a diagnostic Docker `alpine:edge`
container against a live FreeIPA server built by `install.sh`.

- No `freeipa-client` / `ipa-client-install` package exists on Alpine
  (stable or edge).
- `sssd` does not exist on Alpine 3.21 stable (main/community/testing) —
  only on `edge/testing`, which is not ABI-safe to mix onto a stable base.
- On Alpine `edge` (self-consistent repo set), `sssd` installs and its
  Kerberos layer works fully (`kinit -k -t /etc/krb5.keytab host/...`
  succeeds against the real KDC), but `getent passwd`/`id`/`login` never
  resolve LDAP-backed users — musl's libc does not call into NSS modules
  for the `passwd`/`group` databases (only `hosts` gets limited
  third-party support). This is a musl limitation, not a config or
  package problem: `nss-pam-ldapd` (Alpine stable) fails identically for
  the same reason.
- No PAM Kerberos module (`pam_krb5` or equivalent) exists on Alpine
  stable, so there is also no packaged path to make login/su prompt for
  and validate a Kerberos password via plain krb5 alone.
- On Alpine `edge`, `sssd`'s own PAM module (`pam_sss.so`, bundled in the
  single `sssd` package — Alpine has no separate `sssd-client` package,
  unlike RHEL/Fedora's split packaging) DOES work correctly for direct
  authentication: verified with `pamtester` against a custom PAM service
  (`auth required pam_sss.so` / `account required pam_sss.so`) — correct
  FreeIPA password authenticates successfully, wrong password is rejected
  (RC=1). This works because PAM modules are loaded via `dlopen()` by
  `libpam` independently of libc's NSS mechanism, so `pam_sss` doesn't
  need `getpwnam()` to resolve the user first.
- `sssd.conf`/PAM config verified against upstream docs (sssd-ipa(5),
  sssd.conf(5)): the `id_provider = ipa` config used
  (`ipa_server`/`ipa_domain`/`ipa_hostname`/`krb5_realm`/
  `ldap_tls_cacert`/`cache_credentials`/`enumerate = False`) has no
  missing mandatory keys. `ipa_hostname` is optional but recommended when
  auto-detected hostname may not match (true in containers). musl's
  inability to consume `libnss_sss.so.2` (a glibc-only dynamic NSS
  plugin) is a confirmed, documented architectural gap (matches upstream
  SSSD issue #6586) — not a config or package problem — so
  `getent passwd`/`id`/`login` remain permanently unavailable on musl
  regardless of sssd/nss-pam-ldapd config, while `pam_sss`-based
  authentication remains available.
- Ceiling of what's achievable on stock Alpine (3.21 stable): plain
  `krb5` client package + manual `kinit <user>` succeeds against the
  FreeIPA KDC (verified with a real user, `alpineuser`, and its FreeIPA
  password).
- Ceiling of what's achievable on Alpine `edge` (self-consistent repo
  set only — not mixable onto a stable base): `pam_sss`-based PAM
  authentication against the FreeIPA/SSSD backend works and is
  documented-correct. Directory-integrated identity resolution
  (`getent passwd`/`id`/`login`, i.e. NSS-based user/group lookup) is
  not possible on any Alpine release without compiling custom
  musl-compatible NSS glue, which is out of scope for this installer.

Action: none planned — `install.sh` is a server-only script and never
targeted Alpine as an enrollable client. This is documented here so the
limitation isn't rediscovered from scratch, and so client-enrollment
testing scope is accurately understood as 3/4 target distros (Debian,
Ubuntu, Fedora) fully directory-integrated, with Alpine capable only of
`kinit`-level (stable) or `pam_sss`-level (edge) authentication, never
full NSS-based identity resolution.
