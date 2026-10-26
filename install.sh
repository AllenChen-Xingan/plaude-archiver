#!/bin/bash
# Plaud Local v0.2.0-preview.1; source and checksums are published with the release.
set -euo pipefail
umask 077
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo 'This release requires an Apple Silicon Mac.' >&2; exit 1; }
tmp=$(mktemp -d -t plaud-install)
trap 'rm -rf "$tmp"' EXIT
asset="https://github.com/AllenChen-Xingan/plaude-archiver/releases/download/v0.2.0-preview.1/plaud-local-preview.tar.gz"
echo 'Downloading Plaud Local installer...'
curl --proto '=https' --tlsv1.2 -fL --retry 3 --connect-timeout 30 "$asset" -o "$tmp/package.tar.gz"
actual=$(shasum -a 256 "$tmp/package.tar.gz" | awk '{print $1}')
[[ "$actual" == "96908bf02508fb23bf7249e4f60f31f1600a9d226f505fc3f0e86c3ab4d9bafc" ]] || { echo 'Package checksum mismatch; not installing.' >&2; exit 1; }
tar -xzf "$tmp/package.tar.gz" -C "$tmp"
/bin/bash "$tmp/plaud-local-preview/install.sh" "$@"
