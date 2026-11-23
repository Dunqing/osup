# osup

Machine tooling shared by my Mac and cloud coding-agent containers. The private
dotfiles include this repository as a submodule; cloud environments clone it directly.

| Path | What it is |
| --- | --- |
| [`tools.list`](tools.list), [`ensure-tools.sh`](ensure-tools.sh) | Command-line tools (`name \| check \| installers \| needs \| os`) and their installer. |
| [`gh-stack-rest/`](gh-stack-rest) | A `gh stack` build that uses REST instead of GraphQL. |
| [`cloud/`](cloud) | Cloud container setup: `setup.sh`, plus the helpers it installs to `/opt/devtools`. |
| [`test.sh`](test.sh) | Fixture tests for `ensure-tools.sh`. |
| [`AGENTS.md`](AGENTS.md) | Rules and the test recipe for changing this repository. |

## Tools

`ensure-tools.sh` leaves present tools alone and installs a missing one with the first
usable installer listed for it, then runs its check again:

```bash
bash ensure-tools.sh --check          # report only; exit 1 if any is missing
bash ensure-tools.sh gh gh-stack      # install what is missing (and what it needs)
bash ensure-tools.sh --all            # a new machine
```

Installers: `brew:`, `apt:`, `npm:`, `vp:`, `cargo:`, `gh-ext:`, `gh-release:` (a
Linux x86_64 asset from the newest GitHub release, found with `git ls-remote`), `script:`
(a named installer in `ensure-tools.sh`) and `manual:`. A new entry must need no prompts,
install the latest version, and pass its check afterwards.

## gh stack without GraphQL

Claude Code cloud sessions refuse GitHub GraphQL, which `gh stack` uses to find, create and
update PRs. There `gh-stack` falls through to `script:gh-stack-rest`:
[`build.sh`](gh-stack-rest/build.sh) installs Go through `ensure-tools` if it is missing
(with `GOTOOLCHAIN=auto`, so an older distribution Go fetches the version gh-stack needs), clones
the latest gh-stack release,
[`apply.py`](gh-stack-rest/apply.py) points each GraphQL method at its REST version in
[`ccr_rest.go`](gh-stack-rest/ccr_rest.go) (ready-for-review and auto-merge use the proxy's
`/ccr/` routes), and the build is installed as a pinned extension reporting
`<version>-rest`. `apply.py` stops the build if a release adds a GraphQL method without a
REST version. REST has no merge-queue entry, so queued PRs aren't shown as queued, and
the merge wizard defaults to squash rather than the last-used method.

## Cloud environments

The environment's setup script clones this repository and runs the setup, as root, from
the directory holding the session's checkouts. The first line is for images without git,
such as a stock `ubuntu:24.04`:

```bash
#!/bin/bash
command -v git > /dev/null || { apt-get update -qq && apt-get install -y -qq git ca-certificates; }
S=/opt/osup
[ -d $S/.git ] || git clone -q --depth 1 https://github.com/Dunqing/osup $S ||
  { echo "setup: could not clone Dunqing/osup" >&2; exit 0; }
bash $S/cloud/setup.sh claude      # or codex, gemini
```

The setup needs root (it writes `/opt/devtools` and `/etc/profile.d` and installs with apt) on
Linux x86_64. It works on the Claude Code cloud image, which already has most tools, and on a
stock Ubuntu image, where it installs what is missing through `ensure-tools`: curl, python3,
xz, unzip, a C toolchain, rustup and Go (`BASE_TOOLS` in `lib.sh`); a repository's pinned Node
from `.node-version`, and pnpm when no image Node provides it.

[`cloud/setup.sh`](cloud/setup.sh) always exits 0 (a failing setup script stops the session
from starting) and lists failures at the end. It:

- copies [`lib.sh`](cloud/lib.sh), [`pick`](cloud/pick), [`setup-repo`](cloud/setup-repo),
  [`refresh`](cloud/refresh) and [`profile-guard`](cloud/profile-guard) to `/opt/devtools`, and links `pick` as `node`, `npm`,
  `npx`, `corepack` and `cargo-shear`, so each runs the version pinned by the nearest
  `.node-version` or `justfile` (installed on first use);
- installs the `BASE_TOOLS` that are missing and puts `~/.local/bin` and `~/.cargo/bin` on
  shells' `PATH` (`/etc/profile.d/osup.sh`, sourced from `~/.bashrc`);
- installs each checkout's pinned Rust toolchain and the `CLOUD_TOOLS` from `lib.sh`, then
  runs `setup-repo` for every checkout, the `gh-stack` build and, when a `dotfiles`
  checkout is present, its agent profile installer, in parallel (logs in `/tmp/setup-*.log`);
- for `claude`, adds `refresh` as a SessionStart hook and `profile-guard` as a PreToolUse
  hook (until the user's profile from `Dunqing/dotfiles` is installed, it refuses commits,
  pushes and pull request changes, and tells the session to attach it), turns off commit and PR attribution,
  adds three auto-mode rules (commits authored as the user; `--force-with-lease` pushes of the
  session's own non-default branches; attaching `Dunqing/dotfiles`, which `profile-guard` requires) and appends cloud notes to `~/.claude/CLAUDE.md`.

`setup-repo <checkout>` installs one checkout's pinned Node and cargo-shear, Rust toolchain
and dependencies (Oxc and Rolldown have their own steps), fetches crates, and gives a
shallow clone its default branch, `origin/HEAD` and a merge-base. It also sets
`commit.gpgsign false` in the checkout and its submodules (`setup.sh` and `refresh` do the
same for `dotfiles`, which gets no `setup-repo`): commits there are the user's, and the image's signing
key and Stop hook expect the agent's identity. Run it for a repository added mid-session.

The environment saves the container after setup; later sessions start from that snapshot
without running setup again. At each session start, `refresh` updates the clone in
`/opt/osup`, copies changed cloud scripts, merges the same `~/.claude/settings.json` entries
as `setup.sh` (so new auto-mode rules reach existing environments; a change to them applies
from the second session start after the push, since the first one still runs the old
`refresh`), installs missing cloud tools, and re-runs
`setup-repo` for a checkout whose pins, lockfiles, coverage-suite or submodule commits, or
`setup-repo` itself changed. A change pushed here reaches existing environments without
editing them.
