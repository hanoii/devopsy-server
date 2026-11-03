# AGENTS.md

devopsy-server prepares a Debian 13 or Ubuntu 26.04 host for [devopsy](https://github.com/hanoii/devopsy-cli): Docker, the deploy user and devopsy. It is a bash script, `setup.sh`, run as root, often piped from curl, and `cloud-init.yaml`, user data that converts a new server's root to XFS before it.

## Layout

- `setup.sh`: the settings (`load_settings`, `validate_settings`, `save_settings`, `usage`), `preflight`, then one `step_*` function per step, run in order by `main`.
- `cloud-init.yaml`: the XFS conversion, its scripts in `write_files` (`internals/xfs.md`).
- `test/run.sh` and `test/Dockerfile`: `setup.sh` run in containers (Checks); `.github/workflows/`: `lint.yml` and `setup.yml`.
- `README.md` is the user-facing behavior, kept in step with every change: the steps table, the settings table, "An XFS root", "Without the script" (each step by hand, so a change to a `step_*` function changes its commands there) and "Things to know".

## Rules

- Every step is idempotent: a second run in a row changes nothing and restarts nothing.
- Config files are written with `write_file`, which writes, and returns success, only when the content changed, so a service restarts only then.
- A choice is a `DEVOPSY_*` setting with a default in `load_settings`, listed in `SETTINGS` (so it is saved), in `usage` and in the README's table.
- `usage` runs before `preflight`, so `--help` works anywhere, as any user, and shows the saved settings when it can read them.
- Settings are validated, then saved, before any step runs (`validate_settings`, `save_settings`): a failed run remembers them, and a typo never sticks.
- A setting applies its state on every run, both ways (for example `DEVOPSY_KDUMP=on` puts back what `off` took away).
- Never change the SSH server's configuration: providers set it up, and a mistake there locks the operator out.
- No host firewall: the provider's covers it (README.md).
- Debian 13 and Ubuntu 26.04 only, through apt and systemd directly, with no configuration management: each release is tested before `preflight` lists it, and `DEVOPSY_FORCE=1` runs on any other.
- On Ubuntu GNU's coreutils stay the active ones (`coreutils-from-gnu`), since devopsy-cli's scripts on servers expect them (for example GNU `tail`, `mv -T`).
- The base step names uutils' for removal (`coreutils-from-uutils-`, `--allow-remove-essential`), since the two conflict over the essential `coreutils` and apt keeps a manual one over a plain install of GNU's.
- Installs pass `NEEDRESTART_SUSPEND=1`, so Ubuntu's needrestart neither restarts services nor reports into the output.
- Never create or print secrets: the deploy user's keys are devopsy-cli's (`--ssh-keys`), made on the operator's machine.
- Setup is a bootstrap of the host only: per-project deployment belongs in projects' `.devopsy/`, and Traefik is released like any project, so nothing here knows of Traefik.
- The only setting of devopsy's this writes is the release root (`DEVOPSY_ROOT`, as `releases: root` in the deploy user's devopsy config, in a file marked as written here).
- A setup script, never a CLI: no arguments but `--help`, every step on every run, and no command left on the server (no step names, no subcommands, no installed copy that updates itself).
- What a server needs after setup is devopsy and plain SSH.
- A rerun upgrades what the script installed and nothing else: the apt packages it names (an `apt-get install` upgrades an installed one), Docker among them, and devopsy (`devopsy --upgrade` as the deploy user, a failure only warning); never a `dist-upgrade`.
- setup.sh never reboots, since a rerun on a live server would take its sites down; what needs a reboot raises the restart flag a kernel update does (`/run/reboot-required`, `devopsy-server` in its `.pkgs`), only when the reboot changes something.

## Steps

