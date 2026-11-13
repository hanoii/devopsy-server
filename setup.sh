#!/usr/bin/env bash
# Prepares a Debian 13 or Ubuntu 26.04 server for devopsy projects. Run as root:
#
#   curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-server/main/setup.sh | bash
#
# Every step is idempotent, so the same command sets up a new server and
# brings an old one up to date: its packages, Docker and devopsy. It takes
# no arguments but --help (`bash -s -- --help` when piped), which lists the
# settings. Settings come from the environment, and are saved to
# $CONFIG_FILE so a rerun reuses them. See README.md.
#
# It prepares the host only: Traefik (devopsy-template-traefik) and projects are
# released onto it with devopsy, like any project.
set -euo pipefail

STEPS=(base swap docker user upgrades cli)
CONFIG_FILE=/etc/devopsy/server.env
# Settings saved to $CONFIG_FILE. A new one also goes in usage and README.md.
SETTINGS=(
  DEVOPSY_SERVER_USER DEVOPSY_SERVER_SWAP DEVOPSY_SERVER_AUTO_REBOOT_TIME
  DEVOPSY_SERVER_KDUMP
)

usage() {
  cat <<EOF
Prepares a Debian 13 or Ubuntu 26.04 server for devopsy: Docker, the deploy
user, automatic security upgrades and the devopsy CLI. Run it as root, again
at any time: a rerun changes only what differs, and upgrades the packages,
Docker and devopsy.

  curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-server/main/setup.sh | bash

Settings are environment variables, all optional:

  curl -fsSL ... | DEVOPSY_SERVER_SWAP=2G bash

  DEVOPSY_SERVER_USER              The deploy user. Default: devopsy.
  DEVOPSY_SERVER_SWAP              Size of a swap file to create when the
                                   server has no swap, like 2G. Default:
                                   none.
  DEVOPSY_SERVER_AUTO_REBOOT_TIME  Reboot after upgrades that need it, at
                                   this time, like 04:00. Default: never.
  DEVOPSY_SERVER_KDUMP             off frees the memory kdump reserves for
                                   a crash kernel, where the image has
                                   kdump-tools, from the next reboot.
                                   Default: on, as the image.
  DEVOPSY_SERVER_FORCE             1 runs on something other than Debian 13
                                   or Ubuntu 26.04. Not saved.

They are saved to $CONFIG_FILE: a rerun without them
reuses them, and a variable set again replaces its saved value (set empty,
like DEVOPSY_SERVER_SWAP=, it goes back to its default).
EOF
  if [ -r "$CONFIG_FILE" ]; then
    printf '\nSaved on this server:\n\n'
    grep '^DEVOPSY_SERVER_' "$CONFIG_FILE" | sed 's/^/  /'
  fi
}

log() { printf '\033[0;36m[devopsy-server]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[devopsy-server]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[0;31m[devopsy-server]\033[0m %s\n' "$*" >&2
  exit 1
}

# Settings: environment first, then the saved file, then the defaults.
load_settings() {
  if [ -f "$CONFIG_FILE" ]; then
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
      case $line in '' | '#'*) continue ;; esac
      key=${line%%=*}
      value=${line#*=}
      [[ $key =~ ^DEVOPSY_SERVER_[A-Z0-9_]+$ ]] || continue
      if [ -z "${!key+x}" ]; then
        # Values are saved with printf %q.
        eval "$key=$value"
      fi
    done <"$CONFIG_FILE"
  fi

  DEVOPSY_SERVER_USER=${DEVOPSY_SERVER_USER:-devopsy}
  DEVOPSY_SERVER_SWAP=${DEVOPSY_SERVER_SWAP:-}
  DEVOPSY_SERVER_AUTO_REBOOT_TIME=${DEVOPSY_SERVER_AUTO_REBOOT_TIME:-}
  DEVOPSY_SERVER_KDUMP=${DEVOPSY_SERVER_KDUMP:-on}
}

# Rejects bad values before they are saved, so a typo does not stick.
validate_settings() {
  case $DEVOPSY_SERVER_KDUMP in on | off) ;; *) die "DEVOPSY_SERVER_KDUMP is on or off, not '$DEVOPSY_SERVER_KDUMP'" ;; esac
}

