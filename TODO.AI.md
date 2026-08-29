# TODO.AI.md

Issues found by `script-lint` on `install.sh` (not yet fixed — logged per audit findings rule):

1. line 108: `$(\dirname -- "${file}")` — UUOC, replace with parameter expansion `${file%/*}`
2. line 517: `\grep -E '^nameserver...'` missing `--` before pattern
3. line 642: `\grep -q "# ICMP ping allow"` missing `--` before pattern
4. line 1128: inside docker-compose heredoc, `grep -q 'issuer'` missing `--` before pattern
5. line 1165: `\grep -q '"issuer"'` missing `--` before pattern
6. line 1583: `--color` flag missing from argument parser — add to long options and implement handler to complement `--no-color`
