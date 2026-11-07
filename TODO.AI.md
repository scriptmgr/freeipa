# TODO

- install.sh, client.sh: exit codes 79, 80 and 81 fall outside the standard POSIX/sysexits ranges; decide whether to remap (79 is documented in README.md) or keep.
- install.sh: the generated Let's Encrypt renewal hook defines a helper `cred()` without the `__` prefix; rename to `__cred` and retest the hook.
- install.sh: the Let's Encrypt certificate path and renewal hook have not been exercised in a VM test (no publicly trusted certificate available); test before relying on it.
