# AGENTS.md

devopsy-server prepares a Debian 13 or Ubuntu 26.04 host for [devopsy](https://github.com/hanoii/devopsy-cli): Docker, the deploy user and devopsy. It is a bash script, `setup.sh`, run as root, often piped from curl, and `cloud-init.yaml`, user data that converts a new server's root to XFS before it.

## Workflow

### Git

- Conventional commits; the subject about 50 characters, 72 at most, the reason in the body: release notes are commit subjects, and tools cut longer ones.
- A commit made with an AI agent ends with one line naming it, `Assisted-by: <agent>:<model> [<effort>]` (for example `Assisted-by: claude-code:claude-opus-5-5 high`), never a session link (for example `Claude-Session`) or `Co-Authored-By`, even when a tool asks for one: GitHub shows a co-author as a person.
- Any word with an `@` in a commit message or a doc goes in backticks (for example `@prod`, `deploy@host`): GitHub links a bare `@name` to that user.
- Commit each change once it is finished and checked, without waiting to be asked: work left uncommitted is lost with its worktree or its session, or mixed into the next change.
- Push and tag only when asked: a push publishes, a tag releases.
- A change of one commit (for example a quick fix) goes straight onto `main`, in the main checkout.
- Any larger task gets one branch, `<type>/<slug>`, its type what it brings to `main` whatever its commits' types (for example `feat/snapshots`, `docs/readme`).
- All of a task's work goes on its branch, reviews' failing tests and their fixes included; never a branch off a task's branch.
- A finished branch is rebased onto `main`, merged with `--no-ff` and deleted.
- A partial merge, only when asked, is rebased and merged the same way and keeps the branch and its worktree, rebased at once onto the merge for the rest of the task.
- A merge takes git's default message, the agent writing none, `Assisted-by` included (`git merge --no-ff --no-edit <branch>`): a conventional subject would repeat its branch's commits in the release notes.
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
- A review brief also asks for the same pattern written twice, for workarounds of the design (Refactors) and for fixes of a symptom.
- A reviewer writes what it tests into the repository as `test:` commits on the task's branch, a failing test that proves a bug kept with a comment naming it, never product code: a harness outside the repository is lost with its round.
- While building or after a review, a bug, an edge case, a name or a verified finding is decided and fixed without asking, a fix with its failing test first, and said in the summary; only what changes the agreed design or user-facing behavior is asked.
- A fix says whether it reaches the cause or only a symptom, and one of a symptom is flagged before it is built: its cause stays, and breaks the next thing.
- Before a branch merges, a review's tests move into the files of what they cover, named for what they check, each comment saying what the test keeps true: a name or file after its round says only when it was written, and a comment naming a bug reads as an open one after its fix.
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
- A README or doc rewritten (for example reworded, split or moved) gets a fact review against the old text and a separate tone review, told nothing of the changes and reading only for prose that sounds generated: a rewording changes facts its author misses.

## Layout

- `setup.sh`: the settings (`load_settings`, `validate_settings`, `save_settings`, `usage`), `preflight`, then one `step_*` function per step, run in order by `main`.
- `cloud-init.yaml`: the XFS conversion, its scripts in `write_files` (`internals/xfs.md`).
- `test/run.sh` and `test/Dockerfile` run `setup.sh` in containers, with fakes of the swap tools in `test/fakes` (Checks).
- `.github/workflows/` holds `lint.yml` and `setup.yml`.
- `README.md` and `docs/` are the user-facing behavior, kept in step with every change: the README's steps and settings tables, `docs/xfs.md`, `docs/without-the-script.md` (each step by hand, so a change to a `step_*` function changes its commands there, never what devopsy sets up, which its end names as devopsy's two setups) and `docs/things-to-know.md`.

## Rules

