#!/usr/bin/env bash
# Prepares a fresh Debian 13 server for devopsy projects. Run as root:
#
#   curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-server/main/setup.sh | bash
#
# Every step is idempotent: rerun the whole script, or only some steps, at any
# time. Pass step names as arguments (`bash -s -- docker cli` when piped).
# The cli step also installs this script as `devopsy-server`, so later runs
# are `devopsy-server [step...]`.
# Settings come from the environment, and are saved to $CONFIG_FILE so a rerun
# reuses them. See README.md.
#
# It prepares the host only: Traefik (devopsy-template-traefik) and projects are
# released onto it with devopsy, like any project.
set -euo pipefail

STEPS=(base swap docker user upgrades cli ci-key)
CONFIG_FILE=/etc/devopsy/server.env
# Settings saved to $CONFIG_FILE.
SETTINGS=(
  DEVOPSY_USER DEVOPSY_SUDO DEVOPSY_SWAP DEVOPSY_AUTO_REBOOT_TIME
  DEVOPSY_CLI_VERSION DEVOPSY_SERVER_VERSION DEVOPSY_APT_PACKAGES
  DEVOPSY_ROOT
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
  DEVOPSY_SWAP=${DEVOPSY_SWAP:-}
  DEVOPSY_AUTO_REBOOT_TIME=${DEVOPSY_AUTO_REBOOT_TIME:-}
  DEVOPSY_APT_PACKAGES=${DEVOPSY_APT_PACKAGES:-}
  DEVOPSY_CLI_VERSION=${DEVOPSY_CLI_VERSION:-latest}
  DEVOPSY_SERVER_VERSION=${DEVOPSY_SERVER_VERSION:-main}
  DEVOPSY_ROOT=${DEVOPSY_ROOT:-}
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
  apt_install ca-certificates curl git jq openssh-client unattended-upgrades sudo

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
  # Docker upgrade does not stop running containers. Address pools of /24
  # networks: Docker's default cuts the same ranges into /16 and /20, about
  # 30 networks, and every project environment takes at least one.
  if write_file /etc/docker/daemon.json <<'EOF'; then
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  },
  "live-restore": true,
  "default-address-pools": [
    {"base": "172.17.0.0/12", "size": 24},
    {"base": "192.168.0.0/16", "size": 24}
  ]
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
  local tmp
  log "cli: installing devopsy ($DEVOPSY_CLI_VERSION)"
  # The installer always comes from main; it installs the release asked for.
  curl -fsSL "https://raw.githubusercontent.com/hanoii/devopsy-cli/main/install.sh" \
    | DEVOPSY_VERSION=$DEVOPSY_CLI_VERSION DEVOPSY_INSTALL_DIR=/usr/local/bin sh >/dev/null

  log "cli: installing devopsy-server ($DEVOPSY_SERVER_VERSION)"
  tmp=$(mktemp)
  curl -fsSL "https://raw.githubusercontent.com/hanoii/devopsy-server/$DEVOPSY_SERVER_VERSION/setup.sh" -o "$tmp"
  head -n 1 "$tmp" | grep -q '^#!/usr/bin/env bash' || die "cli: could not download devopsy-server ($DEVOPSY_SERVER_VERSION)"
  install -m 755 "$tmp" /usr/local/sbin/devopsy-server
  rm -f "$tmp"
}

