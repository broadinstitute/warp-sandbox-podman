# Agent Directives: warp-sandbox-podman

Welcome to the `warp-sandbox-podman` repository. This repository defines the multi-user containerized sandbox environment for running agentic coding tools on WARP.

## Documentation Index

Before making architectural changes or helping a user debug, please read the relevant documentation:
- [README.md](README.md) — High-level overview and index.
- [USER-SETUP.md](USER-SETUP.md) — Per-user provisioning and update instructions.
- [SERVER.md](SERVER.md) — Admin guide for deploying and maintaining the underlying host VM.
- [CONFIG.md](CONFIG.md) — Configuration details for the sandbox environment.
- [COMPONENTS.md](COMPONENTS.md) — Architecture of the container, volume mounts, and initialization sequence.
- [FORK.md](FORK.md) — Rationale and differences if this was forked from an upstream repo.
- [FAQ.md](FAQ.md) — Common issues and troubleshooting.
- [claude-sandbox-shared/.claude/PLUGIN_PINS.md](claude-sandbox-shared/.claude/PLUGIN_PINS.md) — The strict procedure for bumping and vendoring 3rd-party Claude Code plugins.

## Operational Gotchas & Lessons Learned

When writing scripts or modifying the repository structure, observe these rules derived from past mistakes:

1. **Unattended Git Clones:** When writing bash scripts that execute `git clone` (like `scripts/provision-sandbox-user.sh`), **always prefix the command with `env GIT_TERMINAL_PROMPT=0`**. If a repository is private and credentials aren't cached, Git will hang indefinitely waiting for terminal input, which completely breaks automated server setups.
2. **Vendoring 3rd-Party Plugins (Scanner Triggers):** When vendoring upstream tools into `claude-sandbox-shared/.claude/plugins/marketplaces/`, you must explicitly delete their `tests/` and `benchmarks/` directories before committing. These directories frequently contain mock TLS certificates (`-----BEGIN PRIVATE KEY-----`) or fake AWS/GitHub tokens that trigger our repository's static security scanners and block PRs.
3. **Loading a document into every session:** Add an `@/absolute/path` import to `claude-sandbox-shared/.claude/CLAUDE.md` (the sandbox's user-level memory); that is how `warp/AGENTS.md` loads. User-level imports need no approval prompt, and a missing target is silently skipped, so one line serves every user whether or not they have that checkout. **Never create a `/workspace/CLAUDE.md`** (symlink or copy) or write files into `/workspace` from `docker/start_script.sh`: Claude Code reads AGENTS.md natively only in a project with no CLAUDE.md, so any CLAUDE.md there turns AGENTS.md loading off, and native loading covers only the working directory and its parents at startup, so `warp/AGENTS.md` (a subdirectory of `/workspace`) would otherwise load only on demand. Never have scripts modify files inside a user's repo checkouts.
4. **`docker/start_script.sh` is baked into the image:** The Dockerfile `COPY`s it to `/home/claude/start_script.sh`; it is not bind-mounted. Changes to it (and to anything else under `docker/`) take effect only after the image is rebuilt (`make -C docker build` locally, `sudo ./scripts/build-shared-image.sh` on the shared VM). What takes effect without a rebuild is `claude-sandbox-shared/.claude/` — bind-mounted directly on a local instance, and copied per user on the VM, where re-running `scripts/provision-sandbox-user.sh` refreshes it.
5. **Never commit the repo-root `.claude/settings.json`:** The top-level `.claude/` directory holds *developer-local* Claude Code config for working in this repo — it is not part of the shipped sandbox (that is `claude-sandbox-shared/.claude/`). Permission allowlists and any other local overrides belong in `.claude/settings.local.json`. Do not create or commit `.claude/settings.json`: Claude Code treats it as a shared project file and does **not** ignore it by default, so it will silently ride into a `git add`. Both filenames are excluded in `.gitignore` to make that impossible; do not remove those rules.
6. **Permission-rule path syntax:** In Claude Code permission rules, an absolute path needs a **double** leading slash — `Edit(//workspace/**/CLAUDE.md)`. A single leading slash (`Edit(/workspace/...)`) is resolved relative to the settings file's directory and silently matches nothing. File-writing tools (Write, Edit) are governed by `Edit(...)` rules; `Write(...)` path rules did not block the Write tool. Verified empirically against 2.1.283 in `acceptEdits` mode. Test any new rule rather than trusting that it looks right.
