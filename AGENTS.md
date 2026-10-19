# AGENTS.md

devopsy-server prepares a Debian 13 host for devopsy. It is a single bash
script, `setup.sh`, run as root, often piped from curl. Read `README.md`
for the user-facing behavior and keep it in sync: the steps table, the
settings table and "Things to know".

## Rules

- **Every change is tested before it lands:** shellcheck clean, and
  `setup.sh` run twice on a fresh Debian 13 machine (Checks): the
  second run changes nothing. A step devopsy-cli's e2e servers copy
  (`e2e/Dockerfile`, `e2e/daemon.json`) changes there too, so its e2e
  suite runs on it. Why: a setup bug surfaces only on the next server.
- **Every step is idempotent:** running the script twice in a row
  changes nothing the second time and restarts nothing. Where: each
  `step_*` function.
- **Config files are written with `write_file`,** which only writes, and
  returns success, when the content changed. Why: a service restarts
  only then.
- **A choice is a `DEVOPSY_*` setting with a default in
  `load_settings`,** added to `SETTINGS` (so it is saved), to `usage`
  and to the README table. `usage` runs before `preflight`, so `--help`
  works anywhere, as any user, and shows the saved settings when it can
  read them.
- **Settings are validated, then saved, before any step runs**
  (`validate_settings`, `save_settings`). Why: a failed run remembers
  them, and a typo never sticks.
- **Never change the SSH server configuration.** Why: providers set it
  up, and a mistake there locks the operator out.
- **No host firewall:** the provider's firewall covers it (README.md).
- **Debian 13 only,** with apt and systemd directly and no configuration
  management dependencies.
- **Never create or print secrets.** Keys for the deploy user are
  devopsy-cli's (`--ssh-keys`), made on the operator's machine.
- **A bootstrap of the host only.** Per-project deployment belongs in
  projects' `.devopsy/`, and Traefik is released like any project
  (devopsy-template-traefik): nothing here knows about Traefik. The
  only setting devopsy-cli reads that this writes is the release root
  (`DEVOPSY_ROOT`, as `releases: root` in the deploy user's devopsy
  config, in a file marked as written here). Why: a server needs
  Docker, the deploy user and devopsy, and this script is one way to
  get them.
- **A setup script, not a CLI:** it takes no arguments but `--help`,
  runs every step every time, and leaves no command on the server: no
  step names, no subcommands, no installed copy that updates itself
  (all three existed and were removed, with the `ci-key` step). What a
  server needs after setup is `devopsy` and plain SSH.
- **A rerun upgrades what the script installed, nothing else:** the apt
  packages it names (`apt-get install` upgrades an installed one),
  Docker among them, and devopsy (`devopsy --upgrade` as the deploy
  user; a failure only warns). No `dist-upgrade`.

## Decisions and gotchas

- **devopsy belongs to the deploy user, in `/usr/local/lib/devopsy`**
  (`step_cli`), so `devopsy --upgrade` needs no root: it resolves the
  `/usr/local/bin/devopsy` link and replaces the file in its own
  directory. Not in the user's home: homes are mode 700 or 750 on some
  distributions, and the link would then only work for its owner.
  `/usr/local/bin` itself stays root's, and SSH sessions without a
  login shell have it in `PATH`, unlike `~/.local/bin`. The installer
  runs as the deploy user, so root never runs what it downloads.
- **No version setting:** a rerun runs `devopsy --upgrade` as that user,
  the one way to upgrade, so a pinned version would last only until the
  next rerun.
- **devopsy-cli's end-to-end servers copy this host setup**
  (`e2e/Dockerfile`, `e2e/daemon.json` there: Docker with Buildx, the
  /24 address pools): a change to the `docker` step's packages or
  `daemon.json` goes there too.
- **Provider block volumes are mounted by hand, before setup:**
  DigitalOcean mounts an attached volume on `/mnt/<volume>` with its
  own systemd mount unit. Mount it where releases should live, like
  `/srv` (`srv.mount`, after removing the provider's unit), with
  `DEVOPSY_ROOT=/srv`, and make Docker wait for it
  (`RequiresMountsFor=/srv` in a `docker.service.d` drop-in). Why:
  containers starting before the mount write their bind mounts to the
  root disk, hidden under the volume. `setup.sh` does not do this.
- **OrbStack machines differ from cloud servers:** they lack
  openssh-server and mask systemd-resolved. To reproduce the cloud
  port 53 clash, bind a listener to 127.0.0.53:53 (a few lines of
  python) before starting acme-dns. Right after editing a file,
  OrbStack's file sharing can serve a stale copy to a machine or a
  `docker run` mount: rerun before trusting a surprising result.
  Reaching a machine's IP or `<machine>.orb.local` from macOS makes
  OrbStack ask for admin rights (its network helper): go through `ssh
  <user>@<machine>@orb` instead, and test public DNS and certificates
  on a real server.

## Checks

```sh
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable setup.sh
```

Test on a real Debian 13 machine, for example an OrbStack machine
(`orb create debian:trixie devopsy-test`). Run the script with test
settings, run it again without them to check idempotency, saved
settings and `--help`, then `orb delete -f devopsy-test`.

## Commits

Conventional commits (`feat:`, `fix:`, `docs:`, `build:`...).
