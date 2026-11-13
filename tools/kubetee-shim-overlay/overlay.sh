#!/bin/sh
# KubeTEE kata-deploy runtime-rs shim overlay — fix11649-only (4.3.1).
#
# Minimal overlay: copies the containerd-shim-kata-v2 carrying exactly ONE
# fix onto /opt/kata/runtime-rs/bin/ after kata-deploy installs the stock
# binary:
#  - #11649 (fix15): idempotent block hotplug / hotplug-sized QMP read
#    timeout — deterministic duplicate drive-N CrashLoop on every
#    fetch-certs init recreate.
#
# fix16 (#13641) and T15/T16 (#13665/#13746) are CONSCIOUSLY DROPPED as of
# the 4.3.1 rebase: the Phase 0.5b/0.5c battery on stock 4.3.1 reproduced
# ONLY #11649 (duplicate QEMU block device ID drive-5, 2026-10-22,
# am-b200-59); the heavy 1201G GPU-TDX teardown test — the exact fix16
# class — reaped cleanly (QEMU exit 137 + TaskDelete, zero D-state) and no
# T15/T16 leftover-VM behavior appeared. If a later battery reproduces
# them, add the classes back as separate commits with their own evidence.
#
# No orphan reaper, no other fix classes, no hostPID — see
# nim/kata-shim-ab/README.md for the A/B verdict that scoped this down.
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
