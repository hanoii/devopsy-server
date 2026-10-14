# devopsy-server

Turns a fresh Debian 13 server into a devopsy host: Docker, a deploy user
(releases live in its home, or `DEVOPSY_ROOT`), automatic security upgrades
and the
[devopsy CLI](https://github.com/hanoii/devopsy-cli). Everything else is
released onto it with devopsy, from your machine or CI, starting with
[Traefik](https://github.com/hanoii/devopsy-template-traefik).

It is one bash script, `setup.sh`, and only a setup script: no command is
left on the server. Every step is safe to rerun, so the same command sets
up a new server and brings an old one up to date.

## Usage

As root on the server:

```sh
curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-server/main/setup.sh | bash
```

Then release Traefik onto it from a devopsy-template-traefik checkout (its README,
"Setup"), and your projects after it.

Settings are environment variables, all optional, and `--help` lists them
with what this server has saved:

```sh
curl -fsSL .../setup.sh | DEVOPSY_SWAP=2G DEVOPSY_ROOT=/srv bash
curl -fsSL .../setup.sh | bash -s -- --help
```

They are saved to `/etc/devopsy/server.env`: a rerun without them reuses
them, and a variable set again replaces its saved value (set empty, like
`DEVOPSY_SWAP=`, it goes back to its default).

Rerun the same command at any time. It runs every step, changes only what
differs, and upgrades what it installed: the Debian packages it names,
Docker and devopsy. It takes no other arguments.

## Steps

| Step       | What it does |
| ---------- | ------------ |
| `base`     | Installs curl, git, jq, openssh-client, unattended-upgrades and sudo, plus `DEVOPSY_APT_PACKAGES`. |
| `swap`     | Creates `/swapfile` of `DEVOPSY_SWAP` if the server has no swap. |
| `docker`   | Docker Engine and the Compose plugin from Docker's apt repository. Rotated logs, `live-restore` and /24 address pools for networks. |
| `user`     | Creates the deploy user in the `docker` group, copies root's SSH authorized keys to it, and with `DEVOPSY_ROOT` gives it that directory for releases. |
| `upgrades` | Daily unattended security upgrades, with an optional reboot time. |
| `cli`      | Installs `devopsy` in `/usr/local/lib/devopsy`, owned by the deploy user and linked from `/usr/local/bin`; on a rerun, upgrades it to the latest release. |

## Settings

| Variable                   | Default | |
| -------------------------- | ------- | - |
| `DEVOPSY_USER`             | `devopsy` | The deploy user. |
| `DEVOPSY_SUDO`             | `0`     | `1` gives the deploy user passwordless sudo. |
| `DEVOPSY_APT_PACKAGES`     |         | Extra Debian packages to install, space separated, like `htop ncdu`. Removing one from the list does not uninstall it. |
| `DEVOPSY_SWAP`             |         | Swap file size, like `2G`. |
| `DEVOPSY_AUTO_REBOOT_TIME` |         | Reboot after upgrades that need it, at this time, like `04:00`. |
| `DEVOPSY_ROOT`             |         | Where releases live, like `/srv` on a block volume; default the deploy user's home. Written as `releases: root` in the deploy user's `~/.config/devopsy/config.yaml` (devopsy-cli's README, "Release settings of a server"); a file there that devopsy-server did not write is left alone. |
| `DEVOPSY_FORCE`            | `0`     | `1` to run on something other than Debian 13. Not saved. |

Traefik's settings (ACME email, resolvers, acme-dns, the wildcard domain,
Cloudflare) are devopsy-template-traefik's, in its `shared/.env` on the server; see
its README.

## Deploying from CI

Nothing here makes keys. From your machine, `devopsy --ssh-keys-generate`
makes a pair and `devopsy @<target> --ssh-keys add ~/.ssh/devopsy-ci.pub
--restricted` authorizes its public half for the deploy user, over SSH and
without root; `--ssh-keys` lists and removes keys, for rotation
(devopsy-cli's README, "Keys on a server"). The private key is never on the
server.

For CI's known hosts file, run `ssh-keyscan <server>` from your machine
and check its fingerprints against the server's own:

```sh
for key in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$key"; done
```

## Things to know

- **A block volume for releases.** Releases and their data live in the
  deploy user's home, or `DEVOPSY_ROOT`. Providers mount volumes elsewhere
  (DigitalOcean: `/mnt/<volume>`); mount it where you want releases, like
  `/srv`, set `DEVOPSY_ROOT=/srv`, and add `RequiresMountsFor=/srv` to a
  `docker.service.d` drop-in so containers never start before it. The home
  directory, with `.ssh`, stays off the volume.

- **The deploy user is effectively root.** Membership in the `docker` group
  allows root access through Docker. Treat its keys accordingly.
- **The deploy user owns `devopsy`.** `ssh devopsy@<server> devopsy
  --upgrade` upgrades it, without root, and `--upgrade vX.Y.Z` installs
  that release. A rerun of setup upgrades it to the latest too, so pin a
  version by not rerunning, or `--upgrade vX.Y.Z` afterwards.
  `/usr/local/bin/devopsy` is a link
  to it, so whoever runs `devopsy` there, root included, runs a file the
  deploy user can replace: nothing it could not do already.
- **No host firewall.** Use your provider's firewall and allow only SSH, 80
  and 443. Docker would bypass a host firewall like ufw anyway: a port
  published by a container is open whatever ufw says.
- **Only Traefik publishes ports.** Publish anything else on `127.0.0.1`
  only, and reach it through an SSH tunnel.
- **SSH is left alone.** The script doesn't change the SSH server's
  configuration. Set it up as your provider does, with key login.
- **Thousands of Docker networks, not 30.** Docker's default address pools
  cut `172.17.0.0` to `172.31.255.255` into /16 networks and
  `192.168.0.0/16` into /20 ones: about 30 per host, and every project
  environment takes at least one. Here `172.16.0.0/12` (the same, plus
  `172.16.x`) and `192.168.0.0/16` are cut into /24 networks, 254 addresses
  each. Networks
  that already exist keep their size until recreated (`devopsy down`, then
  `up`). Where the server must reach other hosts in those ranges (a
  corporate network on `172.16.0.0/12`), set `default-address-pools` in
  `/etc/docker/daemon.json` to a range nobody uses.
- Only Debian security updates are automatic. Docker is upgraded by a
  rerun of setup, or by hand with `apt upgrade`. `live-restore` keeps
  containers running while it restarts.
- **Servers set up by earlier versions.** A rerun removes the
  `devopsy-server` command they installed. A CI key the old `ci-key` step
  made (`~devopsy/.ssh/devopsy_ci_ed25519`) stays, and stays authorized:
  list and remove keys with `devopsy @<target> --ssh-keys`.

## License

GPL-3.0. See [LICENSE](LICENSE).
