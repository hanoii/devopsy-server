# Without the script

What `setup.sh` does, by hand, as root, for a fresh server: to see what
it changes, to set up another distribution, or to put it in your own
tooling. The commands use the default settings; optional ones are marked.
They are not idempotent, unlike the script, but running `setup.sh` later
adopts the result. What devopsy sets up itself is not here: its two
setups, run from your machine, [end](#then-devopsy) the page.

## base

```sh
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  tar util-linux bsdutils coreutils openssh-client ca-certificates curl unattended-upgrades
# Ubuntu only: GNU's coreutils, in place of Rust's uutils
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  --allow-remove-essential coreutils-from-gnu coreutils-from-uutils-

mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nLLMNR=no\nMulticastDNS=no\n' > /etc/systemd/resolved.conf.d/90-devopsy.conf
systemctl try-restart systemd-resolved
```

LLMNR is closed once `ss -ltun 'sport = :5355'` lists nothing.

The kernel's arguments, applied by the next reboot ([Memory for
kexec](things-to-know.md#memory-for-kexec)). With `DEVOPSY_SERVER_KDUMP=off`,
and only where `/etc/default/grub.d/kdump-tools.cfg` exists, also the
`crashkernel=` drop-in and kdump-tools:

```sh
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT kho=off"' > /etc/default/grub.d/zz-kho-off.cfg
# DEVOPSY_SERVER_KDUMP=off only
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT=$(echo "$GRUB_CMDLINE_LINUX_DEFAULT" | sed "s/crashkernel=[^ ]*//g")' > /etc/default/grub.d/zz-no-crashkernel.cfg
systemctl disable kdump-tools
update-grub
```

After the reboot `grep CMA /proc/pagetypeinfo` shows no CMA blocks and
`cat /sys/kernel/kexec_crash_size` says 0.

## swap

Only when `swapon --show` prints nothing (many cloud images have none).
How much, as `setup.sh` offers it:

- Up to 2.5 GB of RAM: as much as the RAM.
- Up to 8.5 GB: `2G`.
- More: none.

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

The sysctl file also tells `setup.sh` that `/swapfile` is its own, to
resize or remove.

## docker

```sh
for f in /etc/apt/sources.list.d/*; do if grep -qs download.docker.com "$f"; then rm -f "$f"; fi; done
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
systemctl enable --now docker
```

The first line removes any older list of Docker's repository: apt refuses
every source while two lists of it name different keys.

## user

```sh
useradd --create-home --shell /bin/bash devopsy
usermod -aG docker devopsy
install -d -m 700 -o devopsy -g devopsy /home/devopsy/.ssh
install -m 600 -o devopsy -g devopsy /root/.ssh/authorized_keys /home/devopsy/.ssh/
```

## upgrades

```sh
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades
```

Optional, a reboot when an upgrade needs one (`DEVOPSY_SERVER_AUTO_REBOOT_TIME`),
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

## Then devopsy

devopsy sets up the rest itself, from your machine, as the deploy user:
Docker's `daemon.json`, the release root and the rest of devopsy-cli's
[`--server-setup`](https://github.com/hanoii/devopsy-cli/blob/main/docs/servers.md#--server-setup),
the command `setup.sh` prints at its end:

```sh
devopsy @devopsy@<server>: --server-setup
```

A server with [project
users](https://github.com/hanoii/devopsy-cli/blob/main/docs/project-users.md)
then needs its `--project-users setup` too:

```sh
devopsy @devopsy@<server>: --project-users setup
```

