# syntax=docker/dockerfile:1
# Copyright (c) 2026 KubeTEE
# SPDX-License-Identifier: Apache-2.0
#
# KubeTEE thin repack of upstream kata-deploy: replace ONLY the runtime-rs shim
# (containerd-shim-kata-v2) inside kata-static-shim-v2-rust.tar.zst with our
# patched build (fix15 / kata-containers#11649 + the fdset-reclaim hardening on
# branch kubetee-fix11649-4.3.1). Everything else in the image stays
# upstream-identical to the pinned base: QEMU, firmware, kernel, rootfs, the Go
# shim, the kata-deploy installer, and every runtime config TOML.
#
# Why a repack instead of a full upstream image build: our patch surface is
# exactly one host-side userspace binary. Keeping the rest bit-identical keeps
# the published measurement story honest (MRTD/RTMRs cover OVMF + guest kernel +
# measured rootfs; the host shim does not move them), and it makes "what is
# different from upstream 4.3.1?" answerable with one sha256.
#
# Build from the repo root (the root .dockerignore keeps the context small):
#
#   docker buildx build --platform linux/amd64 \
#     --build-arg BASE_IMAGE=quay.io/kata-containers/kata-deploy@sha256:<amd64 digest> \
#     --build-arg KATA_GIT_COMMIT=$(git rev-parse HEAD) \
#     -f tools/packaging/kata-deploy/repack/Dockerfile \
#     --provenance false --sbom false -t ghcr.io/kubetee-ai/kata-deploy:<tag> --push .
#
# BASE_IMAGE must be the linux/amd64 manifest digest (the fleet is x86_64);
# the build pins --platform linux/amd64 so an arm64 dev machine cannot
# accidentally repack the arm64 variant.

ARG BASE_IMAGE=quay.io/kata-containers/kata-deploy@sha256:799c17dcbd6f2c93f2c84f69667aa74b250ce91986096cc990a12abfc8871799

# Named stage for the upstream base: COPY --from= does not support variable
# expansion, so the base image is referenced through this stage name.
FROM ${BASE_IMAGE} AS upstream-base

# --- Stage 1: build the patched runtime-rs shim ------------------------------
FROM rust:1.97-slim AS shim-build
# Toolchain 1.97.0 = versions.yaml / rust-toolchain.toml at 4.3.1. Pin the exact
# patch version via RUSTUP_TOOLCHAIN (outranks the tree's rust-toolchain.toml):
# with only the file's `channel = "1.97"` spec, the rustup shim re-resolves the
# toolchain when cargo runs from /src — potentially a different toolchain than
# the one `rustup target add` installed musl rust-std into, which fails the
# build with E0463: can't find crate for `core`.
ENV RUSTUP_TOOLCHAIN=1.97.0
RUN apt-get update && apt-get install -y --no-install-recommends \
        musl-tools clang llvm protobuf-compiler libseccomp-dev pkg-config \
        ca-certificates \
    && rustup show active-toolchain \
    && rustup target add x86_64-unknown-linux-musl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# The workspace spans src/libs, src/agent, src/dragonball, src/tools,
# src/runtime-rs, and tools/packaging/kata-deploy/binary (root Cargo.toml
# members), so the whole tree must be present for cargo to load the workspace.
# The root .dockerignore already trims heavy/irrelevant trees from the context.
COPY . .

# config.rs is gitignored (build-generated) and a tree copy can carry stale
# version metadata; regenerate it honestly: release version + the built commit.
ARG KATA_GIT_COMMIT=unknown
RUN printf '// SPDX-License-Identifier: Apache-2.0\n// WARNING: auto-generated\n\npub const PROJECT_NAME: &str = "Kata Containers";\npub const RUNTIME_VERSION: &str = "4.3.1";\npub const RUNTIME_GIT_COMMIT: &str = "%s";\npub const RUNTIME_NAME: &str = "containerd-shim-kata-v2";\npub const CONTAINERD_RUNTIME_NAME: &str = "io.containerd.kata.v2";\npub const RUNTIME_DIR: &str = "/usr/local/bin";\npub const RUNTIME_PATH: &str = "/usr/local/bin/containerd-shim-kata-v2";\n' "${KATA_GIT_COMMIT}" \
        > src/runtime-rs/crates/shim/src/config.rs

