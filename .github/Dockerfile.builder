# syntax=docker/dockerfile:1
#
# Base builder image for spotifyd CI — published to ghcr.io/b0bbywan/spotifyd-builder.
# Embeds system dependencies, the Rust toolchain, and pre-compiled dependencies
# so the main build only has to compile spotifyd itself.
#
# Rebuilt when this file or Cargo.lock changes (see .github/workflows/builder.yml).

# ── Base OS images ─────────────────────────────────────────────────────────────
# amd64: Debian Trixie (native build)
# arm64/armhf: RaspiOS (Trixie), run natively under QEMU binfmt_misc —
#   no cross-compiler needed, not even for bindgen.
FROM debian:trixie-slim       AS base-amd64
FROM vascoguita/raspios:arm64 AS base-arm64
FROM vascoguita/raspios:armhf AS base-arm

# ── Builder ────────────────────────────────────────────────────────────────────
ARG TARGETARCH
FROM base-${TARGETARCH}

ARG TARGETARCH
ARG TARGETVARIANT

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gcc \
    libc6-dev \
    # required by aws-lc-rs (bindgen) on non-x86_64/aarch64 targets
    libclang-dev \
    cmake \
    pkg-config \
    # alsa_backend + base
    libasound2-dev \
    libssl-dev \
    # dbus_mpris
    libdbus-1-dev \
    # pulseaudio_backend
    libpulse-dev \
    # rodiojack_backend
    libjack-dev \
    && rm -rf /var/lib/apt/lists/*

# Force the correct rustup host triple.
# QEMU reports armv7 even inside an armv6 container — override manually.
RUN set -eux; \
    case "${TARGETARCH}${TARGETVARIANT}" in \
        armv6)   RUST_HOST="arm-unknown-linux-gnueabihf"    ;; \
        armv7)   RUST_HOST="armv7-unknown-linux-gnueabihf"  ;; \
        arm64)   RUST_HOST="aarch64-unknown-linux-gnu"      ;; \
        amd64)   RUST_HOST="x86_64-unknown-linux-gnu"       ;; \
        *)       RUST_HOST=""                               ;; \
    esac; \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --default-toolchain stable --profile minimal \
        ${RUST_HOST:+--default-host "$RUST_HOST"}

ENV PATH="/root/.cargo/bin:$PATH"
# Use native bindgen (no cross-compilation)
ENV AWS_LC_SYS_BINDGEN=1

# ── Pre-compile dependencies with cargo-chef ───────────────────────────────────
RUN cargo install cargo-chef --locked

WORKDIR /build
COPY Cargo.lock Cargo.toml ./
# Dummy source so cargo-chef can analyse the dependency graph
RUN mkdir -p src && echo 'fn main() {}' > src/main.rs

RUN cargo chef prepare --recipe-path recipe.json

# Cook with the full feature set so every possible build hits the cache
RUN cargo chef cook --locked --release --no-default-features \
    --features alsa_backend,pulseaudio_backend,rodio_backend,rodiojack_backend,dbus_mpris \
    --recipe-path recipe.json
