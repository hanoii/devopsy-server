History, not rules: AGENTS.md's Checks win where they differ.

- LLMNR is checked open before on Debian, so the check means something.
- The old AGENTS.md was split into a short root and an area on 2026-11-03.
- CI costs nothing: the repository is public.
- The swap step got a check in `test/run.sh` through fakes of `swapon`, `mkswap`, `fallocate` and `sysctl` for `vm.swappiness`, before only on a real machine: the real ones act on the host's kernel.
- `test/run.sh` runs devopsy's `--server-setup --yes` over the container's own sshd after setup.sh's first two runs, three runs of it (a container running, none, nothing to change). `/var/lib/containerd` became a volume too: Docker's containerd image store cannot nest its overlay in the container's. The iptables raw table works in the privileged container, so the metadata firewall loads there. On OrbStack the whole run went from about 49 s to about 69 s, both releases at once.
