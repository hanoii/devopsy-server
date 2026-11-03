# Without the script

The same steps by hand, as root, for a fresh server: to see what the
script does, to set up another distribution, or to put it in your own
tooling. The commands use the default settings; optional ones are marked.
They are not idempotent, unlike the script, but running `setup.sh` later
adopts the result.

## base

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

LLMNR is closed once `ss -ltun 'sport = :5355'` lists nothing.

The kernel's arguments, applied by the next reboot. With
`DEVOPSY_KDUMP=off`, and only where `/etc/default/grub.d/kdump-tools.cfg`
exists, also the `crashkernel=` line and kdump-tools:

```sh
cat > /etc/default/grub.d/zz-devopsy.cfg <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT=$(echo "$GRUB_CMDLINE_LINUX_DEFAULT" | sed "s/crashkernel=[^ ]*//g")
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT kho=off"
EOF
update-grub
systemctl disable kdump-tools
```

After the reboot `grep CMA /proc/pagetypeinfo` shows no CMA blocks and
`cat /sys/kernel/kexec_crash_size` says 0.

## swap

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

## docker

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

# a new daemon.json; on one that exists, add or replace these four keys
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
keeps them running while Docker upgrades. For the address pools, see
["Docker networks"](things-to-know.md#docker-networks).

The socket buffers are for QUIC. A Cloudflare Tunnel's connector
(`cloudflared`) asks the kernel for 7.5 MB, and where the default
maximum is about 200 KB it runs with smaller buffers and warns. The
setting is host-wide, so containers get it, and it has no effect without
a tunnel.

## user

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
volume mounted on `/srv` (see ["A block volume"](things-to-know.md#a-block-volume)):

```sh
install -d -o devopsy -g devopsy /srv
install -d -m 755 -o devopsy -g devopsy /home/devopsy/.config /home/devopsy/.config/devopsy
printf 'releases:\n  root: /srv\n' > /home/devopsy/.config/devopsy/config.yaml
chown devopsy:devopsy /home/devopsy/.config/devopsy/config.yaml

```

`setup.sh` leaves this file alone afterwards, since it did not write it.

## upgrades

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

## cli

```sh
install -d -m 755 -o devopsy -g devopsy /usr/local/lib/devopsy
cd / && curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-cli/main/install.sh \
  | runuser -u devopsy -- env DEVOPSY_INSTALL_DIR=/usr/local/lib/devopsy sh
ln -s /usr/local/lib/devopsy/devopsy /usr/local/bin/devopsy

```

Check: `runuser -u devopsy -- docker ps` and `runuser -u devopsy --
devopsy --version`.

