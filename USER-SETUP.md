# User Setup Guide

### Per-user setup (every user does this once)

Five steps. 1, 4 and 5 are one or two commands each; 2 and 3 are interactive
logins only you can do. Step 1 reprints steps 2-5 when it finishes using the same
numbering as this document, so you can follow either. Following these in order
should require no fixes afterwards — if it does, that is a bug in this document.

Step 1 also clones `warp` and `warp-tools` into your workspace, so step 5 opens
onto real code rather than an empty directory.

Everything of yours lives under `/mnt/sandbox/users/$USER/`: your env file,
workspace, state, Claude token and fiss-mcp venv. Nothing per-user goes in the
shared checkout, and none of it is in `$HOME` — home directories are on the small
boot disk, while the data disk is large and survives a VM rebuild.

```
/mnt/sandbox/users/<user>/          chmod 700
├── env.<user>.sh                   your config; the only place it lives
├── workspace/                      -> /workspace (rw); repos and loose files
├── context/                        -> /context (READ-ONLY); plans the agent cannot edit
├── state/                          per-instance hot state, .claude.json
├── shared/.claude/                 settings, hooks, plugins, YOUR Claude token
└── fiss-mcp/{venv,fiss-mcp}/       your own uv venv and pinned clone
```

**Logging in to the VM does not authenticate you to Google Cloud.** SSH used your
*SSH key* from project metadata, which has nothing to do with your Google
identity. Step 2 is required even though you got in "with GCP".

**0. SSH in — from your own laptop, not from the VM.** Substitute the real
instance name and zone; nothing sets `$VM`/`$ZONE` for you, and the zone is a
*zone*, not a region (`us-central1-c`, not `us-central1`).

```bash
gcloud compute ssh <instance-name> --zone <zone>
```

