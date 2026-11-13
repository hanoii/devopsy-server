#!/usr/bin/env bash
# Prepares a Debian 13 or Ubuntu 26.04 server for devopsy projects. Run as root:
#
#   curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-server/main/setup.sh | bash
#
# Every step is idempotent, so the same command sets up a new server and
# brings an old one up to date: its packages, Docker and devopsy. At a
# terminal it asks for each setting, the saved value or the default in
# brackets; without one, or with --yes, it asks nothing. A setting in the
# environment is taken as it is, never asked. Settings are saved to
# $CONFIG_FILE, so a rerun offers them again. --help lists them. See
# README.md.
#
# It prepares the host only: Traefik (devopsy-template-traefik) and projects are
# released onto it with devopsy, like any project.
set -euo pipefail

STEPS=(base swap docker user upgrades cli)
CONFIG_FILE=/etc/devopsy/server.env
# Settings saved to $CONFIG_FILE. A new one also goes in check_setting,
# default_setting, ask_settings, usage and README.md.
SETTINGS=(
  DEVOPSY_SERVER_USER DEVOPSY_SERVER_SWAP DEVOPSY_SERVER_AUTO_REBOOT_TIME
  DEVOPSY_SERVER_KDUMP
)
# The swap step's sysctl file, which also says /swapfile is setup.sh's.
SWAP_SYSCTL=/etc/sysctl.d/90-devopsy-swap.conf

usage() {
  cat <<EOF
Prepares a Debian 13 or Ubuntu 26.04 server for devopsy: Docker, the deploy
user, automatic security upgrades and the devopsy CLI. Run it as root, again
at any time: a rerun changes only what differs, and upgrades the packages,
Docker and devopsy.

  curl -fsSL https://raw.githubusercontent.com/hanoii/devopsy-server/main/setup.sh | bash

At a terminal it asks for each setting, the saved value or the default in
brackets, Enter keeping it. Without a terminal, or with --yes, it asks
nothing (curl -fsSL ... | bash -s -- --yes). A setting given as a variable
is taken as it is and not asked:

  curl -fsSL ... | DEVOPSY_SERVER_SWAP=2G bash

  DEVOPSY_SERVER_USER              The deploy user, devopsy's login, set by
                                   the first run. Default: devopsy.
  DEVOPSY_SERVER_SWAP              Size of /swapfile, like 2G or 512M, or
                                   none. Default: by the memory, where the
                                   server has no swap of its own.
  DEVOPSY_SERVER_AUTO_REBOOT_TIME  Reboot after upgrades that need it, at
                                   this time, like 04:00, or never.
                                   Default: never.
  DEVOPSY_SERVER_KDUMP             off frees the memory kdump reserves for
                                   a crash kernel, where the image has
                                   kdump-tools, from the next reboot.
                                   Default: on, as the image.
  DEVOPSY_SERVER_FORCE             1 runs on something other than Debian 13
                                   or Ubuntu 26.04 without asking. Not
                                   saved.

They are saved to $CONFIG_FILE.
EOF
  local saved
  # Read whole, never a grep in a pipe, which fails under pipefail when it
  # matches nothing (a file of an older setup.sh's keys).
  saved=$(sed -n 's/^DEVOPSY_SERVER_/  &/p' "$CONFIG_FILE" 2>/dev/null) || true
  if [ -n "$saved" ]; then
    printf '\nSaved on this server:\n\n%s\n' "$saved"
  fi
}

# say <color> <message>: one line, the prefix in the color (36 cyan, 33
# yellow, 31 red), without a newline: log, warn, die and ask add theirs.
say() { printf '\033[0;%sm[devopsy-server]\033[0m %s' "$1" "$2"; }
log() { say 36 "$*"; echo; }
warn() { { say 33 "$*"; echo; } >&2; }
die() {
  { say 31 "$*"; echo; } >&2
  exit 1
}

