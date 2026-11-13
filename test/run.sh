#!/usr/bin/env bash
# Runs setup.sh twice on each distribution it supports, all at once, each
# in a privileged container with systemd and its own Docker (test/Dockerfile):
# checks what the first run set up, and that the second wrote, created and
# restarted nothing; then devopsy's --server-setup, which setup.sh names
# last, over the container's own sshd.
#
#   test/run.sh                            Debian 13 and Ubuntu 26.04
#   test/run.sh ubuntu:26.04               one
#   test/run.sh --devopsy <file> [base]    with that devopsy (linux, the
#                                          containers' architecture, built with
#                                          -X main.version) over the one
#                                          setup.sh installs, to test a
#                                          devopsy-cli branch before its tag
#
# Needs Docker. Each distribution's output goes to test/out/<name>.log
# (gitignored); a failure prints the end of its log. The containers share
# the host's kernel: the socket buffers --server-setup raises are the host's
# (harmless), and on a kernel with AppArmor Docker loads its profile there.
set -euo pipefail
cd "$(dirname "$0")/.."

devopsy=
if [ "${1:-}" = --devopsy ]; then
  devopsy=${2:?--devopsy needs a file}
  [ -f "$devopsy" ] || { echo "no file $devopsy" >&2; exit 1; }
  shift 2
