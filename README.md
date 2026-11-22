# osup

Machine tooling shared by my Mac and cloud coding-agent containers. The private
dotfiles include this repository as a submodule; cloud environments clone it directly.

| Path | What it is |
| --- | --- |
| [`tools.list`](tools.list), [`ensure-tools.sh`](ensure-tools.sh) | Command-line tools (`name \| check \| installers \| needs \| os`) and their installer. |
| [`gh-stack-rest/`](gh-stack-rest) | A `gh stack` build that uses REST instead of GraphQL. |
| [`cloud/`](cloud) | Cloud container setup: `setup.sh`, plus the helpers it installs to `/opt/devtools`. |
| [`test.sh`](test.sh) | Fixture tests for `ensure-tools.sh`. |

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
[`build.sh`](gh-stack-rest/build.sh) clones the latest gh-stack release,
[`apply.py`](gh-stack-rest/apply.py) points each GraphQL method at its REST version in
[`ccr_rest.go`](gh-stack-rest/ccr_rest.go) (ready-for-review and auto-merge use the proxy's
`/ccr/` routes), and the build is installed as a pinned extension reporting
`<version>-rest`. `apply.py` stops the build if a release adds a GraphQL method without a
REST version. REST has no merge-queue entry, so queued PRs aren't shown as queued, and
the merge wizard defaults to squash rather than the last-used method.

## Cloud environments

The environment's setup script clones this repository and runs the setup from the
directory holding the session's checkouts:

```bash
#!/bin/bash
S=/opt/osup
[ -d $S/.git ] || git clone -q --depth 1 https://github.com/Dunqing/osup $S ||
  { echo "setup: could not clone Dunqing/osup" >&2; exit 0; }
bash $S/cloud/setup.sh claude      # or codex, gemini
```

[`cloud/setup.sh`](cloud/setup.sh) always exits 0 (a failing setup script stops the session
from starting) and lists failures at the end. It:

- copies [`lib.sh`](cloud/lib.sh), [`pick`](cloud/pick), [`setup-repo`](cloud/setup-repo)
  and [`refresh`](cloud/refresh) to `/opt/devtools`, and links `pick` as `node`, `npm`,
  `npx`, `corepack` and `cargo-shear`, so each runs the version pinned by the nearest
  `.node-version` or `justfile` (installed on first use);
- installs each checkout's pinned Rust toolchain and the `CLOUD_TOOLS` from `lib.sh`, then
  runs `setup-repo` for every checkout, the `gh-stack` build and, when a `dotfiles`
  checkout is present, its agent profile installer, in parallel (logs in `/tmp/setup-*.log`);
- for `claude`, adds `refresh` as a SessionStart hook and appends cloud notes to
  `~/.claude/CLAUDE.md`.

`setup-repo <checkout>` installs one checkout's pinned Node and cargo-shear, Rust toolchain
and dependencies (Oxc and Rolldown have their own steps), fetches crates, and gives a
shallow clone its default branch, `origin/HEAD` and a merge-base. Run it for a repository
added mid-session.

The environment saves the container after setup; later sessions start from that snapshot
without running setup again. At each session start, `refresh` updates the clone in
`/opt/osup`, copies changed cloud scripts, installs missing cloud tools, and re-runs
`setup-repo` for a checkout whose pins, lockfiles, coverage-suite or submodule commits, or
`setup-repo` itself changed. A change pushed here reaches existing environments without
editing them.
