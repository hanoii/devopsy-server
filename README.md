# devopsy-server

Sets up a fresh Debian 13 or Ubuntu 26.04 server as a host for
[devopsy](https://github.com/hanoii/devopsy-cli): Docker, a deploy user,
automatic security upgrades and devopsy itself. Projects are then released
onto it with devopsy, starting with
[Traefik](https://github.com/hanoii/devopsy-template-traefik).

## Usage

As root on the server:

```sh
curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-server/main/setup.sh | bash
```

It asks for the deploy user, a swap file, a time to reboot after upgrades
that need it and, where the image has kdump, whether to keep its memory,
each with a default in brackets that Enter keeps.

Then run devopsy's own setup of the server from your machine, as the
deploy user (devopsy-cli's
[`--server-setup`](https://github.com/hanoii/devopsy-cli/blob/main/docs/servers.md#--server-setup)),
which asks before it changes what someone else set. `setup.sh` prints
this command at its end and does not run it:

```sh
devopsy @devopsy@<server>: --server-setup
```

A server with [project
users](https://github.com/hanoii/devopsy-cli/blob/main/docs/project-users.md)
also needs devopsy's `--project-users setup`.

Then release Traefik onto it from a devopsy-template-traefik checkout
(`devopsy @<server>:prod setup`; see its README's Setup section), and
your projects after it.

On a new server, `cloud-init.yaml` can first convert its root to XFS
([An XFS root](docs/xfs.md)).

## Reruns

Run the same command again at any time. Every step is idempotent, a
rerun upgrades what the script installed (its apt packages, Docker and
devopsy), and it asks the questions again with the server's saved
answers as their defaults: a rerun is also how a setting changes. It
leaves no command on the server.

Without a terminal (cloud-init, CI), or with `--yes`, it asks nothing and
takes the saved values, else the defaults. A setting given as a variable
is taken as it is and not asked. `--help` lists the settings and the
values saved on the server, in `/etc/devopsy/server.env`:

```sh
curl -fsSL .../setup.sh | bash -s -- --yes
curl -fsSL .../setup.sh | DEVOPSY_SERVER_SWAP=2G bash
curl -fsSL .../setup.sh | bash -s -- --help
```

## Settings

| Variable                          | Default   | |
| --------------------------------- | --------- | - |
| `DEVOPSY_SERVER_USER`             | `devopsy` | The deploy user, the one devopsy logs in as. Asked on the first run only, and never changed after it. |
| `DEVOPSY_SERVER_SWAP`             | by memory | Size of `/swapfile`, like `2G` or `512M`, or `none`. A new size resizes it, and `none` removes it. The default is as much as the memory up to 2.5 GB, `2G` up to 8.5 GB, then none, and none on a server with a swap of its own, which is left as it is. |
| `DEVOPSY_SERVER_AUTO_REBOOT_TIME` | `never`   | Reboot after upgrades that need it, at this time, like `04:00`. |
| `DEVOPSY_SERVER_KDUMP`            | `on`      | `off` frees the memory kdump keeps for a crash kernel and disables kdump-tools, from the next reboot; `on` puts both back. Asked only where the image has kdump-tools. |
| `DEVOPSY_SERVER_FORCE`            | `0`       | `1` runs on a distribution other than Debian 13 or Ubuntu 26.04 without asking. Not saved. |

Traefik's settings (ACME email, resolvers, the wildcard domain) are
devopsy-template-traefik's; see its [Running
Traefik](https://github.com/hanoii/devopsy-template-traefik/blob/main/docs/running.md#settings).

## Steps

| Step       | What it does |
| ---------- | ------------ |
| `base`     | Installs the tools devopsy uses, ssh, curl and unattended-upgrades, with GNU's coreutils on Ubuntu. Turns off systemd-resolved's LLMNR and multicast DNS. Frees the memory the kernel keeps for kexec, from the next reboot ([Memory for kexec](docs/things-to-know.md#memory-for-kexec)). |
| `swap`     | Makes, resizes or removes `/swapfile`, unless the server has a swap of its own. |
| `docker`   | Installs Docker Engine with the Buildx and Compose plugins from Docker's apt repository, and `apparmor`. |
| `user`     | Creates the deploy user in the `docker` group, with root's SSH authorized keys. |
| `upgrades` | Turns on daily unattended security upgrades, and the reboot after them at the time set. |
| `cli`      | Installs devopsy in `/usr/local/lib/devopsy`, owned by the deploy user and linked from `/usr/local/bin`; a rerun upgrades it. |

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
- [Things to know](docs/things-to-know.md): what a devopsy server is protected by and what stays yours, memory for kexec, block volumes.

## License

GPL-3.0. See [LICENSE](LICENSE).
