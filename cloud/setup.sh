#!/usr/bin/env bash
# Cloud environment setup for coding agents. Run it from the directory that holds the
# session's checkouts (where the environment's setup script starts), for example:
#
#   git clone -q --depth 1 https://github.com/Dunqing/osup /opt/osup
#   bash /opt/osup/cloud/setup.sh claude      # agents: claude, codex, gemini
#
# Sets up every checkout there (setup-repo) and the shared tools from tools.list. A
# Dunqing/dotfiles checkout, when present, also installs the personal agent profile. For
# Claude Code it adds the session-start hook and notes for cloud sessions. Always exits 0,
# since a failing setup script stops the session from starting; failures are listed at the
# end. Linux x86_64 only.
set -uo pipefail
here=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src=$(cd "$here/.." && pwd)
base=$PWD
dotfiles=""
[ ! -f "$base/dotfiles/bare-script/install-agents.sh" ] || dotfiles="$base/dotfiles"
[ $# -gt 0 ] || { echo "usage: setup.sh AGENT... (claude, codex, gemini)" >&2; exit 0; }
. "$here/lib.sh"
mkdir -p "$OPT/state" "$BIN"
echo "$base" > "$OPT/base"
echo "$src" > "$OPT/src"
install_scripts "$here" || { echo "setup: could not install scripts into $OPT" >&2; exit 0; }
for n in $(type -ap node); do
    [ "$n" = "$BIN/node" ] || { ln -sfn "$(dirname "$(dirname "$n")")" "$OPT/node-system"; break; }
done
[ -s "$OPT/node.default" ] || echo system > "$OPT/node.default"
ln -sf "$OPT/setup-repo" "$BIN/setup-repo"
for t in node npm npx corepack cargo-shear; do ln -sf "$OPT/pick" "$BIN/$t"; done
FAILED=""
# What a stock image lacks (a C toolchain, rustup, Go, ...), before anything uses it.
et $BASE_TOOLS || FAILED+=" base-tools"
use_tool_path # rustup has just made ~/.cargo/bin
# Shells in the session find what is installed under ~/.local/bin and ~/.cargo/bin.
cat > /etc/profile.d/osup.sh << 'SH'
for d in "$HOME/.cargo/bin" "$HOME/.local/bin"; do
    case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
done
export PATH
SH
grep -qs profile.d/osup.sh ~/.bashrc || echo '. /etc/profile.d/osup.sh' >> ~/.bashrc

claude_setup() {
    mkdir -p ~/.claude
    python3 - << 'PY' || FAILED+=" claude-settings"
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
    grep -qs setup-repo ~/.claude/CLAUDE.md || cat >> ~/.claude/CLAUDE.md << 'MD'
# Cloud environment
To bring in another repository mid-session, call add_repo with access "push" (the user's GitHub
credentials; use the read-only clone only if that is refused), clone it where add_repo says, then
run `setup-repo <checkout-dir>` once before building or testing in it. Re-run it if a tool or
dependency seems missing. In Oxc, run `just submodules` before ESTree conformance work
(estree-conformance isn't pre-cloned). GraphQL is blocked here: use `gh api` (REST), the GitHub
tools, and `gh stack` (a REST build, see Dunqing/osup gh-stack-rest). Sessions usually start with
only the repository the task is about; if a task also needs rolldown/rolldown or oxc-project/oxc
(for example a Rolldown bug that may come from Oxc), attach it as above and run `setup-repo` on it.
MD
    [ -n "$dotfiles" ] || grep -qs 'Dunqing/dotfiles' ~/.claude/CLAUDE.md ||
        echo "Dunqing/dotfiles isn't attached to this session, so the user's personal skills and guide aren't loaded; say so if a task needs them." >> ~/.claude/CLAUDE.md
}

# Checkouts here except dotfiles, oxc first so its Node and cargo-shear become the defaults.
cd "$base" || { echo "setup: cannot enter $base" >&2; exit 0; }
R=()
for d in oxc rolldown */; do
    d=${d%/}
    [ -d "$d/.git" ] && [ "$d" != dotfiles ] && [ "$base/$d" != "$src" ] || continue
    case " ${R[*]-} " in *" $d "*) ;; *) R+=("$d") ;; esac
done
# Defaults and Rust toolchains serially, before the parallel jobs share them.
for d in ${R[@]+"${R[@]}"}; do
    [ "$(cat "$OPT/node.default")" != system ] || [ ! -f "$d/.node-version" ] || cp "$d/.node-version" "$OPT/node.default"
    [ -s "$OPT/cargo-shear.default" ] || grep -so 'cargo-shear@[0-9.]*' "$d/justfile" | cut -d@ -f2 > "$OPT/cargo-shear.default"
    (cd "$d" && rusttc) || FAILED+=" rust:$d"
done
et $CLOUD_TOOLS || FAILED+=" tools"
for a in "$@"; do
    case $a in claude) claude_setup ;; esac
done
# Checkouts, gh-stack's build and the agent profile in parallel, one log each.
P=() N=()
for d in ${R[@]+"${R[@]}"}; do
    setup-repo "$d" > "/tmp/setup-$d.log" 2>&1 & P+=($!) N+=("$d")
done
et gh-stack > /tmp/setup-gh-stack.log 2>&1 & P+=($!) N+=(gh-stack)
if [ -n "$dotfiles" ]; then
    bash "$dotfiles/bare-script/install-agents.sh" "$@" > /tmp/setup-dotfiles.log 2>&1 & P+=($!) N+=(dotfiles)
fi
for i in "${!P[@]}"; do
    wait "${P[$i]}" || FAILED+=" ${N[$i]}"
    echo "== ${N[$i]}"
    cat "/tmp/setup-${N[$i]}.log"
done
[ -z "$FAILED" ] || echo "setup: failed for:$FAILED (re-run: setup-repo <dir>; logs in /tmp/setup-*.log)" >&2
exit 0