save_settings() {
  local key
  install -d -m 755 "$(dirname "$CONFIG_FILE")"
  {
    echo "# Written by devopsy-server setup.sh. Environment variables override these."
    for key in "${SETTINGS[@]}"; do
      printf '%s=%q\n' "$key" "${!key}"
    done
  } >"$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

# Writes stdin to $1 only if the content differs. Returns 1 when unchanged, so
# callers can restart a service only when needed.
write_file() {
  local file=$1 mode=${2:-644} tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if [ -f "$file" ] && cmp -s "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
  install -D -m "$mode" "$tmp" "$file"
  rm -f "$tmp"
  log "wrote $file"
}

as_user() {
  runuser -u "$DEVOPSY_SERVER_USER" -- env HOME="$(getent passwd "$DEVOPSY_SERVER_USER" | cut -d: -f6)" "$@"
}

apt_install() {
  # needrestart (Ubuntu) would restart services and report on every install:
  # the steps restart what they change themselves.
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get install -y -q --no-install-recommends "$@" >/dev/null
}

preflight() {
  [ "$(id -u)" = 0 ] || die "run as root"
  # shellcheck disable=SC1091
  . /etc/os-release
  case ${ID:-}:${VERSION_ID:-} in
    debian:13 | ubuntu:26.04) ;;
    *)
      [ "${DEVOPSY_SERVER_FORCE:-0}" = 1 ] || die "expects Debian 13 or Ubuntu 26.04, found ${PRETTY_NAME:-unknown}. Set DEVOPSY_SERVER_FORCE=1 to try anyway."
      warn "not Debian 13 or Ubuntu 26.04 (${PRETTY_NAME:-unknown}), continuing because DEVOPSY_SERVER_FORCE=1"
      ;;
  esac
}

