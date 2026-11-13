# devopsy-server

Sets up a fresh Debian 13 or Ubuntu 26.04 server as a host for
[devopsy](https://github.com/hanoii/devopsy-cli): Docker, a deploy user,
automatic security upgrades and devopsy itself. Projects are then released
onto it with devopsy, starting with
[Traefik](https://github.com/hanoii/devopsy-template-traefik).

## A new server

If you're creating a new server, it can start on XFS. Give it
[`cloud-init.yaml`](cloud-init.yaml) as user data and it converts the
root from ext4 to XFS on its first boots. That takes about three
minutes and two reboots, all on its own, and then it's ready for
`setup.sh`. It's been tested on DigitalOcean droplets and Vultr
instances, with their Debian 13 and Ubuntu 26.04 images. [An XFS
root](docs/xfs.md) has the steps for each.

> [!TIP]
> XFS copies files with reflinks, so copying data on the server (say,
> an environment and its database) takes seconds, however big it is.
> The conversion only works on a new server, before anything is on the
> disk.

## Usage

> [!NOTE]
> Rather do it by hand? [Without the script](docs/without-the-script.md)
> has the same steps, to run as root.

As root on the server:

```sh
curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-server/main/setup.sh | bash
```

It first checks you want to go on, since it installs the base
packages, Docker and devopsy, and upgrades them on later runs. Then it
asks for the deploy user, the swap size, whether to turn off LLMNR and
multicast DNS, whether to install security updates automatically, and
when to reboot after upgrades that need it.
If the image has kdump, it also asks whether to keep the memory kdump
reserves. Each question shows its default; press Enter to keep it.

Then, from your own machine, run devopsy's
[`--server-setup`](https://github.com/hanoii/devopsy-cli/blob/main/docs/servers.md#--server-setup)
as the deploy user. It asks before changing anything someone else set.
`setup.sh` prints this command when it finishes, but doesn't run it for
you:

```sh
devopsy @devopsy@<server>: --server-setup
```

If the server will have project users, install `sudo` and `acl`, then
run devopsy's `--project-users setup` (see [Project
users](https://github.com/hanoii/devopsy-cli/blob/main/docs/project-users.md)).

After that, release Traefik from a checkout of devopsy-template-traefik
(`devopsy @<server>:prod setup`, explained in the Setup section of its
README), then your own projects.

## Reruns

To upgrade or change a setting, run the same command again. Every step
is safe to repeat. A rerun upgrades what the script installed (its apt
packages, Docker and devopsy) and asks the questions again, with your
saved answers as the defaults. The script doesn't leave a command of its
own on the server.

With `--yes`, or without a terminal (cloud-init, CI), it asks nothing:
it uses the saved values, or the defaults if nothing is saved yet. A
setting passed as a variable is used as is, without asking, and saved
like an answer. On a distribution other than Debian 13 or Ubuntu 26.04
it asks whether to carry on; without a terminal it stops, unless
`DEVOPSY_SERVER_FORCE=1` is set. `--help` lists the settings and the
values saved in `/etc/devopsy/server.env`:

```sh
curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-server/main/setup.sh | bash -s -- --yes
curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-server/main/setup.sh | DEVOPSY_SERVER_SWAP=2G bash
curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-server/main/setup.sh | bash -s -- --help
```

## Settings

| Variable                          | Default   | |
| --------------------------------- | --------- | - |
| `DEVOPSY_SERVER_USER`             | `devopsy` | The deploy user devopsy logs in as. Only asked on the first run, and never changed after that. |
| `DEVOPSY_SERVER_SWAP`             | by memory | Size of `/swapfile`, like `2G` or `512M`, or `none`. A new size resizes it without turning swap off, which needs room on `/` for a second file of the new size while it runs; if the disk can't fit it, you're asked again. `none` removes the swap file `setup.sh` made. The default goes by memory: the same as the memory up to 2.5 GB, `2G` up to 8.5 GB, and none above that. If the server already has a swap of its own, the default is none and it's left alone; giving a size takes over its `/swapfile`, if that's what it uses. |
| `DEVOPSY_SERVER_LLMNR`            | `off`     | `off` turns off LLMNR and multicast DNS in systemd-resolved, name lookups on the local network that a server doesn't need. `on` leaves them as the image has them. |
| `DEVOPSY_SERVER_UPGRADES`         | `on`      | `on` installs security updates automatically with unattended-upgrades. `off` turns that off again. |
| `DEVOPSY_SERVER_AUTO_REBOOT_TIME` | `never`   | When to reboot after upgrades that need it, like `04:00`. Not asked while upgrades are off, since nothing reboots on its own then. |
| `DEVOPSY_SERVER_KDUMP`            | `on`      | `off` frees the memory kdump reserves for a crash kernel and turns off kdump-tools, from the next reboot. `on` brings both back. Only asked if the image has kdump-tools. |
| `DEVOPSY_SERVER_FORCE`            | `0`       | `1` runs on a distribution other than Debian 13 or Ubuntu 26.04 without asking. Not saved. |

## Steps

| Step       | What it does |
| ---------- | ------------ |
| `base`     | Installs the tools devopsy uses, ssh, curl and unattended-upgrades, plus GNU coreutils on Ubuntu. |
| `llmnr`    | Turns off LLMNR and multicast DNS in systemd-resolved, or back on. |
| `kexec`    | Frees the memory reserved for kexec, from the next reboot ([Memory for kexec](docs/things-to-know.md#memory-for-kexec)). |
| `swap`     | Creates, resizes or removes `/swapfile`. |
| `docker`   | Installs Docker Engine with the Buildx and Compose plugins from Docker's apt repository, and `apparmor`. |
| `user`     | Creates the deploy user in the `docker` group and gives it root's SSH authorized keys. |
| `upgrades` | Turns on daily unattended security upgrades, and the reboot after them at the time you set, or turns them off. |
| `cli`      | Installs devopsy in `/usr/local/lib/devopsy`, owned by the deploy user and linked from `/usr/local/bin`; a rerun upgrades it. |

## More

- [An XFS root](docs/xfs.md): converting a new server's root to XFS with `cloud-init.yaml`, for reflink copies.
- [Without the script](docs/without-the-script.md): the same steps by hand, as root.
- [Things to know](docs/things-to-know.md): what protects a devopsy server and what's left to you, memory for kexec, block volumes, Docker networks.

## License

GPL-3.0. See [LICENSE](LICENSE).
