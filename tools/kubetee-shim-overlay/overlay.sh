#!/bin/sh
# KubeTEE kata-deploy runtime-rs shim overlay — 4.4.0 port.
#
# Copies the patched containerd-shim-kata-v2 over the binary after kata-deploy
# installs stock assets. The binary carries:
#  - #11649 (fix15): idempotent block hotplug / hotplug-sized QMP read timeout.
#  - Stale block fdset reclamation at hotplug.
#  - T15/T16 (#13665/#13746): stop_vm on missing-task Kill/Wait.
#
# fix16 (#13641) is consciously dropped; re-add only on new evidence.
# No orphan reaper or hostPID.
set -eu

SRC=/opt/kata/runtime-rs/bin/containerd-shim-kata-v2
DST=/host/opt/kata/runtime-rs/bin/containerd-shim-kata-v2
MARK=/host/opt/kata/runtime-rs/bin/.fix11649-applied

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

apply
echo "[overlay] entering watch loop (overlay every ${OVERLAY_INTERVAL_SECS}s)"
while true; do
  sleep "$OVERLAY_INTERVAL_SECS"
  apply || true
done
