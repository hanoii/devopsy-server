# devopsy-server

Turns a fresh Debian 13 server into a devopsy host: Docker, a deploy user,
automatic security upgrades and the
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
curl -fsSL .../setup.sh | DEVOPSY_SWAP=2G DEVOPSY_ROOT=/srv bash
curl -fsSL .../setup.sh | bash -s -- --help
```

They are saved to `/etc/devopsy/server.env`, so a rerun reuses them. Set
one again to replace it, or empty (`DEVOPSY_SWAP=`) to go back to its
default.

Rerun the same command at any time: every step is idempotent, and a rerun
upgrades what the script installed (its Debian packages, Docker and
devopsy). It leaves no command on the server.

## Steps

| Step       | What it does |
| ---------- | ------------ |
| `base`     | Installs ca-certificates, curl, git, jq, openssh-client, openssl, unattended-upgrades and sudo, plus `DEVOPSY_APT_PACKAGES`. |
| `swap`     | Creates `/swapfile` of `DEVOPSY_SWAP` if the server has no swap. |
| `docker`   | Docker Engine with the Buildx and Compose plugins, from Docker's apt repository, and `apparmor`, so Docker's default profile confines every container. Rotated logs, `live-restore` and /24 address pools. |
| `user`     | Creates the deploy user in the `docker` group, copies root's SSH authorized keys to it, and with `DEVOPSY_ROOT` gives it that directory for releases. |
| `upgrades` | Daily unattended security upgrades, with an optional reboot time. |
| `cli`      | Installs `devopsy` in `/usr/local/lib/devopsy`, owned by the deploy user and linked from `/usr/local/bin`; a rerun upgrades it. |

## Settings

| Variable                   | Default | |
| -------------------------- | ------- | - |
| `DEVOPSY_USER`             | `devopsy` | The deploy user. |
| `DEVOPSY_SUDO`             | `0`     | `1` gives the deploy user passwordless sudo. |
| `DEVOPSY_APT_PACKAGES`     |         | Extra Debian packages, space separated, like `htop ncdu`. Removing one from the list does not uninstall it. |
| `DEVOPSY_SWAP`             |         | Swap file size, like `2G` (see "Swap" below). |
| `DEVOPSY_AUTO_REBOOT_TIME` |         | Reboot after upgrades that need it, at this time, like `04:00`. |
| `DEVOPSY_ADDRESS_POOLS`    | `172.16.0.0/12 192.168.0.0/16` | Ranges Docker cuts into /24 networks, space separated, each /24 or larger. |
| `DEVOPSY_ROOT`             |         | Where releases live, like `/srv` on a block volume; default the deploy user's home. Written as `releases: root` in the deploy user's `~/.config/devopsy/config.yaml` (devopsy-cli's README, "Release settings"); a file there that devopsy-server did not write is left alone. |
| `DEVOPSY_FORCE`            | `0`     | `1` to run on something other than Debian 13. Not saved. |

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

```

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
install -d -m 755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
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

```

Rotated logs keep containers from filling the disk, and `live-restore`
keeps them running while Docker upgrades. Address pools: see "Docker
networks" below.

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

- **The deploy user is effectively root:** the `docker` group allows root
  access through Docker. Treat its keys accordingly.
- **The deploy user owns `devopsy`,** so `devopsy @<server> --upgrade`
  upgrades it from your machine, without root (`--upgrade vX.Y.Z` for a
  given release). A rerun of setup upgrades it to the latest. Commands
  refuse a server whose devopsy is too old for yours, and say so.
- **Firewall: your provider's,** allowing only SSH, 80 and 443. A host
  firewall like ufw would not help: Docker opens published ports past it.
  Only Traefik publishes ports; publish anything else on `127.0.0.1` and
  reach it through an SSH tunnel.
- **SSH is left alone:** set it up as your provider does, with key login.
- **A block volume.** Providers mount volumes elsewhere (DigitalOcean:
  `/mnt/<volume>`). Mount it where releases should live, like `/srv`, set
  `DEVOPSY_ROOT=/srv`, and add `RequiresMountsFor=/srv` to a
  `docker.service.d` drop-in, so containers never start before it. The
  home directory, with `.ssh`, stays off the volume.
- **Docker networks.** Docker's default pools allow about 30 networks per
  host, and every project environment takes at least one. Cut into /24s,
  the same ranges give thousands. Existing networks keep their size until
  recreated (`devopsy down`, then `up`). Where the server must reach hosts
  in these ranges (a corporate network on `172.16.0.0/12`), set
  `DEVOPSY_ADDRESS_POOLS` to ranges nobody uses.
- **Only Debian security updates are automatic.** Docker is upgraded by a
  rerun of setup or `apt upgrade`; `live-restore` keeps containers running
  meanwhile.

## License

GPL-3.0. See [LICENSE](LICENSE).
