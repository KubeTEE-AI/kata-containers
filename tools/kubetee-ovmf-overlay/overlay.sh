#!/bin/sh
# KubeTEE kata-deploy OVMF overlay (TDX lazy-accept firmware).
#
# Copies the official kata-containers #13631 packaging build of the TDX OVMF
# (edk2-stable202608, built from OvmfPkg/IntelTdx/IntelTdxX64.dsc via
# tools/packaging/static-build/ovmf/build-ovmf.sh in the official ovmf builder)
# over the stock kata-deploy OVMF that the kata-deploy install Job placed at
# /opt/kata/share/ovmf/OVMF.inteltdx.fd on the host (stock = edk2-stable202511
# eager-accept build, which hangs large-memory TDX guests — kata#13535).
#
# Waits for kata-deploy to extract the OVMF first, then applies the patch
# idempotently (cmp-based; no-op if already patched). A watch loop re-applies if
# kata-deploy is re-installed/upgraded (or overwrites the firmware). Re-runs on
# node reboot (DaemonSet pod restart), so the patch persists.
set -eu

SRC=/opt/kata/share/ovmf/OVMF.inteltdx.fd    # patched firmware in this image
DST=/host/opt/kata/share/ovmf/OVMF.inteltdx.fd  # on-node target
MARK=/host/opt/kata/share/ovmf/.lazy-accept-ovmf-applied

echo "[ovmf-overlay] waiting for kata-deploy to extract $DST ..."
while [ ! -f "$DST" ]; do sleep 5; done
echo "[ovmf-overlay] $DST present"

apply() {
  if cmp -s "$SRC" "$DST"; then
    echo "[ovmf-overlay] firmware already patched (no-op)"
  else
    # Preserve the stock build for rollback (once — cmp against it so we never
    # back up over the same file).
    STOCK="$DST.stock-$(sha256sum "$DST" | cut -c1-8)"
    if [ ! -f "$STOCK" ]; then
      cp -a "$DST" "$STOCK"
      echo "[ovmf-overlay] backed up stock firmware -> $STOCK"
    fi
    cp "$SRC" "$DST"
    chmod 755 "$DST"
    sha256sum "$SRC" | cut -d' ' -f1 > "$MARK"
    echo "[ovmf-overlay] lazy-accept OVMF applied: $(cut -c1-16 < "$MARK")"
  fi
}

apply
echo "[ovmf-overlay] entering watch loop (re-apply if kata-deploy re-extracts stock)"
while true; do sleep 60; apply; done
