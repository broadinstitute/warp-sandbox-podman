# What is in the image, and the services around it

- [The image](#the-image)
- [In-container root: works locally, not on a shared store](#in-container-root-works-locally-not-on-a-shared-store)
- [fiss-mcp (Terra) — runs on the host](#fiss-mcp-terra-runs-on-the-host)
- [CodeGraph MCP — runs in the container](#codegraph-mcp-runs-in-the-container)
- [Headroom proxy](#headroom-proxy)
- [Vertex AI mode (inherited, unverified)](#vertex-ai-mode-inherited-unverified)
- [Using it with agents other than Claude Code](#using-it-with-agents-other-than-claude-code)

## The image

Base `docker.io/library/node:22-slim`, ~9.0 GB built. Fully qualified base image
names are required: podman on RHEL-family hosts sets
`short-name-mode="enforcing"`, so a bare `node:22-slim` makes a non-interactive
build hang and then fail.

- **Claude Code CLI** — `claude`, pinned via `CLAUDE_CODE_VERSION`. The launcher
  sets `DISABLE_AUTOUPDATER=1`: on a shared store every user must run the same
  version, and a self-update would be lost at container exit anyway.
- **Python** — venv at `/opt/claude-venv`, on `PATH`, preloaded with `numpy`,
  `pandas`, `matplotlib`, `scipy`, `scikit-learn`, `seaborn`, `ipython`,
  `jupyter`, `requests`, `anndata` (with `h5py`), `scanpy[leiden]`
  (so `sc.tl.leiden` works out of the box), `headroom-ai[proxy]`.
  Heavier, project-specific stacks belong in a per-project venv instead — see
  [Installing packages](CONFIG.md#installing-packages).
- **Rust** — stable toolchain at `/usr/local/{cargo,rustup}`.
- **Java 17** — Eclipse Temurin JDK at `/opt/java/openjdk`, `JAVA_HOME` exported.
- **CodeGraph** — `codegraph` at `/usr/local/bin`, pinned via `CODEGRAPH_VERSION`.
  Self-contained bundle with its own Node runtime.
- **Dev tooling** — `git`, `curl`, `ripgrep`, `vim`, `jq`, `build-essential`.
- **Passwordless `sudo`** for the container's `claude` user (uid 1015) — on a
  standalone local install. It grants root *in the container's user namespace
  only*; that uid maps to the invoker's subuid range on the host, so it confers
  nothing outside. See
  [the isolation FAQ](FAQ.md#can-an-agent-reach-another-users-sandbox-on-a-shared-host).
  On a shared image store it does not work at all — next section.

### In-container root: works locally, not on a shared store

Measured on both, with the same image:

| | standalone local store | shared read-only store |
|---|---|---|
| owner of `/usr/bin/sudo` as seen inside | `0`, mode `4755` | `65534` (nobody) |
| `sudo -n id -u` | `0` | refuses to run |

The shared store is populated by **rootful** podman, so its files are owned by
*real* uid 0 on disk. A rootless consumer's user namespace does not map host uid 0
at all — `--userns=keep-id:uid=1015` maps only the invoker's own uid plus subuid
ranges — so root-owned image files appear as `65534`, and a setuid binary owned by
an unmapped uid cannot confer root. sudo notices and refuses:

```
sudo: /etc/sudo.conf is owned by uid 65534, should be 0
sudo: /usr/bin/sudo must be owned by uid 0 and have the setuid bit set
```

This is the same root cause as the `mount_program` requirement, and the same
trade-off seen from the other side. Normally rootless podman *chowns* image layers
into the consumer's namespace on first use, which is exactly what fails on a
read-only store (`error during chown: remove usr/bin/bzcat: permission denied`).
`fuse-overlayfs` lets the image run without that chown — at the cost of uid
fidelity for files owned by uids outside the map.

**What still works:** everything the sandbox actually does. Nothing in
`start_script.sh` or any hook needs root (`service postfix start` is already
tolerated to fail), and `claude`, the MCP servers, `uv pip install --python
/opt/claude-venv/...`, `cargo install` and all file work under `/workspace` are
unaffected.

**What is lost:** `sudo apt install` inside a shared-server sandbox. To add system
packages there, an admin bakes them into the image and rebuilds — which is the
right place for it anyway, since every user then gets the same environment.

**Read it as a security gain as well as a capability loss.** On the shared server
the agent cannot become root even inside its own namespace, so the
passwordless-sudo line in the Dockerfile is inert there.

If a user genuinely needs in-container root, the only way to get it is their own
per-user image store — an 9.0 GB copy each, and they would then be running an
image nobody else can verify. Not recommended.

### No pip, anywhere

All Python is managed by **uv**. The venv is built with `uv venv` against a
uv-pinned CPython 3.12 rather than the base image's python3, so a base-image bump
cannot silently move the interpreter under the scientific stack.

Removing pip took three attempts and is worth recording. Dropping the
`python3-pip`/`python3-venv` apt packages was not sufficient — `python3 -m venv`
still seeded a working pip into any new venv, so pip was one command away rather
than gone. What actually removes it is deleting `ensurepip`, and it has to be
deleted from **both** interpreters (Debian's `/usr/bin/python3` and uv's pinned
CPython). A check written as `python3 -m ensurepip` tests a different interpreter
at build time than at runtime, because `ENV PATH` puts the venv first only later;
the Dockerfile therefore asserts against both absolute paths.

### `/home/claude` is world-writable, on purpose

Upstream's `uid-fixup-entrypoint.sh` chowns `$HOME` at start-up as root. The
podman path never runs that branch — the container already starts unprivileged
under `--userns=keep-id`, where `gosu` cannot `setgroups(2)` without
`CAP_SETGID`. With a rootful-built shared store, `/home/claude` is owned by *real*
uid 1015, which is not in a consuming user's namespace map, so mode `755` denied
every write to `$HOME`. Baking it world-writable removes the dependency on uid
mapping entirely; the container is single-user, so it costs nothing.

`.msmtprc` is the deliberate exception, left at `600`: msmtp refuses a
world-readable config. It holds no secret (`auth off`) and only feeds the
email-notify hooks, which no-op unless `CLAUDE_NOTIFY_EMAIL` is set. If email
notification is ever wanted on a shared store, bind-mount an msmtprc from the host
rather than loosening that mode.

## fiss-mcp (Terra) — runs on the host

[fiss-mcp](https://github.com/broadinstitute/fiss-mcp) gives the agent Terra
tools. The launcher spawns it as a host-side HTTP MCP server before starting the
container and advertises the URL via `FISS_MCP_URL`; a trap on `EXIT INT TERM`
kills it afterwards. If the launcher is `kill -9`'d, reap the orphan with
`pkill -f run-server.py`. Log: `${SANDBOX_HOME}/.claude/host_fiss_mcp.log`.

**Why host-side.** The container never sees `gcloud`, `gsutil`,
`google-cloud-*` libs, `~/.config/gcloud`, or any service-account key. The agent's
only path to Terra/GCP is the tools the server exposes, and there is no
shell-level bypass.

```bash
./run_claude_docker.sh                            # on, read-only (default)
FISS_MCP=0 ./run_claude_docker.sh                 # off entirely
FISS_MCP_ALLOW_WRITES=1 ./run_claude_docker.sh    # WRITE MODE (loud banner)
```

### What write-mode gates

The two gates work by **different mechanisms**, and the difference matters if you
are reasoning about what the agent can reach:

| Tool | Gate | Mechanism when the gate is off |
|---|---|---|
| `submit_workflow`, `abort_submission`, `update_method_config`, `copy_method_config`, `upload_entities` | `FISS_MCP_ALLOW_WRITES=1` | **Registered and visible** in `tools/list`; each begins with `_check_write_access(ctx)` and raises `ToolError` — *"This server is running in read-only mode."* |
| `download_gcs_file` | `FISS_MCP_ALLOW_HOST_WRITES=1` | **Not registered at all** — removed with FastMCP's `remove_tool` at start-up |

Upstream's README implies read-only means the write tools are absent. It does not:
verified by calling `submit_workflow` and `abort_submission` with valid arguments
against this install, and both returned the read-only error rather than failing as
unknown tools. A runtime guard is a perfectly good control, but "the agent cannot
see the tool" and "the tool refuses to act" are different claims, and only the
second one is true here.

`download_gcs_file` gets the stronger treatment because it is the one tool that
writes to a **host** path chosen by the agent — a way out of the sandbox rather
than a Terra mutation. The server refuses to start if the removal fails, rather
than serving it unguarded.

All of them are additionally in the shipped `permissions.deny` list, which is the
only control that still applies under `bypassPermissions`. That is the layer that
makes the guarded-but-visible tools unreachable rather than merely unhelpful.

`FISS_MCP_ALLOW_WRITES=1` prints a red ASCII-art banner on the host **and** inside
the container (pre-rendered; no `figlet` dependency), because it lets the agent
submit workflows and spend money.

### Install and pinning

`setup_host.sh` runs `host_fiss_mcp/install.sh` once. It clones fiss-mcp and
builds a venv beside it — both gitignored, both inside your own tree, nothing
system-wide. The venv is pinned to Python 3.12 and built with `uv`, which
downloads that interpreter if the host lacks it: `terra-mcp` depends on `firecloud`
0.16.x, a legacy `setup.py` package that will not build on 3.13+ (which is what
both Debian trixie and Fedora 44 ship).

The installer pins a release tag **and** verifies the resolved commit SHA against a
recorded value, so a moved upstream tag aborts the install rather than silently
building something else. A marker file in the venv records the ref + SHA; bumping
either constant triggers a re-install on the next run.

### Auth

The server inherits the host's own gcloud credentials — no mount, no env
forwarding:

```bash
gcloud auth login                       # the Terra-registered identity
gcloud auth application-default login   # ADC, which FISS uses
```

`CLAUDE_SANDBOX_GCP_PROJECT` must also be set, and a quota project is not a
substitute — see [the FAQ](FAQ.md#fiss-mcp-gcs-tools-fail-with-project-was-not-passed-and-could-not-be-determined-from-the-environment).
On a GCE VM the metadata server would be picked up automatically, but Terra is
user-identity-based, so a workspace-registered Google account is generally
required.

### Networking

Each instance gets a deterministic port in `39000-39999`, hashed from the
instance name and the invoking uid so concurrent sandboxes and multiple users do
not collide; the launcher scans upward for a free port from there. Override with
`FISS_MCP_PORT`.

The server binds **`127.0.0.1`**, and the container reaches it through a pasta
port forward (`--network=pasta:-T,<port>`) which maps that port on the container's
loopback to the same port on the host's. Measured with a loopback-bound listener:

| Route | Result |
|---|---|
| pasta `-T <port>` | reachable |
| `host.containers.internal` | connection refused |
| `host.docker.internal:host-gateway` | connection refused |

Both names resolve to a non-loopback host address, so they cannot see a
loopback-bound listener. Widening the bind to reach them would put the listener on
an external interface. The forward keeps it strictly on loopback, which is tighter
than upstream's docker-bridge-gateway bind, not looser.
`--add-host=host.docker.internal:host-gateway` is still declared so the name
resolves, but it is not the transport.

## CodeGraph MCP — runs in the container

[CodeGraph](https://github.com/colbymchenry/codegraph) gives the agent a
pre-indexed tree-sitter code graph — `codegraph_search`, `codegraph_callers`,
`codegraph_callees`, `codegraph_impact`, `codegraph_explore`, `codegraph_node`,
`codegraph_files`, `codegraph_status` — instead of grep+Read chains. Maintainer
benchmarks claim ~58% fewer tool calls and ~16% cheaper turns (directional,
single-author).

```bash
./run_claude_docker.sh              # on (default)
CODEGRAPH=0 ./run_claude_docker.sh  # skip MCP registration this launch
```

`start_script.sh` registers `mcpServers.codegraph` in `~/.claude.json` on every
boot (idempotent jq patch). Claude Code spawns `codegraph serve --mcp` as a stdio
subprocess per session, so it dies with `claude` and leaves no daemon. An
in-process inotify watcher (2 s debounce) keeps the SQLite index live.

The index is built per workdir by the SessionStart hook
`claude-sandbox-shared/.claude/hooks/codegraph-init.sh`, which detach-spawns
`codegraph init -y` when `/workspace` is a git repo and
`/workspace/.codegraph/codegraph.db` is missing. The prompt does not block on it;
queries during the initial index return partial results. Later sessions reuse the
index, which lives in `/workspace/.codegraph/` and therefore persists across
container restarts — add `.codegraph/` to the repo's `.gitignore`. Skip indexing
for one workdir with `touch /workspace/.codegraph-disable`.

Cost: ~50 MB image bundle, ~80-150 MB RSS while a session is open, ~1-10 MB
SQLite per 100k LOC, CPU spike only on file change.

## Headroom proxy

[Headroom](https://github.com/chopratejas/headroom) is a local HTTP proxy that
compresses prompts, tool outputs and history before forwarding to the Claude API.
**Off by default.**

```bash
HEADROOM=1 ./run_claude_docker.sh                      # on
HEADROOM_PORT=9000 HEADROOM=1 ./run_claude_docker.sh   # custom port
```

When on, `start_script.sh` launches `headroom proxy` on `127.0.0.1:$HEADROOM_PORT`
(default 8787) and exports `ANTHROPIC_BASE_URL` so `claude` routes through it. It
applies AST-aware code compression, JSON-output stripping, prompt-cache prefix
alignment and recovery-on-demand for dropped messages, then forwards to
`api.anthropic.com` using the existing OAuth token. It dies with the container.
Stats: `curl http://127.0.0.1:8787/stats` from inside.

**Trust model, stated plainly:** the proxy reads every byte of every request —
that is how compression works — including the OAuth bearer header. It runs inside
the same container as `claude`, so it sees exactly what Claude already has and
opens no wider boundary, but it is third-party code in the request path. Leave
`HEADROOM` unset and traffic goes direct.

## Vertex AI mode (inherited, unverified)

Inherited from upstream and **not verified on this fork.** It is documented for
completeness; the parts of it that touch host networking still describe the Docker
bridge-gateway model, which the podman path replaced with a loopback bind plus a
pasta forward. Treat it as a starting point, not a supported configuration.

The design mirrors fiss-mcp: gcloud-shaped pieces stay on the host.
`vertex_proxy.py` accepts Anthropic-shape POST bodies, strips the incoming
Authorization header, signs with a fresh `gcloud auth print-access-token`, and
forwards to Vertex. `claude` does not run in Vertex SDK mode — Vertex's
`:rawPredict` accepts the Anthropic Messages body unchanged, so nothing translates
bodies at any hop.

```
claude (in container)
  └─ ANTHROPIC_BASE_URL = headroom (HEADROOM=1) or vertex_proxy (HEADROOM=0)
       └─ headroom, optional
            └─ ANTHROPIC_TARGET_API_URL = vertex_proxy
                 └─ vertex_proxy.py (host, mints the token)
                      └─ Vertex AI
```

```bash
cp SET_VERTEX_MODE.example.sh SET_VERTEX_MODE.sh
$EDITOR SET_VERTEX_MODE.sh     # ANTHROPIC_VERTEX_PROJECT_ID, CLOUD_ML_REGION
source SET_VERTEX_MODE.sh
./run_claude_docker.sh
```

`SET_VERTEX_MODE.sh` is gitignored. Return to subscription mode with
`source UNSET_VERTEX_MODE.sh` or a fresh shell. The mode is per-launch — `claude`
reads env at startup — and the launcher refuses to start if `gcloud` is missing or
`ANTHROPIC_VERTEX_PROJECT_ID`/`CLOUD_ML_REGION` are unset. Port is hashed into
`38000-38999`, disjoint from fiss-mcp's range; override with
`VERTEX_PROXY_PORT`. Log: `${SANDBOX_HOME}/.claude/host_vertex_proxy.log`.

fiss-mcp and Vertex are orthogonal: separate processes, port ranges and traps.

## Using it with agents other than Claude Code

The isolation is **agent-agnostic**. Nothing in the security model is
Claude-specific — it is all engine-level and holds for any process: rootless
podman user namespace, `--userns=keep-id`, explicit bind mounts as the only way in
or out, cgroup v2 ceilings, and no credentials in the image.

What *is* Claude-specific is the tooling on top: the pinned
`@anthropic-ai/claude-code` install, the MCP wiring and plugin-pin checks in
`docker/start_script.sh`, and the `.claude` state layout the launcher mounts. To
host a different agent, add its runtime to the Dockerfile and swap the final
`claude "$@"` in `start_script.sh` for that agent's entrypoint. The launcher, mount
layout, resource limits and the fiss-mcp bridge need no changes — they only care
that *something* runs in the container. Expect to add tools.
