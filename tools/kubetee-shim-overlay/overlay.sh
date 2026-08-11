#!/bin/sh
# KubeTEE kata-deploy runtime-rs shim overlay + orphan reaper (fix12).
#
# Copies the patched containerd-shim-kata-v2 (runtime-rs) onto
# /opt/kata/runtime-rs/bin/ on the host after kata-deploy installs it.
# Also reaps abandoned shims under init (PPID=1) that hold tap+VFIO and
# cause TUNSETIFF EBUSY CrashLoops (fix12 / kata-containers#13574).
set -eu

SRC=/opt/kata/runtime-rs/bin/containerd-shim-kata-v2
DST=/host/opt/kata/runtime-rs/bin/containerd-shim-kata-v2
MARK=/host/opt/kata/runtime-rs/bin/.nvswitch-fix-applied

# With hostPID:true the container shares the host PID ns — prefer /proc.
# Fall back to the host root mount if someone runs without hostPID.
if [ -d /proc/1 ] && [ "$(awk '/^PPid:/{print $2; exit}' /proc/self/status 2>/dev/null || echo x)" != "x" ]; then
  HOST_PROC=/proc
else
  HOST_PROC=/host/proc
fi
CRICTL=/host/var/lib/rancher/rke2/bin/crictl
CRI_SOCK=unix:///host/run/k3s/containerd/containerd.sock
# Seconds a PPID=1 shim must be alive before we consider reaping it.
ORPHAN_GRACE_SECS=${ORPHAN_GRACE_SECS:-180}
REAP_INTERVAL_SECS=${REAP_INTERVAL_SECS:-30}
OVERLAY_INTERVAL_SECS=${OVERLAY_INTERVAL_SECS:-60}

echo "[overlay] waiting for kata-deploy to install $DST ..."
while [ ! -f "$DST" ]; do sleep 5; done
echo "[overlay] $DST present"

apply() {
  if cmp -s "$SRC" "$DST"; then
    echo "[overlay] shim already patched (no-op)"
  else
    cp "$SRC" "$DST"
    chmod 755 "$DST"
    sha256sum "$SRC" | cut -d' ' -f1 > "$MARK"
    echo "[overlay] patched shim applied: $(cut -c1-16 < "$MARK")"
  fi
}

# Approximate process age in seconds from /proc/<pid>/stat starttime.
proc_age_secs() {
  pid="$1"
  uptime_s=$(awk '{print int($1)}' "$HOST_PROC/uptime" 2>/dev/null || echo 0)
  start_ticks=$(awk '{print $22}' "$HOST_PROC/$pid/stat" 2>/dev/null || echo 0)
  hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
  if [ -z "$start_ticks" ] || [ "$start_ticks" = "0" ] || [ "$hz" = "0" ]; then
    echo 0
    return
  fi
  start_s=$((start_ticks / hz))
  age=$((uptime_s - start_s))
  if [ "$age" -lt 0 ]; then
    echo 0
  else
    echo "$age"
  fi
}

# fix12: kill containerd-shim-kata-v2 processes reparented to init that
# containerd no longer tracks — they hold IFF_PERSIST taps + VFIO forever.
reap_orphans() {
  if [ ! -d "$HOST_PROC" ]; then
    return
  fi

  for status in "$HOST_PROC"/[0-9]*/status; do
    [ -f "$status" ] || continue
    pid=$(basename "$(dirname "$status")")
    ppid=$(awk '/^PPid:/{print $2; exit}' "$status" 2>/dev/null || true)
    [ "$ppid" = "1" ] || continue

    cmd=$(tr '\0' ' ' < "$HOST_PROC/$pid/cmdline" 2>/dev/null || true)
    case "$cmd" in
      *containerd-shim-kata-v2*) ;;
      *) continue ;;
    esac

    age=$(proc_age_secs "$pid")
    if [ "$age" -lt "$ORPHAN_GRACE_SECS" ]; then
      continue
    fi

    # Extract sandbox id from shim argv: ... -id <hex> ...
    sid=$(printf '%s\n' "$cmd" | sed -n 's/.* -id \([0-9a-f]\{64\}\) .*/\1/p')
    if [ -z "$sid" ]; then
      sid=$(printf '%s\n' "$cmd" | sed -n 's/.* -id \([^ ]*\) .*/\1/p')
    fi

    # If containerd still knows this sandbox, leave it alone (PPID=1 after
    # containerd restart can still be a live, connected shim).
    if [ -n "$sid" ] && [ -x "$CRICTL" ]; then
      if "$CRICTL" --runtime-endpoint "$CRI_SOCK" inspectp "$sid" >/dev/null 2>&1; then
        echo "[orphan-reaper] skip pid=$pid id=$sid age=${age}s (still in containerd)"
        continue
      fi
    fi

    echo "[orphan-reaper] killing orphan shim pid=$pid id=${sid:-unknown} age=${age}s ppid=1"
    # Collect QEMU children before killing shim (PDEATHSIG should get them;
    # also kill explicitly if already reparented).
    children=""
    for cstatus in "$HOST_PROC"/[0-9]*/status; do
      [ -f "$cstatus" ] || continue
      cpid=$(basename "$(dirname "$cstatus")")
      cppid=$(awk '/^PPid:/{print $2; exit}' "$cstatus" 2>/dev/null || true)
      [ "$cppid" = "$pid" ] || continue
      ccmd=$(tr '\0' ' ' < "$HOST_PROC/$cpid/cmdline" 2>/dev/null || true)
      case "$ccmd" in
        *qemu-system*) children="$children $cpid" ;;
      esac
    done

    kill "$pid" 2>/dev/null || true
    for cpid in $children; do
      kill "$cpid" 2>/dev/null || true
    done
    sleep 2
    kill -9 "$pid" 2>/dev/null || true
    for cpid in $children; do
      kill -9 "$cpid" 2>/dev/null || true
    done
    echo "[orphan-reaper] killed shim pid=$pid id=${sid:-unknown}"
  done
}

apply
echo "[overlay] entering watch loop (overlay every ${OVERLAY_INTERVAL_SECS}s, reap every ${REAP_INTERVAL_SECS}s, grace=${ORPHAN_GRACE_SECS}s)"
elapsed=0
while true; do
  sleep "$REAP_INTERVAL_SECS"
  elapsed=$((elapsed + REAP_INTERVAL_SECS))
  reap_orphans || true
  if [ "$elapsed" -ge "$OVERLAY_INTERVAL_SECS" ]; then
    apply || true
    elapsed=0
  fi
done
