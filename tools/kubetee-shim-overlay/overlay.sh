#!/bin/sh
# KubeTEE kata-deploy runtime-rs shim overlay — fix11649+fix16 variant.
#
# Minimal overlay: copies the containerd-shim-kata-v2 carrying exactly TWO
# fixes onto /opt/kata/runtime-rs/bin/ after kata-deploy installs the stock
# binary:
#  - #11649 (fix15): idempotent block hotplug / hotplug-sized QMP read
#    timeout — deterministic duplicate drive-N CrashLoop on every
#    fetch-certs init recreate.
#  - #13641 (fix16): close inotify fds off the tokio runtime — restored
#    2026-09-23 after a live repro (graceful teardown of a real ~800Gi
#    GPU-TDX guest wedged the shim, QEMU leaked with all VFIO devices).
# No orphan reaper, no other fix classes — see nim/kata-shim-ab/README.md
# for the A/B verdict that scoped this down.
set -eu

SRC=/opt/kata/runtime-rs/bin/containerd-shim-kata-v2
DST=/host/opt/kata/runtime-rs/bin/containerd-shim-kata-v2
MARK=/host/opt/kata/runtime-rs/bin/.fix11649fix16-applied

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
