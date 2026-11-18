<p align="center">
  <img src="assets/seal_sandbox.png" alt="warp-sandbox-podman" width="600">
</p>

# warp-sandbox-podman

A **rootless [podman](https://podman.io/)** sandbox for running coding agents,
**Claude Code** and Google's **Antigravity CLI** (`agy`), with filesystem isolation. The container sees a workspace directory you choose
and its own state — the host's home directory, `/etc`, other users, and
everything else stay invisible to the agent.

It carries no credentials. No ssh keys, no `~/.git-credentials`, no `gh`, no
cloud CLIs, no tokens. **The agent can commit; only you can push.** That is
enforced by there being nothing to authenticate with, not by policy.

The image is a batteries-included dev environment (Python via uv, Rust, Java 17,
Node) so `uv pip install` and `cargo install` work inside without a slow first
launch. (`sudo apt install` works on a standalone local install but **not** on the
shared server — see [in-container root](COMPONENTS.md#in-container-root-works-locally-not-on-a-shared-store).)

> A fork of [jonn-smith/claude-docker-sandbox](https://github.com/jonn-smith/claude-docker-sandbox),
> which is Docker-based. This fork is **podman-only** — see [Scope](#scope), and
> [FORK.md](FORK.md) for every change and why.

---

## Documentation

- **[USER-SETUP.md](USER-SETUP.md)** — **Start here for shared servers:** `sandbox setup`, then `sandbox claude` / `sandbox agy`; adding files/repos, installing packages
- **[AWS.md](AWS.md)** — Admin runbook for the AWS host: create, bootstrap, build, add users, update, rebuild
- **[CONFIG.md](CONFIG.md)** — Every environment variable, mounts, push workflow, persistence
- **[COMPONENTS.md](COMPONENTS.md)** — What is in the image, fiss-mcp, CodeGraph, Headroom
- **[SERVER.md](SERVER.md)** — Admin guide: VM setup, disk, users, image store, capacity, GPU
- **[FAQ.md](FAQ.md)** — Every error we hit, with the diagnosis that turned out to be right
- **[FORK.md](FORK.md)** — What changed from upstream, and the measurements behind each decision

---

## Two ways to run it

Pick one; they share the same image and launcher but differ in who provisions
what.

| | **A. Standalone local** | **B. Shared server** |
|---|---|---|
| Who | One person on their own machine | Several people on one Linux VM |
| Image | You build it | An admin builds one read-only copy everyone shares |
| State | Anywhere you like | `/mnt/sandbox/users/$USER/` on a data disk |
| Setup | [Local quick start](#a-standalone-local) — three commands | [`sandbox setup`](USER-SETUP.md#quick-start) — one guided command, no root |
| Admin work | none | [AWS.md](AWS.md) (scripted) or [SERVER.md](SERVER.md) (GCP), once |

Both need the same host prerequisites:

- **rootless podman ≥ 5.0** — for the `keep-id:uid=` userns syntax and the pasta
  network backend.
- **`pasta`** (Debian/Ubuntu: `passt`) — how the container reaches the host-side
  Terra MCP server.
- **`/etc/subuid` + `/etc/subgid` ranges** for your user, 65536 wide. Add with
  `sudo usermod --add-subuids 524288-589823 --add-subgids 524288-589823 $USER`.
  Accounts created by `useradd` get these automatically; OS Login accounts do
  **not** (see [SERVER.md](SERVER.md#ssh-access-and-firewall)).
- **`uv`** — all Python here is uv-managed and there is no pip anywhere.
- **cgroup v2 with the `memory` controller delegated**, if you want
  `CLAUDE_SANDBOX_MEMORY` to be enforced rather than silently ignored.

`./setup_host.sh` checks all of this and **installs nothing** — no packages, no
systemd units, and no writes outside the sandbox tree.

---

## A. Standalone local

```bash
# 1. Configure. Copy a template and edit the paths; env.*.sh is gitignored
#    apart from the tracked *.example.sh files.
cp env.podman.example.sh env.main.sh
$EDITOR env.main.sh
source env.main.sh

# 2. Check the host and build the host-side fiss-mcp venv. Installs nothing.
./setup_host.sh

# 3. Build the image: ~9.8 GB, minutes on a fast connection (4 on the AWS host).
cd docker && make && cd ..

# 4. Launch.
./run_claude_docker.sh
```

On first launch Claude Code asks you to pick a login method — choose the first
option (Claude account with subscription) and complete the URL-and-code prompt it
shows. No need to type `/login`. The OAuth token persists into that sandbox's own
state directory, so later launches go straight to a session. No host-side Claude
Code install is needed and the host's `~/.claude/` is never mounted.

Then give the agent something to work on — clone into the directory you set as
`CLAUDE_SANDBOX_PROJECTS_DIR`, which is already mounted as `/workspace`:

```bash
cd <your projects dir> && git clone https://github.com/your-org/your-repo
```

**Other ways to launch:**

```bash
./run_claude_docker.sh --continue                  # resume most recent session
./run_claude_docker.sh --resume <session-id>       # resume a specific one
./start_sandbox.sh                                 # fzf menu: instance, session, workdir
```

`start_sandbox.sh` needs `fzf`. It annotates sessions with the host workdir they
ran against, so two `main` sessions are distinguishable. For a second concurrent
sandbox, copy the env file and change `CLAUDE_SANDBOX_INSTANCE`; ports and state
dirs are derived from it.

Everything configurable is in [CONFIG.md](CONFIG.md).

---

## B. Shared server

One VM, one image, many users. Each user provisions themselves with **their own
account only** — no root, and no admin involvement after the machine exists.

The current host is an AWS EC2 instance, `warp-claude-sandbox-3` (`r6a.2xlarge`,
8 vCPU / 64 GiB, us-east-2), set up by scripts: [AWS.md](AWS.md). It replaces
the GCP VM `warp-claude-sandbox-2` that [SERVER.md](SERVER.md) describes; the same
Debian 13 host layout runs on either. Per admin action: one command to add a user.
Per user:

```bash
ssh <you>@<host>
sandbox setup          # GitHub, repos, Google, Terra venv; re-run any time
sandbox claude         # or: sandbox agy
```

Verified on Debian 13 with podman 5.4.2 and multiple users, on GCP and AWS. Debian
12 cannot host it (podman 4.3.1); see [Choosing the OS](SERVER.md#choosing-the-os).

For everything a user does, including files, repos and packages, see
**[USER-SETUP.md](USER-SETUP.md)**.

---

## What the isolation does and does not cover

**Covered.** An agent in the sandbox cannot read the host filesystem outside its
own mounts, cannot reach another user's directories on a shared host, cannot
obtain a cloud or git credential, and cannot start a process on the host. There is
no docker or podman socket, no `--privileged`, no added capabilities, no host PID
or network namespace. `sudo` inside grants root *in the container's user
namespace*, which maps to your subuid range and confers nothing outside it. Each
claim is verified by probe in
[the FAQ](FAQ.md#can-an-agent-reach-another-users-sandbox-on-a-shared-host).

**Deliberately not covered.**

- **Humans with `sudo` can read everyone's directories.** On the AWS host that is
  only the `admin` account; users get local accounts with no sudo. On a GCE VM
  every metadata-SSH-key user lands in `google-sudoers`. Accepted: co-users are
  trusted people. Agents are not, and they are what the boundary is for.
- **An Antigravity Google sign-in is a cloud credential.** Its token carries Google
  Cloud scope and lives in the agy container. Signed in with a Broad account, that
  agent could act on Google Cloud as the user. Use a Gemini API key or a personal
  account instead: [USER-SETUP.md](USER-SETUP.md#antigravity-sign-in).
  If you would rather your *own* agent sessions could not do that either, run them
  from a `useradd` account, which gets no `google-sudoers` and needs no sudo to run
  the sandbox — see
  [running agents as a sudo-less account](SERVER.md#logging-in-to-a-sudo-less-agent-account).
- **Review is the real control on what leaves the machine.** The agent cannot
  reach GitHub, but it can author something you then push — including CI workflow
  changes. `git diff origin/HEAD..HEAD` before pushing is the gate.
- **Local git history is unprotected.** Under `bypassPermissions` (Claude) and
  `always-proceed` (Antigravity), `git reset --hard` and friends work inside the
  mounted checkouts. Nothing leaves
  the machine, but unpushed work can be destroyed. [Deny rules close
  this](CONFIG.md#two-things-this-does-not-protect).
- **Network egress is unrestricted.** The agent can reach the Anthropic API, npm,
  PyPI, crates.io and the open internet. The goal is filesystem isolation, not a
  firewall. Combine with `--network none` or a restricted network if you need it.

## What you get beyond the isolation

- **Two agents, one sandbox.** [Claude Code](https://code.claude.com) and Google's
  [Antigravity CLI](https://antigravity.google) share the image, the mounts and the
  Terra tools. Each keeps its own state, and neither container can see the other's
  sign-in. Both are pinned, so every user runs the same versions.
  `scripts/bump-versions.sh` moves every pin at once:
  [COMPONENTS.md](COMPONENTS.md#antigravity-cli-agy-the-second-agent).
- **One command for users**: `sandbox setup | claude | agy | status | attach |
  update`. Agents run in tmux, so an SSH drop no longer ends a run.
- **[fiss-mcp](https://github.com/broadinstitute/fiss-mcp)** for Terra, running on
  the **host** rather than in the container — so the sandbox has no `gcloud`, no
  `gsutil` and no credentials, and the MCP tools are the only path to Terra/GCP.
  Read-only by default; the write tools are not registered at all unless you opt
  in.
- **[CodeGraph](https://github.com/colbymchenry/codegraph)** MCP: a pre-indexed
  tree-sitter code graph, so symbol and call-tree questions do not become
  grep+Read chains. Auto-indexes per workdir.
- **[Headroom](https://github.com/chopratejas/headroom)** prompt-compression proxy,
  off by default.
- **Two skill plugins, vendored** so a fresh clone needs no network round-trip and
  every user of a shared image runs identical versions:
  [caveman](https://github.com/JuliusBrussee/caveman) (prompt compression) and
  [ponytail](https://github.com/DietrichGebert/ponytail) (writes less code for the
  same result). Both on by default, both pinned by commit SHA and re-checked at
  container boot — see [PLUGIN_PINS.md](claude-sandbox-shared/.claude/PLUGIN_PINS.md).
  Antigravity gets each one's always-on rule text instead of the plugin.
- **Email notification** for prompts that outlive a threshold (default 120 s),
  off unless `CLAUDE_NOTIFY_EMAIL` is set.
- **Resource ceilings** — `--memory`, `--cpus`, `--shm-size`, enforced through
  cgroup v2.

Details and toggles: [COMPONENTS.md](COMPONENTS.md).

## Documentation

| Document | What is in it |
|---|---|
| [CONFIG.md](CONFIG.md) | Every environment variable, mount layouts, read-only/read-write mounts, the push workflow, installing packages, persistence |
| [COMPONENTS.md](COMPONENTS.md) | What is in the image, fiss-mcp, CodeGraph, Headroom, Vertex mode |
| [AWS.md](AWS.md) | The AWS host: scripted creation and bootstrap, users, updates, resizing, rebuilds, cost |
| [SERVER.md](SERVER.md) | Admin guide for the shared VM: disk, instance, users, image store, capacity, rebuilds (GCP specifics) |
| [FAQ.md](FAQ.md) | Every error we hit, with the diagnosis that turned out to be right |
| [FORK.md](FORK.md) | What changed from upstream, and the measurements behind each decision |

## Scope

**Supported:** rootless podman ≥ 5.0 on Linux, with pasta and cgroup v2.
Developed on Nobara 44 (Fedora 44 base) with podman 5.8.4 and deployed on Debian
13 (trixie) with podman 5.4.2. Nothing is distro-specific beyond package names —
what matters is the podman version, pasta, and subuid ranges. An
SELinux-enforcing host additionally needs `:z` on the bind mounts, which is not
handled yet.

**Not supported: Docker.** Upstream's Docker path still exists in the code — every
podman change is gated on `CLAUDE_SANDBOX_ENGINE` — but `podman` is the default,
nothing here is tested against Docker, and the Docker path depends on
[sysbox-runc](https://github.com/nestybox/sysbox), which has no podman equivalent.
Treat `CLAUDE_SANDBOX_ENGINE=docker` as inherited, unverified code. If you want
Docker, use upstream.

**Not supported: macOS.** Removed rather than left to rot: the macOS helper
installed Docker Desktop or OrbStack, which is a different engine, and every
`IS_DARWIN` branch is gone from the launcher. `./setup_host.sh` exits with a
pointer to upstream on a Darwin host. podman does run there via `podman machine`,
but `--userns=keep-id` mapping and pasta loopback forwarding behave differently
inside that VM, so claiming support would be a guess.

**Dropped on this path:**

| Upstream feature | Status | Why |
|---|---|---|
| sysbox-runc runtime | removed | Docker-only shim needing rootful `dockerd`. Rootless podman's user namespace already provides the isolation this depends on. |
| Docker-in-Docker | removed | Without sysbox a nested daemon cannot mount overlay2. `SANDBOX_HAS_DIND=0`. |
| host postfix / email relay | not set up | Only feeds the optional notify hooks, which no-op when `CLAUDE_NOTIFY_EMAIL` is unset. |
| GPU passthrough | opt-in, off | Rootless podman needs a CDI spec and `--device`, not `--gpus`. `CLAUDE_SANDBOX_GPU=1`. |

## License

[PolyForm Shield License 1.0.0](https://polyformproject.org/licenses/shield/1.0.0)
— see [LICENSE.md](LICENSE.md). Use, modify and redistribute freely for any
purpose **except** providing a product that competes with this software. Standard
fair-use rights are preserved.
