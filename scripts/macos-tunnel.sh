#!/usr/bin/env bash
#
# Forward the BC/SQL container ports from the podman VM to the macOS host.
#
# Why this exists
# ---------------
# On Apple Silicon, BC needs Rosetta (SQL Server segfaults under QEMU), and
# Apple's Rosetta on macOS 15.x cannot run amd64 binaries under the Linux
# 7.1.x kernel that every podman machine-os 6.x image ships -- it aborts with
# `rosetta error: unhandled auxillary vector type 29`. So the machine has to be
# pinned to an older image (MacOS.md step 3). But podman's native host port
# forwarding only works with a podman 6.x guest, so on the pinned image
# published container ports never reach the host, even though they listen fine
# inside the VM. Measured on macOS 15.7.9:
#
#   machine-os 5.2 (kernel 6.11.3)  Rosetta OK    forwarding broken
#   machine-os 5.5 (kernel 6.12.13) Rosetta OK    forwarding broken
#   machine-os 5.8 (kernel 7.1.4)   Rosetta FAILS forwarding broken
#   machine-os 6.0 (kernel 7.1.3)   Rosetta FAILS forwarding OK
#
# No tag satisfies both, so we bridge the gap with ssh -L over podman's own
# machine SSH connection. A newer macOS ships a newer Rosetta and may remove
# the need for all of this -- retest before assuming it is still required.
#
# Usage:
#   ./scripts/macos-tunnel.sh            # foreground; Ctrl-C to stop
#   ./scripts/macos-tunnel.sh --daemon   # background
#   ./scripts/macos-tunnel.sh --stop
#   ./scripts/macos-tunnel.sh --status
#
# Ports are derived from the compose config, so an `instance_slot`-style port
# offset is picked up automatically. Override with BC_TUNNEL_PORTS="7049 11433".
set -euo pipefail

MACHINE="${BC_PODMAN_MACHINE:-podman-machine-default}"
PIDFILE="${TMPDIR:-/tmp}/bc-macos-tunnel.pid"
LOGFILE="${TMPDIR:-/tmp}/bc-macos-tunnel.log"
COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.macos.yml)

command -v podman >/dev/null || { echo "podman not on PATH (try /opt/podman/bin)" >&2; exit 1; }

case "${1:-}" in
  --stop)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      kill "$(cat "$PIDFILE")" && rm -f "$PIDFILE"
      echo "tunnel stopped"
    else
      rm -f "$PIDFILE"
      echo "no tunnel running"
    fi
    exit 0
    ;;
  --status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "tunnel running (pid $(cat "$PIDFILE"))"
      exit 0
    fi
    echo "tunnel not running"
    exit 1
    ;;
esac

# --- work out which ports to forward -----------------------------------------
# NOTE: macOS ships bash 3.2, which has no `mapfile` and trips over `set -u`
# on empty arrays -- keep this a plain space-separated string.
PORTS="${BC_TUNNEL_PORTS:-}"
if [ -z "$PORTS" ]; then
  cd "$(dirname "$0")/.."
  PORTS=$(
    docker-compose "${COMPOSE_FILES[@]}" config --format json 2>/dev/null |
    python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
out = set()
for svc in d.get("services", {}).values():
    for p in svc.get("ports", []) or []:
        if p.get("published"):
            out.add(int(p["published"]))
print(" ".join(str(p) for p in sorted(out)))
' 2>/dev/null
  ) || PORTS=""
fi

if [ -z "$PORTS" ]; then
  # Fall back to the stock published set if compose could not be read.
  PORTS="7045 7048 7049 7052 7085 8080 11433"
  echo "note: could not derive ports from compose, using defaults: $PORTS" >&2
fi

SSH_PORT=$(podman machine inspect "$MACHINE" --format '{{.SSHConfig.Port}}')
IDENTITY=$(podman machine inspect "$MACHINE" --format '{{.SSHConfig.IdentityPath}}')
[ -n "$SSH_PORT" ] && [ -n "$IDENTITY" ] || { echo "machine '$MACHINE' not running?" >&2; exit 1; }

FORWARDS=""
for p in $PORTS; do FORWARDS="$FORWARDS -L ${p}:localhost:${p}"; done

run_tunnel() {
  # `exec` matters: in the --daemon path this function runs in a background
  # subshell, and exec makes that subshell BECOME ssh. Without it, $! would be
  # the subshell and `--stop` would kill the wrapper while ssh kept running.
  # Word splitting on $FORWARDS is intentional (bash 3.2, no arrays here).
  # shellcheck disable=SC2086
  exec ssh -N -i "$IDENTITY" -p "$SSH_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    $FORWARDS core@localhost
}

if [ "${1:-}" = "--daemon" ]; then
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "tunnel already running (pid $(cat "$PIDFILE"))"; exit 0
  fi
  ( run_tunnel ) >"$LOGFILE" 2>&1 &
  TUNNEL_PID=$!
  echo "$TUNNEL_PID" > "$PIDFILE"
  sleep 2
  if kill -0 "$TUNNEL_PID" 2>/dev/null; then
    echo "tunnel up (pid $TUNNEL_PID), forwarding: $PORTS"
    echo "log: $LOGFILE"
  else
    rm -f "$PIDFILE"
    echo "tunnel failed to start; see $LOGFILE" >&2
    exit 1
  fi
else
  echo "forwarding: $PORTS  (Ctrl-C to stop)"
  run_tunnel
fi