# Whether to ask: a terminal this run can open (/dev/tty, there under
# curl | bash over ssh, not under cloud-init or ssh -T), and no --yes.
yes=
can_ask() {
  [ -z "$yes" ] && { : </dev/tty; } 2>/dev/null
}

# ask <var> <question> [<default>]: sets the variable to the answer, read
# from the terminal, the default when it is empty. In the main shell, never
# a command substitution, so its die on no answer (Ctrl-D) ends the run.
ask() {
  local answer
  say 36 "$2${3:+ [$3]}: " >/dev/tty
  IFS= read -r answer </dev/tty || die "no answer to: $2"
  printf -v "$1" %s "${answer:-${3:-}}"
}

# Settings: the environment first, then the saved file, then the defaults.
# from_env lists those the environment set, which are never asked; saved_*
# hold the file's values.
from_env=' '
load_settings() {
  local key line value
  for key in "${SETTINGS[@]}"; do
    if [ -n "${!key+x}" ]; then from_env+="$key "; fi
  done
  if [ -f "$CONFIG_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case $line in '' | '#'*) continue ;; esac
      key=${line%%=*}
      value=${line#*=}
      # Another prefix (an older setup.sh's DEVOPSY_*) is ignored.
      [[ " ${SETTINGS[*]} " == *" $key "* ]] || continue
      # Values are saved with printf %q.
      eval "saved_$key=$value"
      [ -n "${!key+x}" ] || eval "$key=$value"
    done <"$CONFIG_FILE"
  fi
  for key in "${SETTINGS[@]}"; do
    [ -n "${!key+x}" ] || printf -v "$key" %s "$(default_setting "$key")"
    printf -v "$key" %s "$(normal_setting "$key" "${!key}")"
  done
}

default_setting() {
  case $1 in
    DEVOPSY_SERVER_USER) deploy_user || echo devopsy ;;
    DEVOPSY_SERVER_SWAP) swap_default ;;
    DEVOPSY_SERVER_KDUMP) echo on ;;
  esac
}

# deploy_user: the server's deploy user once it exists, the saved one, else
# the owner of devopsy's directory (step_cli), which a server set up by
# any version has, else nothing (exit 1).
deploy_user() {
  local user=${saved_DEVOPSY_SERVER_USER:-}
  if [ -z "$user" ] && [ -d /usr/local/lib/devopsy ]; then
    user=$(stat -c %U /usr/local/lib/devopsy)
    [ "$user" != root ] || user=
  fi
  [ -n "$user" ] && id "$user" >/dev/null 2>&1 && echo "$user"
}

# none_word <key>: the word a setting takes for none, saved empty: the
# swap's none and the reboot time's never; nothing for the others.
none_word() {
  case $1 in
    DEVOPSY_SERVER_SWAP) echo none ;;
    DEVOPSY_SERVER_AUTO_REBOOT_TIME) echo never ;;
  esac
}

# normal_setting <key> <value>: the value as saved, its none word empty.
normal_setting() {
  local none
  none=$(none_word "$1")
  if [ -n "$none" ] && [ "$2" = "$none" ]; then return; fi
  printf '%s\n' "$2"
}

# shown_setting <key>: the value as asked, empty as its none word.
shown_setting() {
  local value=${!1}
  printf '%s\n' "${value:-$(none_word "$1")}"
}

