#!/usr/bin/env bash
# Install command-line tools listed in tools.list when they are missing.
#
#   ensure-tools.sh NAME...     ensure these tools (and what they need)
#   ensure-tools.sh --all       ensure every tool for this OS (new machine)
#   ensure-tools.sh --check [NAME...]   report only; exit 1 if any is missing
#   ensure-tools.sh --dry-run NAME...   print what would be installed
#
# A tool already present is never touched. Installers are tried in the listed
# order; the first one usable here (brew, apt, vp, npm, cargo, go, gh extension,
# GitHub release, a named script) wins, and the check must pass afterwards. Bash 3.2 compatible.
set -euo pipefail

# Resolve symlinks (~/.agents/bin/ensure-tools) to find tools.list beside the real script.
source_path="${BASH_SOURCE[0]}"
while [ -L "$source_path" ]; do
    link_dir="$(cd -P "$(dirname "$source_path")" && pwd)"
    source_path="$(readlink "$source_path")"
    case "$source_path" in /*) ;; *) source_path="$link_dir/$source_path" ;; esac
done
script_dir="$(cd -P "$(dirname "$source_path")" && pwd)"
list="${ENSURE_TOOLS_LIST:-$script_dir/tools.list}"
case "${ENSURE_TOOLS_OS:-$(uname -s)}" in
    Darwin|darwin) os=darwin ;;
    *) os=linux ;;
esac

names=() checks=() installers=() needs=() oses=()
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
while IFS= read -r line || [ -n "$line" ]; do
    case "$(trim "$line")" in ''|\#*) continue ;; esac
    IFS='|' read -r name check installer need tool_os <<< "$line"
    names+=("$(trim "$name")")
    checks+=("$(trim "$check")")
    installers+=("$(trim "$installer")")
    needs+=("$(trim "${need:-}")")
    tool_os="$(trim "${tool_os:-}")"
    oses+=("${tool_os:-any}")
done < "$list"

find_tool() {
    local i
    for ((i = 0; i < ${#names[@]}; i++)); do
        if [ "${names[i]}" = "$1" ]; then found=$i; return 0; fi
    done
    return 1
}

present() { (eval "${checks[$1]}") > /dev/null 2>&1; }

# ENSURE_TOOLS_ROOT=1/0 overrides the check (tests).
running_as_root() {
    case "${ENSURE_TOOLS_ROOT:-}" in 1) return 0 ;; 0) return 1 ;; esac
    [ "$(id -u)" -eq 0 ]
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; elif command -v sudo > /dev/null; then sudo "$@"; else return 1; fi
}

# Make tools installed under the home directory visible to this process.
refresh_path() {
    local dir
    for dir in /opt/homebrew/bin /home/linuxbrew/.linuxbrew/bin "$HOME/.cargo/bin" "$HOME/.local/share/vite-plus/bin" "$HOME/.vite-plus/bin" \
        "$HOME/.local/bin"; do
        case ":$PATH:" in *":$dir:"*) ;; *) [ ! -d "$dir" ] || PATH="$dir:$PATH" ;; esac
    done
    export PATH
}

run_script() {
    case "$1" in
        homebrew) NONINTERACTIVE=1 /bin/bash -c \
            "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" ;;
        oh-my-zsh) # KEEP_ZSHRC: .zshrc belongs to the dotfiles.
            RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c \
                "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended ;;
        starship) mkdir -p "$HOME/.local/bin"
            curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin" ;;
        viteplus) # Vite+ (`vp`): also provides node, npm, and pnpm shims. VP_NODE_MANAGER=yes skips its prompt.
            curl -fsSL https://vite.plus | VP_NODE_MANAGER=yes bash ;;
        rustup) curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path ;;
        gh-stack-rest) # gh-stack built to use REST only, for cloud sessions that refuse GraphQL.
            bash "$script_dir/gh-stack-rest/build.sh" ;;
        *) printf 'Unknown install script: %s\n' "$1" >&2; return 1 ;;
    esac
}

# Newest X.Y.Z tag (with or without a leading v) of OWNER/REPO, from git: the releases API
# is not reachable from every cloud session.
latest_tag() {
    git ls-remote --tags --refs "https://github.com/$1" | sed 's#.*refs/tags/##' |
        grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' |
        awk -F. '{ t = $0; sub(/^v/, "", $1); print $1 + 0, $2 + 0, $3 + 0, t }' |
        sort -k1,1n -k2,2n -k3,3n | tail -n 1 | cut -d' ' -f4
}

# gh-release:OWNER/REPO/ASSET for BINARY: download ASSET ({tag} and {v}, the tag without v,
# are filled in) from the newest release, unpack it, and install BINARY into ~/.local/bin.
install_release() {
    local repo="${1%/*}" asset="${1##*/}" bin="$2" tag dir status file
    tag="$(latest_tag "$repo")"
    [ -n "$tag" ] || { printf 'No X.Y.Z release tag in %s\n' "$repo" >&2; return 1; }
    asset="$(printf '%s' "$asset" | sed "s/{tag}/$tag/g; s/{v}/${tag#v}/g")"
    dir="$(mktemp -d)"
    # Chained with &&: ensure() calls this inside `if`, where errexit is off even in subshells.
    status=0
    curl -fsSL --retry 3 -o "$dir/$asset" "https://github.com/$repo/releases/download/$tag/$asset" &&
        mkdir "$dir/x" &&
        case "$asset" in *.zip) unzip -q "$dir/$asset" -d "$dir/x" ;; *) tar -xf "$dir/$asset" -C "$dir/x" ;; esac &&
        file="$(find "$dir/x" -type f -name "$bin" | head -n 1)" &&
        { [ -n "$file" ] || { printf '%s has no %s\n' "$asset" "$bin" >&2; false; }; } &&
        mkdir -p "$HOME/.local/bin" &&
        install -m 755 "$file" "$HOME/.local/bin/$bin" || status=1
    rm -rf "$dir"
    return "$status"
}

