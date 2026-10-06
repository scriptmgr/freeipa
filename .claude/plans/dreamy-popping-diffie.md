# Context

The user requested a fresh snapshot restore, a full end-to-end retest, and a comprehensive beta test of the FreeIPA server/client scripts. Every observed issue is to be treated as a bug and fixed before final validation. The repository contains `install.sh`, `client.sh`, and `README.md`; the executable VM harness and golden AlmaLinux 9 snapshots are currently under `/var/tmp/freeipa-vm`.

# Plan

1. **Restore and validate the test baseline**
   - Use `/var/tmp/freeipa-vm/build-ipa-base.sh` only if snapshot integrity or the package seed requires rebuilding; otherwise restore fresh qcow2 overlays from `freeipa-almalinux9-base.qcow2` and `freeipa-almalinux9-client-base.qcow2` using the existing libvirt XML and network definitions.
   - Confirm the active `freeipa-net` network, static server/client addresses, snapshot backing files, and absence of stale domains that could interfere with tests.

2. **Run the clean server path**
   - Execute `/var/tmp/freeipa-vm/freeipa-run-test.sh` from a fresh overlay, collecting install output, console output, failed units, listening sockets, Docker state, FreeIPA/LDAP/Kerberos/DNS/Apache checks, Keycloak health/realm/LDAP federation checks, Postfix/Dovecot checks, and AD-trust checks.
   - Treat every failed check, warning that indicates a functional defect, unexpected service state, or diagnostic anomaly as a bug; inspect relevant guest logs and reproduce before changing code.

3. **Expand beta coverage beyond the existing 14 checks**
   - Add/read-only verification for generated credentials/configuration, reverse-proxy HTTP reachability, certificate validity and CA trust, actual `ipa user-add`/lookup and Kerberos authentication, LDAP bind/search, SSSD identity resolution, mail service LDAP/TLS behavior, Keycloak API and federation sync, and idempotent rerun behavior.
   - Exercise supported CLI paths (`--help`, `--version`, `--no-color`, `--no-ntp`) and invalid-input/error paths on disposable environments without touching host firewall configuration.
   - Boot the client golden overlay from `freeipa-client.xml`, update the stale client harness references if needed, run `client.sh` against the installed server, and verify enrollment, SSSD, Kerberos, certificate/host principals, and login/identity resolution.

4. **Fix all confirmed issues in the repository**
   - Keep host firewall ownership with the sysadmin: no firewall packages, commands, documentation, or configuration will be added.
   - Reuse existing installer helpers and current credential/config conventions rather than introducing parallel mechanisms.
   - Update `README.md` and `client.sh`/`install.sh` help text whenever behavior or supported testable inputs change; preserve a single trailing newline in every text file.

5. **Run the complete regression gate**
   - Run `bash -n install.sh client.sh`, `git diff --check`, shell lint, focused CLI tests, clean server install/verification, client enrollment/verification, and idempotent rerun verification.
   - Re-run the expanded beta matrix from fresh overlays after each fix; retain logs for any failure and confirm teardown does not leave running domains or overlays.

6. **Review and commit only after all checks pass**
   - Inspect the final diff and repository status, ensure no secrets or generated VM artifacts enter the repository, write the required commit message file, then use the sanctioned `gitcommit --dir /root/Projects/github/scriptmgr/freeipa all` workflow.

# Critical files and existing utilities

- `/root/Projects/github/scriptmgr/freeipa/install.sh`: server installer, CLI parser, distro detection, credential persistence, FreeIPA/Keycloak/mail configuration.
- `/root/Projects/github/scriptmgr/freeipa/client.sh`: client enrollment flow and client-side CLI/configuration behavior.
- `/root/Projects/github/scriptmgr/freeipa/README.md`: user-facing setup, environment variables, and options documentation.
- `/var/tmp/freeipa-vm/freeipa-run-test.sh`: current clean server reset/install/verification driver; must be extended rather than duplicated.
- `/var/tmp/freeipa-vm/build-ipa-base.sh`: golden server/client snapshot builder and cloud-init preparation.
- `/var/tmp/freeipa-vm/freeipa-server.xml`, `freeipa-client.xml`, `freeipa-net.xml`: libvirt domains/network and static addresses.
- `/var/tmp/freeipa-vm/ipa-test-lib.sh`: stale legacy helper; use only after reconciling its paths/IPs or replace its references with the current harness.

# Verification and completion criteria

Completion requires a fresh server install and expanded verification with zero failures, a fresh client enrollment and functional identity/Kerberos checks, clean idempotent rerun behavior, passing syntax/lint/diff gates, no firewall-related implementation or documentation, no leaked credentials, and a clean repository after a signed commit.