# check_setting <key> <value>: says what is wrong with the value, else
# nothing. The deploy user is fixed once it exists: another one would
# start with none of the releases, which stay in the first one's home. A
# swap size must fit on the disk.
check_setting() {
  local key=$1 value=$2 user need free
  case $key in
    DEVOPSY_SERVER_USER)
      if ! [[ $value =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        echo "$key is a user name (lowercase letters, digits, _ and -), not '$value'"
      elif user=$(deploy_user) && [ "$value" != "$user" ]; then
        echo "$key is $user, this server's deploy user: a server keeps its deploy user, whose home holds the releases"
      fi
      ;;
    DEVOPSY_SERVER_SWAP)
      if ! [[ $value =~ ^([1-9][0-9]*[MG])?$ ]]; then
        echo "$key is a size in M or G, like 2G or 512M, or none, not '$value'"
      elif need=$(swap_room "$value") && free=$(df --output=avail -B1 / | tail -n 1) && [ "$need" -gt "$free" ]; then
        echo "$key $value needs $(swap_size_down "$need") free on /, which has $(swap_size_down "$free")"
      fi
      ;;
    DEVOPSY_SERVER_AUTO_REBOOT_TIME)
      [[ $value =~ ^(([01][0-9]|2[0-3]):[0-5][0-9])?$ ]] || echo "$key is a time, like 04:00, or never, not '$value'"
      ;;
    DEVOPSY_SERVER_KDUMP)
      case $value in on | off) ;; *) echo "$key is on or off, not '$value'" ;; esac
      ;;
  esac
}

# validate_settings [<keys>...]: rejects bad values before they are saved,
# so a typo does not stick; every setting without keys.
validate_settings() {
  local key problem
  [ $# -gt 0 ] || set -- "${SETTINGS[@]}"
  for key in "$@"; do
    problem=$(check_setting "$key" "${!key}")
    [ -z "$problem" ] || die "$problem"
  done
}

# The questions, for every setting the environment did not set, again on
# every run, each with its current value as the answer Enter gives: a
# rerun is where a setting changes. The deploy user only until it exists,
# kdump only where the image has kdump-tools.
ask_settings() {
  local key question value problem
  for key in "${SETTINGS[@]}"; do
    [[ $from_env != *" $key "* ]] || continue
    case $key in
      DEVOPSY_SERVER_USER)
        ! deploy_user >/dev/null || continue
        question="deploy user, the one devopsy logs in as"
        ;;
      DEVOPSY_SERVER_SWAP) question="swap file size, like 2G or 512M, or none" ;;
      DEVOPSY_SERVER_AUTO_REBOOT_TIME) question="reboot after upgrades that need it at, like 04:00, or never" ;;
      DEVOPSY_SERVER_KDUMP)
        [ -f /etc/default/grub.d/kdump-tools.cfg ] || continue
        question="kdump: on keeps its crash kernel's memory reserved, off frees it"
        ;;
    esac
    while :; do
      ask value "$question" "$(shown_setting "$key")"
      value=$(normal_setting "$key" "$value")
      problem=$(check_setting "$key" "$value")
      [ -n "$problem" ] || break
      warn "$problem"
    done
    printf -v "$key" %s "$value"
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
  runuser -u "$DEVOPSY_SERVER_USER" -- env HOME="$(getent passwd "$DEVOPSY_SERVER_USER" | cut -d: -f6)" "$@"
}

apt_install() {
  # needrestart (Ubuntu) would restart services and report on every install:
  # the steps restart what they change themselves.
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get install -y -q --no-install-recommends "$@" >/dev/null
}

preflight() {
  local answer
  [ "$(id -u)" = 0 ] || die "run as root"
  # shellcheck disable=SC1091
  . /etc/os-release
  case ${ID:-}:${VERSION_ID:-} in
    debian:13 | ubuntu:26.04) ;;
    *)
      if [ "${DEVOPSY_SERVER_FORCE:-0}" = 1 ]; then
        warn "not Debian 13 or Ubuntu 26.04 (${PRETTY_NAME:-unknown}), continuing because DEVOPSY_SERVER_FORCE=1"
      elif can_ask; then
        answer=$(ask "this is ${PRETTY_NAME:-unknown}, not Debian 13 or Ubuntu 26.04: continue anyway? (y/N)")
        case $answer in y | Y | yes) ;; *) die "stopped: nothing changed" ;; esac
      else
        die "expects Debian 13 or Ubuntu 26.04, found ${PRETTY_NAME:-unknown}. Set DEVOPSY_SERVER_FORCE=1 to try anyway."
      fi
      ;;
  esac
}