If you are already on the VM — the Cloud Console *SSH* button works fine — skip
this step. Running it from *inside* the VM fails with `Request had insufficient
authentication scopes`, which is [not about your access](FAQ.md#error-request-had-insufficient-authentication-scopes).

**1. Provision.** Creates your directories on the data disk, seeds your Claude
settings, clones `warp` and `warp-tools` into your workspace, writes your
`env.<USER>.sh`, and enables linger. Authenticates nothing.

```bash
cd /mnt/sandbox/repo        # wherever the admin put the shared checkout
./scripts/provision-sandbox-user.sh
```

**Run this before anything else podman-related.** It writes your
`~/.config/containers/storage.conf`, which is what makes the shared image store
visible to you; without it `podman images` looks empty and `podman run` tries to
pull from a registry.

The two repos are cloned over HTTPS and both are public, so this needs no
credentials — pushing does, which is step 3, and stays a host-side action. They are
full clones, not `--depth 1`, because the review-then-push workflow needs real
history. To change or skip that, set `CLAUDE_SANDBOX_SEED_REPOS` to a
space-separated list of clone URLs, or to the empty string.

**No root, and no sudo.** Everything it touches is your own home or your own
directory on the data disk. If a host-level prerequisite is missing it stops and
prints the exact command an admin should run. It also enables linger, without
which systemd tears down your user slice at logout and kills a long-running agent
mid-task.

**2. Google Cloud.** Both commands print a URL to open on your laptop;
`--no-launch-browser` because the VM is headless.

```bash
gcloud auth login --no-launch-browser
gcloud auth application-default login --no-launch-browser
```

The second one warns that it is "not necessary" on a GCE VM. **Answer `Y`** — that
advice is wrong here, because the VM's service account is a different identity
and is not what has access to your Terra workspaces. fiss-mcp needs *your*
credentials.

`CLAUDE_SANDBOX_GCP_PROJECT` is already set in your rendered `env.<USER>.sh`.
It is needed even though gcloud reports adding a quota project — a quota project
is [not a project source](FAQ.md#fiss-mcp-gcs-tools-fail-with-project-was-not-passed-and-could-not-be-determined-from-the-environment).

**3. GitHub** — to push from this host. Everyone needs this: pushing is what your
host account is *for*, since the agent cannot do it.

```bash
gh auth login --web
gh auth setup-git                              # REQUIRED, separate step
git config --get-all credential.helper         # must print: !/usr/bin/gh auth git-credential
```

(When prompted for device activation, open [https://github.com/login/device](https://github.com/login/device) on your laptop and paste the code.)

`gh auth login` gives *gh* a token; it does not necessarily configure *git*. Skip
`setup-git` and `git push` falls back to asking for a password, which GitHub no
longer accepts. Verify with the `credential.helper` line rather than finding out
at push time. Pushes touching `.github/workflows/` need
[one more scope](FAQ.md#push-rejected-for-a-githubworkflows-change).

This authenticates **you on the host**. The container carries no git credentials,
so `git push` from inside cannot succeed. Commit inside, push outside.

**4. Build your fiss-mcp venv.** Installs nothing system-wide; uv fetches its own
pinned Python 3.12 into your directory.

```bash
cd /mnt/sandbox/repo
source /mnt/sandbox/users/$USER/env.$USER.sh
./setup_host.sh
```

**All three in the same shell.** Sourcing your env file is what tells the installer
which directories are yours. Skip it and it aims at the shared checkout instead, then
[fails on an admin-owned git clone](FAQ.md#step-4-fails-dubious-ownership-in-host_fiss_mcpfiss-mcp).
`setup_host.sh` now stops and reprints these exact commands if you get it wrong.

**5. Launch.** Claude Code authenticates itself on the first run — you do not need
to type `/login`. It shows a login-method picker: choose the **first option**
(Claude account with subscription), and it prints a URL and a code. Open the URL on
your laptop, since the VM is headless, and paste the code there.

The token goes to your own state dir, so later launches start straight into a
session; the host's `~/.claude` is never mounted. `/login` still works if you ever
need to re-authenticate or switch accounts.

It is **once per account, not once per launch**, and in shared mode every instance on
the host reuses the same token. Where it lives, and how to carry one to another
account of your own instead of logging in again, is in
[the FAQ](FAQ.md#i-have-to-log-in-to-claude-every-time).

```bash
cd /mnt/sandbox/repo
source /mnt/sandbox/users/$USER/env.$USER.sh
./run_claude_docker.sh
```

Later sessions: `./run_claude_docker.sh --continue` for the most recent, or
`--resume <session-id>` for a specific one. To see what the previous ones *were*,
`./scripts/list-sessions.sh` lists them newest-first with the opening prompt of each,
and `--pick` turns that into an fzf picker with a conversation preview that resumes
what you choose.
Session IDs are per-sandbox and invisible to the host's `claude`.

**Long runs: launch inside `tmux`.** The container is `--rm -it`, so it dies with your
terminal — an SSH drop ends the run and removes the container. `tmux new -s claude`
first, `Ctrl-b d` to detach, `tmux attach -t claude` to come back. Transcripts survive
either way, so a dropped session can always be resumed; work the agent had in flight
cannot. Details in
[the FAQ](FAQ.md#my-ssh-dropped-how-do-i-reconnect-to-the-session).

Inside, `/workspace` already contains `warp` and `warp-tools` from step 1, so there
is nothing else to set up before the agent can do useful work.

### Adding files that are not repos

Two drop-in directories, both already mounted, no configuration:

```bash
cp plan.md  /mnt/sandbox/users/$USER/context/     # -> /context/plan.md, read-only
cp notes.md /mnt/sandbox/users/$USER/workspace/   # -> /workspace/notes.md, writable
```

Use `context/` for a plan or spec you do not want the agent rewriting — the mount is
`:ro`, so it cannot. Verified: both an append and a `touch` inside come back
`Read-only file system`.

**Permissions.** The agent runs as you, so anything you copy or upload yourself just
works. Exactly one combination fails, and it fails silently — a file owned by someone
else *and* not world-readable, which is what `sudo cp` of a private file leaves
behind:

| Owner on the host | Mode | Agent can read it |
|---|---|---|
| you | 644 or 600 | yes |
| someone else | 644 | yes |
| someone else | 600 | **no** |

```bash
ls -l /mnt/sandbox/users/$USER/context/     # owner should be you
chmod 644 /mnt/sandbox/users/$USER/context/*        # if you own them
sudo chown $USER:$USER /mnt/sandbox/users/$USER/context/*   # if you do not
```

Your `context/` also contains a `README.md` written at provisioning time that repeats
this, so it is discoverable from an SSH session.

**Uploading through the Cloud Console?** Its *Upload file* button has no destination
field: everything lands in your home directory, and `/home` is on the boot disk, which
the sandbox does not mount. So upload, then move it into one of the two directories
above — `mv ~/plan.md /mnt/sandbox/users/$USER/context/`.

Full set of routes, including bucket staging and `scp` over a tunnel, is in
[Getting files into the sandbox](CONFIG.md#getting-files-into-the-sandbox).

### Adding more repos

`workspace/` is bind-mounted as `/workspace`, so a clone is all it takes — no mount
configuration, read-write, and files the agent writes stay owned by you:

```bash
cd /mnt/sandbox/users/$USER/workspace
git clone https://github.com/your-org/your-repo
```

You push from the host side at
`/mnt/sandbox/users/$USER/workspace/<repo>`; see
[how pushing works](CONFIG.md#read-write-project-mounts-and-how-pushing-works).

### Installing packages: scvi-tools, worked example

The image already has `numpy`, `pandas`, `scipy`, `scikit-learn`, `matplotlib`,
`seaborn`, `ipython`, `jupyter`, `anndata` and **`scanpy`** (with `igraph` and
`leidenalg`, so clustering works), which covers a lot of single-cell work with no
installing at all.

Heavier, project-specific stacks go in a **venv under `/workspace`**, which is a
bind mount and therefore survives container exit — anything installed elsewhere in
the container is gone when it stops. `scvi-tools` is the case worth spelling out:

```bash
# inside the sandbox
cd /workspace/your-project
export UV_CACHE_DIR=/workspace/.uv-cache      # so re-installs do not re-download
uv venv .venv
uv pip install --torch-backend cpu scvi-tools
.venv/bin/python -c 'import scvi; print(scvi.__version__)'
```

Measured on this deployment: **39 seconds**, a **1.6 GB** venv, and `torch
2.13.0+cpu`. It survives into a fresh container, and `.venv` ends up owned by you on
the host.

**`--torch-backend cpu` is the part not to skip.** Without it you get 109 packages
including 15 `nvidia-*` CUDA wheels — several GB per user, for hardware neither the
shared VM nor most laptops here have. With it: 90 packages, **zero** CUDA wheels.

**If you actually need to train**, CPU wheels will not do, and the shared VM has no
GPU to give you. Adding one is an admin job and a VM rebuild, not a setting — the
E2 machine family cannot host a GPU at all. Procedure, quota status and the
per-user opt-in are in
[Attaching a GPU](SERVER.md#attaching-a-gpu). With a GPU present, install with
`--torch-backend auto` instead, which matches the wheel to the installed driver.

Add `.venv/` and `.uv-cache/` to the project's `.gitignore`. Pin what you install in
the project's own `pyproject.toml` or `requirements.txt` — the point of a per-project
venv is that two projects can disagree about versions.

Full detail, including why `sudo apt install` is not an option on the shared server,
is in [CONFIG.md](CONFIG.md#installing-packages).


### Updating an existing sandbox

Whenever the checkout gains new changes — newly seeded repos, a **plugin bump**
(caveman/ponytail), hook or settings fixes, a new fiss-mcp — refresh your sandbox
with the steps below. (If you also provisioned before the repo was renamed to
`warp-sandbox-podman` and the default branch moved to `main`, step 1 fixes that
too.)

1. **Update the shared checkout:** (Run this on the shared VM, not in the
   container. Only whoever owns `/mnt/sandbox/repo` can pull it; if that is an
   admin, they do this once for everyone.)
   ```bash
   cd /mnt/sandbox/repo
   git remote set-url origin https://github.com/broadinstitute/warp-sandbox-podman.git
   git fetch origin
   git branch -m podman-nobara main 2>/dev/null || true
   git branch -u origin/main main
   git pull
   ```
   If the image itself changed (anything under `docker/`), the admin also rebuilds
   the shared image — see [SERVER.md](SERVER.md#updating-the-image-later). That is
   separate from the per-user steps below.

2. **Re-provision — picks up new repos AND plugin/hook/settings updates.**
   Re-running the provisioner is safe and idempotent. It skips repos you already
   have and clones newly added ones (like `optimus_starsolo_multiome`), and it
   re-syncs the checkout's Claude config into your `shared/.claude`: vendored
   plugin bumps, hook fixes, skills, and `settings.json`. Your OAuth token and
   session history are left untouched.
   ```bash
   cd /mnt/sandbox/repo
   ./scripts/provision-sandbox-user.sh
   ```
   Run this from the host shell while you are **not** in a live sandbox session
   (including a detached `tmux` one). It wipes the rebuildable plugin cache so
   Claude Code re-resolves plugins at the new pins on your next launch, and a
   container running against that directory at the same moment can see a
   half-updated tree. Exit the sandbox first, re-provision, then relaunch — the
   new plugins are live on that next launch, with your session resumable via
   `--continue`.

3. **Rebuild the host fiss-mcp venv:**
   ```bash
   source /mnt/sandbox/users/$USER/env.$USER.sh
   ./setup_host.sh
   ```
