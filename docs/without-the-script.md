# Without the script

These are the steps `setup.sh` runs, done by hand as root on a fresh
server: to see what it changes, to set up another distribution, or to put
them in your own tooling. The commands use the default settings, and
optional ones are marked. Unlike the script they are not idempotent, but
running `setup.sh` later takes their result over. What devopsy sets up
itself is not here: its two setups, run from your machine, are at the
[end](#then-devopsy).

## base

Any other list with an entry for Docker's repository goes first: apt
refuses every source while two lists of it name different keys.

```sh
for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
  if grep -qsE '^[[:space:]]*(deb(-src)?[[:space:]]|URIs:).*download\.docker\.com' "$f"; then rm -f "$f"; fi
done
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  tar util-linux bsdutils coreutils openssh-client ca-certificates curl unattended-upgrades
# Ubuntu only: GNU's coreutils, in place of Rust's uutils
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  --allow-remove-essential coreutils-from-gnu coreutils-from-uutils-
```

## llmnr

With `DEVOPSY_SERVER_LLMNR=off`, the default:

```sh
mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nLLMNR=no\nMulticastDNS=no\n' > /etc/systemd/resolved.conf.d/90-devopsy.conf
systemctl try-restart systemd-resolved
```

LLMNR is closed once `ss -ltun 'sport = :5355'` lists nothing.

## kexec

The kernel's arguments take effect at the next reboot ([Memory for
kexec](things-to-know.md#memory-for-kexec)). With
`DEVOPSY_SERVER_KDUMP=off`, and only where
`/etc/default/grub.d/kdump-tools.cfg` exists, also add the `crashkernel=`
drop-in and disable kdump-tools:

```sh
mkdir -p /etc/default/grub.d
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT kho=off"' > /etc/default/grub.d/zz-kho-off.cfg
# DEVOPSY_SERVER_KDUMP=off only: the next two lines
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT=$(echo "$GRUB_CMDLINE_LINUX_DEFAULT" | sed "s/crashkernel=[^ ]*//g")' > /etc/default/grub.d/zz-no-crashkernel.cfg
systemctl disable kdump-tools
update-grub
```

After the reboot `grep CMA /proc/pagetypeinfo` shows no CMA blocks, and
with kdump off `cat /sys/kernel/kexec_crash_size` says 0.

## swap

Only when `swapon --show` prints nothing (many cloud images have none).
The size `setup.sh` offers:

- Up to 2.5 GB of RAM: as much as the RAM.
- Up to 8.5 GB: `2G`.
- More: none.

In build mode images are built on the server (composer, npm), which takes
more memory than serving. Swap keeps a build from being killed; a server
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

The sysctl file also marks `/swapfile` as `setup.sh`'s, so a later run
may resize or remove it.

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
systemctl enable --now docker
```

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

Optional: a reboot when an upgrade needs one
(`DEVOPSY_SERVER_AUTO_REBOOT_TIME`), at the server's quietest hour.
Without it, a kernel update waits for a reboot by hand:

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

devopsy sets up the rest itself, from your machine, as the deploy user,
with devopsy-cli's
[`--server-setup`](https://github.com/hanoii/devopsy-cli/blob/main/docs/servers.md#--server-setup)
(Docker's `daemon.json` and the release root among what it sets). It is
the command `setup.sh` prints at its end:

```sh
devopsy @devopsy@<server>: --server-setup
```

A server with [project
users](https://github.com/hanoii/devopsy-cli/blob/main/docs/project-users.md)
needs `sudo` and `acl` installed (`devopsy --server-setup-howto
project-users` prints the steps), then `--project-users setup`:

```sh
devopsy @devopsy@<server>: --project-users setup
```