step_base() {
  log "base packages"
  # Another list of Docker's repository than the docker step's (an older
  # install's, a provider's) goes before the first update: apt refuses
  # every source while two lists of it name different keys.
  # A list is a file apt reads (.list, .sources) with an entry, not a
  # comment, naming it.
  local f
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    if [ "$f" != /etc/apt/sources.list.d/docker.sources ] &&
      grep -qsE '^[[:space:]]*(deb(-src)?[[:space:]]|URIs:).*download\.docker\.com' "$f"; then
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
    { [ -n "$written" ] || [ -n "$(ss -Hltun 'sport = :5355')" ]; }; then
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
  local grubd=/etc/default/grub.d grubcfg=/boot/grub/grub.cfg kdump='' stale='' reboot_kho='' reboot_kdump='' mb
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
        reboot_kho=1
        log "base: kho=off from the next reboot: Kexec HandOver holds $mb MB for movable pages only, which page tables, slab and socket buffers cannot use, and nothing here kexecs"
      else
        log "base: kho=off from the next reboot, for a kernel that turns Kexec HandOver on (this one does not)"
      fi
    fi
    if [ "$kdump" = off ] && grep -q ' crashkernel=' "$grubcfg"; then
      stale=1
      mb=$(($(cat /sys/kernel/kexec_crash_size 2>/dev/null || echo 0) / 1048576))
      if [ "$mb" -gt 0 ]; then
        reboot_kdump=1
        log "base: no crash kernel from the next reboot (DEVOPSY_SERVER_KDUMP=off): frees the $mb MB kdump reserves"
      else
        log "base: no crash kernel from the next reboot (DEVOPSY_SERVER_KDUMP=off)"
      fi
    elif [ "$kdump" = on ] && ! grep -q ' crashkernel=' "$grubcfg"; then
      # Said once update-grub put it back (below).
      stale=1 reboot_kdump=1
    fi
  fi
  if [ -n "$stale" ] && command -v update-grub >/dev/null; then
    update-grub >/dev/null 2>&1 || die "update-grub failed"
    # A drop-in after these (an admin's, an older setup.sh's) can undo
    # them: what GRUB's config still lacks is said, and asks no reboot.
    if ! grep -q ' kho=off' "$grubcfg"; then
      reboot_kho=
      warn "base: GRUB's config lacks kho=off after update-grub: a drop-in in $grubd after zz-kho-off.cfg takes it out"
    fi
    if [ "$kdump" = off ] && grep -q ' crashkernel=' "$grubcfg"; then
      reboot_kdump=
      warn "base: GRUB's config keeps crashkernel= after update-grub (DEVOPSY_SERVER_KDUMP=off): a drop-in in $grubd after zz-no-crashkernel.cfg puts it back"
    elif [ "$kdump" = on ] && ! grep -q ' crashkernel=' "$grubcfg"; then
      reboot_kdump='' kdump=kept-out
      warn "base: GRUB's config lacks crashkernel= after update-grub (DEVOPSY_SERVER_KDUMP=on): a drop-in in $grubd takes it out, so kdump-tools stays as it is"
    elif [ "$kdump" = on ] && [ -n "$reboot_kdump" ]; then
      log "base: kdump's crash kernel back from the next reboot (DEVOPSY_SERVER_KDUMP=on)"
    fi
    if [ -n "$reboot_kho$reboot_kdump" ]; then
      echo '*** System restart required ***' >/run/reboot-required
      grep -qsx devopsy-server /run/reboot-required.pkgs || echo devopsy-server >>/run/reboot-required.pkgs
    fi
  fi
  if [ "$kdump" = off ] && systemctl is-enabled --quiet kdump-tools.service 2>/dev/null; then
    log "base: disabling kdump-tools (DEVOPSY_SERVER_KDUMP=off)"
    systemctl disable --quiet kdump-tools.service
  # Enabled only where the crash kernel's memory is kept: without it,
  # kdump-tools fails at boot.
  elif [ "$kdump" = on ] && [ "$(systemctl is-enabled kdump-tools.service 2>/dev/null)" = disabled ]; then
    log "base: enabling kdump-tools (DEVOPSY_SERVER_KDUMP=on)"
    systemctl enable --quiet kdump-tools.service
  fi
}

