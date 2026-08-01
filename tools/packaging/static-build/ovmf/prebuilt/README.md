# Pre-built TDX OVMF (edk2-stable202605, Config-B)

This directory contains a pre-built `OVMF.inteltdx.fd` from
`edk2-stable202605` (2026-05-22 stable tag) using `IntelTdxX64.dsc`
(Config-B, full TDX features including lazy memory acceptance).

## Why this exists

The stock OVMF shipped by `kata-deploy` (built from `OvmfPkgX64.dsc`,
Config-A) eagerly accepts all TDX-protected guest memory in firmware
during boot. For large-memory TDX guests this exceeds the Kata shim's
1200s sandbox-create timeout — the VM is killed before it finishes
firmware init. See [kata-containers#13535](https://github.com/kata-containers/kata-containers/issues/13535)
for the full investigation (1.6 TB guest RAM, 8x NVIDIA B300, TDX CC).

The Config-B build (`IntelTdxX64.dsc`) uses `IntelTdx/IntelTdx.c` to
mark memory `>= 4 GB` as `EFI_RESOURCE_MEMORY_UNACCEPTED`, so the guest
kernel accepts it on demand (lazy acceptance) instead of the firmware
accepting it eagerly. No build PCD is required — it is the default for
`IntelTdxX64.dsc`.

## Files

| File | Description |
|------|-------------|
| `OVMF.inteltdx.fd` | Pre-built firmware (4 MiB), Config-B, no Secure Boot |
| `OVMF.inteltdx.fd.sha256` | SHA256 checksum of the firmware |
| `build-firmware.sh` | Reproducible build script (builds from `edk2-stable202605`) |

## Verification (production)

| Metric | Stock OVMF (Config-A) | This build (Config-B, edk2-stable202605) |
|---|---|---|
| Sandbox create (1.6 TB guest) | timeout > 1200s (hang) | ~541s (success) |
| QEMU RSS during firmware init | eager accept of all 1.6 TB | lazy: 0 → 3 GB over ~7 min |
| Pod reaches `Running` | never (shim kills it) | yes (~9 min) |
| Weight download in guest | n/a | 218 MB/s (hf-xet), 1.42 TiB in ~1h40m |

Tested on `am-b300-60` (HGX B300 8x B200 + Intel TDX, Ubuntu 26.04 LTS,
kernel 7.0.0-27-generic) running Kimi-K3 (2.8T-param MoE) under
`kata-qemu-nvidia-gpu-tdx-runtime-rs` with 1600 GiB guest RAM.

## Reproducing the build

The build can be reproduced with:

```bash
./build-firmware.sh
```

The script:
1. Installs build prerequisites (`uuid-dev`, `nasm`, `iasl`, `build-essential`, `git`)
2. Clones `tianocore/edk2` and checks out `edk2-stable202605`
3. Initializes submodules
4. Builds BaseTools
5. Builds `OvmfPkg/IntelTdx/IntelTdxX64.dsc` (Config-B, RELEASE, GCC toolchain)
6. Copies the resulting `OVMF.fd` to `OVMF.inteltdx.fd` in the script directory

The build was performed directly on `am-b300-60` (Ubuntu 26.04, NASM
2.15.05, GCC 11.4 — note: newer toolchains like NASM 3.0 / GCC 15
require source patches to edk2 BaseTools).

## Installing in a kata-deploy deployment

Copy the firmware to the node's kata OVMF directory:

```bash
sudo cp OVMF.inteltdx.fd /opt/kata/share/ovmf/OVMF.inteltdx.fd
```

The `versions.yaml` bump in this branch (`.externals.ovmf.tdx.version:
edk2-stable202605`) makes the kata-deploy CI build pipeline produce
this same firmware from source, so the pre-built binary here is for
testing/verification only — the canonical source is the CI-built
tarball.
