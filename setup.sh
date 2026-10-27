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
  DEVOPSY_USER DEVOPSY_SUDO DEVOPSY_SWAP DEVOPSY_AUTO_REBOOT_TIME
  DEVOPSY_APT_PACKAGES DEVOPSY_ROOT DEVOPSY_ADDRESS_POOLS
)

usage() {
  cat <<EOF
Prepares a Debian 13 or Ubuntu 26.04 server for devopsy: Docker, the deploy
user, automatic security upgrades and the devopsy CLI. Run it as root, again
at any time: a rerun changes only what differs, and upgrades the packages,
Docker and devopsy.

  curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-server/main/setup.sh | bash

Settings are environment variables, all optional:

  curl -fsSL ... | DEVOPSY_SWAP=2G DEVOPSY_ROOT=/srv bash

  DEVOPSY_USER              The deploy user. Default: devopsy.
  DEVOPSY_ROOT              Where releases live, like /srv on a block
                            volume. Default: the deploy user's home.
  DEVOPSY_SWAP              Size of a swap file to create when the server
                            has no swap, like 2G. Default: none.
  DEVOPSY_AUTO_REBOOT_TIME  Reboot after upgrades that need it, at this
                            time, like 04:00. Default: never.
  DEVOPSY_APT_PACKAGES      Extra apt packages, space separated, like
                            "htop ncdu".
  DEVOPSY_ADDRESS_POOLS     Ranges Docker cuts into /24 networks, space
                            separated. Default: "172.16.0.0/12
                            192.168.0.0/16".
  DEVOPSY_SUDO              1 gives the deploy user passwordless sudo.
                            Default: 0.
  DEVOPSY_FORCE             1 runs on something other than Debian 13 or
                            Ubuntu 26.04. Not saved.

They are saved to $CONFIG_FILE: a rerun without them
reuses them, and a variable set again replaces its saved value (set empty,
like DEVOPSY_SWAP=, it goes back to its default).
EOF
  if [ -r "$CONFIG_FILE" ]; then
    printf '\nSaved on this server:\n\n'
    grep '^DEVOPSY_' "$CONFIG_FILE" | sed 's/^/  /'
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
      [[ $key =~ ^DEVOPSY_[A-Z0-9_]+$ ]] || continue
      if [ -z "${!key+x}" ]; then
        # Values are saved with printf %q.
        eval "$key=$value"
      fi
    done <"$CONFIG_FILE"
  fi

  DEVOPSY_USER=${DEVOPSY_USER:-devopsy}
  DEVOPSY_SUDO=${DEVOPSY_SUDO:-0}
  DEVOPSY_SWAP=${DEVOPSY_SWAP:-}
  DEVOPSY_AUTO_REBOOT_TIME=${DEVOPSY_AUTO_REBOOT_TIME:-}
  DEVOPSY_APT_PACKAGES=${DEVOPSY_APT_PACKAGES:-}
  DEVOPSY_ROOT=${DEVOPSY_ROOT:-}
  DEVOPSY_ADDRESS_POOLS=${DEVOPSY_ADDRESS_POOLS:-172.16.0.0/12 192.168.0.0/16}
}

# Rejects bad values before they are saved, so a typo does not stick.
validate_settings() {
  local pkg name_re='^[a-z0-9][a-z0-9.+-]*(:[a-z0-9]+)?(=[A-Za-z0-9.+:~-]+)?$'
  # Only package names, so the value cannot smuggle apt options in.
  for pkg in $DEVOPSY_APT_PACKAGES; do
    [[ $pkg =~ $name_re ]] || die "'$pkg' in DEVOPSY_APT_PACKAGES is not a package name"
  done
  if [ -n "$DEVOPSY_ROOT" ]; then
    [[ $DEVOPSY_ROOT =~ ^/[A-Za-z0-9._/-]+$ ]] && [ "$DEVOPSY_ROOT" != / ] \
      || die "DEVOPSY_ROOT must be an absolute directory, not /: $DEVOPSY_ROOT"
  fi
  local pool cidr_re='^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|1[0-9]|2[0-4])$'
  [ -n "$DEVOPSY_ADDRESS_POOLS" ] || die "DEVOPSY_ADDRESS_POOLS needs at least one range"
  for pool in $DEVOPSY_ADDRESS_POOLS; do
    [[ $pool =~ $cidr_re ]] || die "'$pool' in DEVOPSY_ADDRESS_POOLS is not a range of /24 or larger, like 10.200.0.0/16"
  done
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
  runuser -u "$DEVOPSY_USER" -- env HOME="$(getent passwd "$DEVOPSY_USER" | cut -d: -f6)" "$@"
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
      [ "${DEVOPSY_FORCE:-0}" = 1 ] || die "expects Debian 13 or Ubuntu 26.04, found ${PRETTY_NAME:-unknown}. Set DEVOPSY_FORCE=1 to try anyway."
      warn "not Debian 13 or Ubuntu 26.04 (${PRETTY_NAME:-unknown}), continuing because DEVOPSY_FORCE=1"
      ;;
  esac
}

step_base() {
  log "base packages"
  apt-get update -q >/dev/null
  apt_install ca-certificates curl git jq openssh-client openssl unattended-upgrades sudo
  # GNU's coreutils, which devopsy's scripts on the server expect (GNU
  # tail, mv -T), where Ubuntu may make Rust's uutils the default. The
  # two packages provide the essential coreutils and conflict, so apt
  # swaps them only when told to remove the other one: installed by hand
  # or by a release upgrade from 24.04, it is never removed otherwise.
  # shellcheck disable=SC1091
  if (. /etc/os-release && [ "${ID:-}" = ubuntu ]); then
    apt_install --allow-remove-essential coreutils-from-gnu coreutils-from-uutils-
  fi

  # Extra packages, space separated (checked in validate_settings).
  if [ -n "$DEVOPSY_APT_PACKAGES" ]; then
    local extra
    read -ra extra <<<"$DEVOPSY_APT_PACKAGES"
    log "base: extra packages: ${extra[*]}"
    apt_install "${extra[@]}"
  fi
}