# swap_default: /swapfile's size where it is setup.sh's ($SWAP_SYSCTL),
# none where the server has a swap of its own, else swap_for_ram.
swap_default() {
  if [ -f "$SWAP_SYSCTL" ] && [ -f /swapfile ]; then
    swap_size "$(stat -c %s /swapfile)"
  elif [ -z "$(own_swaps)" ]; then
    swap_for_ram "$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
  fi
}

# swap_for_ram <kB>: as much swap as memory up to 2.5 GB, in steps of
# 512 MB, then 2G up to 8.5 GB, then none: swap keeps a build on the
# server from being killed, and a server that swaps while serving needs
# more memory.
swap_for_ram() {
  local mb=$(($1 / 1024))
  if [ "$mb" -le 2560 ]; then
    swap_size $(((mb + 511) / 512 * 512 * 1048576))
  elif [ "$mb" -le 8704 ]; then
    echo 2G
  fi
}

# swap_size <bytes>: in G when it is whole Gs, else in M.
swap_size() {
  if [ $(($1 % 1073741824)) = 0 ]; then
    echo "$(($1 / 1073741824))G"
  else
    echo "$(($1 / 1048576))M"
  fi
}

# human_size <bytes>: in whole G, rounded down, else in M.
human_size() {
  if [ "$1" -ge 1073741824 ]; then
    echo "$(($1 / 1073741824))G"
  else
    echo "$(($1 / 1048576))M"
  fi
}

# swap_bytes <size>: a setting's size (512M, 2G) in bytes, as fallocate
# takes it.
swap_bytes() {
  local n=${1%[MG]}
  case $1 in
    *G) echo $((n * 1073741824)) ;;
    *M) echo $((n * 1048576)) ;;
  esac
}

# swap_room <size>: the free space on / that changing /swapfile to that
# size needs now, plus 1 GB left over, or nothing (exit 1) where nothing
# changes: a new file takes its size, a resize the stand-in and the new
# file at once once the old one is gone (step_swap).
swap_room() {
  local want old=0 need
  [ -n "$1" ] || return 1
  want=$(swap_bytes "$1")
  if [ -f /swapfile ]; then
    old=$(stat -c %s /swapfile)
    [ "$old" != "$want" ] || return 1
  elif [ -n "$(own_swaps)" ]; then
    return 1
  fi
  need=$want
  if [ "$old" -gt 0 ] && [ $((2 * want - old)) -gt "$need" ]; then need=$((2 * want - old)); fi
  echo $((need + 1073741824))
}

# swaps: the files and devices the kernel swaps on, one a line. Read whole
# by a command substitution, never piped to grep -q, whose exit at its
# first match fails the pipe (pipefail).
swaps() {
  swapon --show=NAME --noheadings
}

# own_swaps: the server's swaps other than setup.sh's two files.
own_swaps() {
  local swap
  while IFS= read -r swap; do
    case $swap in /swapfile | /swapfile.tmp | '') ;; *) echo "$swap" ;; esac
  done <<<"$(swaps)"
}

# swap_on <file>: whether the kernel swaps on it.
swap_on() {
  [[ $'\n'$(swaps)$'\n' == *$'\n'"$1"$'\n'* ]]
}

# swap_make <file> <size>: a swap area of that size, made under another
# name and renamed once it is one, never renamed while on: the kernel
# refuses to rename a file it swaps on.
swap_make() {
  rm -f "$1.new"
  # What fit is not left behind, filling the disk under the sites.
  fallocate -l "$2" "$1.new" || {
    rm -f "$1.new"
    die "swap: $1 of $2 could not be made"
  }
  chmod 600 "$1.new"
  mkswap "$1.new" >/dev/null
  mv "$1.new" "$1"
}

