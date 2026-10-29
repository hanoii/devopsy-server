#!/usr/bin/env bash
# Runs setup.sh twice on each distribution it supports, all at once, each
# in a privileged container with systemd and its own Docker (test/Dockerfile):
# checks what the first run set up, and that the second wrote, created and
# restarted nothing.
#
#   test/run.sh                  Debian 13 and Ubuntu 26.04
#   test/run.sh ubuntu:26.04     one
#
# Needs Docker. Each distribution's output goes to test/out/<name>.log
# (gitignored); a failure prints the end of its log. The containers share
# the host's kernel: the socket buffers setup.sh raises are the host's
# (harmless), and on a kernel with AppArmor Docker loads its profile there.
set -euo pipefail
cd "$(dirname "$0")/.."

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
  # /var/lib/docker a volume: Docker's overlay storage cannot nest in the
  # container's own overlay.
  docker run -d --privileged --label "$run" --name "$c" \
    --tmpfs /run --tmpfs /run/lock -v /var/lib/docker \
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
  x sh -c 'install -d -m 700 /root/.ssh && echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl test" >/root/.ssh/authorized_keys'
  case $base in
    debian:*)
      x ss -Hltun 'sport = :5355' | grep -q . ||
        fail "LLMNR is not open before setup.sh: the check below would prove nothing"
      ;;
  esac

  echo "== $base: first run"
  x bash /src/setup.sh || fail "the first run failed"
  x systemctl is-active --quiet docker || fail "Docker is not running"
  x docker info >/dev/null || fail "docker info failed"
  x id -nG devopsy | grep -qw docker || fail "devopsy is not in the docker group"
  x cmp -s /root/.ssh/authorized_keys /home/devopsy/.ssh/authorized_keys ||
    fail "root's keys were not copied to devopsy"
  x runuser -u devopsy -- devopsy --version >/dev/null || fail "devopsy does not run as devopsy"
  # The file always; the kernel's value only where a container may set
  # it: GitHub's runners refuse net.core from a container's network
  # namespace, OrbStack's kernel allows it.
  x grep -qx 'net.core.rmem_max = 7500000' /etc/sysctl.d/90-devopsy-net.conf ||
    fail "/etc/sysctl.d/90-devopsy-net.conf lacks the socket buffers"
  if [ "$(x sysctl -n net.core.rmem_max)" != 7500000 ] &&
    x sh -c 'cat /proc/sys/net/core/rmem_max >/proc/sys/net/core/rmem_max' 2>/dev/null; then
    fail "net.core.rmem_max is not 7500000, though the container may set it"
  fi
  x systemctl is-active --quiet systemd-resolved || fail "systemd-resolved is not running"
  if x ss -Hltun 'sport = :5355' | grep .; then
    fail "LLMNR is still open"
  fi

  echo "== $base: second run"
  x bash /src/setup.sh >"$out/$name.second" 2>&1 || {
    cat "$out/$name.second"
    fail "the second run failed"
  }
  cat "$out/$name.second"
  # What only a change logs: every run upgrades the packages and devopsy.
  if grep -E 'wrote |restarting|user: creating|cli: installing|linked' "$out/$name.second"; then
    fail "the second run changed something"
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
