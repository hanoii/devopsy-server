History, not rules: AGENTS.md's Checks win where they differ.

- LLMNR is checked open before on Debian, so the check means something.
- The old AGENTS.md was split into a short root and an area on 2026-11-03.
- CI costs nothing: the repository is public.
- The swap step got a check in `test/run.sh` through fakes of `swapon`, `mkswap`, `fallocate` and `sysctl` for `vm.swappiness`, before only on a real machine: the real ones act on the host's kernel.
