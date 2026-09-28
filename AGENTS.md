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
3. **Forcing Context into Claude Code:** If you need a specific document to automatically load into the agent's context for every session, the most robust architectural pattern is to create a symlink to it named `/workspace/CLAUDE.md`. (This is how `warp/AGENTS.md` is dynamically linked in `docker/start_script.sh`).
4. **Dynamic Container Startup:** Changes made to `docker/start_script.sh` take effect immediately on the next container boot without needing to rebuild the Podman image, as it acts as the persistent runtime entrypoint.