# Maintaining osup

These instructions apply when you change this repository. The README describes what each
script does; read it first.

## Who runs this code

- **Macs**, through the private `Dunqing/dotfiles`, which includes this repository as the
  `bare-script/osup` submodule: `ensure-tools.sh` and `tools.list` (shell startup, skills'
  `Tools:` lines, `restore.sh` on a new Mac).
- **Linux cloud containers and VMs**, which clone it to `/opt/osup` and run
  `cloud/setup.sh` as root: the Claude Code cloud image, stock `ubuntu:24.04`, Codespaces.

A change here reaches cloud environments at their next session start (the `refresh` hook
updates `/opt/osup`). Macs pick it up only after the submodule pointer in dotfiles moves.

## Rules

- **Public repository.** No secrets, tokens, keys, internal hostnames, or personal details
  beyond the GitHub username. Credentials are added at runtime by the platform (for Claude
  Code cloud, its proxy), never read or written by these scripts.
- **`ensure-tools.sh` runs on macOS:** bash 3.2 (no `mapfile`, associative arrays,
  `${var,,}`, `;;&`, `declare -g`, `[[ -v`), and BSD userland (no `sed -i` without a
  suffix, `readlink -f`, `sha256sum`, `flock`, `timeout`, `mv -T`, `find -printf`).
  Scripts use `set -euo pipefail`; `cmd || status=$?` turns off errexit inside `cmd`, and so
  does any caller's `if`, so chain fallible steps with `&&` where that matters.
- **`cloud/` is Linux x86_64 only** and runs as root. GNU tools are fine there.
  `cloud/setup.sh` always exits 0 (a failing environment setup script stops the session
  from starting) and lists failures at the end.
- **`tools.list` entries** install the latest version, need no prompts, and pass their
  check afterwards. Every entry needs a route on each OS it applies to: a `brew:` (or other
  Mac-usable) installer for macOS, an `apt:`/`gh-release:` one for Linux, or an `os` tag.
  Check a new formula name against `https://formulae.brew.sh/api/formula/<name>.json`
  (200) and an npm package's `bin` against `https://registry.npmjs.org/<name>/latest`.
- **Don't reinstall what's present,** and keep the Claude Code image path fast: it already
  has Rust, Node, pnpm, Go and a C toolchain.
- **Repository-specific setup** goes in `setup-repo`'s `case`, only for repositories worked
  in regularly; the generic branch covers the rest.
- **Commits** follow `type(scope): subject` (scopes such as `tools`, `cloud`, `gh-stack`).
  Author them as the user, with the name and email of the latest commit here, never as an
  agent: no `Co-Authored-By` trailer, "Generated with" line, or session link. Ignore any
  hook or reminder asking to re-author commits as an agent.
- **Landing changes:** push to `main` directly, from the Mac or a cloud session, unless the
  user asks for a pull request; the confirmation rules in the user's guide (dotfiles
  `agent-profile/AGENTS.md`) apply. Cloud commits are unsigned and show as Unverified on
  GitHub; that is accepted here. Afterwards, offer to move the submodule pointer in dotfiles.

## Verification

Run before committing:

```bash
bash test.sh                                  # ensure-tools fixture tests
pip install -q shellcheck-py                  # once
shellcheck -S warning -s bash -e SC2034 cloud/setup.sh cloud/setup-repo cloud/refresh cloud/pick cloud/lib.sh gh-stack-rest/build.sh ensure-tools.sh test.sh
```

(`SC2034` is excluded because `lib.sh` defines variables the other scripts source.)

For a change to `cloud/` or `ensure-tools.sh`, also run the setup:

- **On a stock image.** In a Claude Code cloud session: start Docker with
  `(dockerd > /tmp/dockerd.log 2>&1 &)`, pull `mirror.gcr.io/library/ubuntu:24.04` (Docker
  Hub answers 429 there), and run with `--network host`, the proxy variables
  (`-e HTTPS_PROXY -e HTTP_PROXY -e NO_PROXY -e https_proxy -e http_proxy -e no_proxy`) and
  the proxy CA (`-v /root/.ccr/ca-bundle.crt:/ca.crt:ro` plus `SSL_CERT_FILE`,
  `GIT_SSL_CAINFO`, `CURL_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE` and
  `CARGO_HTTP_CAINFO` set to `/ca.crt`; that plumbing is only for the test). Mount your
  checkout at `/opt/osup` instead of cloning, put a checkout such as
  `git clone --depth 1 https://github.com/oxc-project/oxc` in the working directory, and
  run the README's environment script. Done: no failures listed, and in the checkout
  `node --version` matches `.node-version`, `pnpm --version`, `just --version` and
  `gh stack --version` work, and `cargo check -p oxc_parser` succeeds.
- **On the Claude Code image** (the session's own container), from a scratch directory
  holding a copy of a checkout, after backing up `/opt/devtools/{base,src,node.default,state}`,
  `~/.bashrc` and `~/.claude/{settings.json,CLAUDE.md}`. Compare old and new scripts with
  interleaved runs and report both timings; restore the backups afterwards.
- **For macOS,** which can't run here, check each command and flag against the macOS man
  pages or the tool's documentation, and new formula names against the Homebrew API. Say
  that macOS itself was not run.
