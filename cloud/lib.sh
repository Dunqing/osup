# Shared by the cloud scripts. setup.sh copies this directory's scripts to /opt/devtools,
# and the session-start hook (refresh) copies newer ones from the osup checkout.
# Linux x86_64 cloud containers only; sourced by bash.
OPT=/opt/devtools
BIN=$HOME/.local/bin
# npm for global CLIs: the image's own when it has a Node, else the pinned one (pick).
NPM=$OPT/node-system/bin/npm
[ -x "$NPM" ] || NPM=$BIN/npm
# Tools from tools.list that a stock image (ubuntu:24.04) lacks and the scripts here need:
# installed first, serially. go is for the gh-stack build.
BASE_TOOLS="curl python3 xz unzip cc rust go"
# Machine tools from tools.list that every checkout uses. gh-stack is built separately (~25s).
CLOUD_TOOLS="just cargo-insta watchexec ast-grep"
CLOUD_SCRIPTS="lib.sh pick setup-repo refresh"

# et TOOL...: ensure-tools from the osup checkout; without one, installed tools still work.
et() {
    local d
    d=$(cat "$OPT/src" 2> /dev/null) && [ -f "$d/ensure-tools.sh" ] || return 0
    bash "$d/ensure-tools.sh" "$@"
}

# use_tool_path: PATH with the directories ensure-tools installs into (~/.cargo/bin, ...).
use_tool_path() {
    local p
    p=$(et --path 2> /dev/null) && [ -n "$p" ] && PATH=$p
    export PATH="$BIN:$PATH"
}
use_tool_path

# install_scripts DIR: copy the cloud scripts to /opt/devtools (rename, so a running copy is safe).
install_scripts() {
    local f
    for f in $CLOUD_SCRIPTS; do
        cp "$1/$f" "$OPT/.$f.new" && chmod 755 "$OPT/.$f.new" && mv -f "$OPT/.$f.new" "$OPT/$f" || return 1
    done
}

# claude_settings: merge the SessionStart hook, attribution and auto-mode rules into
# ~/.claude/settings.json, keeping other keys; writes only when something changes. Run by
# setup.sh and, so existing environments pick up changes, by refresh.
claude_settings() {
    mkdir -p ~/.claude && python3 - << 'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
s = json.load(open(p)) if os.path.exists(p) else {}
before = json.dumps(s, sort_keys=True)
hooks = s.setdefault("hooks", {}).setdefault("SessionStart", [])
cmd = {"type": "command", "command": "/opt/devtools/refresh", "timeout": 900}
if not any(h.get("command") == cmd["command"] for e in hooks for h in e.get("hooks", [])):
    hooks.append({"hooks": [cmd]})
# No Co-Authored-By trailer, PR footer, or session link, in any repository. Empty strings,
# not `attribution: false`, which older Claude Code versions reject along with the file.
a = s.get("attribution")
s["attribution"] = {**(a if isinstance(a, dict) else {}), "commit": "", "pr": "", "sessionUrl": False}
# Auto mode: the user's standing rules, so the classifier doesn't stop them. Prose entries,
# with "$defaults" keeping the built-in rules.
am = s.get("autoMode")
am = s["autoMode"] = am if isinstance(am, dict) else {}
rules = {
    "environment": "Commits are authored and committed as the user, with the name and email of "
    "their own recent commits in that repository set through GIT_AUTHOR_* and GIT_COMMITTER_* "
    "environment variables. This is the user's standing rule, not impersonation.",
    "allow": "git push --force-with-lease (including --atomic) of non-default branches that the "
    "agent created or rebased in this session, such as stacked PR branches, is pre-approved by "
    "the user. The default branch and branches owned by others are not covered.",
}
for k, rule in rules.items():
    l = am.get(k)
    l = am[k] = l if isinstance(l, list) else []
    if "$defaults" not in l:
        l.insert(0, "$defaults")
    if rule not in l:
        l.append(rule)
if json.dumps(s, sort_keys=True) != before:
    json.dump(s, open(p, "w"), indent=2)
PY
}

# unsign DIR: turn off commit signing in a checkout and its submodules. The image signs
# globally with a key for its agent identity, and its Stop hook asks to re-author unpushed
# commits by anyone else; commits here are the user's, and unsigned ones skip that check.
unsign() {
    git -C "$1" config commit.gpgsign false &&
        git -C "$1" submodule foreach --quiet --recursive 'git config commit.gpgsign false'
}

# pin node|cargo-shear VERSION: install a pinned version once (serialized across jobs, atomic).
pin() {
    [ ! -d "$OPT/$1-$2" ] || return 0
    local t r=0
    t=$(mktemp -d "$OPT/.tmp.XXXX")
    (
        flock 9
        [ ! -d "$OPT/$1-$2" ] || exit 0
        case $1 in
            node) curl -fsSL "https://nodejs.org/dist/v$2/node-v$2-linux-x64.tar.xz" | tar -xJ -C "$t" --strip-components=1 ;;
            cargo-shear)
                curl -fsSL --retry 3 "https://github.com/Boshen/cargo-shear/releases/download/v$2/cargo-shear-x86_64-unknown-linux-musl.tar.gz" |
                    tar -xz -C "$t" cargo-shear ||
                    { cargo install --locked --root "$t/build" "cargo-shear@$2" && mv "$t/build/bin/cargo-shear" "$t/"; } ;;
        esac && mv -T "$t" "$OPT/$1-$2"
    ) 9> "$OPT/.lock" || r=$?
    rm -rf "$t"
    return $r
}

# npm_global PACKAGE BINARY: install an npm package globally and link BINARY into $BIN.
npm_global() {
    "$NPM" i -g --no-update-notifier --no-audit --no-fund "$1" && ln -sf "$("$NPM" prefix -g)/bin/$2" "$BIN/$2"
}

# fp: run in a checkout; a hash of what setup-repo depends on (pins, JS lockfiles, coverage-suite
# and submodule commits, and setup-repo itself). refresh re-runs setup-repo when it changes.
fp() {
    (
        set +e
        {
            cat .node-version rust-toolchain.toml pnpm-lock.yaml package-lock.json "$OPT/setup-repo"
            grep -so 'cargo-shear@[0-9.]*' justfile
            grep -so '"packageManager": *"[^"]*"' package.json
            grep -so '_SHA = "[0-9a-f]*"' .github/scripts/clone-parallel.mjs
            git ls-files -s | awk '$1 == 160000'
        } 2> /dev/null | sha256sum | cut -c1-16
    )
}

# rusttc: run in a checkout; its pinned Rust, minimal profile plus clippy and rustfmt.
rusttc() {
    [ -f rust-toolchain.toml ] || return 0
    local channel
    channel=$(sed -n 's/^channel *= *"\(.*\)"/\1/p' rust-toolchain.toml)
    # Without a channel line, rustup reads the toolchain file itself.
    rustup toolchain install ${channel:+"$channel"} --profile minimal -c clippy -c rustfmt --no-self-update
}