# An SSH key for CI to log in as the deploy user and run deployments. The
# private key is printed when it is created, or when this step is named
# explicitly (`devopsy-server ci-key`). It stays on the server so it can be
# shown again; anyone with root here has the deploy user anyway.
step_ci_key() {
  local home key line host_key created=0
  id "$DEVOPSY_USER" >/dev/null 2>&1 || die "ci-key: $DEVOPSY_USER does not exist, run the user step"
  home=$(getent passwd "$DEVOPSY_USER" | cut -d: -f6)
  key=$home/.ssh/devopsy_ci_ed25519
  install -d -m 700 -o "$DEVOPSY_USER" -g "$DEVOPSY_USER" "$home/.ssh"

  if [ ! -f "$key" ]; then
    log "ci-key: creating $key"
    as_user ssh-keygen -q -t ed25519 -N '' -C "devopsy-ci@$(hostname)" -f "$key"
    created=1
  fi

  # `restrict` turns off port, agent and X11 forwarding and the pty. Commands
  # still run, which is all CI needs.
  line="restrict $(cat "$key.pub")"
  if ! grep -qxF "$line" "$home/.ssh/authorized_keys" 2>/dev/null; then
    printf '%s\n' "$line" >>"$home/.ssh/authorized_keys"
    chown "$DEVOPSY_USER:$DEVOPSY_USER" "$home/.ssh/authorized_keys"
    chmod 600 "$home/.ssh/authorized_keys"
    log "ci-key: authorized for $DEVOPSY_USER"
  fi

  if [ "$created" = 0 ] && [ "$EXPLICIT_STEPS" = 0 ]; then
    log "ci-key: exists. Run 'devopsy-server ci-key' to print it."
    return
  fi

  cat <<EOF

CI deploy key for $DEVOPSY_USER@$(hostname). In GitLab, add it under
Settings > CI/CD > Variables as a protected variable of type File, for
example DEVOPSY_SSH_KEY. GitLab cannot mask multi-line values, so never
echo it in a job.

$(cat "$key")

Host key fingerprints, to check SSH_KNOWN_HOSTS in CI. From your machine,
'ssh-keyscan <this-server>' must print keys with these fingerprints:

EOF
  for host_key in /etc/ssh/ssh_host_*_key.pub; do
    if [ -f "$host_key" ]; then ssh-keygen -lf "$host_key"; fi
  done
  echo
}

# When run as the installed devopsy-server, replace it with the latest version
# first and run that instead, so a stale copy never runs old steps. Piped runs
# from curl are already current. DEVOPSY_NO_SELF_UPDATE=1 skips it.
self_update() {
  local installed=/usr/local/sbin/devopsy-server tmp
  [ "$(readlink -f "$0" 2>/dev/null)" = "$installed" ] || return 0
  [ "${DEVOPSY_NO_SELF_UPDATE:-0}" != 1 ] || return 0
  [ -z "${DEVOPSY_SELF_UPDATED:-}" ] || return 0

  tmp=$(mktemp)
  if ! curl -fsSL "https://raw.githubusercontent.com/hanoii/devopsy-server/$DEVOPSY_SERVER_VERSION/setup.sh" -o "$tmp" \
    || ! head -n 1 "$tmp" | grep -q '^#!/usr/bin/env bash'; then
    rm -f "$tmp"
    warn "self-update: could not download devopsy-server ($DEVOPSY_SERVER_VERSION), running this copy"
    return 0
  fi
  if cmp -s "$tmp" "$installed"; then
    rm -f "$tmp"
    return 0
  fi
  # install writes a new file, so this running copy is not modified under bash.
  install -m 755 "$tmp" "$installed"
  rm -f "$tmp"
  log "self-update: updated devopsy-server ($DEVOPSY_SERVER_VERSION), restarting"
  DEVOPSY_SELF_UPDATED=1 exec "$installed" "$@"
}

main() {
  local steps=("$@") step s known
  preflight
  load_settings
  self_update "$@"
  EXPLICIT_STEPS=1
  if [ ${#steps[@]} -eq 0 ]; then
    steps=("${STEPS[@]}")
    EXPLICIT_STEPS=0
  fi
  for step in "${steps[@]}"; do
    known=0
    for s in "${STEPS[@]}"; do [ "$s" = "$step" ] && known=1; done
    [ "$known" = 1 ] || die "unknown step '$step'. Steps: ${STEPS[*]}"
  done
  # Saved before running, so a failed run still remembers its settings.
  validate_settings
  save_settings
  for step in "${steps[@]}"; do
    "step_${step//-/_}"
  done
  log "done: ${steps[*]}"
}

main "$@"
