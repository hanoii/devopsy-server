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

Then run devopsy's own setup of the server from your machine, as the
deploy user (`devopsy`, unless `DEVOPSY_SERVER_USER` names another; devopsy-cli's
[`--server-setup`](https://github.com/hanoii/devopsy-cli/blob/main/docs/servers.md#--server-setup)):

```sh
devopsy @devopsy@<server>: --server-setup
```

It sets Docker's `daemon.json` (rotated logs, `live-restore`, /24 address
pools) and the socket buffers, makes the release root and has Docker wait
for it, and keeps containers off the cloud's metadata services, asking
before it changes what someone else set. `setup.sh` prints this command
at its end and does not run it.

Then release Traefik onto it from a devopsy-template-traefik checkout
(`devopsy @<server>:prod setup`; see its README's Setup section), and
your projects after it.

At a terminal it asks for each setting, the saved value or the default
in brackets, Enter keeping it, on every run: a rerun is where a setting
changes. Without a terminal (cloud-init, CI), or with `--yes`, it asks
nothing. A setting given as a variable is taken as it is and not asked.
`--help` lists them with the values this server has saved:

```sh
curl -fsSL .../setup.sh | bash -s -- --yes
curl -fsSL .../setup.sh | DEVOPSY_SERVER_SWAP=2G bash
curl -fsSL .../setup.sh | bash -s -- --help
```

They are saved to `/etc/devopsy/server.env`.

Rerun the same command at any time: every step is idempotent, and a rerun
upgrades what the script installed (its apt packages, Docker and
devopsy). It leaves no command on the server.

On a new server, `cloud-init.yaml` can first convert its root to XFS
([An XFS root](docs/xfs.md)).

## Steps

| Step       | What it does |
| ---------- | ------------ |
| `base`     | Installs the tools devopsy uses (tar, util-linux, bsdutils, coreutils), openssh-client, ca-certificates, curl and unattended-upgrades, on Ubuntu `coreutils-from-gnu` (devopsy's scripts expect GNU's coreutils, which Ubuntu may replace with Rust's). Turns off systemd-resolved's LLMNR and multicast DNS, local-network name lookups a server does not need; Debian's answers LLMNR on port 5355 of every address. Sets `kho=off` on every server, freeing the memory the kernel keeps for Kexec HandOver, which a server does not use. Ubuntu 26.04's kernel turns it on and keeps up to 1.25 of 2 GB for movable pages only, which page tables, slab and socket buffers cannot use; a kernel without it ignores the word. With `DEVOPSY_SERVER_KDUMP=off`, also frees the crash kernel kdump-tools reserves (Vultr's Ubuntu: 320 MB) and disables kdump-tools. These apply at the next reboot, which it asks for as a kernel update does (`/run/reboot-required`, taken by `DEVOPSY_SERVER_AUTO_REBOOT_TIME`), only when the reboot frees memory or brings kdump back. |
| `swap`     | Creates or resizes `/swapfile` to `DEVOPSY_SERVER_SWAP`, or removes it with `none`, unless the server has a swap of its own. |
| `docker`   | Docker Engine with the Buildx and Compose plugins, from Docker's apt repository, and `apparmor`, so Docker confines containers with its default profile where the kernel has AppArmor. Debian's and Ubuntu's kernels do, and a rerun restarts a daemon that started without it. `daemon.json` and the socket buffers are `--server-setup`'s. |
| `user`     | Creates the deploy user in the `docker` group and copies root's SSH authorized keys to it. |
| `upgrades` | Daily unattended security upgrades, with an optional reboot time. |
| `cli`      | Installs `devopsy` in `/usr/local/lib/devopsy`, owned by the deploy user and linked from `/usr/local/bin`; a rerun upgrades it. |

## Settings

| Variable                          | Default   | |
| --------------------------------- | --------- | - |
| `DEVOPSY_SERVER_USER`             | `devopsy` | The deploy user, set by the first run. |
| `DEVOPSY_SERVER_KDUMP`            | `on`      | `off` frees the memory kdump reserves for a crash kernel, where the image has kdump-tools (Vultr's Ubuntu: 320 MB of 2 GB), and disables it, from the next reboot; `on` puts both back. |
| `DEVOPSY_SERVER_SWAP`             | by memory | Size of `/swapfile`, like `2G` or `512M`, or `none`; a new size resizes it, `none` removes it. The default is as much as the memory up to 2.5 GB, then `2G` up to 8.5 GB, then none, and none where the server has a swap of its own, which is left alone. |
| `DEVOPSY_SERVER_AUTO_REBOOT_TIME` | `never`   | Reboot after upgrades that need it, at this time, like `04:00`. |
| `DEVOPSY_SERVER_FORCE`            | `0`       | `1` runs on something other than Debian 13 or Ubuntu 26.04 without asking. Not saved. |

Traefik's settings (ACME email, resolvers, the wildcard domain) are
devopsy-template-traefik's; see its [Running
Traefik](https://github.com/hanoii/devopsy-template-traefik/blob/main/docs/running.md#settings).

## Deploying from CI

Nothing here makes keys. From your machine, `devopsy --ssh-keys-generate`
makes a pair and `devopsy @<target> --ssh-keys add ~/.ssh/devopsy-ci.pub
--restricted` authorizes it for the deploy user, without root;
`--ssh-keys` lists and removes keys (devopsy-cli's [Keys on a
server](https://github.com/hanoii/devopsy-cli/blob/main/docs/servers.md#keys-on-a-server)).

For CI's known hosts file, run `ssh-keyscan <server>` from your machine
and check its fingerprints against the server's own:

```sh
for key in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$key"; done
```

## More

- [An XFS root](docs/xfs.md): `cloud-init.yaml`, converting a new server's root to XFS for reflink copies.
- [Without the script](docs/without-the-script.md): the same steps by hand, as root.
- [Things to know](docs/things-to-know.md): what a devopsy server is protected by and what stays yours, block volumes, Docker's networks.

## License

GPL-3.0. See [LICENSE](LICENSE).
