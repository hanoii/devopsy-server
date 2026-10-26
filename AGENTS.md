# AGENTS.md

devopsy-server prepares a Debian 13 or Ubuntu 26.04 host for devopsy. It
is a single bash script, `setup.sh`, run as root, often piped from curl,
and
`cloud-init.yaml`, user data that converts a new server's root to XFS
before it (below, "The XFS root"). Read `README.md` for the user-facing
behavior and keep it in sync: the steps table, the settings table, "An
XFS root", "Without the script" (each step by hand: a change to a
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
- **Debian 13 and Ubuntu 26.04, nothing else,** with apt and systemd
  directly and no configuration management dependencies. Each is
  tested before it is listed (`preflight`; `DEVOPSY_FORCE=1` for any
  other). What differs is small: Docker's repository is
  `download.docker.com/linux/$ID`, and on Ubuntu `coreutils-from-gnu`
  keeps GNU's coreutils the active ones, which devopsy-cli's scripts on
  servers expect (GNU `tail`, `mv -T`): Ubuntu ships Rust's uutils
  beside them and may make them the default (26.04 on DigitalOcean had
  GNU's, checked 2026-10-26). `NEEDRESTART_SUSPEND=1` on installs keeps
  Ubuntu's needrestart from restarting services and reporting into the
  output. Ubuntu's `sudo` is sudo-rs, which reads `/etc/sudoers.d` too;
  its kernel has AppArmor, applied to containers (`docker-default`).
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

## The XFS root

`cloud-init.yaml` converts the image's ext4 root to XFS on a new
server's first boots: the XFS as partition 1 over the rest of the disk,
GRUB reading only ext4, and nothing of the conversion left behind. Why
XFS: reflinks, so a copy of an environment's data takes seconds whatever
its size; Debian's and Ubuntu's kernels have it, it suits databases,
and it grows online (never shrinks). Its comments say how each boot
goes; here are the decisions and the findings.

- **User data, not a step of `setup.sh`** (decided): the conversion
  needs the disk before anything is on it, and two reboots. `setup.sh`
  stays host setup, run after it as on any server, and knows nothing of
  it.
- **The whole root, not a data partition beside an ext4 root**
  (decided 2026-10-26, after building and testing the split): a split
  fixes the root's size forever, while a bigger plan on DigitalOcean
  is a bigger disk, so the root could never grow with the server, and
  with Docker's images on the data side too it would hold only the
  system. One filesystem has no size to choose, no mounts to order and
  nothing to fail when a partition is missing. What the conversion
  risks is a new, empty server's: one that fails is created again.
- **By layout, not by distribution:** boot 1 notes whether `/boot` is
  its own mount (`MODE`, `/etc/devopsy-xfs.conf`): Debian 13's image
  has `/boot` in the root (`boot-in-root`), Ubuntu 26.04's on a
  partition of its own (`boot-separate`). One script converts both
  (`/usr/local/lib/devopsy-xfs/convert`), run from the initramfs by
  whichever builds it: initramfs-tools' `local-premount` on Debian,
  dracut's `pre-mount` on Ubuntu, both through `update-initramfs`
  (dracut's own on Ubuntu). The rest of this section is the
  `boot-in-root` layout's unless it says Ubuntu.
- **`/boot` stays the image's ext4, kept in place:** GRUB never reads
  XFS (its BIOS core carries only the modules for `/boot`'s filesystem,
  and `mkfs.xfs`'s defaults, like `nrext64`, may be newer than a
  GRUB), and the ext4 keeps its UUID, which GRUB's EFI config and the
  boot-1 core search by. Its files move to its top, with `boot -> .`,
  so `/boot/grub` and `/grub` are one directory: the image's GRUB
  looks for the first, `grub-install` from the converted server writes
  the second.
- **DigitalOcean wants the root as partition 1:** creating a Droplet
  from a snapshot of a server whose root was partition 2 failed, the
  Droplet gone during creation (`doctl`'s 404, nothing in the panel),
  live or powered off, at any size; a snapshot of a stock server
  worked, and one with the root renumbered to 1 did (found 2026-10-26).
  Its own XFS image (Rocky Linux) has the root as partition 1 too. GPT
  numbers are independent of where a partition lies, so the XFS takes
  number 1 at the end of the disk, and the ext4 another.
- **GRUB's BIOS core finds `/boot` by partition number** (`(,gpt1)`, as
  `grub-install` writes it): renumbering without reinstalling GRUB left
  a server that never booted (found 2026-10-26). `grub-install` cannot
  run in the initramfs, and run before the renumbering it writes the
  old number. So boot 1 installs a core of its own (`grub-mkimage`
  with a `search.fs_uuid` config, `grub-bios-setup`), valid before and
  after, and the last boot reinstalls GRUB as its updates do
  (`dpkg-reconfigure grub-cloud-amd64`: by number again, the new one).
  The EFI config was by UUID already.
- **The XFS takes the root's PARTUUID** in the same write as its
  number: the kernel's `root=PARTUUID=` (the image's
  `grub.d/10_cloud.cfg`), GRUB's config and the root's fstab line keep
  working unchanged, and every `update-grub` after writes the same.
- **State is the XFS partition's GPT name:** `devopsy-new` (copy),
  `devopsy-copied` (strip the ext4), `devopsy-stripped` (renumber),
  `devopsy-root` (done, nothing ever again), the ext4 `devopsy-boot`.
  The ext4 stays the root until the renumbering, so a failure up to the
  copy boots on as before; from the strip on the ext4 boots no system,
  and the next boot resumes in the initramfs before it needs one.
- **The strip never leaves GRUB without `/boot/grub`:** `/boot`'s files
  are hard-linked to the top (`cp -al`), then one rename swaps the
  directory for the link (`mv -T --exchange`, renameat2's
  `RENAME_EXCHANGE`, coreutils 9.5). Without `-T`, `mv --exchange`
  moves the link into the directory (found).
- **The last boot's script waits for `devopsy-root`,** not for an XFS
  root: an earlier version ran on an XFS root with its last phase left
  (found).
- **Debian 13's initramfs has klibc's tools, no busybox:** the hook
  copies GNU's and util-linux's into `/devopsy/bin`. The script reads
  `root=` from the kernel's command line itself (`blkid -t`), so it
  needs nothing of either initramfs's own functions.
- **On Ubuntu GRUB is untouched:** `/boot` is its own ext4 (`vda13`),
  so the root is only the kernel's (`root=UUID=`, the filesystem's).
  The XFS takes the root's partition number, PARTUUID and filesystem
  UUID (`xfs_db -x -c "uuid ..."`), and the ext4 goes, its signature
  wiped first (`wipefs`): a stale ext4 with the root's UUID would
  shadow the root if a partition were ever made over it. Each step
  leaves the root resolving to a complete copy.
