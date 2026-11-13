# Things to know

This page covers what protects a devopsy host and what stays yours. For
what Cloudflare's edge does and does not cover on sites served through a
tunnel, see the Traefik template's ["Behind a Cloudflare
Tunnel"](https://github.com/hanoii/devopsy-template-traefik/blob/main/docs/tunnel.md).

## Firewall

The firewall is your provider's. Open inbound only what the server serves:

- SSH;
- 80 and 443, only for sites served directly; a server whose sites all go
  through a Cloudflare Tunnel needs SSH alone;
- 53, UDP and TCP, only if the server runs the Traefik template's
  acme-dns.

A tunnel connects out, to port 7844 (UDP for QUIC, else TCP), which
providers' firewalls allow by default.

A host firewall like ufw does not help: Docker opens published ports past
it. Only Traefik and its acme-dns publish ports. Publish anything else on
`127.0.0.1` and reach it through an SSH tunnel.

Of the host's own services, only SSH listens publicly. The `llmnr` step
closes systemd-resolved's LLMNR (port 5355), which Debian leaves open on
every address, unless `DEVOPSY_SERVER_LLMNR=on`.

A container reaches any service of the host's that listens beyond
loopback, through its bridge, whatever the provider's firewall lets in. A
service of the host's that containers must not reach listens on
`127.0.0.1` only.

