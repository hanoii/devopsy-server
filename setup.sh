#!/usr/bin/env bash
# Prepares a fresh Debian 13 server for devopsy projects. Run as root:
#
#   curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-server/main/setup.sh \
#     | DEVOPSY_ACME_EMAIL=you@example.com bash
#
# Every step is idempotent: rerun the whole script, or only some steps, at any
# time. Pass step names as arguments (`bash -s -- docker cli` when piped).
# Settings come from the environment, and are saved to $CONFIG_FILE so a rerun
# reuses them. See README.md.
set -euo pipefail

STEPS=(base swap docker user ssh upgrades cli traefik)
CONFIG_FILE=/etc/devopsy/server.env
# Settings saved to $CONFIG_FILE.
SETTINGS=(
  DEVOPSY_USER DEVOPSY_SUDO DEVOPSY_SSH_KEYS_URL DEVOPSY_SWAP
  DEVOPSY_AUTO_REBOOT_TIME DEVOPSY_ACME_EMAIL DEVOPSY_ACME_PRODUCTION
  DEVOPSY_TRAEFIK_DIR DEVOPSY_TRAEFIK_REPO DEVOPSY_CLI_VERSION
)

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
  DEVOPSY_SSH_KEYS_URL=${DEVOPSY_SSH_KEYS_URL:-}
  DEVOPSY_SWAP=${DEVOPSY_SWAP:-}
  DEVOPSY_AUTO_REBOOT_TIME=${DEVOPSY_AUTO_REBOOT_TIME:-}
  DEVOPSY_ACME_EMAIL=${DEVOPSY_ACME_EMAIL:-}
  DEVOPSY_ACME_PRODUCTION=${DEVOPSY_ACME_PRODUCTION:-0}
  DEVOPSY_TRAEFIK_DIR=${DEVOPSY_TRAEFIK_DIR:-/srv/traefik}
  DEVOPSY_TRAEFIK_REPO=${DEVOPSY_TRAEFIK_REPO:-https://github.com/hanoii/devopsy-traefik.git}
  DEVOPSY_CLI_VERSION=${DEVOPSY_CLI_VERSION:-main}
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
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$@" >/dev/null
}

preflight() {
  [ "$(id -u)" = 0 ] || die "run as root"
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${ID:-}" != debian ] || [ "${VERSION_ID:-}" != 13 ]; then
    [ "${DEVOPSY_FORCE:-0}" = 1 ] || die "expects Debian 13, found ${PRETTY_NAME:-unknown}. Set DEVOPSY_FORCE=1 to try anyway."
    warn "not Debian 13 (${PRETTY_NAME:-unknown}), continuing because DEVOPSY_FORCE=1"
  fi
}

step_base() {
  log "base packages"
  apt-get update -q >/dev/null
  apt_install ca-certificates curl git openssh-server unattended-upgrades sudo
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
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi
  if write_file /etc/apt/sources.list.d/docker.sources <<EOF; then
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $VERSION_CODENAME
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt-get update -q >/dev/null
  fi

  log "docker: installing"
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Rotated logs, so containers cannot fill the disk, and live-restore, so a
  # Docker upgrade does not stop running containers.
  if write_file /etc/docker/daemon.json <<'EOF'; then
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  },
  "live-restore": true
}
EOF
    log "docker: restarting to apply daemon.json"
    systemctl restart docker
  fi
  systemctl enable --now docker >/dev/null 2>&1
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

  if [ "$DEVOPSY_SUDO" = 1 ]; then
    echo "$DEVOPSY_USER ALL=(ALL) NOPASSWD:ALL" | write_file "/etc/sudoers.d/90-devopsy" 440 || true
  else
    rm -f /etc/sudoers.d/90-devopsy
  fi

  # authorized_keys: what it has, plus root's, plus DEVOPSY_SSH_KEYS_URL.
  home=$(getent passwd "$DEVOPSY_USER" | cut -d: -f6)
  keys=$home/.ssh/authorized_keys
  install -d -m 700 -o "$DEVOPSY_USER" -g "$DEVOPSY_USER" "$home/.ssh"
  tmp=$(mktemp)
  {
    [ -f "$keys" ] && cat "$keys"
    [ -f /root/.ssh/authorized_keys ] && cat /root/.ssh/authorized_keys
    if [ -n "$DEVOPSY_SSH_KEYS_URL" ]; then
      curl -fsSL "$DEVOPSY_SSH_KEYS_URL" || warn "user: could not fetch $DEVOPSY_SSH_KEYS_URL"
      echo
    fi
  } | grep -E '^(ssh-|ecdsa-|sk-)' | awk '!seen[$0]++' >"$tmp" || true
  if [ -s "$tmp" ]; then
    install -m 600 -o "$DEVOPSY_USER" -g "$DEVOPSY_USER" "$tmp" "$keys"
    log "user: $(wc -l <"$keys") authorized key(s) for $DEVOPSY_USER"
  else
    warn "user: no SSH keys for $DEVOPSY_USER. Set DEVOPSY_SSH_KEYS_URL (for example https://github.com/<you>.keys)."
  fi
  rm -f "$tmp"
}