- **On Ubuntu no space is lost:** the ext4 is shrunk to its minimum
  (3.4 GiB for 2.5 used: its inode tables), copied whole to the end of
  the disk (`dd`, `devopsy-moving`), and one write moves its partition
  there and gives the space before it to the XFS (`devopsy-old`), which
  grows over the ext4's once it goes (`x-systemd.growfs`). Without the
  move the shrunk ext4's space stayed unused before the root (tried:
  XFS grows only at its end). Until that write the partition is the
  copy's source, untouched, so a cut copies again.
- **dracut runs `pre-mount` hooks sourced into its own shell:** the
  hook only runs the script. Ubuntu builds host-only, which left out
  XFS's driver even with `instmods`, in `install()` or
  `installkernel()` (found: `mount: unknown filesystem type 'xfs'`,
  the server booting on ext4 and retrying); `add_drivers+=" xfs "` in
  `/etc/dracut.conf.d` puts it in. The script also `modprobe`s it.
- **Growing is the image's own:** growroot grows the ext4 over the
  disk on boot 1 (phase 1 shrinks it), and the conversion's boot
  reboots before growroot runs. After it the XFS is the last partition,
  so growroot, cloud-init's `resizefs` and systemd's growfs (fstab's
  `x-systemd.growfs`, kept) grow it after a resize or onto a larger
  Droplet from a snapshot.
