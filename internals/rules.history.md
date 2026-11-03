History, not rules: AGENTS.md's Rules win where they differ.

- Ubuntu's coreutils: Ubuntu ships Rust's uutils beside GNU's and may make them the default. 26.04 on DigitalOcean had GNU's (checked 2026-10-26); OrbStack's 26.04 and a server upgraded from 24.04 have `coreutils-from-uutils` marked manual (checked 2026-10-27), where a plain install of GNU's failed, apt keeping the manual one.
- A setup script, not a CLI: step names, subcommands and an installed copy that updated itself all existed and were removed, with the `ci-key` step.
- Never rebooting, and the flag only when a reboot changes something (the maintainer, 2026-10-29): a flag for nothing, as on Debian 13's 6.12 for KHO, would be a banner asking for a reboot that changes nothing, and an automatic one taking the sites down for it.
