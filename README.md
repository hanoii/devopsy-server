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

The script installs itself as `devopsy-server`, which updates itself to the
latest version before each run (`DEVOPSY_NO_SELF_UPDATE=1` skips that).
Afterwards, rerun it or only some steps with:

```sh
devopsy-server              # everything
devopsy-server docker cli   # only these steps
```

Settings are saved to `/etc/devopsy/server.env`. Later runs reuse them,
and environment variables override them.

## Steps

| Step       | What it does |
| ---------- | ------------ |
| `base`     | Installs curl, git, jq, openssh-client, unattended-upgrades and sudo, plus `DEVOPSY_APT_PACKAGES`. |
| `swap`     | Creates `/swapfile` of `DEVOPSY_SWAP` if the server has no swap. |
| `docker`   | Docker Engine and the Compose plugin from Docker's apt repository. Rotated logs and `live-restore`. |
| `user`     | Creates the deploy user in the `docker` group, gives it `/srv` for projects, and copies root's SSH authorized keys to it. |
| `upgrades` | Daily unattended security upgrades, with an optional reboot time. |
| `cli`      | Installs or updates `devopsy` in `/usr/local/bin`, and this script as `devopsy-server` in `/usr/local/sbin`. |
| `traefik`  | Clones devopsy-traefik, writes its `.env` and starts it. |
| `ci-key`   | Creates an SSH key that lets CI log in as the deploy user, and prints it. See below. |

## Settings

| Variable                   | Default | |
| -------------------------- | ------- | - |
| `DEVOPSY_ACME_EMAIL`       |         | Let's Encrypt email. Required the first time `traefik` runs. |
| `DEVOPSY_ACME_PRODUCTION`  | `1`     | `0` for Let's Encrypt staging. Only applies when Traefik's `.env` is first written. |
| `DEVOPSY_CLOUDFLARE_DNS_API_TOKEN` | | Cloudflare token for Traefik's DNS-01 resolver. Writes Traefik's `dns.env` on every run. |
| `DEVOPSY_CERTRESOLVER`     |         | Traefik's default resolver: `letsencrypt1` (HTTP-01), `acmedns` or `cloudflare` (DNS-01). Kept in sync in Traefik's `.env`. |
| `DEVOPSY_ACMEDNS_DOMAIN`   |         | Runs acme-dns for Traefik's `acmedns` resolver on this subdomain, like `acme-vm1.example.com`. Prints the DNS records to create. |
| `DEVOPSY_ACMEDNS_IP`       | detected | Public IPv4 acme-dns listens on. Set it when the server is behind NAT. |
| `DEVOPSY_USER`             | `devopsy` | The deploy user. |
| `DEVOPSY_SUDO`             | `0`     | `1` gives the deploy user passwordless sudo. |
| `DEVOPSY_APT_PACKAGES`     |         | Extra Debian packages to install, space separated, like `htop ncdu`. Removing one from the list does not uninstall it. |
| `DEVOPSY_SWAP`             |         | Swap file size, like `2G`. |
| `DEVOPSY_AUTO_REBOOT_TIME` |         | Reboot after upgrades that need it, at this time, like `04:00`. |
| `DEVOPSY_TRAEFIK_DIR`      | `/srv/traefik` | Where Traefik is cloned. |
| `DEVOPSY_TRAEFIK_REPO`     | devopsy-traefik on GitHub | Use a fork. |
| `DEVOPSY_CLI_VERSION`      | `latest` | devopsy-cli release to install, like `v0.1.0`. |
| `DEVOPSY_SERVER_VERSION`   | `main`  | devopsy-server branch or tag installed as `devopsy-server`. |
| `DEVOPSY_FORCE`            | `0`     | `1` to run on something other than Debian 13. Not saved. |

The `traefik` step only writes Traefik's `.devopsy/.env` when it doesn't
exist, and never updates the clone. To upgrade Traefik:

```sh
cd /srv/traefik && git pull && devopsy restart
```

`DEVOPSY_ACME_PRODUCTION` only sets the initial Let's Encrypt environment.
To switch later, run `devopsy letsencrypt production` (or `staging`) in
`/srv/traefik`. The Cloudflare resolver's
`dns.env`, the default resolver and acme-dns follow the settings on every
run. With acme-dns on, each run ends with the DNS records to create; also
`cd /srv/traefik && devopsy acmedns`. Open port 53, UDP and TCP, in your
provider's firewall.

See devopsy-traefik's README for how the resolvers work, including DNS-01
for domains outside Cloudflare.

## Deploying from CI

The `ci-key` step creates `~devopsy/.ssh/devopsy_ci_ed25519` and authorizes
it for the deploy user, without port or agent forwarding. It prints the
private key and the server's host key fingerprints the first time. Print
them again with:

```sh
devopsy-server ci-key
```

In GitLab, under Settings > CI/CD > Variables, add:

- `DEVOPSY_SSH_KEY`: the private key, type File, protected.
- `DEVOPSY_SSH_KNOWN_HOSTS`: the output of `ssh-keyscan <server>`, type File.
  Check its fingerprints against the ones the script printed.

A job can then run devopsy on the server:

```yaml
deploy:
  image: alpine:latest
  script:
    - apk add --no-cache openssh-client
    - chmod 600 "$DEVOPSY_SSH_KEY"
    - ssh -i "$DEVOPSY_SSH_KEY" -o UserKnownHostsFile="$DEVOPSY_SSH_KNOWN_HOSTS"
        devopsy@your-server 'cd /srv/my-project && devopsy deploy'
```

GitLab cannot mask a multi-line key, so never print the variable in a job.

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
