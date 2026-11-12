# TODO

- install.sh, client.sh: exit codes 79, 80 and 81 fall outside the standard POSIX/sysexits ranges; decide whether to remap (79 is documented in README.md) or keep.
- install.sh: the generated Let's Encrypt renewal hook defines a helper `cred()` without the `__` prefix; rename to `__cred` and retest the hook.
- install.sh: the Let's Encrypt path was verified in Alma 9 VMs (certificate served on 443/636/993/995/465/587, renewal hook reruns); still untested together with integrated DNS because the available certificate domain is a public zone.