fi
bases=("$@")
[ ${#bases[@]} -gt 0 ] || bases=(debian:trixie ubuntu:26.04)
# Each run's containers carry its own label, so two runs never meet.
run=devopsy-server-test-$$
out=test/out
mkdir -p "$out"

# shellcheck disable=SC2329 # run by the trap
cleanup() {
  docker ps -aq --filter "label=$run" | while read -r id; do
    docker rm -f -v "$id" >/dev/null
  done
}
trap cleanup EXIT

# server_setup: devopsy's --server-setup --yes on the container, as the
# operator runs it, over its own sshd to the deploy user; in test_one's
# scope (x, fail, out, name). A daemon.json of someone else's first: a
# proxy's key, which stays, and pools of their own, which --yes keeps and
# records. A container running: daemon.json put, Docker not restarted, the
# restart flag raised; none: Docker restarted and confirmed; then nothing to
# change. The socket buffers only where the container may set net.core
# (OrbStack's kernel allows it, GitHub's runners refuse it): elsewhere
# their raise is the one failure.
server_setup() {
  local first second third pools='[{"base":"10.10.0.0/16","size":24}]' before after code buffers=1
  docker exec -i "$c" sh -c 'cat >/etc/docker/daemon.json' <<<"{\"proxies\": {\"http-proxy\": \"http://proxy.example.com:8080\"}, \"default-address-pools\": $pools}"
  x sh -c 'cat /proc/sys/net/core/rmem_max >/proc/sys/net/core/rmem_max' 2>/dev/null || buffers=
  x docker run -d --name busy busybox:1.37 sleep 1d >/dev/null || fail "no container to run"
  before=$(x systemctl show -p InvocationID --value docker)

  echo "== $base: --server-setup, a container running"
  first=$out/$name.setup1
  code=0
  x sh -c 'cd / && devopsy @devopsy@localhost: --server-setup --yes' >"$first" 2>&1 || code=$?
  cat "$first"
  if [ -n "$buffers" ]; then
    [ "$code" = 0 ] || fail "--server-setup failed ($code)"
  else
    if [ "$code" != 1 ] || ! grep -q 'net.core.rmem_max is' "$first"; then
      fail "--server-setup: $code, not the buffers' failure alone"
    fi
  fi
  x jq -e '.["log-driver"] == "local" and .["live-restore"] == true and .["log-opts"]["max-size"] == "20m"' /etc/docker/daemon.json >/dev/null ||
    fail "--server-setup did not put daemon.json's parts"
  x jq -e '.proxies["http-proxy"]' /etc/docker/daemon.json >/dev/null || fail "--server-setup dropped daemon.json's proxies"
  # shellcheck disable=SC2016 # jq's own variable
  x jq -e --argjson p "$pools" '.["default-address-pools"] == $p' /etc/docker/daemon.json >/dev/null ||
    fail "--server-setup did not keep the pools set by hand"
  x grep -q '10.10.0.0/16' /home/devopsy/.config/devopsy/server.yaml || fail "the kept pools are not recorded"
  [ "$(x systemctl show -p InvocationID --value docker)" = "$before" ] || fail "Docker restarted with a container running"
  x grep -qx devopsy /run/reboot-required.pkgs || fail "no reboot asked for daemon.json"
  x test -f /etc/systemd/system/docker.service.d/devopsy-mounts.conf || fail "no mounts drop-in"
  x grep -q 'net.core.rmem_max = 7500000' /etc/sysctl.d/90-devopsy-net.conf || fail "no socket buffers' file"
  if [ -n "$buffers" ] && [ "$(x sysctl -n net.core.rmem_max)" != 7500000 ]; then
    fail "net.core.rmem_max is not 7500000, though the container may set it"
  fi
  x test -f /run/devopsy-firewall.loaded || fail "the metadata firewall is not loaded"
  x iptables -t raw -S DEVOPSY-CONTAINERS >/dev/null || fail "no DEVOPSY-CONTAINERS chain"

  echo "== $base: --server-setup, no container"
  x docker rm -f busy >/dev/null
  second=$out/$name.setup2
  code=0
  x sh -c 'cd / && devopsy @devopsy@localhost: --server-setup --yes' >"$second" 2>&1 || code=$?
  cat "$second"
  [ "$code" = 0 ] || [ -z "$buffers" ] || fail "the second --server-setup failed ($code)"
  after=$(x systemctl show -p InvocationID --value docker)
  [ "$after" != "$before" ] || fail "Docker was not restarted"
  grep -q "Docker restarted, with daemon.json's values" "$second" || fail "Docker's restart was not confirmed"
  [ "$(x docker info --format '{{.LiveRestoreEnabled}}')" = true ] || fail "Docker does not run with daemon.json's live-restore"

  echo "== $base: --server-setup, nothing to change"
  third=$out/$name.setup3
  code=0
  x sh -c 'cd / && devopsy @devopsy@localhost: --server-setup --yes' >"$third" 2>&1 || code=$?
  cat "$third"
  if [ -n "$buffers" ]; then
    if [ "$code" != 0 ] || ! grep -q 'nothing to change' "$third"; then
      fail "the third --server-setup changed something ($code)"
    fi
  fi
  [ "$(x systemctl show -p InvocationID --value docker)" = "$after" ] || fail "the third --server-setup restarted Docker"
  rm -f "$first" "$second" "$third"
}

# test_one <base>: one distribution, its output on stdout.
test_one() {
  local base=$1 name tag c
  name=${base//[:\/]/-}
  tag=devopsy-server-test:$name
  c=$run-$name
  x() { docker exec "$c" "$@"; }
  fail() {
    echo "FAIL: $*"
    exit 1
  }

  echo "== $base: image"
  docker build -q --build-arg BASE="$base" -t "$tag" test >/dev/null
  # /var/lib/docker and /var/lib/containerd (Docker's containerd image
  # store) volumes: overlay storage cannot nest in the container's own.
  docker run -d --privileged --label "$run" --name "$c" \
    --tmpfs /run --tmpfs /run/lock -v /var/lib/docker -v /var/lib/containerd \
    -v "$PWD:/src:ro" "$tag" >/dev/null
  # Up once systemd answers, running or degraded (kernel modules cannot
  # load in a container), polled: its socket comes a moment after start.
  local state='' i
  for i in $(seq 60); do
    state=$(x systemctl is-system-running --wait 2>/dev/null) || true
    case $state in running | degraded) break ;; esac
    sleep 1
  done
  case $state in running | degraded) ;; *) fail "systemd did not start (${state:-no answer})" ;; esac

  # As on a cloud server: root has a key. Debian's resolved answers LLMNR
  # (Ubuntu's has it off already), so there the check below proves
  # something.
  # Root's own key too, which setup.sh copies with the rest: devopsy reaches
  # the deploy user with it over the container's sshd, as from the operator's
  # machine.
  x sh -c 'install -d -m 700 /root/.ssh && echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl test" >/root/.ssh/authorized_keys &&
    ssh-keygen -q -t ed25519 -N "" -f /root/.ssh/id_ed25519 && cat /root/.ssh/id_ed25519.pub >>/root/.ssh/authorized_keys &&
    printf "Host localhost\n  StrictHostKeyChecking accept-new\n" >/root/.ssh/config && chmod 600 /root/.ssh/config'
  case $base in
    debian:*)
      x ss -Hltun 'sport = :5355' | grep -q . ||
        fail "LLMNR is not open before setup.sh: the check below would prove nothing"
      ;;
  esac

  # kdump's drop-in, GRUB's config and an update-grub that builds it from
  # the drop-ins, as grub-mkconfig does, and counts its runs.
  # shellcheck disable=SC2016 # expanded in the container
  x sh -c 'mkdir -p /boot/grub /etc/default/grub.d &&
    echo "linux /vmlinuz root=/dev/vda1 ro crashkernel=320M" >/boot/grub/grub.cfg &&
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT crashkernel=2G-4G:320M\"" >/etc/default/grub.d/kdump-tools.cfg &&
    printf "%s\n" "#!/bin/sh" "echo run >>/tmp/update-grub.runs" "GRUB_CMDLINE_LINUX_DEFAULT=quiet" \
      "for f in /etc/default/grub.d/*.cfg; do . \"\$f\"; done" \
      "echo \"linux /vmlinuz root=/dev/vda1 ro \$GRUB_CMDLINE_LINUX_DEFAULT\" >/boot/grub/grub.cfg" \
      >/usr/local/sbin/update-grub && chmod 755 /usr/local/sbin/update-grub &&
    printf "%s\n" "[Service]" "Type=oneshot" "ExecStart=/bin/true" "[Install]" "WantedBy=multi-user.target" \
      >/etc/systemd/system/kdump-tools.service && systemctl enable --quiet kdump-tools.service'

  echo "== $base: first run"
  x bash /src/setup.sh >"$out/$name.first" 2>&1 || {
    cat "$out/$name.first"
    fail "the first run failed"
  }
  cat "$out/$name.first"
  # devopsy's own part is named, not done.
  grep -q 'next, from your machine: devopsy @devopsy@<server>: --server-setup' "$out/$name.first" ||
    fail "the first run did not name --server-setup last"
  rm -f "$out/$name.first"
  for f in /etc/docker/daemon.json /etc/sysctl.d/90-devopsy-net.conf; do
    if x test -e "$f"; then fail "setup.sh wrote $f, which is --server-setup's"; fi
  done
  if [ -n "$devopsy" ]; then
    docker cp "$devopsy" "$c:/usr/local/lib/devopsy/devopsy"
    x chown devopsy: /usr/local/lib/devopsy/devopsy
    x chmod 755 /usr/local/lib/devopsy/devopsy
  fi
  x systemctl is-active --quiet docker || fail "Docker is not running"
  x docker info >/dev/null || fail "docker info failed"
  x id -nG devopsy | grep -qw docker || fail "devopsy is not in the docker group"
  x cmp -s /root/.ssh/authorized_keys /home/devopsy/.ssh/authorized_keys ||
    fail "root's keys were not copied to devopsy"
  x runuser -u devopsy -- devopsy --version >/dev/null || fail "devopsy does not run as devopsy"
  x systemctl is-active --quiet systemd-resolved || fail "systemd-resolved is not running"
  if x ss -Hltun 'sport = :5355' | grep .; then
    fail "LLMNR is still open"
  fi
  x grep -q ' kho=off' /boot/grub/grub.cfg || fail "GRUB's config lacks kho=off"
  # kdump as the image has it: DEVOPSY_SERVER_KDUMP is on by default.
  x grep -q ' crashkernel=' /boot/grub/grub.cfg || fail "the first run took kdump's crash kernel out"
  x systemctl is-enabled --quiet kdump-tools.service || fail "the first run disabled kdump-tools"
  # A restart only when it frees something: KHO's scratch in the running
  # kernel, the host's (CMA pageblocks).
  # shellcheck disable=SC2016 # awk's own fields
  if [ "$(x awk '/^Number of blocks type/ { for (i = 1; i <= NF; i++) if ($i == "CMA") c = i; next }
    c && /^Node/ { n += $c } END { print n + 0 }' /proc/pagetypeinfo)" = 0 ]; then
    if x grep -qsx devopsy-server /run/reboot-required.pkgs; then
      fail "a restart was asked for, though the running kernel holds no KHO scratch"
    fi
  else
    x grep -qx devopsy-server /run/reboot-required.pkgs || fail "no restart asked to free KHO's scratch"
  fi

  echo "== $base: second run"
  x bash /src/setup.sh >"$out/$name.second" 2>&1 || {
    cat "$out/$name.second"
    fail "the second run failed"
  }
  cat "$out/$name.second"
  # What only a change logs: every run upgrades the packages and devopsy.
  if grep -E 'wrote |removed |restarting|updating|disabling|creating|cli: installing|linked' "$out/$name.second"; then
    fail "the second run changed something"
  fi
  [ "$(x sh -c 'wc -l </tmp/update-grub.runs')" = 1 ] || fail "update-grub did not run exactly once"
  if [ -n "$devopsy" ] && ! docker exec -i "$c" cmp -s - /usr/local/lib/devopsy/devopsy <"$devopsy"; then
    fail "the second run replaced the devopsy given with --devopsy"
  fi

  server_setup

  # An older install's list of Docker's repository beside setup.sh's, its
  # key another file: apt refuses every source until it goes.
  # shellcheck disable=SC2016 # expanded in the container
  x sh -c 'cp /etc/apt/keyrings/docker.asc /etc/apt/keyrings/docker-old.asc && . /etc/os-release &&
    echo "deb [signed-by=/etc/apt/keyrings/docker-old.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" >/etc/apt/sources.list.d/docker.list'

  echo "== $base: third run, DEVOPSY_SERVER_KDUMP=off, another list of Docker's"
  x cp /etc/docker/daemon.json /tmp/daemon.before
  invocation=$(x systemctl show -p InvocationID --value docker)
  x env DEVOPSY_SERVER_KDUMP=off bash /src/setup.sh >"$out/$name.third" 2>&1 || {
    cat "$out/$name.third"
    fail "the third run failed"
  }
  rm -f "$out/$name.third"
  if x test -e /etc/apt/sources.list.d/docker.list; then fail "the other list of Docker's repository is still there"; fi
  x cmp -s /tmp/daemon.before /etc/docker/daemon.json || fail "setup.sh changed daemon.json after --server-setup"
  [ "$(x systemctl show -p InvocationID --value docker)" = "$invocation" ] || fail "setup.sh restarted Docker after --server-setup"
  x systemctl is-active --quiet docker || fail "Docker is not running after the third run"
  if x grep crashkernel= /boot/grub/grub.cfg; then
    fail "DEVOPSY_SERVER_KDUMP=off left the crash kernel in GRUB's config"
  fi
  if x systemctl is-enabled --quiet kdump-tools.service; then
    fail "DEVOPSY_SERVER_KDUMP=off left kdump-tools enabled"
  fi

  # A swap file a run left on but not in fstab (cut between the two), which
  # the next run finishes. swapon, mkswap and fallocate are fakes, their
  # state in /tmp, and sysctl leaves vm.swappiness alone: the real ones
  # would act on the host's kernel.
  # shellcheck disable=SC2016 # expanded in the container
  x sh -c 'printf "%s\n" "#!/bin/sh" "echo \"\$*\" >>/tmp/swap.calls" "case \$1 in --show=*) cat /tmp/swaps 2>/dev/null ;; *) echo \"\$1\" >>/tmp/swaps ;; esac" >/usr/local/sbin/swapon &&
    printf "%s\n" "#!/bin/sh" "echo \"mkswap \$*\" >>/tmp/swap.calls" >/usr/local/sbin/mkswap &&
    printf "%s\n" "#!/bin/sh" "echo \"fallocate \$*\" >>/tmp/swap.calls; : >\"\$3\"" >/usr/local/sbin/fallocate &&
    printf "%s\n" "#!/bin/sh" "case \"\$*\" in *90-devopsy-swap.conf) exit 0 ;; esac" "exec /sbin/sysctl \"\$@\"" >/usr/local/sbin/sysctl &&
    chmod 755 /usr/local/sbin/swapon /usr/local/sbin/mkswap /usr/local/sbin/fallocate /usr/local/sbin/sysctl &&
    : >/swapfile && chmod 600 /swapfile && echo /swapfile >/tmp/swaps'

  echo "== $base: fourth run, DEVOPSY_SERVER_KDUMP=on, a swap file not in fstab"
  x env DEVOPSY_SERVER_KDUMP=on DEVOPSY_SERVER_SWAP=64M bash /src/setup.sh >"$out/$name.fourth" 2>&1 || {
    cat "$out/$name.fourth"
    fail "the fourth run failed"
  }
  rm -f "$out/$name.fourth"
  x grep -q ' crashkernel=' /boot/grub/grub.cfg || fail "DEVOPSY_SERVER_KDUMP=on did not put the crash kernel back"
  x systemctl is-enabled --quiet kdump-tools.service || fail "DEVOPSY_SERVER_KDUMP=on did not enable kdump-tools again"
  x grep -qx devopsy-server /run/reboot-required.pkgs || fail "no restart asked to bring kdump back"
  x grep -q ' kho=off' /boot/grub/grub.cfg || fail "the fourth run lost kho=off"
  x grep -qx '/swapfile none swap sw 0 0' /etc/fstab || fail "the fourth run left the swap file out of /etc/fstab"
  if x grep -vx -e '--show=NAME --noheadings' /tmp/swap.calls; then
    fail "the fourth run made or turned on a swap file that was on already"
  fi
  rm -f "$out/$name.second"

  echo "== $base: ok"
}

# Indexed, not associative: macOS's bash 3.2 has none.
pids=()
for base in "${bases[@]}"; do
  name=${base//[:\/]/-}
  test_one "$base" >"$out/$name.log" 2>&1 &
  pids+=($!)
done
status=0
i=0
for base in "${bases[@]}"; do
  name=${base//[:\/]/-}
  pid=${pids[$i]}
  i=$((i + 1))
  if wait "$pid"; then
    echo "ok    $base"
  else
    status=1
    echo "FAIL  $base ($out/$name.log):"
    tail -n 30 "$out/$name.log" | sed 's/^/  /'
  fi
done
exit $status
