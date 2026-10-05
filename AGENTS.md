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
- Keep it a bootstrap. Per-project deployment belongs in projects'
  `.devopsy/`, and Traefik's setup in devopsy-traefik.

## Design decisions and gotchas

The workspace README (`../devopsy/README.md` locally) describes how the repos
fit together, and `../devopsy/ROADMAP.md` the open ideas.

- Settings are validated, then saved, before any step runs: a failed run
  remembers them, and a typo never sticks.
- `env_set` replaces a key in place: appending reordered files and made
  reruns rewrite them.
- `DEVOPSY_ACME_PRODUCTION` only applies when Traefik's `.env` is first
  written; afterwards `devopsy letsencrypt` switches, and reruns never undo
  that.
- The installed copy (`/usr/local/sbin/devopsy-server`) updates itself before
  running. The traefik step never pulls `/srv/traefik`: upgrading the proxy of
  every site stays a deliberate `git pull` and `devopsy restart`.
- Testing with OrbStack: machines lack openssh-server and mask
  systemd-resolved. To reproduce the cloud port 53 clash, bind a listener to
  127.0.0.53:53 (a few lines of python) before starting acme-dns. Right after
  editing a file, OrbStack's file sharing can serve a stale copy to a machine
  or a `docker run` mount: rerun before trusting a surprising result.

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
