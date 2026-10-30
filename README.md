# devopsy-server

Turns a fresh Debian 13 or Ubuntu 26.04 server into a devopsy host: Docker,
a deploy user, automatic security upgrades and the
[devopsy CLI](https://github.com/hanoii/devopsy-cli). Everything else is
released onto it with devopsy, starting with
[Traefik](https://github.com/hanoii/devopsy-template-traefik).

## Usage

As root on the server:

```sh
curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-server/main/setup.sh | bash
```

Then release Traefik onto it from a devopsy-template-traefik checkout
(`devopsy @<server>:prod setup`, its README's "Setup"), and your projects
after it.

Settings are optional environment variables. `--help` lists them with the
values this server has saved:

```sh
curl -fsSL .../setup.sh | DEVOPSY_SWAP=2G bash
curl -fsSL .../setup.sh | bash -s -- --help
```

They are saved to `/etc/devopsy/server.env`, so a rerun reuses them. Set
one again to replace it, or empty (`DEVOPSY_SWAP=`) to go back to its
default.

Rerun the same command at any time: every step is idempotent, and a rerun
upgrades what the script installed (its apt packages, Docker and
devopsy). It leaves no command on the server.

On a new server, `cloud-init.yaml` can first convert its root to XFS
(see "An XFS root" below).

## An XFS root

`cloud-init.yaml` is user data for a new server. On its first boots it
converts the root from ext4 to XFS, which copies files with reflinks:
copies of data on the server (an environment's, a database included)
take seconds whatever their size, sharing blocks until written.
Everything stays on one filesystem the size of the disk (the system,
releases, Docker's images and volumes), and a disk resize grows it.

Tried on DigitalOcean's and Vultr's Debian 13 and Ubuntu 26.04 images.
Only for a new server: the conversion runs once, at its first boots,
before anything is on the disk.

1. Create the server with the file as its user data, nothing to edit:
   in DigitalOcean's control panel, "Advanced Options", "Add
   Initialization scripts", pasted whole, or `doctl compute droplet
   create ... --user-data-file cloud-init.yaml`; on Vultr, "Cloud-Init
   User-Data", or `vultr-cli instance create ... --userdata-file
   cloud-init.yaml`.
2. It reboots twice on its own, about three minutes, then is ready:
   `findmnt /` says `xfs`, and `grep devopsy-xfs
   /var/log/cloud-init-output.log` ends with "done, the root is XFS",
   each line with its time.
3. Run `setup.sh` as usual.

What the server gets, by what the image had:

```
DigitalOcean, Debian 13 (/boot in the root)
vda1   /           XFS, the rest of the disk: everything
vda2   /boot       ext4, 2 GiB: the image's own root, kept for GRUB
vda14              BIOS boot, the image's
vda15  /boot/efi   EFI system, the image's

DigitalOcean, Ubuntu 26.04 (/boot on its own partition)
vda1   /           XFS, the rest of the disk: everything
vda13  /boot       ext4, the image's
vda14              BIOS boot, the image's
vda15  /boot/efi   EFI system, the image's

Vultr, Debian 13 and Ubuntu 26.04 (/boot in the root, EFI only)
vda1   /boot/efi   EFI system, the image's
vda2   /           XFS, the rest of the disk: everything
vda3   /boot       ext4, 5 to 6 GiB: the image's own root, kept for GRUB
```

With `/boot` in the root, the ext4 holds the whole root until the copy
is done, so it keeps 2 GiB or what the image needs then, in whole GiB
(Vultr's images are larger). With `/boot` on its own partition, the old
root's ext4 goes once the copy is done, and the XFS grows over its
space. A swap file the provider made on the root (Vultr's `/swapfile`)
is made again on the XFS, the same size.

- **Updates work as on any server of the distribution:** kernel, GRUB
  and release upgrades write `/boot`, which GRUB reads as before; it
  never reads XFS. Tried on DigitalOcean: a kernel upgrade, GRUB's
  packages reinstalled (GRUB installs itself again then) and a kernel
  removed, each followed by reboots, on both; on Debian an upgrade to
  the next release too (Ubuntu 26.04 is offered none yet).
- **Without `/boot` the server still boots** (`nofail`), reachable over
  SSH, and an update fails instead of writing where GRUB never looks:
  `/boot`'s mount point on the XFS is immutable (`chattr +i`).
- **A disk resize grows the root:** power off, resize with the disk (on
  DigitalOcean permanent), power on.
- **The provider's snapshots and backups restore as on any server,**
  onto a new server (a larger one grows to its disk) or by a rebuild:
  DigitalOcean expects the root as partition 1, as the conversion
  leaves it.
- **Anything else is refused, and the server stays as created** (ext4,
  its log saying why, ending "not converting"): another release than
  Debian 13 or Ubuntu 26.04 (each is tried before it is added), a
  kernel that finds the root by anything but UUID, PARTUUID or device,
  an initramfs that would not carry the conversion or XFS's driver.
- **The conversion's own boot shows only on the serial console** (the
  provider's recovery console, lines starting `devopsy-xfs:`): it runs
  before the root is mounted. If anything is not as it expects (a root
  that is not ext4, a partition after it, under 4 GiB left for XFS),
  it does nothing and the server boots on ext4, as created; a failure
  up to the copy into XFS also boots on ext4. Past the copy, a cut boot
  resumes where it was on the next one.
- **XFS against ext4:** about the same for a site. On a small
  DigitalOcean server, random writes like a database's were 20% faster,
  unpacking 34,000 small files 10% slower and deleting them 2.5 s
  against 1.

## Steps

| Step       | What it does |
| ---------- | ------------ |
| `base`     | Installs ca-certificates, curl, git, jq, openssh-client, openssl, unattended-upgrades and sudo, on Ubuntu `coreutils-from-gnu` (devopsy's scripts expect GNU's coreutils, which Ubuntu may replace with Rust's), plus `DEVOPSY_APT_PACKAGES`. Turns off systemd-resolved's LLMNR and multicast DNS, name lookups on the local network that a server never needs (Debian's answers LLMNR on port 5355 of every address). Frees the memory the kernel keeps for kexec, which a server never uses, from the next reboot: `kho=off` where a kernel turns Kexec HandOver on by default (Ubuntu 26.04's keeps up to 1.25 of 2 GB for movable pages only), and no crash kernel where kdump-tools reserves one (Vultr's Ubuntu: 320 MB), kdump-tools disabled. |
| `swap`     | Creates `/swapfile` of `DEVOPSY_SWAP` if the server has no swap. |
| `docker`   | Docker Engine with the Buildx and Compose plugins, from Docker's apt repository, and `apparmor`, so Docker confines containers with its default profile where the kernel has AppArmor (Debian's and Ubuntu's do; a rerun restarts a daemon that started without it). Rotated logs, `live-restore` and /24 address pools. Socket buffers of 7.5 MB (`net.core.rmem_max`, `wmem_max`), what a Cloudflare Tunnel's connector asks for. |
| `user`     | Creates the deploy user in the `docker` group, copies root's SSH authorized keys to it, and with `DEVOPSY_ROOT` gives it that directory for releases. |
| `upgrades` | Daily unattended security upgrades, with an optional reboot time. |
| `cli`      | Installs `devopsy` in `/usr/local/lib/devopsy`, owned by the deploy user and linked from `/usr/local/bin`; a rerun upgrades it. |

## Settings

| Variable                   | Default | |
| -------------------------- | ------- | - |
| `DEVOPSY_USER`             | `devopsy` | The deploy user. |
| `DEVOPSY_SUDO`             | `0`     | `1` gives the deploy user passwordless sudo. |
| `DEVOPSY_APT_PACKAGES`     |         | Extra apt packages, space separated, like `htop ncdu`. Removing one from the list does not uninstall it. |
| `DEVOPSY_SWAP`             |         | Swap file size, like `2G` (see "Swap" below). |
| `DEVOPSY_AUTO_REBOOT_TIME` |         | Reboot after upgrades that need it, at this time, like `04:00`. |
| `DEVOPSY_ADDRESS_POOLS`    | `172.16.0.0/12 192.168.0.0/16` | Ranges Docker cuts into /24 networks, space separated, each /24 or larger. |
| `DEVOPSY_ROOT`             |         | Where releases live, like `/srv` on a block volume; default the deploy user's home. Written as `releases: root` in the deploy user's `~/.config/devopsy/config.yaml` (devopsy-cli's README, "Release settings"); a file there that devopsy-server did not write is left alone. |
| `DEVOPSY_FORCE`            | `0`     | `1` to run on something other than Debian 13 or Ubuntu 26.04. Not saved. |

Traefik's settings (ACME email, resolvers, the wildcard domain) are
devopsy-template-traefik's; see its README.

## Without the script

The same steps by hand, as root, for a fresh server: to see what the
script does, to set up another distribution, or to put it in your own
tooling. The commands use the default settings; optional ones are marked.
They are not idempotent, unlike the script, but running `setup.sh` later
adopts the result.

### base

```sh
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ca-certificates curl git jq openssh-client openssl unattended-upgrades sudo
# Ubuntu only: GNU's coreutils, in place of Rust's uutils
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  --allow-remove-essential coreutils-from-gnu coreutils-from-uutils-

mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nLLMNR=no\nMulticastDNS=no\n' > /etc/systemd/resolved.conf.d/90-devopsy.conf
systemctl try-restart systemd-resolved
```

`ss -ltun 'sport = :5355'` then lists nothing: LLMNR is closed.

Where `grep -sx CONFIG_KEXEC_HANDOVER_ENABLE_DEFAULT=y /boot/config-*`
finds a kernel (Ubuntu 26.04's), or `/etc/default/grub.d/kdump-tools.cfg`
is there (kdump), the kernel's arguments, applied by the next reboot
(leave out the line that does not apply):

```sh
cat > /etc/default/grub.d/zz-devopsy.cfg <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT=$(echo "$GRUB_CMDLINE_LINUX_DEFAULT" | sed "s/crashkernel=[^ ]*//g")
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT kho=off"
EOF
update-grub
systemctl disable kdump-tools   # with kdump only
```

After the reboot `grep CMA /proc/pagetypeinfo` shows no CMA blocks and
`cat /sys/kernel/kexec_crash_size` says 0.

### swap

Only when `swapon --show` prints nothing (many cloud images have none).
How much:

- Up to 2 GB of RAM: as much as the RAM.
- 4 to 8 GB: `2G`.
- More: optional.

Build mode builds images on the server (composer, npm), which takes more
memory than serving: swap keeps a build from being killed, but a server
that swaps while serving needs more RAM.

```sh
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
echo 'vm.swappiness = 10' > /etc/sysctl.d/90-devopsy-swap.conf
sysctl -p /etc/sysctl.d/90-devopsy-swap.conf

```

### docker

```sh
. /etc/os-release
install -d -m 755 /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$ID
Suites: $VERSION_CODENAME
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  apparmor docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  },
  "live-restore": true,
  "default-address-pools": [
    {"base": "172.16.0.0/12", "size": 24},
    {"base": "192.168.0.0/16", "size": 24}
  ]
}
EOF
systemctl restart docker
systemctl enable docker

printf 'net.core.rmem_max = 7500000\nnet.core.wmem_max = 7500000\n' > /etc/sysctl.d/90-devopsy-net.conf
sysctl -p /etc/sysctl.d/90-devopsy-net.conf

```

Rotated logs keep containers from filling the disk, and `live-restore`
keeps them running while Docker upgrades. Address pools: see "Docker
networks" below. The socket buffers are for QUIC: a Cloudflare Tunnel's
connector (`cloudflared`) asks the kernel for 7.5 MB and runs with
smaller buffers, warning, where the default maximum is about 200 KB; the
setting is the host's, containers get it, and it changes nothing without
a tunnel.

### user

```sh
useradd --create-home --shell /bin/bash devopsy
usermod -aG docker devopsy
install -d -m 700 -o devopsy -g devopsy /home/devopsy/.ssh
install -m 600 -o devopsy -g devopsy /root/.ssh/authorized_keys /home/devopsy/.ssh/

```

Optional, passwordless sudo (`DEVOPSY_SUDO=1`). The `docker` group is
root-equivalent already; this only saves going through root's login:

```sh
echo 'devopsy ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-devopsy
chmod 440 /etc/sudoers.d/90-devopsy

```

Optional, releases elsewhere than the home (`DEVOPSY_ROOT`), like a block
volume mounted on `/srv` (see "A block volume" below):

```sh
install -d -o devopsy -g devopsy /srv
install -d -m 755 -o devopsy -g devopsy /home/devopsy/.config /home/devopsy/.config/devopsy
printf 'releases:\n  root: /srv\n' > /home/devopsy/.config/devopsy/config.yaml
chown devopsy:devopsy /home/devopsy/.config/devopsy/config.yaml

```

`setup.sh` leaves this file alone afterwards, since it did not write it.

### upgrades

```sh
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades

```

Optional, a reboot when an upgrade needs one (`DEVOPSY_AUTO_REBOOT_TIME`),
in the server's quietest hour. Without it, a kernel update waits for a
reboot by hand:

```sh
cat > /etc/apt/apt.conf.d/52devopsy-reboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

```

### cli

```sh
install -d -m 755 -o devopsy -g devopsy /usr/local/lib/devopsy
cd / && curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-cli/main/install.sh \
  | runuser -u devopsy -- env DEVOPSY_INSTALL_DIR=/usr/local/lib/devopsy sh
ln -s /usr/local/lib/devopsy/devopsy /usr/local/bin/devopsy

```

Check: `runuser -u devopsy -- docker ps` and `runuser -u devopsy --
devopsy --version`.

## Deploying from CI

Nothing here makes keys. From your machine, `devopsy --ssh-keys-generate`
makes a pair and `devopsy @<target> --ssh-keys add ~/.ssh/devopsy-ci.pub
--restricted` authorizes it for the deploy user, without root;
`--ssh-keys` lists and removes keys (devopsy-cli's README, "Keys on a
server").

For CI's known hosts file, run `ssh-keyscan <server>` from your machine
and check its fingerprints against the server's own:

```sh
for key in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$key"; done
```

## Things to know

What a devopsy server is protected by, and what stays yours. This is the
host's half; what Cloudflare's edge covers for sites served through a
tunnel, and what it does not, is the Traefik template's README, ["Behind
a Cloudflare
Tunnel"](https://github.com/hanoii/devopsy-template-traefik#behind-a-cloudflare-tunnel).

- **The firewall is your provider's.** Open inbound only what the
  server serves: SSH; 80 and 443 only for sites served directly, so on a
  server whose sites all go through a Cloudflare Tunnel, SSH alone; 53,
  UDP and TCP, only if the server runs the Traefik template's acme-dns.
  A tunnel connects out, to port 7844 (UDP for QUIC, else TCP), which
  providers' firewalls allow by default. A host firewall like ufw would
  not help: Docker opens published ports past it. Only Traefik publishes
  ports (and acme-dns, with it); publish anything else on `127.0.0.1` and
  reach it through an SSH tunnel. Of the host's own services only SSH
  listens publicly: the `base` step closes systemd-resolved's LLMNR
  (5355), which Debian leaves open on every address.
- **SSH is left alone, and whoever has a key has the server.** `setup.sh`
  never changes the SSH server: set it up as your provider does, with key
  login only, and check it (`sshd -T | grep -i passwordauthentication`
  says `no`). The deploy user is in the `docker` group, which is root
  through Docker, and it got root's authorized keys at setup. From then
  on `devopsy @<server> --ssh-keys` lists, adds and removes its keys from
  your machine; a machine's key (CI) gets `add --restricted`, which
  allows commands only, no shell (devopsy-cli's README, "Keys on a
  server"). Nothing on the server knows your repository: releases are
  pushed over SSH, and nothing listens for webhooks.
- **The distribution's security updates install themselves,** daily
  (unattended-upgrades). A kernel update waits for a reboot by hand
  unless `DEVOPSY_AUTO_REBOOT_TIME` is set. Docker is upgraded by a rerun
  of setup or `apt upgrade`, with `live-restore` keeping containers
  running meanwhile. The deploy user owns `devopsy`, so
  `devopsy @<server> --upgrade` upgrades it from your machine, without
  root (`--upgrade vX.Y.Z` for a given release); a rerun of setup
  upgrades it to the latest. Commands refuse a server whose devopsy is
  too old for yours, and say so.
- **Containers run without privilege, by the templates' rules.** Every
  service in the devopsy templates runs as a fixed non-root UID (apps as
  10001, shared by all projects; never 1000, the deploy user's), with a
  read-only root filesystem, every capability dropped (one added back
  only with a stated reason) and `no-new-privileges`; the data a service
  writes is its own directory under `mnt`, given to its UID by devopsy.
  Docker confines them with its `docker-default` AppArmor profile where
  the kernel has AppArmor (Debian's and Ubuntu's do; some cloud kernels
  and OrbStack do not; `docker inspect -f '{{.AppArmorProfile}}'
  <container>` shows it; a server set up before the script installed
  `apparmor` gets a Docker restart on its next rerun, said, and running
  containers stay unconfined until they next start). These are the
  templates' conventions, not something devopsy enforces: a project of
  your own decides for itself. Projects on one server trust each other
  (they share the `traefik` network, and anyone in the `docker` group is
  root); separation between clients means separate servers.
- **Data and secrets are the server's until you copy them off.**
  `devopsy @<target> --snapshot` takes an environment's data, code and
  the images it ran as one consistent copy; keep them on another disk with the
  server's `snapshots: root` (the deploy user's
  `~/.config/devopsy/config.yaml`; with `DEVOPSY_ROOT` set, that file is
  setup's while its first line says so, so drop that line before adding
  to it and set `releases: root` yourself), or send one off the server
  (`--snapshots export <id> | ...`). A snapshot carries the environment's
  `shared/.env`, where its secrets live (a database password a release
  generated no longer matches the database without it); without
  snapshots, back up `shared/.env`, `shared/mnt` (databases as dumps)
  and `.devopsy-data-images` beside them. Your provider's disk backups
  restore the whole server as on any other, the XFS root included.
- **An environment nobody releases gets no fixes.** Images float on
  their series (`mariadb:11.8`, `traefik:v3.7`) and are pulled again
  only by a release, so an environment left alone for weeks runs what it
  pulled last: release each, Traefik included, on a schedule from CI
  with the restricted key (devopsy-cli's README, "Environments nobody
  releases").
- **What stays yours:** the private keys (on laptops and in CI's
  protected variables), the provider's and Cloudflare's accounts (second
  factor on both: one holds the disks, the other DNS and the tunnel), a
  tunnel's token (it runs the tunnel; rotate it from the dashboard), and
  the applications themselves: devopsy updates nothing in your code, and
  a site's own bugs are reachable through a tunnel as they are through a
  port.
- **A block volume.** Providers mount volumes elsewhere (DigitalOcean:
  `/mnt/<volume>`). Mount it where releases should live, like `/srv`, set
  `DEVOPSY_ROOT=/srv`, and add `RequiresMountsFor=/srv` to a
  `docker.service.d` drop-in, so containers never start before it. The
  home directory, with `.ssh`, stays off the volume. Docker's named
  volumes stay on the root disk.
- **Docker networks.** Docker's default pools allow about 30 networks per
  host, and every project environment takes at least one. Cut into /24s,
  the same ranges give thousands. Existing networks keep their size until
  recreated (`devopsy down`, then `up`). Where the server must reach hosts
  in these ranges (a corporate network on `172.16.0.0/12`), set
  `DEVOPSY_ADDRESS_POOLS` to ranges nobody uses.

## License

GPL-3.0. See [LICENSE](LICENSE).