step_base() {
  log "base packages"
  # Another list of Docker's repository than the docker step's (an older
  # install's, a provider's) goes before the first update: apt refuses
  # every source while two lists of it name different keys.
  local f
  for f in /etc/apt/sources.list.d/*; do
    if [ "$f" != /etc/apt/sources.list.d/docker.sources ] && grep -qs download.docker.com "$f"; then
      rm -f "$f"
      log "base: removed $f, another list of Docker's repository"
    fi
  done
  apt-get update -q >/dev/null
  # devopsy's tools (tar, flock, setsid, script, mkfifo, tail), ssh for a
  # sync across servers, and what the steps here fetch with and run.
  apt_install tar util-linux bsdutils coreutils openssh-client ca-certificates curl unattended-upgrades
  # GNU's coreutils, which devopsy's scripts on the server expect (GNU
  # tail, mv -T), where Ubuntu may make Rust's uutils the default. The
  # two packages provide the essential coreutils and conflict, so apt
  # swaps them only when told to remove the other one: installed by hand
  # or by a release upgrade from 24.04, it is never removed otherwise.
  # shellcheck disable=SC1091
  if (. /etc/os-release && [ "${ID:-}" = ubuntu ]); then
    apt_install --allow-remove-essential coreutils-from-gnu coreutils-from-uutils-
  fi

  # Name lookups on the local network, which a server never needs:
  # Debian's systemd-resolved answers LLMNR on port 5355 of every address
  # (Ubuntu's has it off), and multicast DNS when turned on. Set on both,
  # should a default change.
  # Written where resolved is missing too, for when it comes. Restarted
  # when written, or while 5355 is still open: a first run that failed
  # after writing is applied by the next, and an applied one restarts
  # nothing.
  local written=
  write_file /etc/systemd/resolved.conf.d/90-devopsy.conf <<'EOF' && written=1
[Resolve]
LLMNR=no
MulticastDNS=no
EOF
  if systemctl is-active --quiet systemd-resolved &&
    { [ -n "$written" ] || ss -Hltun 'sport = :5355' | grep -q .; }; then
    log "base: restarting systemd-resolved: no LLMNR or multicast DNS"
    systemctl restart systemd-resolved
  fi


  # Memory the kernel keeps for kexec, which nothing on a server uses.
  # Kexec HandOver's scratch memory, held for movable pages only by a
  # kernel that turns it on by default (Ubuntu 26.04's: 646 MB of 2 GB on
  # DigitalOcean, 1.25 GB on Vultr), which page tables, slab and socket
  # buffers cannot use: kho=off on every server, so a later kernel with it
  # on (a release upgrade) has it from its first boot, and one without it
  # passes the word to init, which ignores it. kdump's crash kernel, where
  # kdump-tools adds crashkernel= (Vultr's Ubuntu: 320 MB), is a setting,
  # DEVOPSY_SERVER_KDUMP: off takes crashkernel= out and disables its service
  # (it fails without that memory), on puts both back. Drop-ins after
  # the image's (zz-), the files and lines devopsy's how-to topics
  # (kexec-handover, kdump) write, applied by the next reboot, which the
  # restart flag asks for as a kernel update does (DEVOPSY_SERVER_AUTO_REBOOT_TIME
  # takes it), only when it changes something: the running kernel holds
  # KHO's scratch or a crash kernel to free, or kdump comes back.
  # GRUB's config is updated while it does not say what the drop-ins do,
  # so a run cut after writing is finished by the next, and an applied
  # one updates nothing.
  local grubd=/etc/default/grub.d grubcfg=/boot/grub/grub.cfg kdump='' stale='' reboot='' mb
  if [ -f "$grubd/kdump-tools.cfg" ]; then kdump=$DEVOPSY_SERVER_KDUMP; fi
  # shellcheck disable=SC2016 # grub-mkconfig expands them
  echo 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT kho=off"' |
    write_file "$grubd/zz-kho-off.cfg" || true
  if [ "$kdump" = off ]; then
    # shellcheck disable=SC2016 # grub-mkconfig expands them
    echo 'GRUB_CMDLINE_LINUX_DEFAULT=$(echo "$GRUB_CMDLINE_LINUX_DEFAULT" | sed "s/crashkernel=[^ ]*//g")' |
      write_file "$grubd/zz-no-crashkernel.cfg" || true
  elif [ -f "$grubd/zz-no-crashkernel.cfg" ]; then
    rm -f "$grubd/zz-no-crashkernel.cfg"
    log "base: removed $grubd/zz-no-crashkernel.cfg"
  fi
  if [ -f "$grubcfg" ]; then
    if ! grep -q ' kho=off' "$grubcfg"; then
      stale=1
      # KHO's scratch is the CMA pageblocks of a kernel with no CMA of its
      # own (the rows have the header's four leading words).
      mb=$(awk '/^Pages per block:/ { p = $4 } /^Number of blocks type/ { for (i = 1; i <= NF; i++) if ($i == "CMA") c = i; next }
        c && /^Node/ { n += $c } END { print int(n * p * 4 / 1024) }' /proc/pagetypeinfo 2>/dev/null)
      if [ "${mb:-0}" -gt 0 ]; then
        reboot=1
        log "base: kho=off from the next reboot: Kexec HandOver holds $mb MB for movable pages only, which page tables, slab and socket buffers cannot use, and nothing here kexecs"
      else
        log "base: kho=off from the next reboot, for a kernel that turns Kexec HandOver on (this one does not)"
      fi
    fi
    if [ "$kdump" = off ] && grep -q ' crashkernel=' "$grubcfg"; then
      stale=1
      mb=$(($(cat /sys/kernel/kexec_crash_size 2>/dev/null || echo 0) / 1048576))
      if [ "$mb" -gt 0 ]; then
        reboot=1
        log "base: no crash kernel from the next reboot (DEVOPSY_SERVER_KDUMP=off): frees the $mb MB kdump reserves"
      else
        log "base: no crash kernel from the next reboot (DEVOPSY_SERVER_KDUMP=off)"
      fi
    elif [ "$kdump" = on ] && ! grep -q ' crashkernel=' "$grubcfg"; then
      stale=1 reboot=1
      log "base: kdump's crash kernel back from the next reboot (DEVOPSY_SERVER_KDUMP=on)"
    fi
  fi
  if [ -n "$stale" ] && command -v update-grub >/dev/null; then
    update-grub >/dev/null 2>&1 || die "update-grub failed"
    if [ -n "$reboot" ]; then
      echo '*** System restart required ***' >/run/reboot-required
      grep -qsx devopsy-server /run/reboot-required.pkgs || echo devopsy-server >>/run/reboot-required.pkgs
    fi
  fi
  if [ "$kdump" = off ] && systemctl is-enabled --quiet kdump-tools.service 2>/dev/null; then
    log "base: disabling kdump-tools (DEVOPSY_SERVER_KDUMP=off)"
    systemctl disable --quiet kdump-tools.service
  elif [ "$kdump" = on ] && [ "$(systemctl is-enabled kdump-tools.service 2>/dev/null)" = disabled ]; then
    log "base: enabling kdump-tools (DEVOPSY_SERVER_KDUMP=on)"
    systemctl enable --quiet kdump-tools.service
  fi
}

step_swap() {
  if [ -z "$DEVOPSY_SERVER_SWAP" ]; then
    log "swap: DEVOPSY_SERVER_SWAP not set, skipping"
    return
  fi
  # The file, that it is on, and its fstab line, each checked apart, so a
  # run cut between them is finished by the next. The file is made under
  # another name and renamed once it is a swap area. A server with a swap
  # of its own and no /swapfile is left as it is.
  if [ ! -f /swapfile ] && swapon --show=NAME --noheadings | grep -q .; then
    log "swap: already enabled"
  else
    if [ ! -f /swapfile ]; then
      log "swap: creating /swapfile ($DEVOPSY_SERVER_SWAP)"
      rm -f /swapfile.new
      fallocate -l "$DEVOPSY_SERVER_SWAP" /swapfile.new
      chmod 600 /swapfile.new
      mkswap /swapfile.new >/dev/null
      mv /swapfile.new /swapfile
    fi
    if ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
      log "swap: turning on /swapfile"
      swapon /swapfile
    fi
    if ! grep -q '^/swapfile ' /etc/fstab; then
      log "swap: /swapfile in /etc/fstab, on at every boot"
      echo '/swapfile none swap sw 0 0' >>/etc/fstab
    fi
  fi
  # Applied on every run, written or not: a first run that failed here
  # left the file, and the next would skip it.
  echo 'vm.swappiness = 10' | write_file /etc/sysctl.d/90-devopsy-swap.conf || true
  sysctl -q -p /etc/sysctl.d/90-devopsy-swap.conf
}

step_docker() {
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ ! -f /etc/apt/keyrings/docker.asc ]; then
    log "docker: adding the Docker apt repository"
    install -d -m 755 /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi
  if write_file /etc/apt/sources.list.d/docker.sources <<EOF; then
Types: deb
URIs: https://download.docker.com/linux/$ID
Suites: $VERSION_CODENAME
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt-get update -q >/dev/null
  fi

  # apparmor with it: Docker applies its docker-default profile to
  # containers only when the kernel has AppArmor and apparmor_parser is
  # there, which cloud images vary on and --no-install-recommends never
  # pulls in. The daemon checks once, when it starts (docker_apparmor).
  log "docker: installing"
  apt_install apparmor docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # daemon.json, the socket buffers and the release root are
  # devopsy's --server-setup's, which main names last.
  systemctl enable --now docker >/dev/null 2>&1
  docker_apparmor
}