# swap_drop <file>: turned off and removed; exit 1, with the file left on,
# where the kernel cannot take its pages elsewhere.
swap_drop() {
  if swap_on "$1"; then swapoff "$1" || return 1; fi
  rm -f "$1"
}

step_swap() {
  local want=$DEVOPSY_SERVER_SWAP
  if [ -z "$want" ]; then
    # None: /swapfile goes only where setup.sh made it, turned off first,
    # then its fstab line, the file and last the sysctl file that says it
    # was setup.sh's, so a run cut between them is finished by the next.
    if [ -f "$SWAP_SYSCTL" ]; then
      log "swap: removing /swapfile (DEVOPSY_SERVER_SWAP none)"
      swap_drop /swapfile.tmp || warn "swap: /swapfile.tmp could not be turned off, its pages needing more memory than is free: the next run tries again"
      if ! swap_drop /swapfile; then
        warn "swap: /swapfile could not be turned off, its pages needing more memory than is free: it stays, and the next run tries again"
        return 0
      fi
      sed -i '\#^/swapfile #d' /etc/fstab
      rm -f /swapfile.new /swapfile.tmp.new "$SWAP_SYSCTL"
    else
      log "swap: none set, skipping"
    fi
    return 0
  fi
  # A server with a swap of its own and no /swapfile is left as it is.
  if [ ! -f /swapfile ] && [ -n "$(own_swaps)" ]; then
    log "swap: the server has a swap of its own, skipping"
    return 0
  fi
  # The sysctl file first: it says /swapfile is setup.sh's, so a run cut
  # once the file is made still removes it with none. Applied on every run,
  # written or not, at the end, so a run failing at sysctl is finished by
  # the next.
  echo 'vm.swappiness = 10' | write_file "$SWAP_SYSCTL" || true
  # A resize: a stand-in of the new size on, the old file off and replaced,
  # the new one on, then the stand-in off and removed, so the server is
  # never without swap. Each part is checked apart, so a run cut at any
  # point is finished by the next; one the memory cannot take leaves the
  # old size, said.
  if [ -f /swapfile ] && [ "$(stat -c %s /swapfile)" != "$(swap_bytes "$want")" ]; then
    log "swap: resizing /swapfile to $want"
    if ! swap_on /swapfile.tmp; then
      swap_make /swapfile.tmp "$want"
      swapon /swapfile.tmp
    fi
    if swap_drop /swapfile; then
      swap_make /swapfile "$want"
    else
      warn "swap: /swapfile could not be turned off, its pages needing more memory than is free: it keeps its size, and the next run tries again"
    fi
  elif [ ! -f /swapfile ]; then
    log "swap: creating /swapfile ($want)"
    swap_make /swapfile "$want"
  fi
  if ! swap_on /swapfile; then
    log "swap: turning on /swapfile"
    swapon /swapfile
  fi
  if [ -f /swapfile.tmp ] && ! swap_drop /swapfile.tmp; then
    warn "swap: /swapfile.tmp could not be turned off, its pages needing more memory than is free: the next run tries again"
  fi
  # What a cut swap_make left, never on.
  rm -f /swapfile.new /swapfile.tmp.new
  if ! grep -q '^/swapfile ' /etc/fstab; then
    log "swap: /swapfile in /etc/fstab, on at every boot"
    echo '/swapfile none swap sw 0 0' >>/etc/fstab
  fi
  sysctl -q -p "$SWAP_SYSCTL"
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
    -y | --yes) yes=1 ;;
    '') ;;
    *) die "'$1': setup.sh takes no arguments but --help and --yes, settings are asked or variables" ;;
  esac
  [ $# -le 1 ] || die "'$2': setup.sh takes one argument at most"
  preflight
  load_settings
  # The environment's are checked before anything is asked, every one
  # after: an answer is checked as it is given, a saved value or a default
  # the questions offer to change.
  # shellcheck disable=SC2086 # one key a word
  [ "$from_env" = ' ' ] || validate_settings $from_env
  if can_ask; then ask_settings; fi
  validate_settings
  # Saved before running, so a failed run still remembers its settings.
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