- **fstab:** the root `xfs defaults` (no `discard`: `fstrim.timer` is
  on), `/boot` by its UUID, `nofail` with an immutable mount point, so
  a missing `/boot` boots on and an update writing there fails.
- **Measured** (2026-10-26, `s-1vcpu-512mb`, ext4 `/boot` against the
  XFS root, the same disk): unpacking 34,000 files (754 MB) 6.3 to 7.0
  s against 7.1 to 7.8, deleting them 1.0 s against 2.5, random 16k
  writes 19.7k against 23.8k IOPS; a reflink copy of a 650 MB database
  0.03 s. Swap on a `fallocate`d file works (`setup.sh`'s swap step).
- **Tested on DigitalOcean only** (2026-10-26). Ubuntu 26.04 (kernel
  7.0, GRUB 2.14, dracut 110): the conversion at 10 GB (8.9 GiB XFS,
  nothing unused), and resumed after a failure past phase 1 (the
  missing XFS driver); a kernel upgrade, GRUB's packages reinstalled
  (`grub-install` for BIOS and EFI) and a kernel removed, each with
  reboots; `setup.sh`; a release like Debian's, its reflink snapshot
  and restore; a live snapshot onto a new 25 GB Droplet, a rebuild from
  it and a disk resize. No release upgrade (26.04 is offered none yet). Debian 13: the
  conversion at 10 and 25 GB; reboots; a kernel upgrade, GRUB's
  packages reinstalled, a kernel removed and an upgrade to forky
  (Debian 14: kernel 7.2, GRUB 2.14), each with reboots; `setup.sh`, a
  release with a database in a named volume and an owned `mnt` entry,
  reflink copies of both; a live snapshot onto a new 25 GB Droplet
  (grown, the services and data back) and a rebuild from it; a disk
  resize. Not testable on OrbStack: its machines boot no initramfs of
  their own.

## Checks

```sh
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable setup.sh
```

The scripts inside `cloud-init.yaml`, extracted first:

```sh
rm -rf /tmp/ci && mkdir /tmp/ci && i=0
for p in $(docker run --rm -v "$PWD:/w" -w /w mikefarah/yq:4 \
  '.write_files[] | select(.permissions == "0755") | .path' cloud-init.yaml); do
  i=$((i + 1))
  docker run --rm -v "$PWD:/w" -w /w mikefarah/yq:4 \
    ".write_files[] | select(.path == \"$p\") | .content" cloud-init.yaml >"/tmp/ci/$i-${p##*/}"
done
{ echo '#!/bin/sh'; docker run --rm -v "$PWD:/w" -w /w mikefarah/yq:4 '.runcmd[0]' cloud-init.yaml; } >/tmp/ci/runcmd
docker run --rm -v /tmp/ci:/mnt -w /mnt koalaman/shellcheck:stable -S warning $(ls /tmp/ci)
```

`cloud-init.yaml` itself, with Debian 13's cloud-init:

```sh
docker run --rm -v "$PWD:/w:ro" debian:trixie sh -c 'apt-get update -qq &&
  apt-get install -y -qq --no-install-recommends cloud-init >/dev/null &&
  cloud-init schema -c /w/cloud-init.yaml'
```

It is tested on a cloud server (above, "The XFS root"), the smallest
size, deleted afterwards.

Test on a real Debian 13 or Ubuntu 26.04 machine, for example an
OrbStack machine (`orb create debian:trixie devopsy-test`, `orb create
ubuntu:resolute devopsy-test`). Run the script with test
settings, run it again without them to check idempotency, saved
settings and `--help`, then `orb delete -f devopsy-test`.

## Commits

Conventional commits (`feat:`, `fix:`, `docs:`, `build:`...).
