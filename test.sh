#!/usr/bin/env bash
# Exercise ensure-tools.sh against a fixture tool list; nothing real is installed.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$(mktemp -d)"
fixture="$(cd "$fixture" && pwd -P)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bare-script" "$fixture/bin"
cp "$here/ensure-tools.sh" "$fixture/bare-script/"
(
    list="$fixture/tools.list"
    cat > "$list" <<'EOS'
present  | true  | manual:never needed |      |
handmade | false | manual:download it from the vendor |  |
chained  | false | vp:x-not-run        | present |
macos    | false | brew:x              |      | darwin
userland | false | manual:not as root  |      | nonroot
EOS
    export ENSURE_TOOLS_LIST="$list" ENSURE_TOOLS_OS=linux
    out="$(bash "$fixture/bare-script/ensure-tools.sh" --check 2>&1 || true)"
    case "$out" in *'ok       present'*'missing  handmade'*'skip     macos (darwin only)'*) ;; *) printf '%s\n' "$out" >&2; exit 1 ;; esac
    case "$(ENSURE_TOOLS_ROOT=1 bash "$fixture/bare-script/ensure-tools.sh" --check userland)" in
        *'skip     userland (not installed as root)'*) ;; *) exit 1 ;; esac
    case "$(ENSURE_TOOLS_ROOT=0 bash "$fixture/bare-script/ensure-tools.sh" --check userland || true)" in
        *'missing  userland'*) ;; *) exit 1 ;; esac
    if bash "$fixture/bare-script/ensure-tools.sh" --check present > /dev/null; then :; else exit 1; fi
    if bash "$fixture/bare-script/ensure-tools.sh" handmade > /dev/null 2>&1; then
        printf 'Expected a manual-only tool to fail\n' >&2; exit 1
    fi
    if bash "$fixture/bare-script/ensure-tools.sh" no-such-tool > /dev/null 2>&1; then
        printf 'Expected an unknown tool to fail\n' >&2; exit 1
    fi
    # A tool whose dependency fails is not attempted.
    printf 'needy | false | vp:x-not-run | handmade | |\n' >> "$list"
    out="$(bash "$fixture/bare-script/ensure-tools.sh" needy 2>&1 || true)"
    case "$out" in *'failed   needy: needs handmade'*) ;; *) printf '%s\n' "$out" >&2; exit 1 ;; esac
    case "$out" in *'install  needy'*) exit 1 ;; esac
    # vp: installs a global package from $HOME and wins over npm.
    vpbin="$fixture/vp-bin"; mkdir -p "$vpbin"
    cat > "$vpbin/vp" <<'EOS'
#!/bin/sh
printf '%s|%s\n' "$PWD" "$*" > "$VP_LOG"
printf '#!/bin/sh\n' > "$VP_BIN/vp-made"; chmod +x "$VP_BIN/vp-made"
EOS
    printf '#!/bin/sh\nexit 1\n' > "$vpbin/npm"; chmod +x "$vpbin/vp" "$vpbin/npm"
    printf 'vp-made | vp-made | vp:@scope/pkg npm:@scope/pkg | | |\n' >> "$list"
    (cd /; PATH="$vpbin:$PATH" VP_LOG="$fixture/vp-log" VP_BIN="$vpbin" \
        bash "$fixture/bare-script/ensure-tools.sh" vp-made > /dev/null)
    [ "$(cat "$fixture/vp-log")" = "$HOME|install --global @scope/pkg" ] ||
        { printf 'unexpected vp call: %s\n' "$(cat "$fixture/vp-log")" >&2; exit 1; }
    out="$(PATH="$fixture/bin:$PATH" bash "$fixture/bare-script/ensure-tools.sh" --dry-run chained 2>&1 || true)"
    case "$out" in *'ok       present'*) ;; *) printf '%s\n' "$out" >&2; exit 1 ;; esac
    # --path adds install directories that exist, once, ahead of PATH.
    mkdir -p "$fixture/home/.local/bin" "$fixture/home/.cargo/bin"
    base_path="/usr/bin:/bin:$fixture/home/.cargo/bin"
    expected_path="$base_path"
    # System Homebrew directories may exist independently of the fixture HOME.
    if [ -d /opt/homebrew/bin ]; then expected_path="/opt/homebrew/bin:$expected_path"; fi
    if [ -d /home/linuxbrew/.linuxbrew/bin ]; then expected_path="/home/linuxbrew/.linuxbrew/bin:$expected_path"; fi
    expected_path="$fixture/home/.local/bin:$expected_path"
    path="$(HOME="$fixture/home" PATH="$base_path" bash "$fixture/bare-script/ensure-tools.sh" --path)"
    [ "$path" = "$expected_path" ] ||
        { printf 'unexpected --path: %s\n' "$path" >&2; exit 1; }
)
printf 'ensure-tools checks passed\n'