- Every step is idempotent: a second run in a row changes nothing and restarts nothing.
- Config files are written with `write_file`, which writes, and returns success, only when the content changed, so a service restarts only then.
- A choice is a `DEVOPSY_SERVER_*` setting listed in `SETTINGS` (so it is saved), with its check (`check_setting`), its default (`default_setting`) and its question (`ask_settings`), in `usage` and in the README's table.
- At a terminal (`/dev/tty`, there under `curl | bash` over SSH), every run asks each setting the environment did not set, its current value (saved, else the default) what Enter gives: a rerun is where a setting changes.
- Without a terminal, or with `--yes`, nothing is asked: the environment, then the saved file, then the defaults.
- A setting in the environment is never asked: a scripted run does what its variables say, at a terminal too.
- The deploy user is asked until it exists (`deploy_user`, the saved one), and another one is refused once it does: the first one's home holds the releases.
- A setting's none (`none` for the swap, `never` for the reboot time) is saved empty, and shown as the word.
- The saved file is read for the keys in `SETTINGS` only, any other ignored.
- `usage` runs before `preflight`, so `--help` works anywhere, as any user, and shows the saved settings when it can read them.
- Settings are validated, then saved, before any step runs (`validate_settings`: the environment's before the questions, each answer as it is given, every setting after them; `save_settings`): a failed run remembers them, a typo never sticks, and a saved value no longer valid is offered to change.
- A question sets its variable in the main shell (`ask`), never through a command substitution, so no answer (Ctrl-D) ends the run.
- A command's output read whole goes through a command substitution, never a pipe into `grep -q` or a `grep` that may match nothing: either fails the pipe under `pipefail`.
- A setting applies its state on every run, both ways (for example `DEVOPSY_SERVER_KDUMP=on` puts back what `off` took away).
- Never change the SSH server's configuration: providers set it up, and a mistake there locks the operator out.
- No host firewall: the provider's covers it (`docs/things-to-know.md`).
- Debian 13 and Ubuntu 26.04 only, through apt and systemd directly, with no configuration management: each release is tested before `preflight` lists it, and `DEVOPSY_SERVER_FORCE=1` runs on any other.
- Docker's apt repository is per distribution, `download.docker.com/linux/$ID`, and any other list naming it in an entry (a `.list` or `.sources` file apt reads) is removed before the base step's first `apt-get update`: apt refuses every source while two lists name different keys.
- On Ubuntu GNU's coreutils stay the active ones (`coreutils-from-gnu`), since devopsy-cli's scripts on servers expect them (for example GNU `tail`, `mv -T`).
- The base step names uutils' for removal (`coreutils-from-uutils-`, `--allow-remove-essential`), since the two conflict over the essential `coreutils` and apt keeps a manual one over a plain install of GNU's.
- Installs pass `NEEDRESTART_SUSPEND=1`, so Ubuntu's needrestart neither restarts services nor reports into the output.
- Never create or print secrets: the deploy user's keys are devopsy-cli's (`--ssh-keys`), made on the operator's machine.
- A step a devopsy-cli `--server-setup-howto` topic covers (for example `docker`, `tools`, `kexec-handover`, `kdump`) writes the topic's files with the topic's text: a server set up by hand from the topic and one set up here are the same.
- Setup is a bootstrap of the host only: per-project deployment belongs in projects' `.devopsy/`, and Traefik is released like any project, so nothing here knows of Traefik.
- Nothing here writes devopsy's config (the deploy user's `~/.config/devopsy/`), the release root included: devopsy's settings are devopsy's.
- What devopsy sets up itself is never done here, `--server-setup`'s (`daemon.json`, the socket buffers, the release root and Docker's wait for it, the metadata firewall) and `--project-users setup`'s (other users' processes hidden, what project users need): setup.sh's last line names `--server-setup`, and never runs it, since it asks before changing what someone else set.
- What setup.sh once set and devopsy now does (`daemon.json`'s four keys, the socket buffers' file, a saved `DEVOPSY_ADDRESS_POOLS`, `/proc`'s fstab line, the `devopsy-proc` group and polkit's drop-in) is left as it is, never removed or migrated: devopsy adopts it.
- A setup script, never a CLI: no arguments but `--help` and `--yes`, every step on every run, and no command left on the server (no step names, no subcommands, no installed copy that updates itself).
- What a server needs after setup is devopsy and plain SSH.
- A rerun upgrades what the script installed and nothing else: the apt packages it names (an `apt-get install` upgrades an installed one), Docker among them, and devopsy (`devopsy --upgrade` as the deploy user, a failure only warning); never a `dist-upgrade`.
- setup.sh never reboots, since a rerun on a live server would take its sites down; what needs a reboot raises the restart flag a kernel update does (`/run/reboot-required`, `devopsy-server` in its `.pkgs`), only when the reboot changes something.

## Steps

