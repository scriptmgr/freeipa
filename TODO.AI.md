# TODO

Pre-existing script-lint findings (not introduced by recent changes).

- install.sh: lines 382, 389, 402 are over 180 characters; break them. Lines 1310 and 2787 are also over 180.
- install.sh:372: bare `return` mid-function inside an `if`; use an explicit status.
- install.sh: `grep` calls without `--` before the query at lines 933, 1030, 1370, 1371, 1388, 1678, 3155.
- install.sh, client.sh: exit codes 79 and 81 fall outside the standard POSIX/sysexits ranges; decide whether to remap or keep.
