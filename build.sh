#!/usr/bin/env bash
# Assemble lib/*.sh into the single distributable installer: psai.sh
#
# The installer ships as ONE self-contained file so it can be run via
#   bash <(curl -fsSL <url>)
# and copied into a stack. Source of truth is lib/; this concatenates the
# modules in numeric-prefix order and syntax-checks the result before publishing.
set -euo pipefail
cd "$(dirname "$0")"

OUT="psai.sh"
MODULES=(lib/*.sh)   # glob expands in sorted (numeric-prefix) order

[ ${#MODULES[@]} -gt 0 ] || { echo "no lib/*.sh modules found" >&2; exit 1; }

tmp="$(mktemp)"
for f in "${MODULES[@]}"; do
  cat "$f" >> "$tmp"
done

# Sanity: the assembled file must be valid bash before we publish it.
bash -n "$tmp" || { echo "assembled file failed syntax check" >&2; rm -f "$tmp"; exit 1; }

mv "$tmp" "$OUT"
chmod +x "$OUT"
echo "Built $OUT from ${#MODULES[@]} modules ($(wc -l < "$OUT" | tr -d ' ') lines)."

# Record the installer's sha256 in versions.json so installs can verify self-update.
if [ -f versions.json ]; then
  sha="$( (shasum -a 256 "$OUT" 2>/dev/null || sha256sum "$OUT") | awk '{print $1}')"
  if [ -n "$sha" ]; then
    t2="$(mktemp)"
    sed "s/\"installer_sha256\": *\"[^\"]*\"/\"installer_sha256\": \"$sha\"/" versions.json > "$t2" && mv "$t2" versions.json
    echo "versions.json installer_sha256 = $sha"
  fi
fi

# versions.json is signed at release time with the maintainer's SSH key (YubiKey-resident):
#   ssh-keygen -Y sign -f <signing.pub> -n psai-versions versions.json   # -> versions.json.sig
# self-update (lib/96-cron.sh) verifies that .sig with `ssh-keygen -Y verify` against the
# pinned UPDATE_SIGN_PUBKEY. Signing is NOT done here (no key in CI) — this only records the
# installer_sha256 above; the maintainer signs versions.json before pushing the release.