- devopsy belongs to the deploy user, in `/usr/local/lib/devopsy` (`step_cli`), so `devopsy --upgrade` needs no root: it resolves the `/usr/local/bin/devopsy` link and replaces the file in its own directory.
- devopsy is never in the deploy user's home: homes are mode 700 or 750 on some distributions, and the link would then work only for its owner.
- `/usr/local/bin` stays root's, and SSH sessions without a login shell have it in `PATH`, unlike `~/.local/bin`.
- The installer runs as the deploy user, so root never runs what it downloads.
- No version setting: a rerun runs `devopsy --upgrade`, so a pinned version would last only until the next rerun.
- devopsy-cli's end-to-end servers copy this host setup (`e2e/Dockerfile` and `e2e/entrypoint` there: Docker with Buildx), so a change to the docker step's packages goes there too; their `daemon.json` is devopsy-cli's own.
- Never mirrored there: `apparmor`, which on a host with AppArmor would start confining the privileged Docker-in-Docker servers' inner containers.
- The base step turns off systemd-resolved's LLMNR and multicast DNS (`/etc/systemd/resolved.conf.d/90-devopsy.conf`) on both releases, not as a setting: a server never resolves names on its local network, and Debian 13's resolved answers LLMNR on port 5355 of every address.
- The resolved drop-in is written where resolved is missing or masked too, for when it comes, and resolved restarts when the file was written or while 5355 is still open, so a run cut after writing is finished by the next.
- The base step frees the memory the kernel keeps for kexec (`/etc/default/grub.d/zz-kho-off.cfg`, after the image's drop-ins): `kho=off` on every server, as no setting since nothing on a devopsy server kexecs.
- kdump is a setting, `DEVOPSY_SERVER_KDUMP` (`on` by default): crash dumps are a capability the image chose, which setup.sh does not undo unasked.
- `DEVOPSY_SERVER_KDUMP=off` takes out `crashkernel=` where `kdump-tools.cfg` adds it (`zz-no-crashkernel.cfg`, removed by `on`) and disables kdump-tools' service, which fails without the memory; never purged, since some images depend on it.
- `kho=off` goes on every server, not only on a kernel with Kexec HandOver on by default: a later kernel with it on has it from its first boot without a rerun, and a kernel without it passes the word to user space, which ignores it.
- The log says what the base step frees for kexec and why, with the size it reads (KHO's from the CMA pageblocks in `/proc/pagetypeinfo`, kdump's from `kexec_crash_size`).
- The base step raises the restart flag for kexec's memory only when the running kernel holds KHO's scratch or a crash kernel to free, or kdump comes back: a flag for nothing is a banner asking for a reboot that changes nothing, and an automatic reboot taking the sites down for it.
- unattended-upgrades takes the flag at `DEVOPSY_SERVER_AUTO_REBOOT_TIME`, even on a day with nothing to upgrade.
- `update-grub` runs while GRUB's config does not say what the drop-in does yet, never only when the drop-in was written, so a run cut between the two is finished by the next.
- The swap step checks `/swapfile`, that it is on, and its fstab line each apart, the file made under another name and renamed once it is a swap area, so a run cut between them is finished by the next.
- A new swap size resizes `/swapfile` through a stand-in of the new size (`/swapfile.tmp`) on before the old file goes off, the new `/swapfile` made, turned on, then the stand-in off and removed, so the server is never without swap.
- No swap file is renamed while it is on: the kernel refuses (EPERM), so a swap area is made under another name and renamed before `swapon` (`swap_make`).
- Each part of a resize is checked apart, so a run cut at any point is finished by the next, and one the memory cannot take (`swapoff` failing) leaves the old size, warned, the run going on.
- A swap size is checked against the free space on `/` as it is given (`swap_room`, the stand-in and the new file at once, less what a cut run left on disk, 1 GB left over), so a size the disk cannot hold is asked again, never a disk filled under the sites; a `fallocate` that fails anyway leaves nothing.
- The swap's sysctl file, which marks `/swapfile` as setup.sh's, is written before the file is made, so `none` removes even a file a cut run left.
- `none` removes `/swapfile` only where setup.sh made it (its `90-devopsy-swap.conf`), `/swapfile` turned off before its stand-in and the sysctl file kept while either is left; a server with a swap of its own is never touched.
- `/swapfile` is setup.sh's only where its sysctl file marks it (`own_swaps`): one the server had is its own swap, offered none and taken over only by a size given.
- The swap offered is `/swapfile`'s size where it is setup.sh's, none where the server has a swap of its own, else by the memory (`swap_for_ram`) where it fits on the disk, the default without a terminal too: a default nobody chose never stops a run.
- Sysctl files (the swap step's `vm.swappiness`) are written with `write_file` and applied with `sysctl -p` on every run, never only when written, so a run failing at `sysctl` is finished by the next.
- The base packages are devopsy's tools (devopsy-cli's `--server-setup-howto tools`), `openssh-client` for a sync across servers, and what the steps fetch with and run, never a package for a server's other uses: the admin installs those.
- A package dropped from the list is never removed from a server.
- Docker looks for AppArmor once per daemon, so `apparmor` installed under a running daemon changes nothing until it restarts: `docker_apparmor` restarts Docker when the kernel's `enabled` flag is Y, securityfs has apparmor, `/sbin/apparmor_parser` is there (Docker's own test; without the parser it only warns) and `docker info` lacks `name=apparmor`, once, since the restarted daemon reports it.
- Running containers keep their profile (none) through that restart (`live-restore`, once `--server-setup` set it) until they next start.
- Provider block volumes are mounted by hand before setup, where releases should live (for example `/srv`, a `srv.mount` replacing the provider's unit, the release root devopsy's), and Docker waits for the mount through `--server-setup`'s drop-in (`RequiresMountsFor=` the release root): containers starting before it write their bind mounts to the root disk, hidden under the volume.
- The deploy user gets no sudo: it is root through Docker already, and passwordless sudo would make any shell of it root in one word, outside Docker's and devopsy's logs.
- Ubuntu's kernel has AppArmor, which Docker applies to containers (`docker-default`).

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

