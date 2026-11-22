# Shared by the cloud scripts. setup.sh copies this directory's scripts to /opt/devtools,
# and the session-start hook (refresh) copies newer ones from the osup checkout.
# Linux x86_64 cloud containers only; sourced by bash.
OPT=/opt/devtools
BIN=$HOME/.local/bin
NPM=$OPT/node-system/bin/npm # the image's own npm, for global CLIs (not the pinned Node's)
export PATH="$BIN:$PATH"
# Machine tools from tools.list that every checkout uses. gh-stack is built separately (~25s).
CLOUD_TOOLS="just cargo-insta watchexec ast-grep"
CLOUD_SCRIPTS="lib.sh pick setup-repo refresh"

# et TOOL...: ensure-tools from the osup checkout; without one, installed tools still work.
et() {
    local d
    d=$(cat "$OPT/src" 2> /dev/null) && [ -f "$d/ensure-tools.sh" ] || return 0
    bash "$d/ensure-tools.sh" "$@"
}

# install_scripts DIR: copy the cloud scripts to /opt/devtools (rename, so a running copy is safe).
install_scripts() {
    local f
    for f in $CLOUD_SCRIPTS; do
        cp "$1/$f" "$OPT/.$f.new" && chmod 755 "$OPT/.$f.new" && mv -f "$OPT/.$f.new" "$OPT/$f" || return 1
    done
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