# Static musl build, matching upstream's shipped shim (ELF x86-64, statically
# linked). The workspace target-dir is the repo root, not src/runtime-rs/target.
RUN cargo build --release --target x86_64-unknown-linux-musl --bin containerd-shim-kata-v2 \
    && sha256sum /src/target/x86_64-unknown-linux-musl/release/containerd-shim-kata-v2

# --- Stage 2: repack the shim component tarball (needs a shell) --------------
FROM debian:trixie-slim AS repack
RUN apt-get update && apt-get install -y --no-install-recommends zstd tar findutils \
    && rm -rf /var/lib/apt/lists/*
ARG BASE_IMAGE
ARG KATA_GIT_COMMIT=unknown
COPY --from=upstream-base /opt/kata-artifacts/tarballs/kata-static-shim-v2-rust.tar.zst /opt/kata-artifacts/tarballs/
COPY --from=shim-build /src/target/x86_64-unknown-linux-musl/release/containerd-shim-kata-v2 /tmp/kubetee-containerd-shim-kata-v2
# Swap ONLY ./opt/kata/runtime-rs/bin/containerd-shim-kata-v2 (mode 0755); every
# other entry in the tarball — including all runtime-rs config TOMLs — passes
# through byte-identical. Entry paths keep the opt/kata prefix the installer
# strips (tools/packaging/kata-deploy/binary/src/artifacts/install.rs).
RUN set -eux; \
    cd /tmp; \
    mkdir -p t/keep; \
    zstd -dc /opt/kata-artifacts/tarballs/kata-static-shim-v2-rust.tar.zst | tar -xf - -C t/keep; \
    cp /tmp/kubetee-containerd-shim-kata-v2 t/keep/opt/kata/runtime-rs/bin/containerd-shim-kata-v2; \
    chmod 0755 t/keep/opt/kata/runtime-rs/bin/containerd-shim-kata-v2; \
    (cd t/keep && find ./opt | LC_ALL=C sort | tar -cf - -T -) > t/shim-v2-rust.tar; \
    zstd -q -19 -o /opt/kata-artifacts/tarballs/kata-static-shim-v2-rust.tar.zst.new t/shim-v2-rust.tar; \
    mv /opt/kata-artifacts/tarballs/kata-static-shim-v2-rust.tar.zst.new /opt/kata-artifacts/tarballs/kata-static-shim-v2-rust.tar.zst; \
    SHIM_SHA256="$(sha256sum /tmp/kubetee-containerd-shim-kata-v2 | awk '{print $1}')"; \
    { \
      echo "kubetee kata-deploy repack"; \
      echo "base_image=${BASE_IMAGE}"; \
      echo "kata_git_commit=${KATA_GIT_COMMIT}"; \
      echo "shim_sha256=${SHIM_SHA256}"; \
    } > /opt/kata-artifacts/kubetee-repack-info.txt; \
    echo "--- repacked tarball shim entry:"; \
    zstd -dc /opt/kata-artifacts/tarballs/kata-static-shim-v2-rust.tar.zst | tar -tvf - | grep containerd-shim-kata-v2; \
    echo "--- repacked tarball config entries (must survive, 12 TOMLs):"; \
    zstd -dc /opt/kata-artifacts/tarballs/kata-static-shim-v2-rust.tar.zst | tar -tf - | grep -c '\.toml'; \
    zstd -dc /opt/kata-artifacts/tarballs/kata-static-shim-v2-rust.tar.zst | tar -tf - | grep configuration-qemu-tdx-runtime-rs.toml; \
    cat /opt/kata-artifacts/kubetee-repack-info.txt

# --- Stage 3: upstream image + the two changed files -------------------------
# Distroless base: COPY only, no RUN. The rest of the image layers (and the
# image config — ENTRYPOINT etc.) are inherited unchanged from upstream-base.
FROM upstream-base
COPY --from=repack /opt/kata-artifacts/tarballs/kata-static-shim-v2-rust.tar.zst /opt/kata-artifacts/tarballs/kata-static-shim-v2-rust.tar.zst
COPY --from=repack /opt/kata-artifacts/kubetee-repack-info.txt /opt/kata-artifacts/kubetee-repack-info.txt
