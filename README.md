# devopsy-server

Sets up a fresh Debian 13 or Ubuntu 26.04 server as a host for
[devopsy](https://github.com/hanoii/devopsy-cli): Docker, a deploy user,
automatic security upgrades and devopsy itself. Projects are then released
onto it with devopsy, starting with
[Traefik](https://github.com/hanoii/devopsy-template-traefik).

## A new server

A new server can start on XFS: create it with
[`cloud-init.yaml`](cloud-init.yaml) as its user data, and on its first
boots it converts the root from ext4 to XFS, in about three minutes and
two reboots of its own, before `setup.sh` runs. It is tried on
DigitalOcean droplets and Vultr instances, with their Debian 13 and
Ubuntu 26.04 images; [An XFS root](docs/xfs.md) has the steps for each.

> [!TIP]
> XFS copies files with reflinks, so a copy of data on the server (an
> environment's, with its database) takes seconds at any size. The
> conversion is only for a new server, before anything is on its disk.

## Usage

> [!NOTE]
> To set up a server by hand instead, [Without the
> script](docs/without-the-script.md) has the same steps, run as root.

As root on the server:

```sh
curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-server/main/setup.sh | bash
```

It asks for the deploy user, a swap file and a time to reboot after
upgrades that need it. Where the image has kdump, it also asks whether to
keep kdump's memory. Each question shows a default in brackets, which
Enter keeps.

Next, from your machine, run devopsy-cli's
[`--server-setup`](https://github.com/hanoii/devopsy-cli/blob/main/docs/servers.md#--server-setup)
as the deploy user. It asks before it changes what someone else set.
`setup.sh` prints this command at its end but does not run it:

```sh
devopsy @devopsy@<server>: --server-setup
```

A server with project users needs `sudo` and `acl` installed, then
devopsy's `--project-users setup` (devopsy-cli's [Project
users](https://github.com/hanoii/devopsy-cli/blob/main/docs/project-users.md)).

Then release Traefik to the server from a devopsy-template-traefik
checkout (`devopsy @<server>:prod setup`; see the Setup section of its
README), and your projects after it.

## Reruns

Run the same command again to upgrade or to change a setting. Every step
is idempotent. A rerun upgrades what the script installed (its apt
packages, Docker and devopsy) and asks the questions again, with the
server's saved answers as defaults. It leaves no command on the server.

Without a terminal (cloud-init, CI), or with `--yes`, it asks nothing and
uses the saved values, or the defaults where none are saved. A setting
given as a variable is used as given, not asked, and saved like an
answer. On a distribution other than Debian 13 or Ubuntu 26.04 it asks
whether to go on, and without a terminal stops unless
`DEVOPSY_SERVER_FORCE=1`. `--help` lists the settings and the values saved
in `/etc/devopsy/server.env`:

```sh
curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-server/main/setup.sh | bash -s -- --yes
curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-server/main/setup.sh | DEVOPSY_SERVER_SWAP=2G bash
curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-server/main/setup.sh | bash -s -- --help
```

## Settings

| Variable                          | Default   | |
| --------------------------------- | --------- | - |
| `DEVOPSY_SERVER_USER`             | `devopsy` | The deploy user, the one devopsy logs in as. Asked on the first run only, and never changed after it. |
| `DEVOPSY_SERVER_SWAP`             | by memory | Size of `/swapfile`, like `2G` or `512M`, or `none`. A new size resizes it with the swap kept on, which takes room on `/` for a second file of the new size while it runs; a size the disk cannot hold is asked again. `none` removes the one `setup.sh` made. By default: as much as the memory up to 2.5 GB, `2G` up to 8.5 GB, none above that. A server with a swap of its own is offered none and keeps it; a size given takes over its `/swapfile`, if that is what it has. |
| `DEVOPSY_SERVER_AUTO_REBOOT_TIME` | `never`   | Reboot after upgrades that need it, at this time, like `04:00`. |
| `DEVOPSY_SERVER_KDUMP`            | `on`      | `off` frees the memory kdump keeps for a crash kernel and disables kdump-tools, both from the next reboot. `on` puts both back. Asked only where the image has kdump-tools. |
| `DEVOPSY_SERVER_FORCE`            | `0`       | `1` runs on a distribution other than Debian 13 or Ubuntu 26.04 without asking. Not saved. |

## Steps

| Step       | What it does |
| ---------- | ------------ |
| `base`     | Installs the tools devopsy uses, ssh, curl and unattended-upgrades, and on Ubuntu GNU's coreutils. Turns off systemd-resolved's LLMNR and multicast DNS. Frees the memory kept for kexec, from the next reboot ([Memory for kexec](docs/things-to-know.md#memory-for-kexec)). |
| `swap`     | Makes, resizes or removes `/swapfile`. |
| `docker`   | Installs Docker Engine with the Buildx and Compose plugins from Docker's apt repository, and `apparmor`. |
| `user`     | Creates the deploy user in the `docker` group, with root's SSH authorized keys. |
| `upgrades` | Turns on daily unattended security upgrades, and the reboot after them at the time set. |
| `cli`      | Installs devopsy in `/usr/local/lib/devopsy`, owned by the deploy user and linked from `/usr/local/bin`; a rerun upgrades it. |

## More

- [An XFS root](docs/xfs.md): `cloud-init.yaml`, converting a new server's root to XFS for reflink copies.
- [Without the script](docs/without-the-script.md): the same steps by hand, as root.
- [Things to know](docs/things-to-know.md): what protects a devopsy server and what stays yours, memory for kexec, block volumes, Docker networks.

## License

GPL-3.0. See [LICENSE](LICENSE).
