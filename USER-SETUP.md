# User Setup Guide

Everything here is done as yourself, with no root and no sudo. On the shared server
it comes down to three commands: `ssh` in, `sandbox setup` once, then
`sandbox claude` or `sandbox agy`.

- [Quick start](#quick-start)
- [Everyday use](#everyday-use)
- [Antigravity sign-in: read this before your first `sandbox agy`](#antigravity-sign-in)
- [Per-user setup, step by step](#per-user-setup-step-by-step) (what `sandbox setup` does)
- [Adding files](#adding-files-that-are-not-repos), [repos](#adding-more-repos),
  [packages](#installing-packages-scvi-tools-worked-example)
- [Updating an existing sandbox](#updating-an-existing-sandbox)

## Quick start

**0. Get an account.** Send the admin your SSH **public** key (`~/.ssh/id_ed25519.pub`,
or the `~/.ssh/google_compute_engine.pub` you already use for GCP). They run one
command and send you the host address. On the AWS host that is
[`add-sandbox-user.sh`](AWS.md#adding-a-user); on a GCP host your key goes into
project metadata instead ([SERVER.md](SERVER.md#adding-a-user)).

**1. Log in**, from the Broad network or the Broad VPN:

```bash
ssh <you>@<host>
```

On the old GCP host it was `gcloud compute ssh <vm-username>@<instance> --zone <zone>
--tunnel-through-iap` instead; see [step 0 below](#0-ssh-in).

**2. Set up**, once:

```bash
sandbox setup
```

It walks through everything in order and asks before each login:

| | What | You do |
|---|---|---|
| 1 | GitHub, so you can push what the agent commits, and so the private seed repos clone | enter a one-time code at github.com/login/device on your laptop; then confirm a name and email for your commits |
| 2 | your directories, settings and env file; clones `warp`, `warp-tools` and the other seed repos into your workspace | nothing |
| 3 | Google Cloud, for the Terra tools: **one** browser sign-in covers both gcloud and the application-default credentials | open a URL on your laptop, sign in with your Terra Google account, paste the code back |
| 4 | your own venv for the Terra MCP server | nothing, about a minute |

Re-run it any time. It skips whatever is done, so it is also the repair command.
`sandbox setup --check` only reports.

**3. Start an agent:**

```bash
sandbox claude      # Claude Code
sandbox agy         # Antigravity CLI (Google's agent)
```

Each asks you to sign in the first time only:

* **Claude Code** shows a login-method picker. Choose the **first option** (Claude
  account with subscription). It prints a URL; open it on your laptop and paste the
  code back. No need to type `/login`.
* **Antigravity** prints a sign-in URL to open on your laptop and waits for the
  code. **[Read which account to use](#antigravity-sign-in) before you do this.**

Both tokens are stored in your own state directory on the data disk. Later
launches go straight in, and they survive a VM rebuild. Your workspace already holds
`warp` and the other repos, so there is nothing else to set up.

## Everyday use

```bash
sandbox claude                 # start Claude Code, or reattach to the one running
sandbox claude --continue      # resume your most recent session (any claude flags pass through)
sandbox agy                    # start Antigravity, or reattach
sandbox agy -c                 # continue the most recent agy conversation
sandbox status                 # logins, sign-ins, image versions, what is running
sandbox attach [claude|agy]    # back into a running agent after an SSH drop
sandbox sessions --pick        # browse past Claude sessions and resume one
sandbox update                 # after the admin updates the checkout (see below)
sandbox shell                  # bash inside the sandbox image, for poking around
```

**Agents run inside tmux, one session per agent.** If your SSH connection drops, the
agent keeps working. Log back in and run the same command, `sandbox claude`, to
reattach. Inside, `Ctrl-b d` detaches on purpose and leaves it running. Claude and
Antigravity can run at the same time, against the same workspace. Set
`SANDBOX_NO_TMUX=1` to run in the foreground instead.

**Commit inside, push outside.** The container holds no git credentials, so the
agent can commit but not push. Review and push from the host:

```bash
cd /mnt/sandbox/users/$USER/workspace/warp
git log --oneline origin/HEAD..HEAD     # what the agent added
git diff origin/HEAD..HEAD              # what it actually changed
git push origin HEAD
```

## Antigravity sign-in

Read this before your first `sandbox agy`. Which account you sign in with decides
what that agent could reach.

**Where the sign-in goes.** Claude's token is an Anthropic credential and reaches
nothing but Claude. Antigravity's Google sign-in is different: like Gemini CLI's,
its OAuth token carries Google's `cloud-platform` scope. The consent screen says so,
listing access to your Google Cloud data. That token is stored **inside the agy
container**, where the agent can read it. Signed in as your Broad Google account,
the one that has Terra and GCS access, an agent in that container could act on
Google Cloud as you. Keeping that kind of credential out of the container is what
this sandbox otherwise guarantees. The Claude container is unaffected: it never
mounts Antigravity's state, and the agy container never mounts Claude's.

So, in order of preference:

1. **A Gemini API key.** Grants only the Gemini API. Create one at
   [aistudio.google.com/apikey](https://aistudio.google.com/apikey) and put it in your
   env file, which only you can read:

   ```bash
   echo 'export GEMINI_API_KEY=<key>' >> /mnt/sandbox/users/$USER/env.$USER.sh
   ```

   The next `sandbox agy` uses it, with no sign-in at all. The launcher forwards it
   by name only, into agy containers only. Usage is billed to the key's project.
2. **A personal Google account** (free, Google AI Pro or Ultra) with no access to
   Broad cloud resources. The token's scope then reaches nothing that matters.
3. **Your Broad account, through a Google Cloud project** ("Use a Google Cloud
   project" at the sign-in prompt), only if you accept the exposure above.
   Workspace accounts such as `@broadinstitute.org` have no Antigravity plan of
   their own: Google's docs list personal plans, Gemini Enterprise, or a Cloud
   project as the ways in.

To switch, type `/logout` inside agy (it clears the saved sign-in), then launch
again. Adding or removing `GEMINI_API_KEY` takes effect on the next launch.

## Per-user setup, step by step

This is what `sandbox setup` automates, with the reasons. Following it by hand works
too. Each step is safe to repeat.

Everything of yours lives under `/mnt/sandbox/users/$USER/`: your env file,
workspace, state, both agents' tokens and the fiss-mcp venv. Nothing per-user goes
in the shared checkout, and none of it is in `$HOME`. Home directories are on the
small boot disk; the data disk is large and survives a VM rebuild.

```
/mnt/sandbox/users/<user>/          chmod 700
├── env.<user>.sh                   your config; the only place it lives
├── workspace/                      -> /workspace (rw); repos and loose files
├── context/                        -> /context (READ-ONLY); plans the agent cannot edit
├── state/                          per-instance hot state, .claude.json
├── shared/.claude/                 Claude settings, hooks, plugins, YOUR Claude token
├── shared/.gemini/                 Antigravity settings, conversations, YOUR agy token
└── fiss-mcp/{venv,fiss-mcp}/       your own uv venv and pinned clone
```

### 0. SSH in

From your own laptop, not from the VM. **AWS host:** `ssh <you>@<host>` from the
Broad network or VPN; the address comes from the admin.

**GCP host:** substitute the real instance name and zone; nothing sets `$VM`/`$ZONE`
for you, and the zone is a *zone*, not a region (`us-central1-c`, not `us-central1`).

```bash
gcloud compute ssh <vm-username>@<instance-name> --zone <zone> --tunnel-through-iap
```

`--tunnel-through-iap` is what makes this work off the Broad network: the VM's port
22 accepts only Broad IP ranges and Google's IAP range, so without it the connection
fails with `connect to host ... port 22: Connection timed out`. (It needs IAP tunnel
permission on the project; ask the admin if it is refused.) `<vm-username>@` matters
when your laptop username differs from your VM account (e.g. `cox` locally, `rcox`
on the VM). Without it gcloud uses the laptop name, and if that name has no key on
file it silently creates a new account; see [SERVER.md](SERVER.md#ssh-access-and-firewall).
Running it from *inside* the VM fails with `Request had insufficient authentication
scopes`, which is [not about your access](FAQ.md#error-request-had-insufficient-authentication-scopes).

**Logging in to the VM does not authenticate you to anything else.** SSH used your
*SSH key*, which has nothing to do with your Google or GitHub identity. Steps 1 and
3 are required even so.

### 1. GitHub

To push from this host. Everyone needs it: pushing is what your host account is
*for*, since the agent cannot do it. First, so that step 2 can clone the private
seed repos.

```bash
gh auth login --web
gh auth setup-git                              # REQUIRED, separate step
git config --get-all credential.helper         # must mention: gh auth git-credential
```

When prompted for device activation, open
[https://github.com/login/device](https://github.com/login/device) on your laptop and
enter the code. `gh auth login` gives *gh* a token; it does not necessarily configure
*git*. Skip `setup-git` and `git push` falls back to asking for a password, which
GitHub no longer accepts. Pushes touching `.github/workflows/` need
[one more scope](FAQ.md#push-rejected-for-a-githubworkflows-change).

Then a git identity, which the launcher forwards into the container so the agent's
commits are attributed to you (without it, `git commit` inside fails with "Author
identity unknown"):

```bash
git config --global user.name  "Your Name"
git config --global user.email "you@broadinstitute.org"
```

This authenticates **you on the host**. The container carries no git credentials, so
`git push` from inside cannot succeed. Commit inside, push outside.

### 2. Provision

Creates your directories on the data disk, seeds your Claude settings, clones the
seed repos into your workspace, writes your `env.<USER>.sh` and enables linger.
Authenticates nothing.

```bash
/mnt/sandbox/repo/scripts/provision-sandbox-user.sh
```

**Run this before anything else podman-related.** It writes your
`~/.config/containers/storage.conf`, which is what makes the shared image store
visible to you. Without it `podman images` looks empty and `podman run` tries to
pull from a registry.

The seed repos are `warp`, `warp-tools`, `optimus_starsolo_multiome` and
`warp-private`, cloned over HTTPS. The last two are **private**. They clone only
once step 1 is done; until then provisioning warns and skips them, and re-running
it clones whatever is missing. They are full clones, not `--depth 1`, because the
review-then-push workflow needs real history. To change the list, set
`CLAUDE_SANDBOX_SEED_REPOS` to space-separated clone URLs, or to the empty string.

**No root, and no sudo.** Everything it touches is your own home or your own
directory on the data disk. If a host-level prerequisite is missing it stops and
prints the exact command an admin should run. Linger matters: without it systemd
tears down your user slice at logout and kills a long-running agent mid-task.

### 3. Google Cloud

For the Terra tools only: fiss-mcp runs on the host, as you, on these credentials.
One command, one browser sign-in; `--update-adc` writes the application-default
credentials fiss-mcp uses from the same login:

```bash
gcloud auth login --update-adc --no-launch-browser
```

It prints a URL to open on your laptop (`--no-launch-browser`, because the VM is
headless). Use the Google account registered with Terra. On a GCE VM, a separate
`gcloud auth application-default login` warns that it is "not necessary". **Answer
`Y`**: the VM's service account is a different identity and is not what has access
to your Terra workspaces.

`CLAUDE_SANDBOX_GCP_PROJECT` is already set in your rendered `env.<USER>.sh`. It is
needed even though gcloud reports adding a quota project: a quota project is
[not a project source](FAQ.md#fiss-mcp-gcs-tools-fail-with-project-was-not-passed-and-could-not-be-determined-from-the-environment).

### 4. Build your fiss-mcp venv

Installs nothing system-wide; uv fetches its own pinned Python 3.12 into your
directory.

```bash
cd /mnt/sandbox/repo
source /mnt/sandbox/users/$USER/env.$USER.sh
./setup_host.sh
```

**All three in the same shell.** Sourcing your env file is what tells the installer
which directories are yours. Skip it and it aims at the shared checkout instead, then
[fails on an admin-owned git clone](FAQ.md#step-4-fails-dubious-ownership-in-host_fiss_mcpfiss-mcp).
`setup_host.sh` stops and reprints these exact commands if you get it wrong.

### 5. Launch

`sandbox claude` or `sandbox agy`, as in the [quick start](#quick-start). Without the
`sandbox` command, the launcher is:

```bash
cd /mnt/sandbox/repo
source /mnt/sandbox/users/$USER/env.$USER.sh
./run_claude_docker.sh                       # Claude Code
SANDBOX_AGENT=agy ./run_claude_docker.sh     # Antigravity
```

run inside `tmux` yourself: the container is `--rm -it`, so it dies with your
terminal. The Claude token is once per account, not once per launch, and every
instance of yours reuses it. Where it lives, and how to carry one to another account
of your own instead of logging in again, is in
[the FAQ](FAQ.md#i-have-to-log-in-to-claude-every-time). Session IDs are per-sandbox
and invisible to the host's `claude`; `sandbox sessions` lists them newest-first
with each one's opening prompt.

## Adding files that are not repos

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

## Adding more repos

`workspace/` is bind-mounted as `/workspace`, so a clone is all it takes — no mount
configuration, read-write, and files the agent writes stay owned by you:

```bash
cd /mnt/sandbox/users/$USER/workspace
git clone https://github.com/your-org/your-repo
```

You push from the host side at
`/mnt/sandbox/users/$USER/workspace/<repo>`; see
[how pushing works](CONFIG.md#read-write-project-mounts-and-how-pushing-works).

## Installing packages: scvi-tools, worked example

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
GPU to give you. Adding one is an admin job, not a setting: on AWS a change of
instance type ([AWS.md](AWS.md#changing-the-instance-type)), on GCP a VM rebuild,
since the E2 family cannot host a GPU at all. Driver steps and the per-user opt-in
are in [Attaching a GPU](SERVER.md#attaching-a-gpu). With a GPU present, install with
`--torch-backend auto` instead, which matches the wheel to the installed driver.

Add `.venv/` and `.uv-cache/` to the project's `.gitignore`. Pin what you install in
the project's own `pyproject.toml` or `requirements.txt` — the point of a per-project
venv is that two projects can disagree about versions.

Full detail, including why `sudo apt install` is not an option on the shared server,
is in [CONFIG.md](CONFIG.md#installing-packages).


## Updating an existing sandbox

When the admin updates the shared checkout (new seed repos, a plugin bump, hook or
settings fixes, a new fiss-mcp), refresh yours with **no sandbox running**:

```bash
sandbox update
```

It re-runs provisioning, which clones newly added repos and re-syncs the checkout's
Claude config into your `shared/.claude` (your token and history untouched), then
rebuilds the fiss-mcp venv if its pin moved. It refuses while a sandbox of yours is
running, because a plugin refresh under a live Claude session breaks it:
every prompt then fails with `Plugin directory does not exist`. If you already hit
that error, exit, `sandbox update`, relaunch with `sandbox claude --continue`.

A new **image** (newer Claude Code or agy) needs nothing from you. You get it on
your next launch after the admin rebuilds.

The manual equivalent, on an older checkout without `sandbox`:

```bash
cd /mnt/sandbox/repo
./scripts/provision-sandbox-user.sh
source /mnt/sandbox/users/$USER/env.$USER.sh
./setup_host.sh
```
