# AGENTS.md

devopsy-server prepares a Debian 13 or Ubuntu 26.04 host for [devopsy](https://github.com/hanoii/devopsy-cli): Docker, the deploy user and devopsy. It is a bash script, `setup.sh`, run as root, often piped from curl, and `cloud-init.yaml`, user data that converts a new server's root to XFS before it.

## Workflow

### Git

- Conventional commits; the subject about 50 characters, 72 at most, the reason in the body: release notes are commit subjects, and tools cut longer ones.
- A commit made with an AI agent ends with one line naming it, `Assisted-by: <agent>:<model> [<effort>]` (for example `Assisted-by: claude-code:claude-opus-5-5 high`), never `Co-Authored-By`: GitHub shows a co-author as a person.
- Any word with an `@` in a commit message or a doc goes in backticks (for example `@prod`, `deploy@host`): GitHub links a bare `@name` to that user.
- Push and tag only when asked: a push publishes, a tag releases.
- A change of one commit (for example a quick fix) goes straight onto `main`, in the main checkout.
- Any larger task gets one branch, `<type>/<slug>`, its type what it brings to `main` whatever its commits' types (for example `feat/snapshots`, `docs/readme`).
- All of a task's work goes on its branch, reviews' failing tests and their fixes included; never a branch off a task's branch.
- A finished branch is rebased onto `main`, merged with `--no-ff` and deleted.
- A partial merge, only when asked, is rebased and merged the same way and keeps the branch and its worktree, rebased at once onto the merge for the rest of the task.
- A branch is worked in a worktree of its own, `.worktrees/<slug>` (`git worktree add .worktrees/<slug> -b <type>/<slug>`), removed once merged: inside the repository, a worktree is within the directories the agent may use.
- The main checkout stays on `main`.
- A worktree of a devopsy project run beside its main checkout gets its own `project:` (for example `whoami-<slug>`) in `.devopsy/config.local.yaml`: otherwise both are one local compose project, sharing containers and volumes.
- `.worktrees/` is listed in `.gitignore` and in the ignore file of any Docker build context that holds it: a `docker build` would otherwise send every worktree in its context.
- A session in a worktree starts by rebasing it onto `main`: the work adapts to what changed while it is still cheap.

### Tests and checks

- Every change carries its test, a fix's failing without it, a feature's checking what it promises, and a behavior a change touches with no test gets one then: a test is what keeps a fix fixed.
- A fix's test is run against the code before the fix, and the summary says it failed there.
- Unit tests first; an end-to-end test only for what needs a real system (for example Docker, sshd, the network, a terminal or timing).
- One test per behavior: extend the test that covers it before adding another, and never test one thing at both levels.
- The suites stay fast, locally and in CI, since every change waits on them: a new test runs in parallel with the others where it can, polls rather than sleeps, and reuses the setups that exist.
- A test made faster checks the same things, never fewer: a speed-up that drops a case or an assertion is a regression.
- A check or a refusal is only for a mistake any release can make, a setting a tool would otherwise take without a word; none is added for one upgrade only (for example a refusal of an old name after a rename): an upgrade's own steps cover those, and old names left over are ignored.
- Until 1.0.0, no tests of specific older versions and no handling of mixed versions (for example an operator and a server on different devopsy): a new behavior an older server lacks refuses before anything changes, and that is all.

### Refactors

- Before writing code for one case, look for the same pattern elsewhere (for example a message, a check, an interrupt) and propose one helper for all, each site adding only what is its own: variants drift apart, and a fix then lands in one of them only.
- A design that makes a change awkward is proposed for change, never worked around: workarounds pile up where the design is wrong.
- When a change makes the code simpler (less code, fewer external calls), the tests' fakes are extended to match, never the heavier code kept or a test weakened to pass.
- A refactor reaching beyond the task is agreed before it is made.

### Reviews

- A review round is two independent reviewers, one on Opus and one on Fable, on the task's branch in its worktree.
- A review brief lists what earlier rounds found and states Tests and checks' two limits, mixed versions and lean checks: findings of those kinds are not fixed.
- A review brief also asks for the same pattern written twice and for workarounds of the design (Refactors).
- A reviewer writes what it tests into the repository as `test:` commits on the task's branch, a failing test that proves a bug kept with a comment naming it, never product code: a harness outside the repository is lost with its round.
- While building or after a review, a bug, an edge case, a name or a verified finding is decided and fixed without asking, a fix with its failing test first, and said in the summary; only what changes the agreed design or user-facing behavior is asked.
- At most two rounds per branch: after the second round's fixes, the tests, the end-to-end suite and a hand test cover the rest.

### Servers and names

- Never touch a real server without asking, even read-only; test on throwaway machines and delete them afterwards: a read can still load a server, and only its owner knows what runs there.
- Names in examples, tests, docs and commit messages are generic (for example `app`, `shop`, `vm1`, `example.com`), never a real project, client, server, domain or person, nor anything from an agent's memory or another project: a public history keeps whatever a commit once said.

### Docs

- The root holds what every task in the repository needs; a part only some tasks need is an area, `internals/<area>.md`, with one line in the root's index saying what it covers and when to read it: the root loads with every session, the areas only when their line says so.
- A root is kept under about 250 lines, a guide, never a cap: past it, what only some tasks need moves to an area, and no needed rule is cut or squeezed to fit.
- A rule's history goes in `internals/<area>.history.md`, or `internals/<section>.history.md` for a rule in a section of the root, starting with a line saying it is history, not rules, and its area's file wins where they differ.
- A history file is read only before changing or questioning one of its rules, when a review finding looks like it contradicts a decision, or when asked why.
- How a script or a function works, step by step, goes in its comments, never in an AGENTS.md or area: a comment changes with its code.
- A commit's reason goes in its body; only a decision a later session must respect becomes a rule, in its area or the root, its story in the history, in the same commit: anywhere else, the next session rediscovers it or contradicts it.
- Before adding a rule, find any line it repeats or contradicts, in its file and the root, and change that line instead: two lines on one thing drift apart.
- A line written or changed in an AGENTS.md or area is checked before its commit (for example `Push and tag only when asked: a push publishes, a tag releases.`):
  - one rule, imperative, no bold, no prose around it;
  - a why only when something real breaks without it, saying what breaks, never an invented one, which an agent takes for a reason;
  - examples written "(for example ...)" before the colon, and one colon at most outside code;
  - one reading only, else reworded, never explained further;
  - no story (review rounds, what broke, measurements), which goes in the history.
- A README says at a glance what the repository is and how to start; anything longer is a doc of its own in `docs/` that it links to: a README that piles up docs gets skimmed past.
- READMEs and docs are written plainly, with no selling words, no bold lead-in on every bullet, no closing summary, no emoji and no "Note" asides: they read as generated and bury the facts.
- Each fact has one home, and other docs link to it rather than repeat it: two copies drift apart.

## Layout

- `setup.sh`: the settings (`load_settings`, `validate_settings`, `save_settings`, `usage`), `preflight`, then one `step_*` function per step, run in order by `main`.
- `cloud-init.yaml`: the XFS conversion, its scripts in `write_files` (`internals/xfs.md`).
- `test/run.sh` and `test/Dockerfile` run `setup.sh` in containers (Checks).
- `.github/workflows/` holds `lint.yml` and `setup.yml`.
- `README.md` and `docs/` are the user-facing behavior, kept in step with every change: the README's steps and settings tables, `docs/xfs.md`, `docs/without-the-script.md` (each step by hand, so a change to a `step_*` function changes its commands there) and `docs/things-to-know.md`.

## Rules

- Every step is idempotent: a second run in a row changes nothing and restarts nothing.
- Config files are written with `write_file`, which writes, and returns success, only when the content changed, so a service restarts only then.
- A choice is a `DEVOPSY_*` setting with a default in `load_settings`, listed in `SETTINGS` (so it is saved), in `usage` and in the README's table.
- `usage` runs before `preflight`, so `--help` works anywhere, as any user, and shows the saved settings when it can read them.
- Settings are validated, then saved, before any step runs (`validate_settings`, `save_settings`): a failed run remembers them, and a typo never sticks.
- A setting applies its state on every run, both ways (for example `DEVOPSY_KDUMP=on` puts back what `off` took away).
- Never change the SSH server's configuration: providers set it up, and a mistake there locks the operator out.
- No host firewall: the provider's covers it (README.md).
- Debian 13 and Ubuntu 26.04 only, through apt and systemd directly, with no configuration management: each release is tested before `preflight` lists it, and `DEVOPSY_FORCE=1` runs on any other.
- Docker's apt repository is per distribution, `download.docker.com/linux/$ID`.
- On Ubuntu GNU's coreutils stay the active ones (`coreutils-from-gnu`), since devopsy-cli's scripts on servers expect them (for example GNU `tail`, `mv -T`).
- The base step names uutils' for removal (`coreutils-from-uutils-`, `--allow-remove-essential`), since the two conflict over the essential `coreutils` and apt keeps a manual one over a plain install of GNU's.
- Installs pass `NEEDRESTART_SUSPEND=1`, so Ubuntu's needrestart neither restarts services nor reports into the output.
- Never create or print secrets: the deploy user's keys are devopsy-cli's (`--ssh-keys`), made on the operator's machine.
- Setup is a bootstrap of the host only: per-project deployment belongs in projects' `.devopsy/`, and Traefik is released like any project, so nothing here knows of Traefik.
- The only setting of devopsy's this writes is the release root (`DEVOPSY_ROOT`, as `releases: root` in the deploy user's devopsy config, in a file marked as written here).
- A setup script, never a CLI: no arguments but `--help`, every step on every run, and no command left on the server (no step names, no subcommands, no installed copy that updates itself).
- What a server needs after setup is devopsy and plain SSH.
- A rerun upgrades what the script installed and nothing else: the apt packages it names (an `apt-get install` upgrades an installed one), Docker among them, and devopsy (`devopsy --upgrade` as the deploy user, a failure only warning); never a `dist-upgrade`.
- setup.sh never reboots, since a rerun on a live server would take its sites down; what needs a reboot raises the restart flag a kernel update does (`/run/reboot-required`, `devopsy-server` in its `.pkgs`), only when the reboot changes something.