step_ssh() {
  local home
  home=$(getent passwd "$DEVOPSY_USER" | cut -d: -f6 || true)
  # Never lock ourselves out: only turn passwords off when a key exists.
  if ! [ -s /root/.ssh/authorized_keys ] && ! [ -s "${home:-/nonexistent}/.ssh/authorized_keys" ]; then
    warn "ssh: no authorized keys for root or $DEVOPSY_USER, leaving password login on"
    return
  fi
  # sshd uses the first value it reads, and Debian includes sshd_config.d/*
  # first, in order: 10- wins over cloud-init's 50-cloud-init.conf.
  if write_file /etc/ssh/sshd_config.d/10-devopsy.conf <<'EOF'; then
# Written by devopsy-server setup.sh.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
    if ! /usr/sbin/sshd -t; then
      rm -f /etc/ssh/sshd_config.d/10-devopsy.conf
      die "ssh: invalid sshd configuration, removed 10-devopsy.conf and did not reload"
    fi
    systemctl reload ssh
    log "ssh: password login disabled"
  fi
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
  log "cli: installing devopsy ($DEVOPSY_CLI_VERSION)"
  curl -fsSL "https://raw.githubusercontent.com/hanoii/devopsy-cli/$DEVOPSY_CLI_VERSION/install.sh" \
    | DEVOPSY_VERSION=$DEVOPSY_CLI_VERSION DEVOPSY_INSTALL_DIR=/usr/local/bin sh >/dev/null
}

step_traefik() {
  local dir=$DEVOPSY_TRAEFIK_DIR uid gid docker_gid
  command -v devopsy >/dev/null || die "traefik: devopsy is not installed, run the cli step"
  id "$DEVOPSY_USER" >/dev/null 2>&1 || die "traefik: $DEVOPSY_USER does not exist, run the user step"

  if [ ! -d "$dir/.git" ]; then
    log "traefik: cloning into $dir"
    install -d -o "$DEVOPSY_USER" -g "$DEVOPSY_USER" "$dir"
    as_user git clone -q "$DEVOPSY_TRAEFIK_REPO" "$dir"
  else
    log "traefik: $dir exists, not updating it (git pull and devopsy restart to upgrade)"
  fi

  if [ ! -f "$dir/.devopsy/.env" ]; then
    [ -n "$DEVOPSY_ACME_EMAIL" ] || die "traefik: set DEVOPSY_ACME_EMAIL for Let's Encrypt"
    uid=$(id -u "$DEVOPSY_USER")
    gid=$(id -g "$DEVOPSY_USER")
    docker_gid=$(stat -c %g /var/run/docker.sock)
    {
      echo "TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT1_ACME_EMAIL=$DEVOPSY_ACME_EMAIL"
      if [ "$DEVOPSY_ACME_PRODUCTION" = 1 ]; then
        echo "TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT1_ACME_CASERVER=https://acme-v02.api.letsencrypt.org/directory"
      fi
      echo "DEVOPSY_UID=$uid"
      echo "DEVOPSY_GID=$gid"
      echo "DEVOPSY_DOCKER_GID=$docker_gid"
    } | write_file "$dir/.devopsy/.env" 600
    chown "$DEVOPSY_USER:$DEVOPSY_USER" "$dir/.devopsy/.env"
  else
    log "traefik: keeping the existing .devopsy/.env"
  fi
  install -d -o "$DEVOPSY_USER" -g "$DEVOPSY_USER" "$dir/.devopsy/mnt/letsencrypt"

  log "traefik: starting"
  (cd "$dir" && as_user devopsy up -d --wait --quiet-pull) >/dev/null
  log "traefik: running"
}

main() {
  local steps=("$@") step s known
  preflight
  load_settings
  [ ${#steps[@]} -gt 0 ] || steps=("${STEPS[@]}")
  for step in "${steps[@]}"; do
    known=0
    for s in "${STEPS[@]}"; do [ "$s" = "$step" ] && known=1; done
    [ "$known" = 1 ] || die "unknown step '$step'. Steps: ${STEPS[*]}"
  done
  # Saved before running, so a failed run still remembers its settings.
  save_settings
  for step in "${steps[@]}"; do
    "step_$step"
  done
  log "done: ${steps[*]}"
}

main "$@"