step_swap() {
  if [ -z "$DEVOPSY_SWAP" ]; then
    log "swap: DEVOPSY_SWAP not set, skipping"
    return
  fi
  if swapon --show=NAME --noheadings | grep -q .; then
    log "swap: already enabled"
  else
    log "swap: creating /swapfile ($DEVOPSY_SWAP)"
    fallocate -l "$DEVOPSY_SWAP" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
  fi
  if echo 'vm.swappiness = 10' | write_file /etc/sysctl.d/90-devopsy-swap.conf; then
    sysctl -q -p /etc/sysctl.d/90-devopsy-swap.conf
  fi
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

  # Rotated logs, so containers cannot fill the disk, and live-restore, so a
  # Docker upgrade does not stop running containers. Address pools of /24
  # networks: Docker's default cuts nearly the same ranges into /16 and /20,
  # about 30 networks, and every project environment takes at least one.
  # The ranges are a setting: a server that must reach a corporate network
  # in them names others, and a rerun keeps them.
  local pool pools=""
  for pool in $DEVOPSY_ADDRESS_POOLS; do
    pools+="${pools:+,}
    {\"base\": \"$pool\", \"size\": 24}"
  done
  if write_file /etc/docker/daemon.json <<EOF; then
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  },
  "live-restore": true,
  "default-address-pools": [$pools
  ]
}
EOF
    log "docker: restarting to apply daemon.json"
    systemctl restart docker
  fi
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
  if ! id "$DEVOPSY_USER" >/dev/null 2>&1; then
    log "user: creating $DEVOPSY_USER"
    useradd --create-home --shell /bin/bash "$DEVOPSY_USER"
  fi
  # The docker group is root-equivalent: this user is trusted.
  if getent group docker >/dev/null; then
    usermod -aG docker "$DEVOPSY_USER"
  fi

  step_user_root

  if [ "$DEVOPSY_SUDO" = 1 ]; then
    echo "$DEVOPSY_USER ALL=(ALL) NOPASSWD:ALL" | write_file "/etc/sudoers.d/90-devopsy" 440 || true
  else
    rm -f /etc/sudoers.d/90-devopsy
  fi

  # Root's authorized keys, so whoever manages the server can also log in as
  # the deploy user. Keys already there are kept.
  home=$(getent passwd "$DEVOPSY_USER" | cut -d: -f6)
  keys=$home/.ssh/authorized_keys
  if [ -s /root/.ssh/authorized_keys ]; then
    install -d -m 700 -o "$DEVOPSY_USER" -g "$DEVOPSY_USER" "$home/.ssh"
    tmp=$(mktemp)
    {
      if [ -f "$keys" ]; then cat "$keys"; fi
      cat /root/.ssh/authorized_keys
    } | awk 'NF && !seen[$0]++' >"$tmp"
    install -m 600 -o "$DEVOPSY_USER" -g "$DEVOPSY_USER" "$tmp" "$keys"
    rm -f "$tmp"
    log "user: copied root's authorized keys to $DEVOPSY_USER"
  else
    warn "user: root has no authorized keys, add some to $keys to log in as $DEVOPSY_USER"
  fi
}

# Where releases live: the deploy user's home, unless DEVOPSY_ROOT names
# another directory (a block volume, say). devopsy reads it from the deploy
# user's own config, releases: root; this step writes that file, marked as
# its own, and never touches one it did not write.
step_user_root() {
  local home config marker="# Written by devopsy-server (DEVOPSY_ROOT)."
  home=$(getent passwd "$DEVOPSY_USER" | cut -d: -f6)
  config=$home/.config/devopsy/config.yaml
  if [ -f "$config" ] && ! head -n 1 "$config" | grep -qxF "$marker"; then
    [ -z "$DEVOPSY_ROOT" ] || warn "user: $config exists and was not written by devopsy-server: set releases: root: $DEVOPSY_ROOT in it yourself"
    return 0
  fi
  if [ -z "$DEVOPSY_ROOT" ]; then
    if [ -f "$config" ]; then
      rm -f "$config"
      log "user: releases live in $home again"
    fi
    return 0
  fi
  # Not recursive: only the root itself, so releases create directories.
  install -d "$DEVOPSY_ROOT"
  chown "$DEVOPSY_USER:$DEVOPSY_USER" "$DEVOPSY_ROOT"
  install -d -m 755 -o "$DEVOPSY_USER" -g "$DEVOPSY_USER" "$home/.config" "$home/.config/devopsy"
  printf '%s\nreleases:\n  root: %s\n' "$marker" "$DEVOPSY_ROOT" | write_file "$config" 644 || true
  chown "$DEVOPSY_USER:$DEVOPSY_USER" "$config"
}

step_upgrades() {
  log "upgrades: unattended security upgrades"
  write_file /etc/apt/apt.conf.d/20auto-upgrades <<'EOF' || true
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  if [ -n "$DEVOPSY_AUTO_REBOOT_TIME" ]; then
    write_file /etc/apt/apt.conf.d/52devopsy-reboot <<EOF || true
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "$DEVOPSY_AUTO_REBOOT_TIME";
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
      || warn "cli: could not upgrade devopsy: 'devopsy --upgrade' as $DEVOPSY_USER tries again"
  else
    log "cli: installing devopsy"
    install -d -m 755 -o "$DEVOPSY_USER" -g "$DEVOPSY_USER" "$dir"
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
}

main "$@"
