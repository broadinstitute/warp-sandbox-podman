# Sandbox instructions (Antigravity CLI)

You are running inside a rootless podman container on a shared sandbox host.
This file is the sandbox's global rules file for `agy`. It mirrors
`~/.claude/CLAUDE.md`, which gives Claude Code the same rules; keep the two in
step (claude-sandbox-shared/.claude/CLAUDE.md and docker/agy/GEMINI.md in the
warp-sandbox-podman repository).

## Where things are

- `/workspace` is the user's workspace, read-write. It holds their repositories
  (`warp`, `warp-tools`, ...) side by side; it is not itself a repository.
- `/context` holds plans and specs the user put there for you. It is mounted
  read-only. Read it; never try to change it.
- `/projects/plans`, when present, is shared with the other users of this host.
  Write there only what is meant for colleagues, and say so in your reply.
- `/read-only-reference/...`, when present, is shared reference material, read-only.

The primary agent instructions for this sandbox are `warp/AGENTS.md`. It is
linked into your global rules as `~/.gemini/AGENTS.md` whenever the warp checkout
exists. The other repositories' `AGENTS.md` files point there and carry their
own guidance; read the one for any repository you work in.

Never create a `CLAUDE.md` or `GEMINI.md` in `/workspace` itself or in any
repository that has an `AGENTS.md`. That `AGENTS.md` is the only place for agent
guidance there, so put changes in it instead.

## What this container can and cannot reach

- There are no git credentials here: no SSH keys, no token, no `gh`. You can
  commit; you cannot push. The user reviews and pushes from the host. Do not
  try to work around this.
- There are no Google Cloud credentials here: no `gcloud`, no `gsutil`. Terra and
  Google Cloud Storage are reachable only through the `fiss-mcp` tools, which are
  read-only unless the user launched with writes enabled.
- `codegraph` is available as an MCP server for symbol and call-graph questions.

## Autonomous operation mode

This sandbox is a disposable container designed for long unattended work. The
host operator has authorized you to proceed without confirmation on the actions
that a default policy would normally pause to check. Treat this file as durable,
scope-wide authorization.

### Authorized without asking

- Any file edit, creation, or deletion under `/workspace` and the home directory.
- Installing packages (uv, npm, cargo, go install, etc.), including ones with side
  effects on the container. There is no pip: use `uv pip` or a project venv.
- Starting, stopping, killing local processes; modifying local services.
- Running tests, builds, migrations, and codegen against local resources.
- Running git operations on local branches: commit, branch, reset, rebase, stash,
  clean. Use the configured git identity. NEVER `--no-verify`.
- Calling any MCP tool already configured in this session, including writes that
  have been enabled by the launch flags (fiss-mcp writes only with
  `FISS_MCP_ALLOW_WRITES=1`).
- Long-running jobs: leave them running and poll them; do not block on
  confirmation.
- Iterating on errors: diagnose, fix, retry. Do not stop to report each step
  unless you are fully blocked.

### Still require explicit instruction

These remain off-limits without a direct user message authorizing them:

- `git push`, force-push, or any write to a remote (GitHub, a GCS bucket, Terra
  workspace state, a container registry).
- Deleting or rewriting commits that have been pushed.
- Sending messages, posting comments on PRs or issues, opening PRs, sending email,
  or any other externally visible communication.
- Spending money on external compute beyond what the launch flags already permit
  (e.g. submitting Terra workflows while fiss-mcp writes are off).
- Disabling safety checks the host operator put in place (commit hooks, type
  checkers, lint gates).

When a task ends and the user is not online, do not idle: commit work in progress
on a branch, write a brief status note to a file the user will find, and stop.

## Audit log

Keep a persistent, append-only research journal as you work. The user may not be
watching in real time; the journal is how they audit what you did, why, and on
what evidence. Write for a reader who was not in the loop.

- Location: `/workspace/JOURNAL.md`, or `/workspace/JOURNAL/YYYY-MM-DD.md` when the
  `/workspace/JOURNAL/` directory exists. Never overwrite; always append.
- Log every meaningful step: a decision (and the alternative rejected), a
  hypothesis, an action with a non-obvious effect, an observation that changed
  the plan, a dead end. Routine single-file edits do not need an entry.
- Entry format:

  ```
  ## YYYY-MM-DDTHH:MM:SSZ  — <short title>

  **Context.** State of the project; the user-facing goal.
  **Decision / action.** What you did, with `path:line` references.
  **Why.** Engineering rationale, alternatives considered, constraints.
  **Evidence.** Commands run and outputs observed, commit SHAs, test results.
  **Outcome.** What changed; follow-ups created.
  ```

- Use UTC timestamps. Record failed experiments, dead ends, and reversals too; if
  new evidence overturns an earlier entry, add a new entry that references it
  rather than editing history.
- At the end of a long task, append a "Session summary" entry: what to read first,
  the two or three most important findings, open questions, blockers.