## Steps

- devopsy belongs to the deploy user, in `/usr/local/lib/devopsy` (`step_cli`), so `devopsy --upgrade` needs no root: it resolves the `/usr/local/bin/devopsy` link and replaces the file in its own directory.
- devopsy is never in the deploy user's home: homes are mode 700 or 750 on some distributions, and the link would then work only for its owner.
- `/usr/local/bin` stays root's, and SSH sessions without a login shell have it in `PATH`, unlike `~/.local/bin`.
- The installer runs as the deploy user, so root never runs what it downloads.
- No version setting: a rerun runs `devopsy --upgrade`, so a pinned version would last only until the next rerun.
- devopsy-cli's end-to-end servers copy this host setup (`e2e/Dockerfile` and `e2e/daemon.json` there: Docker with Buildx, the /24 address pools), so a change to the docker step's packages or `daemon.json` goes there too.
- Never mirrored there: `apparmor`, which on a host with AppArmor would start confining the privileged Docker-in-Docker servers' inner containers, and the socket buffers, the host's.
- The base step turns off systemd-resolved's LLMNR and multicast DNS (`/etc/systemd/resolved.conf.d/90-devopsy.conf`) on both releases, not as a setting: a server never resolves names on its local network, and Debian 13's resolved answers LLMNR on port 5355 of every address.
- The resolved drop-in is written where resolved is missing or masked too, for when it comes, and resolved restarts when the file was written or while 5355 is still open, so a run cut after writing is finished by the next.
- The base step frees the memory the kernel keeps for kexec (`/etc/default/grub.d/zz-devopsy.cfg`, after the image's drop-ins): `kho=off` on every server, as no setting since nothing on a devopsy server kexecs.
- kdump is a setting, `DEVOPSY_KDUMP` (`on` by default): crash dumps are a capability the image chose, which setup.sh does not undo unasked.
- `DEVOPSY_KDUMP=off` takes out `crashkernel=` where `kdump-tools.cfg` adds it and disables kdump-tools' service, which fails without the memory; never purged, since some images depend on it.
- `kho=off` goes on every server, not only on a kernel with Kexec HandOver on by default: a later kernel with it on has it from its first boot without a rerun, and a kernel without it passes the word to user space, which ignores it.
- The log says what the base step frees for kexec and why, with the size it reads (KHO's from the CMA pageblocks in `/proc/pagetypeinfo`, kdump's from `kexec_crash_size`).
- The base step raises the restart flag for kexec's memory only when the running kernel holds KHO's scratch or a crash kernel to free, or kdump comes back: a flag for nothing is a banner asking for a reboot that changes nothing, and an automatic reboot taking the sites down for it.
- unattended-upgrades takes the flag at `DEVOPSY_AUTO_REBOOT_TIME`, even on a day with nothing to upgrade.
- `update-grub` runs while GRUB's config does not say what the drop-in does yet, never only when the drop-in was written, so a run cut between the two is finished by the next.
- The docker step raises the socket buffers to 7.5 MB (`/etc/sysctl.d/90-devopsy-net.conf`, `net.core.rmem_max` and `wmem_max`) for a Cloudflare Tunnel's QUIC, which otherwise warns and runs on the kernel's 208 KB maximum.
- The socket buffers are here, not a setting nor a template's: `net.core` is the host kernel's, not a network namespace's, so no project can set it, and it changes nothing without a tunnel.
- Sysctl files are written with `write_file` and applied with `sysctl -p` on every run (as the swap step's `vm.swappiness`), never only when written, so a run failing at `sysctl` is finished by the next.
- `daemon.json` is merged, never written whole (`step_docker`, with `jq`): its four keys (`log-driver`, `log-opts`, `live-restore`, `default-address-pools`) are setup's and replaced, with a warning when they held something else, and every other key stays, since others edit that file too (for example an HTTP proxy's `proxies`).
- The address pools are a setting, `DEVOPSY_ADDRESS_POOLS`, which the warning names, so no prompt: setup.sh often runs without a terminal (`curl | bash`), with nowhere to remember a choice, and the pools are the one key to change.
- `daemon.json` is compared as JSON (`jq -cS`), so a file saying the same in other words is not rewritten and Docker not restarted.
- A `daemon.json` that is not a JSON object stops setup.sh, the file as it is.
- A key setup.sh stops setting is left in `daemon.json`.
- Docker looks for AppArmor once per daemon, so `apparmor` installed under a running daemon changes nothing until it restarts: `docker_apparmor` restarts Docker when the kernel's `enabled` flag is Y, securityfs has apparmor, `/sbin/apparmor_parser` is there (Docker's own test; without the parser it only warns) and `docker info` lacks `name=apparmor`, once, since the restarted daemon reports it.
- Running containers keep their profile (none) through that restart (`live-restore`) until they next start.
- Provider block volumes are mounted by hand before setup, where releases should live (for example `/srv`, a `srv.mount` replacing the provider's unit, with `DEVOPSY_ROOT=/srv`), and Docker waits for the mount (`RequiresMountsFor=/srv` in a `docker.service.d` drop-in): containers starting before it write their bind mounts to the root disk, hidden under the volume.
- Ubuntu's `sudo` is sudo-rs, which reads `/etc/sudoers.d` too, and its kernel has AppArmor, which Docker applies to containers (`docker-default`).

## Checks

```sh
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable setup.sh test/run.sh
```

The scripts inside `cloud-init.yaml`, extracted first:

```sh
rm -rf /tmp/ci && mkdir /tmp/ci && i=0
for p in $(docker run --rm -v "$PWD:/w" -w /w mikefarah/yq:4 \
  '.write_files[] | select(.permissions == "0755") | .path' cloud-init.yaml); do
  i=$((i + 1))
  docker run --rm -v "$PWD:/w" -w /w mikefarah/yq:4 \
    ".write_files[] | select(.path == \"$p\") | .content" cloud-init.yaml >"/tmp/ci/$i-${p##*/}"
done
{ echo '#!/bin/sh'; docker run --rm -v "$PWD:/w" -w /w mikefarah/yq:4 '.runcmd[0]' cloud-init.yaml; } >/tmp/ci/runcmd
{ echo '#!/bin/sh'; docker run --rm -v "$PWD:/w" -w /w mikefarah/yq:4 '.bootcmd[0]' cloud-init.yaml; } >/tmp/ci/bootcmd
docker run --rm -v /tmp/ci:/mnt -w /mnt koalaman/shellcheck:stable -S warning $(ls /tmp/ci)
```

`cloud-init.yaml` itself, with Debian 13's cloud-init:

```sh
docker run --rm -v "$PWD:/w:ro" debian:trixie sh -c 'apt-get update -qq &&
  apt-get install -y -qq --no-install-recommends cloud-init >/dev/null &&
  cloud-init schema -c /w/cloud-init.yaml'
```

`setup.sh` on both releases at once, about a minute (`test/run.sh ubuntu:26.04` runs one):

```sh
test/run.sh
```

- `test/run.sh` runs `setup.sh` in a privileged container per release, systemd its first process, with its own Docker (`test/Dockerfile`, systemd-resolved added as cloud images have it), and checks what the first run set up, that a second wrote, created, restarted and updated nothing, and the runs after with changed settings.
- What `test/run.sh` checks: Docker, the deploy user and its keys, devopsy, the socket buffers, LLMNR closed, the kernel's arguments for kexec's memory and the restart flag (from kdump's drop-in and an `update-grub` planted in both), a key of another's in `daemon.json` kept, pools changed by hand replaced with a warning, and `DEVOPSY_KDUMP` off then on.
- A new check goes in `test/run.sh`, and a new supported release is a line of its default list and of `setup.yml`'s matrix.
- `test/run.sh` cannot show AppArmor (the container shares the host's kernel), swap (`DEVOPSY_SWAP` stays empty, since `swapon` would act on the host), `--help` and saved settings, or the XFS conversion; the socket buffers it sets are the host's.
- CI runs `lint.yml` (shellcheck and the schema) on every push, and `setup.yml` (`test/run.sh`, one job per release) on a push that changes `setup.sh` or the test, weekly (Docker's repository, the releases' packages and defaults and devopsy's installer change without a commit here) and on demand; a newer push to a branch cancels the run before it.
- What a container cannot show is checked on a real machine, an OrbStack one (`orb create debian:trixie devopsy-test`, `orb create ubuntu:resolute devopsy-test`) or a cloud server: the script with test settings, again without them, `--help`, then the machine deleted (`orb delete -f devopsy-test`).
- OrbStack machines lack openssh-server and mask systemd-resolved; to reproduce the cloud's port 53 clash, bind a listener to 127.0.0.53:53 before starting acme-dns.
- Right after a file is edited, OrbStack's file sharing can serve a stale copy to a machine or a `docker run` mount, so a surprising result is run again before it is trusted.
- Reaching a machine's IP or `<machine>.orb.local` from macOS makes OrbStack ask for admin rights, so go through `ssh <user>@<machine>@orb`, and test public DNS and certificates on a real server.

## Areas

Each area is read when its line says so; its history, `internals/<area>.history.md`, as Workflow's Docs says. The root's own sections have `internals/rules.history.md`, `internals/steps.history.md` and `internals/checks.history.md`.

- `internals/xfs.md`: the XFS root, boot by boot, its layouts, GRUB, the partitions' numbers and names, Ubuntu's and Vultr's differences, what it refuses and how it is tested (`cloud-init.yaml`); read when a task touches `cloud-init.yaml` or a server's disk layout.
