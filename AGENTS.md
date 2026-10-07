# AGENTS.md

devopsy-server prepares a Debian 13 host for devopsy. It is a single bash
script, `setup.sh`, run as root, often piped from curl. Read `README.md` for
the user-facing behavior and keep it in sync: the steps table, the settings
table and "Things to know".

## Rules

- Every step must be idempotent. Running the script twice in a row changes
  nothing the second time and restarts nothing.
- Write config files with `write_file`. It only writes and returns success
  when the content changed, so a service restarts only then.
- New settings are `DEVOPSY_*` variables with a default in `load_settings`.
  Add them to `SETTINGS` so they are saved, and to the README table.
- Never change the SSH server configuration. Providers set it up, and a
  mistake there locks the operator out.
- No host firewall: the provider's firewall covers it. See README.md.
- Debian 13 only. Use apt and systemd directly. No configuration management
  dependencies.
- Only print secrets when they are created or explicitly asked for, like
  the `ci-key` step does. A plain rerun must not print them.
- Keep it a bootstrap: the host only. Per-project deployment belongs in
  projects' `.devopsy/`, and Traefik is released like any project
  (devopsy-traefik). Nothing here knows about Traefik or writes settings
  devopsy-cli reads: a server needs Docker, the deploy user owning `/srv`
  and devopsy, and this script is one way to get them.

## Design decisions and gotchas

The workspace README (`../devopsy/README.md` locally) describes how the repos
fit together, and `../devopsy/ROADMAP.md` the open ideas.

- Settings are validated, then saved, before any step runs: a failed run
  remembers them, and a typo never sticks.
- The installed copy (`/usr/local/sbin/devopsy-server`) updates itself before
  running.
- Until October 2026 a `traefik` step cloned devopsy-traefik, wrote its
  `.env`, `/etc/devopsy/devopsy.env` and a Cloudflare range timer. The `cli`
  step removes the last two from servers that still have them.
- Testing with OrbStack: machines lack openssh-server and mask
  systemd-resolved. To reproduce the cloud port 53 clash, bind a listener to
  127.0.0.53:53 (a few lines of python) before starting acme-dns. Right after
  editing a file, OrbStack's file sharing can serve a stale copy to a machine
  or a `docker run` mount: rerun before trusting a surprising result.
  Reaching a machine's IP or `<machine>.orb.local` from macOS makes OrbStack
  ask for admin rights (its network helper): go through `ssh
  <user>@<machine>@orb` instead, and test public DNS and certificates on a
  real server.
- Provider block volumes: DigitalOcean mounts an attached volume on
  `/mnt/<volume>` with its own systemd mount unit. devopsy keeps projects and
  data in `/srv`, so mount the volume there (`srv.mount`, after removing the
  provider's unit) before running setup, and make Docker wait for it
  (`RequiresMountsFor=/srv` in a `docker.service.d` drop-in): otherwise
  containers starting before the mount write their bind mounts to the root
  disk, hidden under the volume. Done by hand on builder1; not automated
  (see ROADMAP.md).
- The first run prints the CI private key (`ci-key`). Run setup where its
  output is not logged, or replace the key afterwards.

## Checks

```sh
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable setup.sh
```

Test on a real Debian 13 machine, for example an OrbStack machine
(`orb create debian:trixie devopsy-test`). Run the script with test settings,
run it again without them to check idempotency and saved settings, then
`orb delete -f devopsy-test`.

## Commits

Conventional commits (`feat:`, `fix:`, `docs:`, `build:`...).
