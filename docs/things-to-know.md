# Things to know

What a devopsy server is protected by, and what stays yours. This is the
host's half; what Cloudflare's edge covers for sites served through a
tunnel, and what it does not, is the Traefik template's ["Behind
a Cloudflare
Tunnel"](https://github.com/hanoii/devopsy-template-traefik/blob/main/docs/tunnel.md).

## The firewall is your provider's

Open inbound only what the server serves: SSH; 80 and 443 only for sites served directly, so on a server whose sites all go through a Cloudflare Tunnel, SSH alone; 53, UDP and TCP, only if the server runs the Traefik template's acme-dns. A tunnel connects out, to port 7844 (UDP for QUIC, else TCP), which providers' firewalls allow by default. A host firewall like ufw would not help: Docker opens published ports past it. Only Traefik publishes ports (and acme-dns, with it); publish anything else on `127.0.0.1` and reach it through an SSH tunnel. Of the host's own services only SSH listens publicly: the `base` step closes systemd-resolved's LLMNR (5355), which Debian leaves open on every address.

## SSH is left alone, and whoever has a key has the server

`setup.sh` never changes the SSH server: set it up as your provider does, with key login only, and check it (`sshd -T | grep -i passwordauthentication` says `no`). The deploy user is in the `docker` group, which is root through Docker, and it got root's authorized keys at setup. From then on `devopsy @<server> --ssh-keys` lists, adds and removes its keys from your machine; a machine's key (CI) gets `add --restricted`, which allows commands only, no shell (devopsy-cli's [Keys on a server](https://github.com/hanoii/devopsy-cli/blob/main/docs/servers.md#keys-on-a-server)). Nothing on the server knows your repository: releases are pushed over SSH, and nothing listens for webhooks.

## Security updates

The distribution's security updates install themselves daily (unattended-upgrades). A kernel update waits for a reboot by hand unless `DEVOPSY_AUTO_REBOOT_TIME` is set. Docker is upgraded by a rerun of setup or `apt upgrade`, with `live-restore` keeping containers running meanwhile. The deploy user owns `devopsy`, so `devopsy @<server> --upgrade` upgrades it from your machine, without root (`--upgrade vX.Y.Z` for a given release); a rerun of setup upgrades it to the latest. Commands refuse a server whose devopsy is too old for yours, and say so.

## Containers run without privilege, by the templates' rules

Every service in the devopsy templates runs as a fixed non-root UID (apps as 10001, shared by all projects; never 1000, the deploy user's), with a read-only root filesystem, every capability dropped (one added back only with a stated reason) and `no-new-privileges`; the data a service writes is its own directory under `mnt`, given to its UID by devopsy. Docker confines them with its `docker-default` AppArmor profile where the kernel has AppArmor (Debian's and Ubuntu's do; some cloud kernels and OrbStack do not; `docker inspect -f '{{.AppArmorProfile}}' <container>` shows it; a server set up before the script installed `apparmor` gets a Docker restart on its next rerun, said, and running containers stay unconfined until they next start). These are the templates' conventions, not something devopsy enforces: a project of your own decides for itself. Projects on one server trust each other (they share the `traefik` network, and anyone in the `docker` group is root); separation between clients means separate servers.

## Data and secrets are the server's until you copy them off

`devopsy @<target> --snapshot` takes an environment's data, code and the images it ran as one consistent copy; keep them on another disk with the server's `snapshots: root` (the deploy user's `~/.config/devopsy/config.yaml`; with `DEVOPSY_ROOT` set, that file is setup's while its first line says so, so drop that line before adding to it and set `releases: root` yourself), or send one off the server (`--snapshots export <id> | ...`). A snapshot carries the environment's `shared/.env`, where its secrets live (a database password a release generated no longer matches the database without it); without snapshots, back up `shared/.env`, `shared/mnt` (databases as dumps) and `.devopsy-data-images` beside them. Your provider's disk backups restore the whole server as on any other, the XFS root included.

## An environment nobody releases gets no fixes

Images float on their series (`mariadb:11.8`, `traefik:v3.7`) and are pulled again only by a release, so an environment left alone for weeks runs what it pulled last: release each, Traefik included, on a schedule from CI with the restricted key (devopsy-cli's [Environments nobody releases](https://github.com/hanoii/devopsy-cli/blob/main/docs/servers.md#environments-nobody-releases)).

## What stays yours

The private keys (on laptops and in CI's protected variables), the provider's and Cloudflare's accounts (second factor on both: one holds the disks, the other DNS and the tunnel), a tunnel's token (it runs the tunnel; rotate it from the dashboard), and the applications themselves: devopsy updates nothing in your code, and a site's own bugs are reachable through a tunnel as they are through a port.

## A block volume

Providers mount volumes elsewhere (DigitalOcean:
  `/mnt/<volume>`). Mount it where releases should live, like `/srv`, set
  `DEVOPSY_ROOT=/srv`, and add `RequiresMountsFor=/srv` to a
  `docker.service.d` drop-in, so containers never start before it. The
  home directory, with `.ssh`, stays off the volume. Docker's named
  volumes stay on the root disk.
## Docker networks

Docker's default pools allow about 30 networks per
  host, and every project environment takes at least one. Cut into /24s,
  the same ranges give thousands. Existing networks keep their size until
  recreated (`devopsy down`, then `up`). Where the server must reach hosts
  in these ranges (a corporate network on `172.16.0.0/12`), set
  `DEVOPSY_ADDRESS_POOLS` to ranges nobody uses.