# Docker (containerd's check, behind a sync.Once) looks for AppArmor once
# per daemon, when it starts: a daemon that started before apparmor was
# installed (a server set up before this script installed it) runs every
# container unconfined until it restarts, which nothing else here does on
# a rerun. So restart it when the host supports AppArmor as Docker tests
# it and the running daemon does not report it. live-restore keeps
# containers running meanwhile, so they get the profile only when they
# next start, restarted or recreated. Without AppArmor in the kernel
# (OrbStack, some cloud kernels) there is nothing to restart for.
docker_apparmor() {
  local enabled
  enabled=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) || enabled=N
  if [ "$enabled" != Y ] || [ ! -d /sys/kernel/security/apparmor ]; then
    log "docker: no AppArmor in this kernel, containers run without it"
    return 0
  fi
  if [ ! -x /sbin/apparmor_parser ]; then
    warn "docker: no /sbin/apparmor_parser, containers run without AppArmor"
    return 0
  fi
  case $(docker_security_options) in
    *'"name=apparmor'*) return 0 ;;
    '') warn "docker: 'docker info' failed, cannot tell whether containers get AppArmor" ;;
    *)
      log "docker: restarting so new containers get AppArmor: the daemon started before apparmor was installed; running containers get it when they next start (restarted or recreated)"
      systemctl restart docker
      case $(docker_security_options) in
        *'"name=apparmor'*) ;;
        *) warn "docker: still no AppArmor in 'docker info' after a restart: containers run without it" ;;
      esac
      ;;
  esac
}

# The running daemon's security options (name=apparmor when it applies
# AppArmor), empty when it does not answer.
docker_security_options() {
  docker info --format '{{json .SecurityOptions}}' 2>/dev/null || true
}

