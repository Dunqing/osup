#!/usr/bin/env bash
# Build the latest gh-stack release with REST calls in place of GraphQL and install it
# as the `gh stack` extension. For Claude Code cloud sessions, whose GitHub proxy refuses
# GraphQL and `gh extension install`; ensure-tools runs it as `script:gh-stack-rest`.
# Needs git, python3 and Go. Bash 3.2 compatible.
set -euo pipefail
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo=https://github.com/github/gh-stack
for tool in git python3 go; do
    command -v "$tool" > /dev/null || { printf 'gh-stack-rest: needs %s\n' "$tool" >&2; exit 1; }
done
# Newest vX.Y.Z tag (the releases API is blocked in cloud sessions; git tags are not).
version="$(git ls-remote --tags --refs "$repo" | sed -n 's#.*refs/tags/v\([0-9]*\.[0-9]*\.[0-9]*\)$#\1#p' |
    sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
[ -n "$version" ] || { printf 'gh-stack-rest: no release tag found in %s\n' "$repo" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git -c advice.detachedHead=false clone -q --depth 1 --branch "v$version" "$repo" "$work/src"
python3 -I "$here/apply.py" "$work/src"
(cd "$work/src" && go build -trimpath -ldflags "-s -w -X github.com/github/gh-stack/cmd.Version=$version-rest" -o "$work/gh-stack" .)
# A pinned binary extension, so `gh extension upgrade` leaves it alone.
dir="${XDG_DATA_HOME:-$HOME/.local/share}/gh/extensions/gh-stack"
mkdir -p "$dir"
install -m 755 "$work/gh-stack" "$dir/gh-stack"
printf 'owner: github\nname: gh-stack\nhost: github.com\ntag: v%s\nispinned: true\npath: %s\n' "$version" "$dir/gh-stack" > "$dir/manifest.yml"
printf 'gh-stack-rest: installed gh-stack %s (REST build) in %s\n' "$version" "$dir"
