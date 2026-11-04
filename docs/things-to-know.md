# Things to know

What a devopsy server is protected by, and what stays yours. This page
covers the host. What Cloudflare's edge covers for sites served through a
tunnel, and what it does not, is in the Traefik template's ["Behind a
Cloudflare
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

A host firewall like ufw would not help, since Docker opens published
ports past it. Only Traefik publishes ports (and acme-dns, with it).
Publish anything else on `127.0.0.1` and reach it through an SSH tunnel.

Of the host's own services, only SSH listens publicly. The `base` step
closes systemd-resolved's LLMNR (5355), which Debian leaves open on every
address.

## SSH and keys

`setup.sh` never changes the SSH server. Set it up as your provider does,
with key login only, and check it (`sshd -T | grep -i
passwordauthentication` says `no`).

The deploy user is in the `docker` group, which is root through Docker,
so whoever has one of its keys has the server. It got root's authorized
keys at setup. From then on, `devopsy @<server> --ssh-keys` lists, adds
and removes its keys from your machine. A machine's key (CI) gets `add
--restricted`, which allows commands only, no shell (devopsy-cli's [Keys
on a
server](https://github.com/hanoii/devopsy-cli/blob/main/docs/servers.md#keys-on-a-server)).

Nothing on the server refers to your repository: no clone, URL or deploy
key. Releases are pushed over SSH, and nothing listens for webhooks.

## Security updates

The distribution's security updates are installed daily by
unattended-upgrades. A kernel update waits for a reboot by hand unless
`DEVOPSY_AUTO_REBOOT_TIME` is set.

Docker is upgraded by a rerun of setup or `apt upgrade`, with
`live-restore` keeping containers running meanwhile.

The deploy user owns `devopsy`, so `devopsy @<server> --upgrade` upgrades
it from your machine, without root (`--upgrade vX.Y.Z` for a given
release). A rerun of setup upgrades it to the latest. Commands refuse a
server whose devopsy is too old for yours, and say so.

## Containers

Every service in the devopsy templates runs without privilege:

- as a fixed non-root UID: apps as 10001, shared by all projects, and
  never 1000, the deploy user's;
- with a read-only root filesystem;
- with every capability dropped, one added back only with a stated
  reason;
- with `no-new-privileges`.

The data a service writes is a directory of its own under `mnt`, which
devopsy gives to its UID. devopsy does not enforce these conventions: a
project you write yourself decides for itself.

Docker confines containers with its `docker-default` AppArmor profile
where the kernel has AppArmor. Debian's and Ubuntu's kernels do; some
cloud kernels and OrbStack do not. `docker inspect -f
'{{.AppArmorProfile}}' <container>` shows it. On a server set up before
the script installed `apparmor`, the next rerun restarts Docker and says
so, and running containers stay unconfined until they next start.

Projects on one server trust each other: they share the `traefik`
network, and anyone in the `docker` group is root. Separation between
clients means separate servers.

## Data and secrets

An environment's data and secrets stay on the server until you copy them
off.

`devopsy @<target> --snapshot` takes an environment's data, code and the
images it ran as one consistent copy. Keep snapshots on another disk with
the server's `snapshots: root`, in the deploy user's
`~/.config/devopsy/config.yaml`, or send one off the server
(`--snapshots export <id> | ...`).

With `DEVOPSY_ROOT` set, setup owns that config file while its first line
says so. To add to it, delete that line and set `releases: root`
yourself.

A snapshot carries the environment's `shared/.env`, where its secrets
live. Without that file, a database password a release generated no
longer matches the database. Without snapshots, back up `shared/.env`,
`shared/mnt` (databases as dumps) and `.devopsy-data-images` beside them.

Your provider's disk backups restore the whole server as on any other,
including the XFS root.

## Image updates

An environment nobody releases gets no fixes. Images float on their
series (`mariadb:11.8`, `traefik:v3.7`) and are pulled again only by a
release, so an environment left alone for weeks runs what it pulled last.
Release each one, Traefik too, on a schedule from CI with the restricted
key (devopsy-cli's [Environments nobody
releases](https://github.com/hanoii/devopsy-cli/blob/main/docs/servers.md#environments-nobody-releases)).

## What stays yours

- The private keys, on laptops and in CI's protected variables.
- The provider's and Cloudflare's accounts, with a second factor on both:
  one holds the disks, the other DNS and the tunnel.
- A tunnel's token, which runs the tunnel; rotate it from the dashboard.
- The applications themselves. devopsy updates nothing in your code, and
  a site's bugs are reachable through a tunnel as they are through a
  port.

## A block volume

Providers mount volumes elsewhere (DigitalOcean: `/mnt/<volume>`). Mount
it where releases should live, like `/srv`, set `DEVOPSY_ROOT=/srv`, and
add `RequiresMountsFor=/srv` to a `docker.service.d` drop-in, so
containers never start before it. The home directory, with `.ssh`, stays
off the volume. Docker's named volumes stay on the root disk.

## Docker networks

Docker's default pools allow about 30 networks per host, and every
project environment takes at least one. Cut into /24s, the same ranges
give thousands. Existing networks keep their size until recreated
(`devopsy down`, then `up`). Where the server must reach hosts in these
ranges (a corporate network on `172.16.0.0/12`), set
`DEVOPSY_ADDRESS_POOLS` to ranges nobody uses.
