#!/usr/bin/env bash
# Cross-build stack-vault into vault/dist/stack-vault-<os>-<arch> for the release, so
# agent worker nodes (and a KMS node) can install the daemon without a Rust toolchain.
# build_vault() prefers these over compiling from source.
#
# Linux targets use musl (static, no libc version skew across distros). Run this in CI
# or on a Linux host with `cross` (Docker) installed, or with the musl targets added:
#   rustup target add x86_64-unknown-linux-musl aarch64-unknown-linux-musl
#   cargo install cross    # optional, handles the linkers via Docker
set -eu

cd "$(dirname "$0")"
DIST="dist"; mkdir -p "$DIST"

# host = the macOS/native build (used by a local install on this machine)
host_arch() { case "$(uname -m)" in arm64|aarch64) echo aarch64 ;; x86_64|amd64) echo x86_64 ;; *) uname -m ;; esac; }
host_os()   { case "$(uname -s)" in Darwin) echo macos ;; Linux) echo linux ;; *) uname -s | tr 'A-Z' 'a-z' ;; esac; }

build_one() { # $1=rust-target  $2=os  $3=arch  [$4=builder]
  local target="$1" os="$2" arch="$3" builder="${4:-cargo}" out="$DIST/stack-vault-$2-$3"
  echo "==> $builder build --release --target $target"
  if "$builder" build --release --target "$target" 2>/dev/null; then
    cp "target/$target/release/stack-vault" "$out" && chmod +x "$out"
    echo "    -> $out ($(wc -c < "$out") bytes)"
  else
    echo "    SKIP $target (toolchain/linker missing — run in CI or install: rustup target add $target [+ cross])"
  fi
}

# 1) native host build (always works where you have cargo)
echo "==> native: cargo build --release"
cargo build --release
cp "target/release/stack-vault" "$DIST/stack-vault-$(host_os)-$(host_arch)"
chmod +x "$DIST/stack-vault-$(host_os)-$(host_arch)"
echo "    -> $DIST/stack-vault-$(host_os)-$(host_arch)"

# 2) Linux x86_64 + aarch64 (musl). Prefer `cross` if available (Docker-backed).
BUILDER=cargo; command -v cross >/dev/null 2>&1 && BUILDER=cross
build_one x86_64-unknown-linux-musl  linux x86_64  "$BUILDER"
build_one aarch64-unknown-linux-musl linux aarch64 "$BUILDER"

echo
echo "dist/:"; ls -la "$DIST" 2>/dev/null | sed 's/^/  /'
echo "sha256:"; (command -v sha256sum >/dev/null && sha256sum "$DIST"/* || shasum -a 256 "$DIST"/*) 2>/dev/null | sed 's/^/  /'
