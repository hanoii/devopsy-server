# AGENTS.md

devopsy-server prepares a Debian 13 host for devopsy. It is a single bash
script, `setup.sh`, run as root, often piped from curl, and
`cloud-init.yaml`, user data that splits a new server's disk before it
(below, "The data partition"). Read `README.md` for the user-facing
behavior and keep it in sync: the steps table, the settings table, "A
data partition", "Without the script" (each step by hand: a change to a
`step_*` function changes its commands there) and "Things to know".

## Rules

- **Every step is idempotent:** running the script twice in a row
  changes nothing the second time and restarts nothing. Where: each
  `step_*` function.
- **Config files are written with `write_file`,** which only writes, and
  returns success, when the content changed. Why: a service restarts
  only then.
- **A choice is a `DEVOPSY_*` setting with a default in
  `load_settings`,** added to `SETTINGS` (so it is saved), to `usage`
  and to the README table. `usage` runs before `preflight`, so `--help`
  works anywhere, as any user, and shows the saved settings when it can
  read them.
- **Settings are validated, then saved, before any step runs**
  (`validate_settings`, `save_settings`). Why: a failed run remembers
  them, and a typo never sticks.
- **Never change the SSH server configuration.** Why: providers set it
  up, and a mistake there locks the operator out.
- **No host firewall:** the provider's firewall covers it (README.md).
- **Debian 13 only,** with apt and systemd directly and no configuration
  management dependencies.
- **Never create or print secrets.** Keys for the deploy user are
  devopsy-cli's (`--ssh-keys`), made on the operator's machine.
- **A bootstrap of the host only.** Per-project deployment belongs in
  projects' `.devopsy/`, and Traefik is released like any project
  (devopsy-template-traefik): nothing here knows about Traefik. The
  only setting devopsy-cli reads that this writes is the release root
  (`DEVOPSY_ROOT`, as `releases: root` in the deploy user's devopsy
  config, in a file marked as written here). Why: a server needs
  Docker, the deploy user and devopsy, and this script is one way to
  get them.
- **A setup script, not a CLI:** it takes no arguments but `--help`,
  runs every step every time, and leaves no command on the server: no
  step names, no subcommands, no installed copy that updates itself
  (all three existed and were removed, with the `ci-key` step). What a
  server needs after setup is `devopsy` and plain SSH.
- **A rerun upgrades what the script installed, nothing else:** the apt
  packages it names (`apt-get install` upgrades an installed one),
  Docker among them, and devopsy (`devopsy --upgrade` as the deploy
  user; a failure only warns). No `dist-upgrade`.

## Decisions and gotchas

- **devopsy belongs to the deploy user, in `/usr/local/lib/devopsy`**
  (`step_cli`), so `devopsy --upgrade` needs no root: it resolves the
  `/usr/local/bin/devopsy` link and replaces the file in its own
  directory. Not in the user's home: homes are mode 700 or 750 on some
  distributions, and the link would then only work for its owner.
  `/usr/local/bin` itself stays root's, and SSH sessions without a
  login shell have it in `PATH`, unlike `~/.local/bin`. The installer
  runs as the deploy user, so root never runs what it downloads.
- **No version setting:** a rerun runs `devopsy --upgrade` as that user,
  the one way to upgrade, so a pinned version would last only until the
  next rerun.
