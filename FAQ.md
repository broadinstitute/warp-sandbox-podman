# FAQ / troubleshooting

Every entry here is a failure that actually happened, with the diagnosis that
turned out to be right. Errors are quoted verbatim so they can be searched for.

Grouped by where you hit them:

- [Storage and images](#storage-and-images)
- [Inside the container](#inside-the-container)
- [Google Cloud and Terra](#google-cloud-and-terra)
- [GitHub and pushing](#github-and-pushing)
- [The shared VM](#the-shared-vm)
- [Resource limits](#resource-limits)

---

## Storage and images

### `podman images` is empty, and `podman run` tries to pull from a registry

You have not been provisioned yet. The shared image store becomes visible only
through `~/.config/containers/storage.conf`, which
`scripts/provision-sandbox-user.sh` writes — step 1 of
[Per-user setup](USER-SETUP.md). Run it
before anything else podman-related.

This is worth knowing because the symptom looks like the shared store is broken
or the image was never built, when in fact nothing is wrong with either.

### `Error: configure storage: open /mnt/sandbox/imagestore/overlay-images/images.json: permission denied`

Something ran a rootful podman command against the shared store and left the
metadata mode `0600`. `image prune` is the usual culprit. Fix, as an admin:

```bash
sudo chmod -R a+rX /mnt/sandbox/imagestore
```

Nothing is damaged — it is one permission bit. To avoid it, prune through the
script, which restores permissions in the same breath:

```bash
sudo ./scripts/build-shared-image.sh --prune
```

### `Error: OCI runtime attempted to invoke a command that was not found`

The image lists fine and only *running* it fails. Your `storage.conf` is missing
the `mount_program` line:

```toml
[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
```

The shared store is built by rootful podman, whose overlay layers carry
`trusted.overlay.*` xattrs. A rootless consumer mounts with `userxattr` and
cannot read those, so the container starts with an incomplete rootfs — some
binaries simply are not there. `fuse-overlayfs` handles ownership in userspace
and fixes it. Re-running `provision-sandbox-user.sh` repairs an incomplete
`storage.conf`.

### `Error: creating container storage: error during chown: remove usr/bin/bzcat: permission denied`

Same root cause as the entry above, showing up at a different stage: podman is
trying to copy the rootful-built layers into your own store rather than read them
in place. Fix the same way.

### Do I need to rebuild the image after pulling the repo?

Only if `docker/` changed, and only an admin can do it on a shared host. `git
pull` alone changes nothing about the image — the store still holds the old
layers. See [Updating the image](SERVER.md#updating-the-image-later).

---

## Inside the container

### Claude is not following `warp/AGENTS.md`, or `agents-md: WARNING — /workspace/CLAUDE.md exists`

`warp/AGENTS.md` is loaded by an `@/workspace/warp/AGENTS.md` import in the
sandbox's `~/.claude/CLAUDE.md` (from `claude-sandbox-shared/.claude/CLAUDE.md`),
so it sits at the top of every session and nothing is written into `/workspace`.
Check inside the sandbox with `/context`: its memory-files list should include
`/workspace/warp/AGENTS.md`. If it does not, your `shared/.claude` predates the
import — re-run `./scripts/provision-sandbox-user.sh`, which refreshes it.

A `CLAUDE.md` at the top of your workspace is a copy of AGENTS.md (or `/init`
output) made by a person or an agent. It is not needed, it duplicates the imported
file, and it silently goes stale, so the container warns about it at boot rather
than deleting it. Read it, move anything worth keeping into the relevant repo's
`AGENTS.md`, then remove it on the host:

```bash
rm /mnt/sandbox/users/$USER/workspace/CLAUDE.md
```

Why not a `/workspace/CLAUDE.md` symlink, as this sandbox used to do: Claude Code
reads AGENTS.md natively only in a project with no CLAUDE.md, and at startup only
from the working directory and its parents. `warp/` is a *subdirectory* of
`/workspace`, so its AGENTS.md otherwise loads only once Claude happens to read a
file under `warp/`; and any CLAUDE.md in `/workspace` switches AGENTS.md loading
off entirely. The user-level import avoids both.

`git status` in `workspace/warp` shows `AGENTS.md` modified, ending in an
`## Other Repositories` section: an older start script appended that on every
boot. The current image reverts it on first boot when it is the only change to the
file. If you had also edited AGENTS.md, delete that trailing section by hand.

### `Permission denied` writing to `/home/claude` (hooks fail, `/workspace` is fine)

```
/home/claude/.claude/hooks/record-task-start.sh: line 21:
/home/claude/claude_task_start_warp: Permission denied
```

You are on a **stale shared image**. `/home/claude` used to be mode `755` owned
by uid 1015, relying on the entrypoint to `chown` it at start-up — which the
podman path skips, because the container already starts unprivileged. That was
invisible with a per-user rootless store, where on-disk layer uids and the
runtime user namespace agree. On the shared store, built by *rootful* podman,
`/home/claude` is owned by *real* uid 1015, which is not in your namespace map;
it reads as unmapped and `755` refuses the write. `/workspace` keeps working
because it is a bind mount carrying host ownership, which is what makes the
symptom look account-specific.

Check which image you have:

```bash
podman run --rm localhost/claude-sandbox:0.0.1 stat -c '%a %n' /home/claude
# 777 → fixed.   755 → stale, ask an admin to rebuild.
```

The Dockerfile bakes `/home/claude` world-writable, so the fix is an admin
rebuild; users only need to relaunch.

### `Can't auto-update: npm global folder isn't writable`

Expected, and harmless. Claude Code is pinned in the image
(`CLAUDE_CODE_VERSION`) so that every user of a shared store runs the same
version, and the launcher sets `DISABLE_AUTOUPDATER=1`. To move versions, bump
that variable and rebuild — an in-place self-update would make the image
non-reproducible and would be lost on the next container exit anyway.

### My SSH dropped: how do I reconnect to the session?

You do not reattach; you resume. The launcher runs `podman run --rm -it`, so the
container is tied to your terminal **and** deleted on exit: losing SSH destroys the
TTY, `claude` takes SIGHUP, and the container is removed. `podman ps` will show
nothing.

The *conversation* survives, though — transcripts are on the data disk under
`$CLAUDE_SANDBOX_HOME/.claude/projects/-workspace/<uuid>.jsonl`. Relaunch and pick up
where you left off:

```bash
cd /mnt/sandbox/repo
source /mnt/sandbox/users/$USER/env.$USER.sh

./run_claude_docker.sh --continue            # most recent conversation
./run_claude_docker.sh --resume <uuid>       # a specific one
./start_sandbox.sh                           # fzf picker over your sessions
```

**To see what your previous sessions were about** — a directory of uuids tells you
nothing — list them with the first prompt of each:

```bash
./scripts/list-sessions.sh          # newest first, with the resume command for each
./scripts/list-sessions.sh --pick   # fzf picker with a conversation preview, then resumes
```

```
WHEN               MSGS   SIZE  FIRST PROMPT
2026-08-06 12:35   1880   4.5M  test that you can use mcp to reach this terra submission
                                resume: ./run_claude_docker.sh --resume 08e622fe-...
2026-08-05 14:54     34   119K  describe the warp repo and agents.md in one short paragraph
                                resume: ./run_claude_docker.sh --resume 857ec2f8-...
```

Or read the directory directly — the filenames *are* the session ids:

```bash
ls -lt "$CLAUDE_SANDBOX_HOME/.claude/projects/-workspace/"*.jsonl | head
```

**Work in progress is a different matter.** Files the agent had already written to
`/workspace` are on the host and intact — that is a bind mount. Anything it held only
in memory, plus whatever it was part-way through, is gone. Uncommitted edits it made
are still there; a command it was running died with the container.

### Stop it happening: run inside tmux

The container dies with the terminal, so put the terminal somewhere that outlives your
connection:

```bash
sudo apt-get install -y tmux        # once, if the admin has not
tmux new -s claude                  # then launch the sandbox inside it
# detach: Ctrl-b d       reattach later: tmux attach -t claude
```

`loginctl enable-linger` (done by provisioning) is what lets that tmux session keep
running after you log out — without it systemd tears down your user slice and takes
tmux with it. This is worth doing for anything long: a dropped laptop lid should not
kill a 40-minute run.

### I have to log in to Claude every time

You should log in **once per state directory**, not once per launch. The token is
written to `.credentials.json` inside whichever `.claude` the launcher mounts:

| layout | token path |
|---|---|
| shared (`CLAUDE_SANDBOX_USE_SHARED=1`, every template) | `$CLAUDE_SANDBOX_SHARED/.claude/.credentials.json` |
| per-instance | `$CLAUDE_SANDBOX_HOME/.claude/.credentials.json` |

In shared mode every instance on the host reads the same file, so a second or third
sandbox does **not** mean a second login. On the shared VM that path is under
`users/$USER/shared/`, which lives on the data disk and therefore survives VM
rebuilds too.

**If it really is every launch, the token cannot be written back.** Claude Code
*refreshes* the credential in place — measured: after one `claude -p` call the file's
mtime and contents both changed. A read-only or wrong-owner file authenticates once
and then cannot be updated, and the next launch prompts again. Check:

```bash
source /mnt/sandbox/users/$USER/env.$USER.sh
ls -l "$CLAUDE_SANDBOX_SHARED/.claude/.credentials.json"
# mode must be 600 and owner must be YOU; mtime should move after each session
```

If the mtime never advances, fix the ownership rather than logging in again:

```bash
chown "$USER:$USER" "$CLAUDE_SANDBOX_SHARED/.claude/.credentials.json"
chmod 600 "$CLAUDE_SANDBOX_SHARED/.claude/.credentials.json"
```

**To skip the login on a new account or a fresh instance of your own**, copy the
token in — verified to work, with no prompt:

```bash
install -m 600 -o "$NEW" -g "$NEW" \
  /mnt/sandbox/users/$USER/shared/.claude/.credentials.json \
  /mnt/sandbox/users/$NEW/shared/.claude/.credentials.json
```

**Only do that between accounts belonging to you.** That file *is* your Claude
identity: whoever holds it can use your subscription, and usage is attributed to
you. Other people should run their own `/login` — which is also why the per-user
directories are `700`.

### `sudo` fails inside the container on the shared server

```
sudo: /etc/sudo.conf is owned by uid 65534, should be 0
sudo: /usr/bin/sudo must be owned by uid 0 and have the setuid bit set
```

Expected on a shared image store, and not fixable there. The store is built by
rootful podman, so its files are owned by *real* uid 0, which a rootless
consumer's namespace does not map — they appear as `65534`, and a setuid binary
owned by an unmapped uid cannot confer root.

Nothing the sandbox does needs root, so `claude`, the MCP servers, `uv pip
install`, `cargo install` and all work under `/workspace` are unaffected. What you
lose is `sudo apt install` inside the container: to add system packages on a shared
host, an admin bakes them into the image and rebuilds. Full explanation and the
measurements in
[COMPONENTS.md](COMPONENTS.md#in-container-root-works-locally-not-on-a-shared-store).

It works normally on a standalone local install, where the store is yours and the
uids line up.

### `gosu: initgroups(claude): Operation not permitted`

Historical; fixed. If it reappears you are running an old image. Under
`--userns=keep-id` the container starts as an unprivileged uid with no
`CAP_SETGID`, so `gosu`'s `setgroups(2)` fails even when the target uid equals the
current one. `docker/uid-fixup-entrypoint.sh` now exits early to `exec` the
command directly when it is not root.

### Why can't the agent `git push`?

By design, and it is the core property of this sandbox. The image contains no
credential of any kind — no ssh keys, no `~/.git-credentials`, no `gh`, no
tokens — so a push to an authenticated remote cannot succeed. `Bash(git push:*)`
is *also* denied in the shipped settings, which is redundant while there is no
credential, but keeps the boundary a stated rule rather than an accident of what
happens not to be installed. Commit inside, push outside: see
[the push workflow](CONFIG.md#read-write-project-mounts-and-how-pushing-works).

### Can an agent reach another user's sandbox on a shared host?

No. Four independent reasons, each verified by probe rather than by reading code:

1. **No host paths are mounted** beyond that user's own workspace, state and
   `/context`. `/mnt/sandbox`, `/home/<user>` and the rest are simply absent.
2. **Container root is not host root.** `sudo` inside works, but the container's
   uid 0 maps to the invoker's *subuid* range. A file written by container root
   lands on the host owned by e.g. `524288`, which is not a real account and has
   no rights anywhere else on the machine.
3. **No escape hatch to the host.** No docker or podman socket is mounted, no
   `--privileged`, no added capabilities, no host PID or network namespace, and
   `machinectl`/`gcloud`/`gsutil` are not in the image. There is no way to start
   a host process at all.
4. **No credentials leak in.** `SSH_AUTH_SOCK` is unset, `~/.ssh` and
   `~/.config/gcloud` do not exist inside, and no `GOOGLE_*`/`CLOUDSDK_*`
   variables are forwarded.

Note the deliberate asymmetry: **humans** on a GCE VM can read each other's
directories via `sudo`, because every metadata-SSH-key user lands in
`google-sudoers`. That is accepted here — co-users are trusted people. Agents are
not, and they are the ones the boundary is built for.

What the boundary does *not* cover is reviewed in
[Two things this does not protect](CONFIG.md#two-things-this-does-not-protect):
an agent can author a change you then push yourself, and it can destroy
uncommitted local work inside its own mounts.

---

## Google Cloud and Terra

### `ERROR: (gcloud.compute.ssh) could not parse resource []`

`$VM` / `$ZONE` are empty. They are set only inside the admin section of
[SERVER.md](SERVER.md), which users do not run. Substitute real values.

### `ERROR: Request had insufficient authentication scopes`

You are running `gcloud compute ...` **from inside the VM**, before step 2. There,
gcloud authenticates as the VM's attached service account via the metadata
server, and its scopes are `devstorage.read_only`, `logging.write`,
`monitoring.write`, `pubsub`, `service.management.readonly`, `servicecontrol` and
`trace.append` — no `compute`, so the Compute API refuses the call regardless of
who you are.

This is not about your access to the project. If you only wanted a shell, you are
already in — skip the `gcloud compute ssh`. Otherwise run
`gcloud auth login --no-launch-browser` first, which replaces that credential with
your own identity.

On a VM created with `--no-service-account --no-scopes` (recommended) there is no
fallback credential at all, and the same command fails earlier with a missing-ADC
error instead.

### `You are running on a Google Compute Engine virtual machine ... it is not necessary to use this command`

Answer **`Y`**. The advice is wrong for this use: the VM's service account is a
different identity with narrow scopes and is not what has access to your Terra
workspaces. fiss-mcp needs *your* credentials from your own `~/.config/gcloud`.

### fiss-mcp GCS tools fail with `Project was not passed and could not be determined from the environment`

Set `CLAUDE_SANDBOX_GCP_PROJECT` — it is already in your rendered
`env.<USER>.sh`, defaulted to `warp-pipeline-dev`.

It is needed **even though** gcloud reports `Quota project "..." was added to
ADC`. That sets `quota_project_id`, which is not a project source:
`google.auth.default()` still returns `project=None`. Measured with
`quota_project_id` populated, not assumed — the same applies to
`gcloud auth application-default set-quota-project`, which is a red herring here.

### The fiss-mcp write tools are listed but refuse to run

```
This server is running in read-only mode.
```

Deliberate, and note that the tools really are *listed*: `submit_workflow`,
`abort_submission`, `update_method_config`, `copy_method_config` and
`upload_entities` stay registered and visible in `tools/list`, but each one checks
`FISS_MCP_ALLOW_WRITES` at call time and raises that error when it is off. Upstream's
README implies they are absent in read-only mode; measured, they are not.

`download_gcs_file` is the exception and is genuinely removed unless
`FISS_MCP_ALLOW_HOST_WRITES=1`, because it writes to a *host* path of the agent's
choosing — an escape route rather than a Terra mutation.

All of them are also in the settings deny list, which is what actually stops the
agent calling them under `bypassPermissions`. Details in
[COMPONENTS.md](COMPONENTS.md#what-write-mode-gates).

### A pet service account cannot read the bucket I need

Terra pet service accounts have no access to `scorch-emb` buckets. Stage inputs
into the workspace's own `fc-` bucket instead.

---

## GitHub and pushing

### `git push` asks for a username and password

`gh auth login` gives *gh* a token; it does not necessarily configure *git* to
use it. Run the second command:

```bash
gh auth setup-git
git config --get-all credential.helper    # must print: !/usr/bin/gh auth git-credential
```

The interactive flow offers to do this and it is easy to miss; `--web` may not
prompt at all. GitHub removed password auth, so the prompt can never succeed —
verify the helper rather than finding out at push time.

### Push rejected for a `.github/workflows/` change

Your login worked; GitHub blocks OAuth apps from modifying CI definitions.

```bash
gh auth refresh -s workflow
```

Treat the rejection as a prompt to look, not just a step to clear. A modified
workflow runs with your Actions permissions and secrets, and it is exactly the
category the credential boundary does not cover — the agent cannot reach GitHub,
but it can author a workflow change that you push:

```bash
git diff origin/HEAD...HEAD -- .github/workflows/
```

SSH keys sidestep the scope system entirely, since a key is not an OAuth app.

### `fatal: detected dubious ownership in repository at '/mnt/sandbox/repo'`

The shared checkout belongs to the admin, and git refuses to operate in a
repository owned by another user — including for plain reads. For a one-off read:

```bash
git -c safe.directory=/mnt/sandbox/repo -C /mnt/sandbox/repo log --oneline -1
```

You cannot `git pull` it; only its owner can. `provision-sandbox-user.sh` already
passes `-c safe.directory` internally for its staleness check.

---

## The shared VM

### "All my work is gone"

Two failure modes make a populated data disk look empty. Neither loses anything,
and one command tells them apart:

```bash
findmnt /mnt/sandbox
```

**Output, but `ls: cannot open directory '/mnt/sandbox': Permission denied`.**
The disk is mounted; you just cannot *list* the directory. `ls` needs read on a
directory while `cd` needs only execute, so mode `751` lets you sit inside one
that will not list. Paths inside keep working:

```bash
ls /mnt/sandbox/repo                    # works even while the parent will not list
stat -c '%a %U:%G %n' /mnt/sandbox
sudo chmod 755 /mnt/sandbox             # the fix
```

The mountpoint has to be world-readable; `users/` under it is `1777` so each user
can create their own directory, and each user's own directory is `700`.

**No output at all.** The disk is not mounted and you are looking at a bare
mountpoint on the boot disk. Everything — checkout, image store, every user's
state — lives under this mount, so an unmounted disk is indistinguishable from a
wiped one.

```bash
lsblk                                   # is the 200 GB disk visible at all?
grep sandbox /etc/fstab                 # is there an entry?
sudo mount -a && findmnt /mnt/sandbox
```

If `/etc/fstab` has no entry, add one keyed on **UUID**, not a device path — the
data disk has been observed moving between `/dev/sda` and `/dev/sdb` across
reboots:

```bash
echo "UUID=$(sudo blkid -s UUID -o value /dev/disk/by-id/google-sandbox-data) \
/mnt/sandbox ext4 discard,defaults,nofail 0 2" | sudo tee -a /etc/fstab
```

**Before assuming data loss, check the disk still exists.** It is created
independently of the instance with `auto-delete=no`, so it survives VM deletion:

```bash
gcloud compute disks describe sandbox-data --zone "$ZONE" \
  --format="value(name,sizeGb,status,users)"
```

`status: READY` with the instance under `users` means the data is intact and the
problem is on the mount or permission side.

### Step 4 fails: `dubious ownership` in `host_fiss_mcp/fiss-mcp`

```
=== sandbox directory layout ===
  warn    no CLAUDE_SANDBOX_{PROJECTS_DIR,CONTEXT_DIR,HOME} in the environment.
...
fatal: detected dubious ownership in repository at '/mnt/sandbox/repo/host_fiss_mcp/fiss-mcp'
```

**The env file was not in effect.** Either you skipped sourcing it, or — look one
line further up — it does not exist yet:

```
bash: /mnt/sandbox/users/<you>/env.<you>.sh: No such file or directory
```

That means **step 1 never ran**, and step 1 is what writes that file. Note what
happened next in that transcript: `source` failed, and `./setup_host.sh` ran anyway.
A failed `source` does not abort an interactive shell, so pasting the step-4 block
carries on into a half-configured run. Start from step 1:

```bash
cd /mnt/sandbox/repo
./scripts/provision-sandbox-user.sh          # step 1 — writes the env file
source /mnt/sandbox/users/$USER/env.$USER.sh # step 4, same shell
./setup_host.sh
```

Sourcing is what sets `CLAUDE_SANDBOX_FISS_ROOT` to your own
`users/$USER/fiss-mcp`. Without it the installer falls back to the shared checkout,
tries to `git fetch` in a clone owned by whoever set the host up, and git refuses —
correctly, since that clone is shared. The directory warning just above it is the
same missing variables showing up a step earlier.

Nothing is broken and nothing needs cleaning up: re-run from whichever step you
missed.

Do **not** "fix" it with the `git config --global --add safe.directory` line git
suggests. That would let you mutate the admin's clone, which other users depend on;
the point is to use your own.

Newer versions catch both variants before they reach git. `setup_host.sh` stops and
names the missing step -- "you have not been provisioned yet" when there is no env
file, "exists but has not been sourced" when there is -- and `install.sh` refuses a
state directory it does not own. Seeing the raw git error means the checkout predates
that, so `git pull` in the shared repo is worth doing.

### `make: command not found`

Correct, and not a missing dependency. Users do not build the image on a shared
host — an admin builds it once into a read-only store so everyone provably runs
the same one, and `scripts/build-shared-image.sh` calls `podman build` directly.
Nothing on the host needs `make`.

### `cannot chdir to /home/<other-user>: Permission denied`

You became another user with `sudo -u` and inherited the previous user's working
directory, which the new user cannot read. podman has to `chdir` before doing
anything.

```bash
cd ~
```

Prefer `sudo machinectl shell <user>@`, which gives a real systemd session — and
therefore an `XDG_RUNTIME_DIR`, without which podman fails with confusing
runtime-directory errors.

### My containers die when I log out

Enable linger, which `provision-sandbox-user.sh` does for you:

```bash
loginctl enable-linger $USER
```

Without it systemd tears down your user slice at logout and kills a long-running
agent mid-task. It needs `dbus-user-session` installed to hold.

---

## Resource limits

### Is `CLAUDE_SANDBOX_MEMORY` actually enforced?

Only with cgroup v2 delegation. Without it rootless podman silently ignores
`--memory` and the ceiling is fiction:

```bash
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers
# must list `memory`
```

Confirm from inside the container that the cap landed:

```bash
cat /sys/fs/cgroup/memory.max      # 17179869184 for 16g
```

### How many sandboxes fit on one host?

CPU is the ceiling, not RAM. A live sandbox measures ~547 MB resident but ~147%
CPU at start-up, so on 8 vCPU roughly **five** concurrent sandboxes saturate the
host — fewer with parallel subagents, since fan-out multiplies CPU rather than
memory. The `16g` default in the template over-promises with more than three
users on a 64 GB box; given measured usage, `4g` is generous. See
[Capacity](SERVER.md#capacity-not-disk-is-the-real-limit).