- devopsy belongs to the deploy user, in `/usr/local/lib/devopsy` (`step_cli`), so `devopsy --upgrade` needs no root: it resolves the `/usr/local/bin/devopsy` link and replaces the file in its own directory.
- devopsy is never in the deploy user's home: homes are mode 700 or 750 on some distributions, and the link would then work only for its owner.
- `/usr/local/bin` stays root's, and SSH sessions without a login shell have it in `PATH`, unlike `~/.local/bin`.
- The installer runs as the deploy user, so root never runs what it downloads.
- No version setting: a rerun runs `devopsy --upgrade`, so a pinned version would last only until the next rerun.
- devopsy-cli's end-to-end servers copy this host setup (`e2e/Dockerfile` and `e2e/daemon.json` there: Docker with Buildx, the /24 address pools), so a change to the docker step's packages or `daemon.json` goes there too.
- Never mirrored there: `apparmor`, which on a host with AppArmor would start confining the privileged Docker-in-Docker servers' inner containers, and the socket buffers, the host's.
- The base step turns off systemd-resolved's LLMNR and multicast DNS (`/etc/systemd/resolved.conf.d/90-devopsy.conf`) on both releases, not as a setting: a server never resolves names on its local network, and Debian 13's resolved answers LLMNR on port 5355 of every address.
- The resolved drop-in is written where resolved is missing or masked too, for when it comes, and resolved restarts when the file was written or while 5355 is still open, so a run cut after writing is finished by the next.
- The base step frees the memory the kernel keeps for kexec (`/etc/default/grub.d/zz-devopsy.cfg`, after the image's drop-ins): `kho=off` on every server, as no setting since nothing on a devopsy server kexecs.
- kdump is a setting, `DEVOPSY_KDUMP` (`on` by default): crash dumps are a capability the image chose, which setup.sh does not undo unasked.
- `DEVOPSY_KDUMP=off` takes out `crashkernel=` where `kdump-tools.cfg` adds it and disables kdump-tools' service, which fails without the memory; never purged, since some images depend on it.
- `kho=off` goes on every server, not only on a kernel with Kexec HandOver on by default: a later kernel with it on has it from its first boot without a rerun, and a kernel without it passes the word to user space, which ignores it.
- The log says what the kexec step frees and why, with the size it reads (KHO's from the CMA pageblocks in `/proc/pagetypeinfo`, kdump's from `kexec_crash_size`).
- The kexec step raises the restart flag only when the running kernel holds KHO's scratch or a crash kernel to free, or kdump comes back: a flag for nothing is a banner asking for a reboot that changes nothing, and an automatic reboot taking the sites down for it.
- unattended-upgrades takes the flag at `DEVOPSY_AUTO_REBOOT_TIME`, even on a day with nothing to upgrade.
- `update-grub` runs while GRUB's config does not say what the drop-in does yet, never only when the drop-in was written, so a run cut between the two is finished by the next.
- The docker step raises the socket buffers to 7.5 MB (`/etc/sysctl.d/90-devopsy-net.conf`, `net.core.rmem_max` and `wmem_max`) for a Cloudflare Tunnel's QUIC, which otherwise warns and runs on the kernel's 208 KB maximum.
- The socket buffers are here, not a setting nor a template's: `net.core` is the host kernel's, not a network namespace's, so no project can set it, and it changes nothing without a tunnel.
- Sysctl files are written with `write_file` and applied with `sysctl -p` on every run (as the swap step's `vm.swappiness`), never only when written, so a run failing at `sysctl` is finished by the next.
- `daemon.json` is merged, never written whole (`step_docker`, with `jq`): its four keys (`log-driver`, `log-opts`, `live-restore`, `default-address-pools`) are setup's and replaced, with a warning when they held something else, and every other key stays, since others edit that file too (for example an HTTP proxy's `proxies`).
- The address pools are a setting, `DEVOPSY_ADDRESS_POOLS`, which the warning names: of setup's four keys only the pools are something to change, so no prompt.
- `daemon.json` is compared as JSON (`jq -cS`), so a file saying the same in other words is not rewritten and Docker not restarted.
- A `daemon.json` that is not a JSON object stops setup.sh, the file as it is.
- A key setup.sh stops setting is left in `daemon.json`.
- Docker looks for AppArmor once per daemon, so `apparmor` installed under a running daemon changes nothing until it restarts: `docker_apparmor` restarts Docker when the host has AppArmor and `docker info` lacks `name=apparmor`, once, since the restarted daemon reports it.
- Running containers keep their profile (none) through that restart (`live-restore`) until they next start.
- Provider block volumes are mounted by hand before setup, where releases should live (for example `/srv`, a `srv.mount` replacing the provider's unit, with `DEVOPSY_ROOT=/srv`), and Docker waits for the mount (`RequiresMountsFor=/srv` in a `docker.service.d` drop-in): containers starting before it write their bind mounts to the root disk, hidden under the volume.
- Ubuntu's `sudo` is sudo-rs, which reads `/etc/sudoers.d` too, and its kernel has AppArmor, which Docker applies to containers (`docker-default`).

## Checks

```sh
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable setup.sh test/run.sh
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
{ echo '#!/bin/sh'; docker run --rm -v "$PWD:/w" -w /w mikefarah/yq:4 '.bootcmd[0]' cloud-init.yaml; } >/tmp/ci/bootcmd
docker run --rm -v /tmp/ci:/mnt -w /mnt koalaman/shellcheck:stable -S warning $(ls /tmp/ci)
```

`cloud-init.yaml` itself, with Debian 13's cloud-init:

```sh
docker run --rm -v "$PWD:/w:ro" debian:trixie sh -c 'apt-get update -qq &&
  apt-get install -y -qq --no-install-recommends cloud-init >/dev/null &&
  cloud-init schema -c /w/cloud-init.yaml'
```

`setup.sh` on both releases at once, about a minute (`test/run.sh ubuntu:26.04` runs one):

```sh
test/run.sh
```

- `test/run.sh` runs `setup.sh` in a privileged container per release, systemd its first process, with its own Docker (`test/Dockerfile`, systemd-resolved added as cloud images have it), and checks what the first run set up, that a second wrote, created, restarted and updated nothing, and the runs after with changed settings.
- What `test/run.sh` checks: Docker, the deploy user and its keys, devopsy, the socket buffers, LLMNR closed, the kernel's arguments for kexec's memory and the restart flag (from kdump's drop-in and an `update-grub` planted in both), a key of another's in `daemon.json` kept, pools changed by hand replaced with a warning, and `DEVOPSY_KDUMP` off then on.
- A new check goes in `test/run.sh`, and a new supported release is a line of its default list and of `setup.yml`'s matrix.
- `test/run.sh` cannot show AppArmor (the container shares the host's kernel), swap (`DEVOPSY_SWAP` stays empty, since `swapon` would act on the host), `--help` and saved settings, or the XFS conversion; the socket buffers it sets are the host's.
- CI runs `lint.yml` (shellcheck and the schema) on every push, and `setup.yml` (`test/run.sh`, one job per release) on a push that changes `setup.sh` or the test, weekly (Docker's repository, the releases' packages and devopsy's installer change without a commit here) and on demand; a newer push to a branch cancels the run before it.
- What a container cannot show is checked on a real machine, an OrbStack one (`orb create debian:trixie devopsy-test`, `orb create ubuntu:resolute devopsy-test`) or a cloud server: the script with test settings, again without them, `--help`, then the machine deleted (`orb delete -f devopsy-test`).
- OrbStack machines lack openssh-server and mask systemd-resolved; to reproduce the cloud's port 53 clash, bind a listener to 127.0.0.53:53 before starting acme-dns.
- Right after a file is edited, OrbStack's file sharing can serve a stale copy to a machine or a `docker run` mount, so a surprising result is run again before it is trusted.
- Reaching a machine's IP or `<machine>.orb.local` from macOS makes OrbStack ask for admin rights, so go through `ssh <user>@<machine>@orb`, and test public DNS and certificates on a real server.

## Areas

Each area is read when its line says so; its history, `internals/<area>.history.md`, as Workflow's Docs says. The root's own sections have `internals/rules.history.md`, `internals/steps.history.md` and `internals/checks.history.md`.

- `internals/xfs.md`: the XFS root, boot by boot, its layouts, GRUB, the partitions' numbers and names, Ubuntu's and Vultr's differences, what it refuses and how it is tested (`cloud-init.yaml`); read when a task touches `cloud-init.yaml` or a server's disk layout.
