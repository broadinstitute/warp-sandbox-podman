# What is in the image, and the services around it

- [The image](#the-image)
- [In-container root: works locally, not on a shared store](#in-container-root-works-locally-not-on-a-shared-store)
- [fiss-mcp (Terra) — runs on the host](#fiss-mcp-terra--runs-on-the-host)
- [CodeGraph MCP — runs in the container](#codegraph-mcp--runs-in-the-container)
- [caveman and ponytail](#caveman-and-ponytail)
- [Antigravity CLI (agy): the second agent](#antigravity-cli-agy-the-second-agent)
- [Headroom proxy](#headroom-proxy)
- [Vertex AI mode (inherited, unverified)](#vertex-ai-mode-inherited-unverified)
- [Using it with agents other than Claude Code](#using-it-with-agents-other-than-claude-code)

## The image

Base `docker.io/library/node:24-slim`, ~9.8 GB built. Fully qualified base image
names are required: podman on RHEL-family hosts sets
`short-name-mode="enforcing"`, so a bare `node:22-slim` makes a non-interactive
build hang and then fail.

**Newest at every build:** Claude Code, agy, caveman and ponytail.
`scripts/resolve-latest.sh` looks up the newest release of each and the build
installs it, so a rebuild is how they update; the image records what it got, and
`sandbox status` shows it. Everything else below is pinned in the Dockerfile and
moved with `scripts/bump-versions.sh`.

- **Claude Code CLI** — `claude`, the newest npm release as of the build
  (`CLAUDE_CODE_VERSION` records which). The launcher sets `DISABLE_AUTOUPDATER=1`:
  on a shared store every user must run the same version, and a self-update would
  be lost at container exit anyway.
- **Antigravity CLI** — `agy`, Google's terminal agent, the newest release as of the
  build, checked against the sha512 in Google's manifest. See
  [its section](#antigravity-cli-agy-the-second-agent).
- **caveman and ponytail** — the sandbox's two plugins, in `/opt/sandbox/plugins`,
  the newest GitHub release of each as of the build. See
  [their section](#caveman-and-ponytail).
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

## Antigravity CLI (agy): the second agent

Google's terminal agent runs in the same image and the same sandbox as Claude
Code: `sandbox agy`, or `SANDBOX_AGENT=agy ./run_claude_docker.sh`. Only the agent
differs. `/workspace`, `/context`, the read-only and read-write mounts, the
resource limits and the host-side fiss-mcp are the same, so everything in the
isolation model holds unchanged. The two can run at once: the containers are named
`claude-sandbox-<instance>` and `claude-sandbox-<instance>-agy`.

### Newest at each build, fixed in between

`scripts/resolve-latest.sh` reads Google's release manifest, the same file the
official `install.sh` reads, and passes its version, URL and sha512 to the build,
which checks the sha512. Each rebuild therefore installs the newest release.

agy updates itself in the background, but only when it can write the directory its
binary is in. In the image that is `/usr/local/bin`, which the container user cannot
write, so the updater stands down. Measured:
`auto_updater.go: Directory /usr/local/bin is not fully accessible (readable: true,
writable: false), skipping update`. That is the job `DISABLE_AUTOUPDATER` does for
claude. Installed under `$HOME` instead, every user would drift to whatever was
current, and each release would drop a 270 MB binary into their persisted state.

### State, and why the two agents do not share it

| Host path | Container path | Holds |
|---|---|---|
| `<state>/.gemini/` | `/home/claude/.gemini` | settings, global rules, MCP config, conversations, the **sign-in token** |
| `<state>/.config/antigravity/` | `/home/claude/.config/antigravity` | plugin secrets |

`<state>` is `$CLAUDE_SANDBOX_SHARED` in shared mode (`users/<user>/shared/` on a
shared host), else `$CLAUDE_SANDBOX_HOME`. These are mounted **only** into agy
containers, and an agy container mounts none of Claude's state. Neither agent can
read the other's token.

### Sign-in

There is no keyring in the container (no D-Bus session), so agy keeps its token in a
file under `~/.gemini`. Measured: `Using file-based token storage because no D-Bus
session bus detected`. Being a file in the mounted state is what makes it survive
relaunches. The first run asks how to sign in and, with no browser available, prints
a URL to open on your laptop and waits for the code.

| Route | How | What the token can reach |
|---|---|---|
| Gemini API key | `GEMINI_API_KEY` in the env file | the Gemini API only |
| Personal Google account | sign-in prompt | Google Cloud as that person; nothing, for an account with no cloud access |
| Google Cloud project, e.g. a Broad account | "Use a Google Cloud project" at the prompt | **Google Cloud as that account**, including Terra buckets |

The last row is the one to understand. Antigravity's Google sign-in, like Gemini
CLI's, carries the `cloud-platform` OAuth scope, and the token sits where the agent
can read it. Signed in with a Broad identity, the agy container therefore holds a
Google Cloud credential: exactly what the rest of this design keeps out (no
`gcloud`, no ADC, Terra only through fiss-mcp). Users are steered to the first two
rows in [USER-SETUP.md](USER-SETUP.md#antigravity-sign-in).

`GEMINI_API_KEY` is forwarded with `-e GEMINI_API_KEY`, by name, so its value never
appears in the podman command line that `ps` shows other users. agy ignores the key
unless settings say `"modelProvider": "gemini"`, and refuses to start if they say so
without a key. start_script.sh therefore derives that setting from whether the key is
set.

**Deliberately not wired:** ADC sign-in (`AGY_ADC_AUTH`). It would need gcloud
application-default credentials inside the container.

### What start_script.sh does on every agy launch

- **Settings**: seeds `~/.gemini/antigravity-cli/settings.json` from
  `/opt/sandbox/agy/settings.json` (docker/agy/ in the repo), then merges the
  sandbox's entries into the user's file: deny `command(git push)`,
  `command(git remote add)` and `command(git remote set-url)`, and trust
  `/workspace`. A user's model, allow rules and other preferences are kept; the deny
  rules come back if deleted.
- **No permission prompts**: the merge also sets `"toolPermission": "always-proceed"`
  when the key is absent. That is agy's no-prompts mode, the one
  `--dangerously-skip-permissions` selects, and the counterpart of Claude's
  `bypassPermissions` here. The deny rules still apply under it (agy's changelog:
  "your explicit deny rules still apply"), and so does agy's built-in command
  denylist. A user who picks another Tool Permission in `/config` keeps it, since
  only a missing key is filled in. Plans in `/plan` mode still wait for review;
  that is the separate Artifact Review setting.
- **Rules**: `~/.gemini/GEMINI.md` links to `/opt/sandbox/agy/GEMINI.md`, the
  sandbox rules (the counterpart of `~/.claude/CLAUDE.md`), and
  `~/.gemini/AGENTS.md` links to `/workspace/warp/AGENTS.md`. agy reads both as
  global rules. A user's own regular file at either path is left alone.
- **caveman and ponytail**: written as always-on rules,
  `~/.gemini/config/rules/sandbox-caveman.md` and `sandbox-ponytail.md`. Each is the
  plugin's own text for agents without hooks (caveman's
  `src/rules/caveman-activate.md`, ponytail's `.agents/rules/ponytail.md`), read
  from the image's copy of the plugin, plus the `trigger: always_on` frontmatter
  without which agy silently drops a rule file. A release that moved its file is
  skipped with a warning. agy installs neither plugin and runs
  neither one's hooks, so the `/caveman` and `/ponytail` commands are Claude-only;
  "stop caveman", "stop ponytail" and "normal mode" work as plain requests. The
  caveman text is the short one (caveman's full ruleset, which Claude gets, is
  several times longer): kept simple on purpose, at some cost in how strictly agy
  sticks to it. If writing them fails, agy starts without them.
- **MCP**: `agy mcp add fiss-mcp <url>` and
  `agy mcp add codegraph codegraph serve --mcp`, through agy's CLI rather than by
  writing its config file, so a format change between releases cannot break them.
  `FISS_MCP=0` / `CODEGRAPH=0` remove them.
- **Skipped**: Headroom and the Vertex routing (Anthropic traffic only), the Claude
  plugins, and `~/.claude.json`.

### Limits

- No browser in the image, so agy's browser and Chrome DevTools features are
  unavailable.
- agy's own terminal sandbox (`--sandbox`) is redundant here, since the container is
  the boundary, and has not been tested inside it.
- Remote Control (`agy --remote-control`) relays through Google's service. It is
  not configured, and is off unless you start it.

## caveman and ponytail

Two third-party plugins, on for every user in both agents:
[caveman](https://github.com/JuliusBrussee/caveman) (short replies; it changes only
how the agent talks) and [ponytail](https://github.com/DietrichGebert/ponytail)
(the least code that works; it changes only what the agent builds). For users:
[USER-SETUP.md](USER-SETUP.md#caveman-and-ponytail).

**Where they come from.** Every image build downloads the newest GitHub release of
each into `/opt/sandbox/plugins/<name>`. `scripts/resolve-latest.sh` resolves the
release tag to its commit, and the Dockerfile fetches that commit. The image records
both as `CAVEMAN_VERSION` and `PONYTAIL_VERSION`, which `sandbox status` shows.

**How Claude loads them.** `start_script.sh` adds `--plugin-dir
/opt/sandbox/plugins/<name>` for each to the `claude` command line. Claude Code
lists them as session-only plugins (`caveman@inline`, `ponytail@inline`) and runs
their hooks as usual: each one's SessionStart hook switches its mode on (caveman's
only in interactive sessions: from 4.x it starts headless `claude -p` and SDK runs
off, since scripts parse that output), and ponytail's adds its band above the
prompt. Nothing is installed into a user's own
`~/.claude`, so nothing there can go stale or half-install. That is what went wrong
before 2026-11-18, when each user's Claude installed them from pinned marketplace
copies: on the AWS host that install silently did not happen
(`installed_plugins.json` stayed empty and neither plugin loaded). A `--plugin-dir`
plugin also overrides an installed marketplace plugin of the same name, so an older
user `settings.json` that still enables `caveman@caveman` does no harm.

**How agy gets them.** As always-on rules rather than plugins: see
[What start_script.sh does on every agy launch](#what-start_scriptsh-does-on-every-agy-launch).

**When a release misbehaves.** Hold it out of the next build with
`CAVEMAN_VERSION=<tag>` or `PONYTAIL_VERSION=<tag>`
([AWS.md](AWS.md#updating-the-image)). Plugin hooks run in every session as the
container user, where the user's Claude token is readable too, so look at what a
new major release's hooks do before rebuilding with it. caveman 4.1.0 and ponytail
5.3.3 were read before they first shipped here: their hooks make no network calls,
except ponytail's optional webhook, which is empty unless a user configures it.

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

[Antigravity](#antigravity-cli-agy-the-second-agent) is the worked example: the
pattern for any further agent is the same. The isolation is **agent-agnostic**. Nothing in the security model is
Claude-specific — it is all engine-level and holds for any process: rootless
podman user namespace, `--userns=keep-id`, explicit bind mounts as the only way in
or out, cgroup v2 ceilings, and no credentials in the image.

What is agent-specific is the tooling on top: the install, the MCP wiring
and settings in `docker/start_script.sh`, and the state directories the launcher
mounts. To add one: install it in the Dockerfile (pinned, or resolved newest like
Claude Code and agy in `scripts/resolve-latest.sh`; somewhere the container
user cannot write, if it self-updates), add a `SANDBOX_AGENT` value to the launcher
with its own state mounts and container-name suffix, add its setup and entrypoint
to `start_script.sh`, and a subcommand to `scripts/sandbox`. The mount layout for
`/workspace`, the resource limits and the fiss-mcp bridge need no changes.