step_user() {
  local home keys tmp
  if ! id "$DEVOPSY_SERVER_USER" >/dev/null 2>&1; then
    log "user: creating $DEVOPSY_SERVER_USER"
    useradd --create-home --shell /bin/bash "$DEVOPSY_SERVER_USER"
  fi
  # The docker group is root-equivalent: this user is trusted.
  if getent group docker >/dev/null; then
    usermod -aG docker "$DEVOPSY_SERVER_USER"
  fi

  # Root's authorized keys, so whoever manages the server can also log in as
  # the deploy user. Keys already there are kept.
  home=$(getent passwd "$DEVOPSY_SERVER_USER" | cut -d: -f6)
  keys=$home/.ssh/authorized_keys
  if [ -s /root/.ssh/authorized_keys ]; then
    install -d -m 700 -o "$DEVOPSY_SERVER_USER" -g "$DEVOPSY_SERVER_USER" "$home/.ssh"
    tmp=$(mktemp)
    {
      if [ -f "$keys" ]; then cat "$keys"; fi
      cat /root/.ssh/authorized_keys
    } | awk 'NF && !seen[$0]++' >"$tmp"
    install -m 600 -o "$DEVOPSY_SERVER_USER" -g "$DEVOPSY_SERVER_USER" "$tmp" "$keys"
    rm -f "$tmp"
    log "user: copied root's authorized keys to $DEVOPSY_SERVER_USER"
  else
    warn "user: root has no authorized keys, add some to $keys to log in as $DEVOPSY_SERVER_USER"
  fi
}

step_upgrades() {
  log "upgrades: unattended security upgrades"
  write_file /etc/apt/apt.conf.d/20auto-upgrades <<'EOF' || true
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  if [ -n "$DEVOPSY_SERVER_AUTO_REBOOT_TIME" ]; then
    write_file /etc/apt/apt.conf.d/52devopsy-reboot <<EOF || true
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "$DEVOPSY_SERVER_AUTO_REBOOT_TIME";
EOF
  else
    rm -f /etc/apt/apt.conf.d/52devopsy-reboot
  fi
  systemctl enable --now unattended-upgrades >/dev/null 2>&1
}

step_cli() {
  local dir=/usr/local/lib/devopsy link=/usr/local/bin/devopsy
  # The binary is the deploy user's, in a directory of its own, so it runs
  # `devopsy --upgrade` itself, without root, as this step does on a rerun;
  # the link keeps it in everyone's PATH, SSH sessions without a login shell
  # included. From /: the deploy user cannot read root's working directory.
  if [ -x "$dir/devopsy" ]; then
    log "cli: upgrading devopsy"
    # Not fatal: the host is set up, and the installed devopsy keeps working.
    (cd / && as_user "$dir/devopsy" --upgrade) \
      || warn "cli: could not upgrade devopsy: 'devopsy --upgrade' as $DEVOPSY_SERVER_USER tries again"
  else
    log "cli: installing devopsy"
    install -d -m 755 -o "$DEVOPSY_SERVER_USER" -g "$DEVOPSY_SERVER_USER" "$dir"
    (cd / && curl -fsSL "https://raw.githubusercontent.com/hanoii/devopsy-cli/main/install.sh" \
      | as_user DEVOPSY_INSTALL_DIR="$dir" sh >/dev/null)
  fi
  if [ "$(readlink "$link" 2>/dev/null)" != "$dir/devopsy" ]; then
    # Renamed into place, so devopsy never goes missing under a release.
    ln -s "$dir/devopsy" "$link.new"
    mv -T "$link.new" "$link"
    log "cli: linked $link to $dir/devopsy"
  fi
}

main() {
  local step
  case ${1:-} in
    -h | --help)
      usage
      exit 0
      ;;
    '') ;;
    *) die "'$1': setup.sh takes no arguments but --help, settings are variables" ;;
  esac
  preflight
  load_settings
  # Saved before running, so a failed run still remembers its settings.
  validate_settings
  save_settings
  for step in "${STEPS[@]}"; do
    "step_$step"
  done
  log "done: ${STEPS[*]}"
  # What devopsy sets up itself (daemon.json, the socket buffers, the release
  # root and Docker's wait for it, the metadata firewall) runs from the
  # operator's machine, which asks before it changes what someone set.
  log "next, from your machine: devopsy @$DEVOPSY_SERVER_USER@<server>: --server-setup"
}

main "$@"
