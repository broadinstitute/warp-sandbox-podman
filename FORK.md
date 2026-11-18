# Fork notes — rootless podman on Fedora/Nobara

Fork of [jonn-smith/claude-docker-sandbox](https://github.com/jonn-smith/claude-docker-sandbox)
(`upstream` remote), branch `main`, forked at upstream commit `b969b39`.

Upstream is Docker-only and assumes a Debian/Ubuntu host: `setup_host.sh` installs
Docker CE pinned to 28.x, sysbox-runc, and postfix via `apt`. This fork runs the same
sandbox under **rootless podman** with no Docker, no sysbox, and no MTA.

Every change is gated on `CLAUDE_SANDBOX_ENGINE`, so the Docker path is byte-for-byte
unchanged and upstream rebases stay tractable.

## Host it was built and verified on

| | |
|---|---|
| OS | Nobara 44 (Fedora 44 base), no `apt` |
| Engine | podman 5.8.4, rootless, netavark + pasta |
| Image store | `/mnt/data/containers/storage` |
| subuid/subgid | a 65536-wide range for the invoking user |
| SELinux | disabled (so no `:z`/`:Z` relabeling needed; an enforcing host will need it) |
| cgroups | v2, systemd, `memory` delegated to the user slice |
| Host uid/gid | 1000:1001 |
| Python | 3.14.6 system-wide — too new for fiss-mcp's deps |

## What changed and why

### 1. No sysbox-runc

Sysbox is a Docker-only OCI runtime shim: it needs `sysbox-mgr`/`sysbox-fs` daemons and
a rootful `dockerd`. There is no podman equivalent. Rootless podman's user namespace
already puts the host filesystem out of reach, which is the isolation property this
sandbox actually depends on — verified below.

### 2. UID mapping: `--userns=keep-id:uid=1015,gid=1015`

This is the crux of the port. Rootless podman maps the invoking user to *container root*
by default, so anything the agent wrote to `/workspace` would land on the host owned by a
subuid in the 524288+ range — unreadable by the invoking user. `keep-id:uid=1015` pins the
invoker onto the image's baked `claude` uid instead.

Measured mapping inside the container:

```
container 0..1014  -> subuid 1..1015     (so uid 0 is mapped: sudo still works)
container 1015     -> the invoking host uid
container 1016+    -> subuid 1016+
```

`HOST_UID`/`HOST_GID` are passed **empty** on this path, because the remap has already
happened by mapping rather than by `usermod`.

### 3. `uid-fixup-entrypoint.sh` — early exit when already unprivileged

The only change to a file that both engines share, and it fixes a hard failure rather
than a cosmetic one. Upstream's entrypoint ends with `exec gosu claude "$@"`. Under
`keep-id` the container starts as uid 1015 with no capabilities, and `gosu` calls
`setgroups(2)`, which needs `CAP_SETGID`:

```
error: failed switching to "claude": operation not permitted
```

That happens **even though the target uid equals the current uid**, so `gosu` cannot be
treated as a no-op. The entrypoint now execs the command directly when `id -u` is not 0.
Root-start (Docker) behaviour is untouched.

### 4. No Docker-in-Docker

`SANDBOX_HAS_DIND=0`; the DinD volume is neither created nor mounted. Plain runc cannot
mount overlay2 for a nested dockerd. `start_dockerd.sh` already self-skips on that flag,
so no change was needed there.

### 5. Host services over a pasta forward, not `host.docker.internal`

Upstream binds host fiss-mcp to the Docker bridge gateway and has the container reach it
at `host.docker.internal`. Neither works here. Measured against a loopback-bound listener
on this host:

| From container | Result |
|---|---|
| `--network=pasta:-T,<port>` → `127.0.0.1:<port>` | **reachable** |
| `host.containers.internal:<port>` | connection refused |
| `host.docker.internal:<port>` via `--add-host=...:host-gateway` | connection refused |

Both names resolve to a non-loopback host address and cannot see a listener bound to
`127.0.0.1`. Widening the bind to reach them would put the listener on an external
interface — exactly what upstream avoids with the bridge-gateway bind. So the fork keeps
the listener strictly on loopback and forwards the port into the container's netns. That
is **tighter** than the Docker path, not looser.

Note the syntax: `pasta:<opt>,<opt>` — a colon after the network name, commas between
option tokens. `--network=pasta,-T,39856` is silently wrong.

### 6. `fiss-mcp` venv pinned to Python 3.12 via uv

`terra-mcp` declares `requires-python >=3.10`, but depends on `firecloud` 0.16.x (legacy
`setup.py`) and its own classifiers stop at 3.12. This host's `python3` is 3.14.6, which
cannot build that tree. `host_fiss_mcp/install.sh` now prefers `uv venv --python 3.12`
(uv downloads the interpreter if absent) and falls back to `python3 -m venv` when uv is
missing, so the Debian path is unchanged. An `import terra_mcp.server` check was added so
a broken venv fails at install time rather than inside the launcher's 30-second readiness
wait.

### 7. Fully qualified base images

`node:22-slim` → `docker.io/library/node:22-slim` (same for `eclipse-temurin:17-jdk`).
Fedora's `/etc/containers/registries.conf` sets `short-name-mode = "enforcing"`, so a
bare short name makes podman stop and ask which registry to use, hanging a
non-interactive build. No-op for Docker.

### 8. `service postfix start` made non-fatal

`start_script.sh` runs as the unprivileged `claude` user, so starting postfix fails and
`set -e` would abort before `claude` ever runs. Mail is optional here (no MTA on this
host, `CLAUDE_NOTIFY_EMAIL` unset), so the failure is swallowed with a notice.

### 9. Resource ceilings

New `CLAUDE_SANDBOX_MEMORY` / `CLAUDE_SANDBOX_CPUS` → `--memory`/`--memory-swap`/`--cpus`.
Equal memory and memory-swap makes the ceiling real rather than a soft push into swap.
Enforcement is genuine here because cgroup v2 delegates `memory` to the user slice.

### 10. GPU is opt-in and off

Rootless podman needs a CDI spec (`nvidia-ctk cdi generate`) and `--device nvidia.com/gpu=all`
rather than `--gpus all`. Gated behind `CLAUDE_SANDBOX_GPU=1`, which warns and continues
without the GPU if no CDI spec exists.

### 11. `docker` CLI references parameterized

`run_claude_docker.sh`, `list_sandboxes.sh`, `scripts/sandbox_lib.sh` and
`start_sandbox.sh` all shelled out to a literal `docker`. On a host with no `docker`
binary the `docker ps` calls fail silently and every sandbox reports as not running.

## Authentication posture

No credential of any kind is baked into the image or mounted into the container.

- **Claude Code** — the container authenticates itself on first launch (it prompts for
  a login method; no `/login` needed) and writes the token to the sandbox state dir. The host's `~/.claude` is never mounted.
- **Terra/GCP** — fiss-mcp runs on the **host** and inherits host gcloud ADC. The image
  has no `gcloud`, no `gsutil`, no `google-cloud-*` libraries and no `~/.config/gcloud`
  mount (all verified below). The MCP endpoint is the only path from the sandbox to Terra.
- **`docker/msmtprc`** — audited: `auth off`, no passwords or tokens.
- **No** ssh keys, ssh-agent socket, or `.netrc` reach the container.
- All `gcloud auth` actions are left to the operator; `setup_host_podman.sh` only reports
  credential state and never mutates it.

### One correction to upstream's docs

Upstream's README implies `FISS_MCP_ALLOW_WRITES=0` means the write tools are not
registered. That is **not** how it works. All 21 tools stay registered and visible in
`tools/list`, including the 5 write tools. The block is a **runtime guard**: each write
tool begins with `_check_write_access(ctx)`, which raises `ToolError` when
`ALLOW_WRITES` is false. Verified by calling `submit_workflow` and `abort_submission`
with valid arguments against this install — both returned *"This server is running in
read-only mode."* All 5 write tools were confirmed to call the guard.

Practical consequence: the agent can see the write tools and may attempt one; it gets
refused rather than being unable to name it. Real protection, but a guard, not absence.

## Verification performed

Image `localhost/claude-sandbox:0.0.1`, 9.0 GB — 8951288750 bytes as
`podman image inspect` reports it (upstream README says ~3 GB).

| Gate | Result |
|---|---|
| Toolchain | `claude` 2.1.200, `codegraph` 0.9.9, `headroom` 0.24.0, `cargo`, `java`, `rg`, `jq` all present; numpy/pandas/scipy/sklearn/seaborn import |
| uid mapping | inside: `uid=1015(claude)`; a host file written from the container comes out owned by the invoking user |
| `sudo` | passwordless, reaches uid 0 |
| Isolation | the host home directory, the host data volume, `gcloud`, `gsutil`, `~/.config/gcloud`, `~/.ssh` and `google.auth` all unreachable; `/etc/subuid` and `/etc/passwd` are the container's own, with no host users |
| Ceilings | `memory.max` = 17179869184 (16 GiB), `memory.swap.max` = 0, `/dev/shm` = 2.0G |
| fiss-mcp | host server on `127.0.0.1:39856`, registered as HTTP, **`✔ Connected`** from inside the container via the pasta forward |
| codegraph | **`✔ Connected`** |
| DinD | cleanly skipped |
| Plugin pins | caveman + ponytail both vendored, informational |
| Host cleanup | fiss-mcp killed by the launcher's EXIT trap |

Not yet exercised: a live Terra API call. That needs application-default credentials,
which are absent on this host — run `gcloud auth application-default login`.

`bash -lc` hides `headroom`/`cargo`/`java`: a login shell re-sources `/etc/profile` and
discards the Dockerfile's `ENV PATH`. `start_script.sh` uses a non-login shell, so this
does not affect the sandbox — but it will confuse manual `podman exec` debugging.

## Layout

Code lives in this checkout; mutable sandbox data lives on the data volume.

```
<checkout>/                            # this fork
├── claude-sandbox-shared/.claude/     # shared settings, hooks, caveman + ponytail, OAuth token
├── host_fiss_mcp/{venv,fiss-mcp}/     # host-side Terra MCP (uv, python 3.12, tag 1.0.5)
├── context_reference/                 # -> /context
└── env.nobara.sh                      # this host's instance

/mnt/data/claude-sandbox/
├── workspace/                         # -> /workspace (rw). Provision per project.
└── state/main/                        # per-instance hot state + .claude.json
```

The fiss-mcp venv is **not relocatable** — uv bakes absolute paths into `pyvenv.cfg` and
`bin/` shebangs. If this checkout moves, `rm -rf host_fiss_mcp/venv` and re-run
`./setup_host.sh`.

## Usage

```bash
source env.nobara.sh
./setup_host.sh                  # verify-only; installs nothing, changes no system state
cd docker && make ENGINE=podman && cd ..
./run_claude_docker.sh           # first run walks you through login
```

`./start_sandbox.sh` (fzf menu) also works.

## Portability to a GCP VM

Dropping sysbox means no custom runtime on the VM — plain rootless podman.

- Sizing: container is capped at 16 GB, so `n2-standard-8` (8 vCPU / 32 GB) is
  comfortable; `e2-standard-4` (4 / 16) is the floor and leaves the host squeezed.
- VM prep: subuid/subgid for the user, `loginctl enable-linger`, cgroup v2 memory
  delegation, persistent disk for the data paths.
- fiss-mcp picks up the VM's default service account from the metadata server, so the
  no-credentials-in-container property holds end to end with no key files.
- If the VM has SELinux enforcing (RHEL-family images), bind mounts will need `:z`.

## Portability to AWS

Done, on 2026-11-18: [AWS.md](AWS.md). The same Debian 13 host, with three
differences that matter. There is no metadata-key account mechanism, so users get
local accounts (`scripts/add-sandbox-user.sh`, no sudo). The instance has no IAM
role. And an nftables rule closes the metadata service to non-root uids, because
pasta makes it reachable from rootless containers whatever the IMDSv2 hop limit.

## A second agent

Google's Antigravity CLI runs in the same image (`SANDBOX_AGENT=agy`); see
[COMPONENTS.md](COMPONENTS.md#antigravity-cli-agy-the-second-agent). Nothing in
the isolation model changed for it. What did need care: its self-updater (defeated
by installing it where the container user cannot write), its keyring (absent, so it
falls back to a token file in the mounted state), and keeping each agent's sign-in
out of the other's container.

## Not addressed

- **Base image CVEs** — the IDE scanner flags high-severity findings in the base
  images (`eclipse-temurin:17-jdk`, `node:24-slim`). Base images are re-pulled on a
  forced rebuild; they are not otherwise patched here.
- Vertex mode is wired for the pasta forward but untested here.
- Nested containers (podman-in-podman) — deliberately out of scope.

## Agent capability boundary (audited)

The sandbox exists so an agent can run unattended without being able to push to
GitHub or write to cloud storage. Those are the two hard requirements. This
section records what was audited, what was found, and what changed.

### GitHub: agents cannot push

Verified against the running image, not assumed:

| path | result |
|---|---|
| `~/.ssh` | absent |
| `SSH_AUTH_SOCK` | unset |
| `~/.git-credentials` | absent |
| `~/.netrc` | absent |
| `gh` binary | absent |
| `GH_TOKEN` / `GITHUB_TOKEN` | unset |
| `~/.config/gh` | absent |
| global `credential.helper` | none |
| `credential.helper` in each mounted repo | none |
| remote URLs in mounted repos | plain https, no embedded tokens |
| `git push --dry-run` from inside | `fatal: could not read Username` |

The host `~/.gitconfig` is deliberately never mounted, because it carries
`credential.helper = !gh auth git-credential`. Only `user.name` and `user.email`
are forwarded, so commits are attributed but unpushable.

`permissions.deny` also blocks `Bash(git push:*)`, `git remote set-url` and
`git remote add`. Redundant today — there is nothing to authenticate with — but
it makes the rule explicit rather than an accident of what happens not to be
installed, so adding `gh` to the image later cannot silently grant push access.
Deny rules are the only control that still applies in `bypassPermissions` mode,
which is how this sandbox runs.

### GCP: agents cannot write

Verified in the image: no `gcloud`, no `gsutil`, no `bq`, no `~/.config/gcloud`,
no `GOOGLE_APPLICATION_CREDENTIALS`, no `CLOUDSDK_*` variables, and neither
`google.auth` nor `google.cloud.storage` importable. The only route to Terra/GCP
is the host-side fiss-mcp server, reached over a loopback port forward.

**A real gap was found here and fixed.** `download_gcs_file` is classified
upstream as a read tool and therefore carries no `_check_write_access` guard, so
`FISS_MCP_ALLOW_WRITES=0` did not block it. But it takes an agent-supplied
`local_path` (documented as "Absolute local destination path"), calls
`os.makedirs(parent, exist_ok=True)` and then `blob.download_to_filename()` —
all host-side, as the invoking user. An agent could create directories and
overwrite files anywhere that user can write: shell rc files, git config, the ssh
directory, the checkout, another user's tree where permissions allowed. That is a
filesystem write primitive *outside* the sandbox, a stronger capability than the
bucket writes `FISS_MCP_ALLOW_WRITES` exists to gate.

All 21 tools were audited for `download_to_filename`, `os.makedirs` and
`open(..., "w")`. `download_gcs_file` is the only one that writes to the host, and
was the only write-capable tool that was ungated.

Two independent mitigations, because one of them is a config value someone could
flip:

1. `host_fiss_mcp/run-server.py` removes the tool at startup via
   `FastMCP.remove_tool`, unless `FISS_MCP_ALLOW_HOST_WRITES=1`. Verified over
   the wire: `tools/list` returns 20 rather than 21, and a direct call gets
   `Unknown tool: 'download_gcs_file'`. A removal failure is fatal — the server
   refuses to start rather than start weaker than advertised.
2. `permissions.deny` blocks `mcp__fiss-mcp__download_gcs_file` plus the five
   Terra write tools.

Agents needing file contents use `read_gcs_object`, which returns bytes over MCP
and writes nothing.

### Known residual: the GCE metadata server

On a GCE VM the container can route to `169.254.169.254` — pasta installs a
default route that carries link-local, confirmed with `ip route get` from inside a
container. An agent can therefore request the VM service account access token.

This does **not** breach the no-bucket-writes requirement: the attached service
account's storage scope is `devstorage.read_only`. But it is a cloud credential
the agent was never meant to hold, and the scope list also includes
`logging.write`, `monitoring.write` and `pubsub`.

Confirm on the VM, from inside a container:

    curl -s -H "Metadata-Flavor: Google" \
      http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token

The fix is to remove the credential rather than block the route, which a rootless
container cannot do without CAP_NET_ADMIN. Nothing in this design uses the VM
service account — every user authenticates with their own ADC — so detach it:

    # Run these from a machine that is NOT the VM -- a laptop, or Cloud Shell.
    # The stop severs your own SSH session, and anything after it in the same
    # shell never executes.
    #
    # --no-scopes is required alongside --no-service-account; gcloud rejects the
    # command without it.
    gcloud compute instances stop $VM --zone $ZONE
    gcloud compute instances set-service-account $VM --zone $ZONE \
        --no-service-account --no-scopes
    gcloud compute instances start $VM --zone $ZONE

    # The external IP is ephemeral and changes across stop/start unless
    # reserved. Reserve one first if people have it bookmarked:
    #   gcloud compute addresses create <name> --region <region>
    #
    # Detaching the service account also stops the OS Config / ops agents from
    # reporting, since they authenticate with it. Nothing in this sandbox uses
    # it, but patch-management and VM metrics dashboards will go quiet.

### Operational note: shared settings do not propagate to existing users

`provision-sandbox-user.sh` copies `claude-sandbox-shared/.claude` into each
user's own tree and leaves it alone on re-runs, so changes to `settings.json` —
including the deny rules above — do NOT reach users who were already
provisioned. After changing shared settings, each existing user needs:

    cp <checkout>/claude-sandbox-shared/.claude/settings.json \
       /mnt/sandbox/users/$USER/shared/.claude/settings.json