- `test/run.sh` runs `setup.sh` in a privileged container per release, systemd its first process, with its own Docker (`test/Dockerfile`, systemd-resolved added as cloud images have it, and sshd), and checks what the first run set up, that a second wrote, created, restarted and updated nothing, devopsy's `--server-setup --yes` after them over the container's own sshd, and the runs after with changed settings.
- `test/run.sh --devopsy <file>` copies that devopsy over the one setup.sh installs, to test a devopsy-cli branch before its tag; the input is `run.sh`'s, never `setup.sh`'s.
- What `test/run.sh` checks: the questions (none without a terminal or with `--yes`, the saved values offered at a terminal through `script`, the deploy user asked until it exists, a setting in the environment not asked, a wrong answer asked again, Ctrl-D stopping the run), `--help` before anything is saved, Docker, the deploy user and its keys, devopsy, the last line naming `--server-setup` and no `daemon.json` or socket buffers' file of setup.sh's, LLMNR closed, the kernel's arguments for kexec's memory and the restart flag (from kdump's drop-in and an `update-grub` planted in both), a swap file left on without its fstab line, resized through its stand-in, a resize the memory cannot take, one cut once the old file went, a size past the free disk, and none, with the fakes of `test/fakes` (`mv` and `rm` refusing a swap file on, `swapon` one never made a swap area or on already, as the kernel does), the size offered for the memory, `DEVOPSY_SERVER_KDUMP` off then on, another list of Docker's repository removed and a comment naming it kept, and of `--server-setup`: `daemon.json`'s parts put with a key of another's kept and pools set by hand kept and recorded, with a container running no restart and the restart flag raised, then Docker's restart confirmed, the socket buffers, the mounts drop-in, the metadata firewall loaded, a run after with nothing to change, and setup.sh's next run touching neither `daemon.json` nor Docker.
- A new check goes in `test/run.sh`, and a new supported release is a line of its default list and of `setup.yml`'s matrix.
- `test/run.sh` cannot show AppArmor (the container shares the host's kernel), a real swap file (`swapon` and `vm.swappiness` would act on the host), `--help`, or the XFS conversion; the socket buffers `--server-setup` sets are the host's, and where the container may not set `net.core` (GitHub's runners) their raise is `--server-setup`'s one failure.
- CI runs `lint.yml` (shellcheck and the schema) on every push, and `setup.yml` (`test/run.sh`, one job per release) on a push that changes `setup.sh` or the test, weekly (Docker's repository, the releases' packages and defaults and devopsy's installer change without a commit here) and on demand; a newer push to a branch cancels the run before it.
- What a container cannot show is checked on a real machine, an OrbStack one (`orb create debian:trixie devopsy-test`, `orb create ubuntu:resolute devopsy-test`) or a cloud server: the script with test settings, again without them, `--help`, then the machine deleted (`orb delete -f devopsy-test`).
- OrbStack machines lack openssh-server and mask systemd-resolved; to reproduce the cloud's port 53 clash, bind a listener to 127.0.0.53:53 before starting acme-dns.
- Right after a file is edited, OrbStack's file sharing can serve a stale copy to a machine or a `docker run` mount, so a surprising result is run again before it is trusted.
- Reaching a machine's IP or `<machine>.orb.local` from macOS makes OrbStack ask for admin rights, so go through `ssh <user>@<machine>@orb`, and test public DNS and certificates on a real server.

## Areas

Each area is read when its line says so; its history, `internals/<area>.history.md`, as Workflow's Docs says. The root's own sections have `internals/rules.history.md`, `internals/steps.history.md` and `internals/checks.history.md`.

- `internals/xfs.md`: the XFS root, boot by boot, its layouts, GRUB, the partitions' numbers and names, Ubuntu's and Vultr's differences, what it refuses and how it is tested (`cloud-init.yaml`); read when a task touches `cloud-init.yaml` or a server's disk layout.