devopsy's `--server-setup` loads a firewall of its own, which filters no
inbound traffic. It keeps containers off the cloud's metadata services,
where an app could read its instance's credentials, their DNS aside
(devopsy-cli's [`--server-setup`](https://github.com/hanoii/devopsy-cli/blob/main/docs/servers.md#--server-setup)).

## SSH and keys

`setup.sh` never changes the SSH server's configuration. Allow key login
only, as your provider sets it up, and check it: `sshd -T | grep -i
passwordauthentication` says `no`.

The `docker` group is root through Docker, and the deploy user is in it,
so whoever holds one of its keys has the server. The deploy user got
root's authorized keys at setup. `devopsy @<server> --ssh-keys` lists,
adds and removes its keys from your machine. A machine's key (CI) gets
`add --restricted`, which allows commands only and no shell (devopsy-cli's
[Keys on a
server](https://github.com/hanoii/devopsy-cli/blob/main/docs/servers.md#keys-on-a-server)).

The server holds no clone, URL or deploy key of your repository. Releases
are pushed over SSH, and nothing listens for webhooks.

## Other users' processes

Every user sees every process and its command line, unless `/proc` hides
them. On a server with devopsy-cli's [project
users](https://github.com/hanoii/devopsy-cli/blob/main/docs/project-users.md),
its `--project-users setup` hides them; on any other server, `devopsy
--server-setup-howto processes` prints the steps. Either way root and the
deploy user still see every process, and containers keep their own
process list.

## Security updates

unattended-upgrades installs the distribution's security updates daily. A
kernel update waits for a reboot by hand unless a reboot time is set
(`DEVOPSY_SERVER_AUTO_REBOOT_TIME`).

A rerun of setup or `apt upgrade` upgrades Docker. `live-restore`, which
devopsy's `--server-setup` sets, keeps containers running during the
upgrade.

The deploy user owns `devopsy`, so `devopsy @<server> --upgrade` upgrades
it from your machine, without root (`--upgrade vX.Y.Z` for a given
release). A rerun of setup upgrades it to the latest. Commands refuse a
server whose devopsy is too old for yours, and say why.

## Memory for kexec

The `kexec` step adds `kho=off` to the kernel's command line on every
server. It frees the memory the kernel keeps for Kexec HandOver, which a
server does not use. Ubuntu 26.04's kernel turns Kexec HandOver on and
keeps up to 1.25 of 2 GB for it. That memory takes movable pages only, so
page tables, slab and socket buffers cannot use it. A kernel without Kexec
HandOver ignores the argument.

With `DEVOPSY_SERVER_KDUMP=off`, where the image has kdump-tools,
`setup.sh` also frees the memory kept for a crash kernel (Vultr's Ubuntu:
320 MB) and disables kdump-tools. `on` puts both back.

Both apply at the next reboot. `setup.sh` never reboots. It asks for a
reboot as a kernel update does (`/run/reboot-required`), only when the
reboot frees memory or brings kdump back, and unattended-upgrades reboots
at the time set. It writes the same files as devopsy-cli's
`--server-setup-howto kexec-handover` and `kdump`.

## Containers

Every service in the devopsy templates runs without privilege:

- as the uid devopsy gives its environment (`DEVOPSY_UID`, devopsy-cli's
  [Configuration](https://github.com/hanoii/devopsy-cli/blob/main/docs/config.md)),
  which no other environment's containers run as;
- with a read-only root filesystem;
- with every capability dropped, one added back only with a stated
  reason;
- with `no-new-privileges`.

The data a service writes is a directory of its own under `mnt`, which
devopsy gives to its uid. devopsy does not enforce these conventions, so
a project you write yourself sets its own.

Docker confines containers with its `docker-default` AppArmor profile
where the kernel has AppArmor. Debian's and Ubuntu's kernels do; some
cloud kernels and OrbStack do not. `docker inspect -f
'{{.AppArmorProfile}}' <container>` shows it. On a server set up before
the script installed `apparmor`, the next rerun restarts Docker and says
so. Running containers stay unconfined until they start again.

Projects on one server trust each other: they share the `traefik`
network, and anyone in the `docker` group is root. Clients kept apart need
servers of their own.

## Data and secrets

An environment's data and secrets stay on the server until you copy them
off.

`devopsy @<target> --snapshot` takes one consistent copy of an
environment's data, code, secrets and the images it ran. You can keep it
on another disk or send it off the server (devopsy-cli's
[Snapshots](https://github.com/hanoii/devopsy-cli/blob/main/docs/snapshots.md)).
To back up without snapshots, see what to copy in devopsy-cli's
[Data](https://github.com/hanoii/devopsy-cli/blob/main/docs/data.md).
Keep the environment's `shared/.env` with its data: a database password a
release generated is there, and without it no longer matches the
database.

Your provider's disk backups restore the whole server, the XFS root
included.

## Image updates

Images float on their series (`mariadb:11.8`, `traefik:v3.7`) and are
pulled again only by a release, so an environment nobody releases gets no
fixes. Release every environment, Traefik too, on a schedule from CI with
the restricted key (devopsy-cli's [Environments nobody
releases](https://github.com/hanoii/devopsy-cli/blob/main/docs/servers.md#environments-nobody-releases)).

## What stays yours

- The private keys, on laptops and in CI's protected variables.
- The provider's and Cloudflare's accounts, with a second factor on both:
  one holds the disks, the other DNS and the tunnel.
- A tunnel's token, which runs the tunnel; rotate it from the dashboard.
- The applications themselves. devopsy updates nothing in your code, and
  a site's bugs are as reachable through a tunnel as through a port.

## A block volume

Providers mount volumes elsewhere (DigitalOcean: `/mnt/<volume>`).
Replace the provider's mount unit with one that mounts the volume where
releases should live, like `/srv`, and make that the release root
(devopsy-cli's [Release
settings](https://github.com/hanoii/devopsy-cli/blob/main/docs/config.md#release-settings)).

devopsy's `--server-setup` then makes the directory if it is missing, and
gives it to the deploy user if root owns it and it is empty (a fresh
volume's `lost+found` aside). It refuses a directory root owns that holds
files, and one another user owns.

It also adds a `docker.service.d` drop-in with `RequiresMountsFor=` set to
the release root, so Docker never starts without the volume. Containers
starting before the volume would write their bind mounts to the root disk,
where the volume then hides them. An fstab `x-systemd.before=docker.service`
is not enough: it orders Docker after the mount, but Docker still starts
when the volume is missing.

The home directory, with `.ssh`, stays off the volume. Docker's named
volumes stay on the root disk.

## Docker networks

Docker's default pools allow about 30 networks per host, and every
project environment takes at least one. devopsy's `--server-setup` cuts
the same ranges into /24s, which allow thousands of networks. Existing
networks keep their size until recreated (`devopsy down`, then `up`).

Where the server must reach hosts in these ranges (a corporate network on
`172.16.0.0/12`), write ranges nobody uses in `daemon.json`'s
`default-address-pools`. `--server-setup` asks once whether to keep them,
and asks again only when they change.
