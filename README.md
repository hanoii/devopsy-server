# devopsy-server

Turns a fresh Debian 13 server into a devopsy host: Docker, a deploy user,
automatic security upgrades, the
[devopsy CLI](https://github.com/hanoii/devopsy-cli) and
[Traefik](https://github.com/hanoii/devopsy-traefik).

It is one bash script, `setup.sh`. Every step is safe to rerun, so the same
command sets up a new server and brings an old one up to date.

## Usage

As root on the server:

```sh
curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-server/main/setup.sh \
  | DEVOPSY_ACME_EMAIL=you@example.com bash
```

To run only some steps, name them:

```sh
curl -fsSL .../setup.sh | bash -s -- docker cli
```

Settings are saved to `/etc/devopsy/server.env`. Later runs reuse them,
and environment variables override them.

## Steps

| Step       | What it does |
| ---------- | ------------ |
| `base`     | Installs curl, git, unattended-upgrades and sudo. |
| `swap`     | Creates `/swapfile` of `DEVOPSY_SWAP` if the server has no swap. |
| `docker`   | Docker Engine and the Compose plugin from Docker's apt repository. Rotated logs and `live-restore`. |
| `user`     | Creates the deploy user in the `docker` group and copies root's SSH authorized keys to it. |
| `upgrades` | Daily unattended security upgrades, with an optional reboot time. |
| `cli`      | Installs or updates `devopsy` in `/usr/local/bin`. |
| `traefik`  | Clones devopsy-traefik, writes its `.env` and starts it. |

## Settings

| Variable                   | Default | |
| -------------------------- | ------- | - |
| `DEVOPSY_ACME_EMAIL`       |         | Let's Encrypt email. Required the first time `traefik` runs. |
| `DEVOPSY_ACME_PRODUCTION`  | `0`     | `1` for real certificates. Staging otherwise. |
| `DEVOPSY_USER`             | `devopsy` | The deploy user. |
| `DEVOPSY_SUDO`             | `0`     | `1` gives the deploy user passwordless sudo. |
| `DEVOPSY_SWAP`             |         | Swap file size, like `2G`. |
| `DEVOPSY_AUTO_REBOOT_TIME` |         | Reboot after upgrades that need it, at this time, like `04:00`. |
| `DEVOPSY_TRAEFIK_DIR`      | `/srv/traefik` | Where Traefik is cloned. |
| `DEVOPSY_TRAEFIK_REPO`     | devopsy-traefik on GitHub | Use a fork. |
| `DEVOPSY_CLI_VERSION`      | `main`  | devopsy-cli branch or tag. |
| `DEVOPSY_FORCE`            | `0`     | `1` to run on something other than Debian 13. Not saved. |

The `traefik` step only writes Traefik's `.devopsy/.env` when it doesn't
exist, and never updates the clone. To upgrade Traefik:

```sh
cd /srv/traefik && git pull && devopsy restart
```

Setting `DEVOPSY_ACME_PRODUCTION=1` later has no effect on an existing
`.env`. Edit it and run `devopsy restart`.

## Things to know

- **The deploy user is effectively root.** Membership in the `docker` group
  allows root access through Docker. Treat its keys accordingly.
- **No host firewall.** Use your provider's firewall and allow only SSH, 80
  and 443. Docker would bypass a host firewall like ufw anyway: a port
  published by a container is open whatever ufw says.
- **Only Traefik publishes ports.** Publish anything else on `127.0.0.1`
  only, and reach it through an SSH tunnel.
- **SSH is left alone.** The script doesn't change the SSH server's
  configuration. Set it up as your provider does, with key login.
- Only Debian security updates are automatic. Upgrade Docker by hand with
  `apt upgrade`. `live-restore` keeps containers running while it restarts.

## License

GPL-3.0. See [LICENSE](LICENSE).