apt_updated=false
usable() {
    case "$1" in
        brew:*) command -v brew > /dev/null ;;
        apt:*) command -v apt-get > /dev/null && { [ "$(id -u)" -eq 0 ] || command -v sudo > /dev/null; } ;;
        vp:*) command -v vp > /dev/null ;;
        npm:*) command -v npm > /dev/null ;;
        cargo:*) command -v cargo > /dev/null ;;
        go:*) command -v go > /dev/null ;;
        gh-ext:*) command -v gh > /dev/null ;;
        # Release assets in tools.list are Linux x86_64 builds.
        gh-release:*) [ "$os" = linux ] && [ "$(uname -m)" = x86_64 ] && command -v curl > /dev/null && command -v git > /dev/null ;;
        script:*|manual:*) true ;;
        *) return 1 ;;
    esac
}

# install_with INSTALLER TOOL-INDEX
install_with() {
    local value="${1#*:}"
    case "$1" in
        brew:*) brew install "$value" ;;
        apt:*)
            if ! $apt_updated; then as_root apt-get update -qq; apt_updated=true; fi
            as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$value" ;;
        # From $HOME so a project's Node.js pin does not choose the runtime.
        vp:*) (cd "$HOME" && vp install --global "$value") ;;
        npm:*) npm install --global "$value" ;;
        cargo:*) cargo install --locked "$value" ;;
        go:*) mkdir -p "$HOME/.local/bin" && GOBIN="$HOME/.local/bin" go install "$value@latest" ;;
        gh-ext:*) gh extension install "$value" ;;
        gh-release:*) install_release "$value" "${checks[$2]%% *}" ;;
        script:*) run_script "$value" ;;
        manual:*) printf 'Install it manually: %s\n' "$value" >&2; return 1 ;;
    esac
}

# Split an installer field on spaces; `manual:` takes the rest of the field.
split_installers() {
    local rest="$1" word
    split=()
    while [ -n "$rest" ]; do
        rest="$(trim "$rest")"
        case "$rest" in
            manual:*) split+=("$rest"); return ;;
            *' '*) word="${rest%% *}"; rest="${rest#* }" ;;
            *) word="$rest"; rest="" ;;
        esac
        [ -z "$word" ] || split+=("$word")
    done
}

mode=install
case "${1:-}" in
    --check) mode=check; shift ;;
    --dry-run) mode=dry-run; shift ;;
esac
targets=()
if [ "${1:-}" = --all ] || { [ "$mode" = check ] && [ "$#" -eq 0 ]; }; then
    for ((i = 0; i < ${#names[@]}; i++)); do targets+=("${names[i]}"); done
    [ "${1:-}" != --all ] || shift
fi
targets+=("$@")
if [ "${#targets[@]}" -eq 0 ]; then
    sed -n '2,8s/^# \{0,1\}//p' "$0" >&2
    exit 2
fi

refresh_path
done_list=" " failed=0
ensure() {
    local name="$1" i installer need tried=""
    case "$done_list" in *" $name "*) return 0 ;; esac
    done_list="$done_list$name "
    if ! find_tool "$name"; then
        printf 'unknown  %s (not in %s)\n' "$name" "$list" >&2; failed=1; return 0
    fi
    i=$found
    case " ${oses[i]} " in
        *" darwin "*) [ "$os" = darwin ] || { printf 'skip     %s (darwin only)\n' "$name"; return 0; } ;;
        *" linux "*) [ "$os" = linux ] || { printf 'skip     %s (linux only)\n' "$name"; return 0; } ;;
    esac
    case " ${oses[i]} " in
        *" nonroot "*) if running_as_root; then printf 'skip     %s (not installed as root)\n' "$name"; return 0; fi ;;
    esac
    if present "$i"; then printf 'ok       %s\n' "$name"; return 0; fi
    if [ "$mode" = check ]; then printf 'missing  %s\n' "$name"; failed=1; return 0; fi
    local before="$failed"
    failed=0
    for need in ${needs[i]}; do ensure "$need"; done
    if [ "$failed" -ne 0 ]; then
        printf 'failed   %s: needs %s\n' "$name" "${needs[i]}" >&2
        return 0 # failed stays 1
    fi
    failed="$before"
    split_installers "${installers[i]}"
    for installer in ${split[@]+"${split[@]}"}; do
        usable "$installer" || continue
        if [ "$mode" = dry-run ]; then printf 'install  %s via %s\n' "$name" "$installer"; return 0; fi
        printf 'install  %s via %s\n' "$name" "$installer"
        tried=1
        if install_with "$installer" "$i" && { refresh_path; present "$i"; }; then
            printf 'ok       %s\n' "$name"; return 0
        fi
        printf 'failed   %s via %s\n' "$name" "$installer" >&2
        case "$installer" in manual:*) break ;; esac
    done
    [ -n "$tried" ] || printf 'failed   %s: no usable installer among: %s\n' "$name" "${installers[i]}" >&2
    failed=1
}
for target in "${targets[@]}"; do ensure "$target"; done
exit "$failed"