- **devopsy-cli's end-to-end servers copy this host setup**
  (`e2e/Dockerfile`, `e2e/daemon.json` there: Docker with Buildx, the
  /24 address pools): a change to the `docker` step's packages or
  `daemon.json` goes there too. Except `apparmor`, never mirrored: those
  servers are privileged Docker-in-Docker, and on a host with AppArmor
  (GitHub's Ubuntu runners included) it would start confining the inner
  containers, changing what the suite tests.
- **Docker looks for AppArmor once per daemon** (containerd's
  `HostSupports`, behind a `sync.Once`: securityfs, the kernel's
  `enabled` flag, `/sbin/apparmor_parser`), so installing `apparmor`
  under a running daemon changes nothing until it restarts, and a rerun
  restarts Docker only when `daemon.json` changes. `docker_apparmor`
  restarts it when the host passes those checks and `docker info` lacks
  `name=apparmor`: once, since the restarted daemon reports it. Running
  containers keep their profile (none) through the restart
  (`live-restore`) until they next start. Not testable on OrbStack,
  whose kernel has no AppArmor: there the step only says so.
- **Provider block volumes are mounted by hand, before setup:**
  DigitalOcean mounts an attached volume on `/mnt/<volume>` with its
  own systemd mount unit. Mount it where releases should live, like
  `/srv` (`srv.mount`, after removing the provider's unit), with
  `DEVOPSY_ROOT=/srv`, and make Docker wait for it
  (`RequiresMountsFor=/srv` in a `docker.service.d` drop-in). Why:
  containers starting before the mount write their bind mounts to the
  root disk, hidden under the volume. `setup.sh` does not do this.
- **OrbStack machines differ from cloud servers:** they lack
  openssh-server and mask systemd-resolved. To reproduce the cloud
  port 53 clash, bind a listener to 127.0.0.53:53 (a few lines of
  python) before starting acme-dns. Right after editing a file,
  OrbStack's file sharing can serve a stale copy to a machine or a
  `docker run` mount: rerun before trusting a surprising result.
  Reaching a machine's IP or `<machine>.orb.local` from macOS makes
  OrbStack ask for admin rights (its network helper): go through `ssh
  <user>@<machine>@orb` instead, and test public DNS and certificates
  on a real server.

## The data partition

`cloud-init.yaml`: an ext4 root of `ROOT_GB` and an XFS partition with
the rest on `/srv`, `DEVOPSY_ROOT=/srv/devopsy` and Docker's named
volumes bound from `/srv/docker-volumes`. Why XFS: reflinks, so a copy
of an environment's data on the same filesystem takes seconds whatever
its size; Debian's kernel has it, it suits databases, and it grows
online (never shrinks). Its comments say how
each boot goes; here are the decisions and the findings.

- **User data, not a step of `setup.sh`** (decided): the split needs
  the disk before anything is on it, and two reboots. `setup.sh` stays
  host setup, run after it as on any server, and knows nothing of it.
- **The root cannot be kept small by cloud-init:** DigitalOcean's image
  grows it in the initramfs (`cloud-initramfs-growroot`,
  `local-bottom/growroot`) before cloud-init runs, then ext4 through
  `x-systemd.growfs`; `growpart: off` and `resize_rootfs: false` come
  too late. So boot 1 writes `/etc/growroot-disabled` (growroot then
  skips) and a `local-premount` script into the initramfs, which
  shrinks the root on boot 2, before it is mounted.
- **State is the new partition's GPT name:** none (shrink and
  partition), `devopsy-new` (make XFS), `devopsy-data` (done, nothing
  ever again). XFS is only ever made on a partition the script created,
  and every failure boots on, unsplit. The root's partition is
  rewritten at the same start with the same type, PARTUUID and name:
  the kernel boots `root=PARTUUID=`.
- **Debian 13's initramfs has no busybox:** the hook copies `mawk` and
  `sed` with the tools.
- **`/etc/growroot-disabled` turns cloud-init's `growpart` off too**
  ("growpart disabled: /etc/growroot-disabled exists"), so its config
  needs `ignore_growroot_disabled: true`, with `devices: [/srv]` alone:
  after a disk resize only the data partition can grow, and should.
  Before the split `/srv` resolves to the root, which then cannot grow
  past the data partition (NOCHANGE). The XFS grows in a per-boot
  script (cloud-init's final stage, after growpart; `bootcmd` runs
  before it, and `resizefs` grows only the root). `/srv` is ordered
  before cloud-init's network stage, where growpart runs
  (`x-systemd.before`: `nofail` alone orders it before nothing).
- **Docker's named volumes are a bind, not Docker's `data-root`:**
  images and build cache stay on the root, sized for them, and the data
  partition holds data only. The bind's source is made by
  `devopsy-docker-volumes.service`, after `srv.mount` and before the
  bind (`x-systemd.requires`). A reflink across the bind works (checked
  2026-10-26: the same filesystem).
- **Without `/srv` nothing writes to the root disk:** `/srv` and
  `/var/lib/docker/volumes` are immutable while unmounted, and Docker's
  drop-in `RequiresMountsFor` both, so it fails with "dependency"
  (checked with a wrong UUID: the deploy user's `mkdir` and root's
  `touch` refused). The boot then waits out the missing device
  (systemd's 90 s) before going on.
- **Tested on DigitalOcean only** (2026-10-25 and 26, `s-1vcpu-512mb`,
  Debian 13): the split, `setup.sh` after it, a release on `/srv`, a
  reboot, the missing mount and a disk resize. Not testable on
  OrbStack: its machines boot no initramfs of their own.

## Checks

```sh
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable setup.sh
```

The scripts inside `cloud-init.yaml`, extracted first:

```sh
for p in /etc/initramfs-tools/hooks/devopsy-data \
  /etc/initramfs-tools/scripts/local-premount/devopsy-data \
  /var/lib/cloud/scripts/per-boot/devopsy-data-grow; do
  docker run --rm -v "$PWD:/w" -w /w mikefarah/yq:4 \
    ".write_files[] | select(.path == \"$p\") | .content" cloud-init.yaml \
    >"/tmp/$(basename "$(dirname "$p")")-$(basename "$p")"
done
docker run --rm -v /tmp:/mnt -w /mnt koalaman/shellcheck:stable -s sh -S warning \
  hooks-devopsy-data local-premount-devopsy-data per-boot-devopsy-data-grow
```

`cloud-init.yaml` itself on a server it set up: `cloud-init schema
--system`. It is tested on a cloud server (above, "The data partition"),
the smallest size, deleted afterwards, with a small `ROOT_GB` so the
data partition gets a few GiB of a 10 GB disk.

Test on a real Debian 13 machine, for example an OrbStack machine
(`orb create debian:trixie devopsy-test`). Run the script with test
settings, run it again without them to check idempotency, saved
settings and `--help`, then `orb delete -f devopsy-test`.

## Commits

Conventional commits (`feat:`, `fix:`, `docs:`, `build:`...).
