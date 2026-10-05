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
- Keep it a bootstrap. Per-project deployment belongs in projects'
  `.devopsy/`, and Traefik's setup in devopsy-traefik.

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
