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

Then release Traefik onto it from a devopsy-template-traefik checkout
(`devopsy @<server>:prod setup`; see its README's Setup section), and
your projects after it.

Settings are optional environment variables. `--help` lists them with the
values this server has saved:

```sh
curl -fsSL .../setup.sh | DEVOPSY_SWAP=2G bash
curl -fsSL .../setup.sh | bash -s -- --help
```

They are saved to `/etc/devopsy/server.env`, so a rerun reuses them. Set
one again to replace it, or empty (`DEVOPSY_SWAP=`) to go back to its
default.

Rerun the same command at any time: every step is idempotent, and a rerun
upgrades what the script installed (its apt packages, Docker and
devopsy). It leaves no command on the server.

On a new server, `cloud-init.yaml` can first convert its root to XFS
([An XFS root](docs/xfs.md)).

## Steps

| Step       | What it does |
| ---------- | ------------ |
| `base`     | Installs ca-certificates, curl, git, jq, openssh-client, openssl, unattended-upgrades and sudo, on Ubuntu `coreutils-from-gnu` (devopsy's scripts expect GNU's coreutils, which Ubuntu may replace with Rust's), plus `DEVOPSY_APT_PACKAGES`. Turns off systemd-resolved's LLMNR and multicast DNS, local-network name lookups a server does not need; Debian's answers LLMNR on port 5355 of every address. Sets `kho=off` on every server, freeing the memory the kernel keeps for Kexec HandOver, which a server does not use. Ubuntu 26.04's kernel turns it on and keeps up to 1.25 of 2 GB for movable pages only, which page tables, slab and socket buffers cannot use; a kernel without it ignores the word. With `DEVOPSY_KDUMP=off`, also frees the crash kernel kdump-tools reserves (Vultr's Ubuntu: 320 MB) and disables kdump-tools. These apply at the next reboot, which it asks for as a kernel update does (`/run/reboot-required`, taken by `DEVOPSY_AUTO_REBOOT_TIME`), only when the reboot frees memory or brings kdump back. |
| `swap`     | Creates `/swapfile` of `DEVOPSY_SWAP` if the server has no swap. |
| `docker`   | Docker Engine with the Buildx and Compose plugins, from Docker's apt repository, and `apparmor`, so Docker confines containers with its default profile where the kernel has AppArmor. Debian's and Ubuntu's kernels do, and a rerun restarts a daemon that started without it. Merges rotated logs, `live-restore` and /24 address pools (`DEVOPSY_ADDRESS_POOLS`) into `daemon.json`. Those four keys are setup's, and one changed by hand is replaced, with a warning; anything else there, like a proxy's `proxies`, stays. Sets socket buffers of 7.5 MB (`net.core.rmem_max`, `wmem_max`), what a Cloudflare Tunnel's connector asks for. |
| `user`     | Creates the deploy user in the `docker` group, copies root's SSH authorized keys to it, and with `DEVOPSY_ROOT` gives it that directory for releases. |
| `upgrades` | Daily unattended security upgrades, with an optional reboot time. |
| `cli`      | Installs `devopsy` in `/usr/local/lib/devopsy`, owned by the deploy user and linked from `/usr/local/bin`; a rerun upgrades it. |

## Settings

| Variable                   | Default | |
| -------------------------- | ------- | - |
| `DEVOPSY_USER`             | `devopsy` | The deploy user. |
| `DEVOPSY_SUDO`             | `0`     | `1` gives the deploy user passwordless sudo. |
| `DEVOPSY_KDUMP`            | `on`    | `off` frees the memory kdump reserves for a crash kernel, where the image has kdump-tools (Vultr's Ubuntu: 320 MB of 2 GB), and disables it, from the next reboot; `on` puts both back. |
| `DEVOPSY_APT_PACKAGES`     |         | Extra apt packages, space separated, like `htop ncdu`. Removing one from the list does not uninstall it. |
| `DEVOPSY_SWAP`             |         | Swap file size, like `2G` (see ["swap"](docs/without-the-script.md#swap)). |
| `DEVOPSY_AUTO_REBOOT_TIME` |         | Reboot after upgrades that need it, at this time, like `04:00`. |
| `DEVOPSY_ADDRESS_POOLS`    | `172.16.0.0/12 192.168.0.0/16` | Ranges Docker cuts into /24 networks, space separated, each /24 or larger. |
| `DEVOPSY_ROOT`             |         | Where releases live, like `/srv` on a block volume; default the deploy user's home. Written as `releases: root` in the deploy user's `~/.config/devopsy/config.yaml` (devopsy-cli's [Release settings](https://github.com/hanoii/devopsy-cli/blob/main/docs/config.md#release-settings)); a file there that devopsy-server did not write is left alone. |
| `DEVOPSY_FORCE`            | `0`     | `1` to run on something other than Debian 13 or Ubuntu 26.04. Not saved. |

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
