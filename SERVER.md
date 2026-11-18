# Running the shared server (admin guide)

Everything in this document is done **once, by an admin**. Users never run any of
it. Their side is [`sandbox setup`](USER-SETUP.md#quick-start), which needs no
root.

> **On AWS the procedure is scripted:** see [AWS.md](AWS.md). This document stays
> the reference for *why* each piece exists, and for the GCP specifics. Two of its
> scripts work on any Debian 13 host, GCP included:
> `scripts/setup-debian-host.sh` does [Host packages](#host-packages),
> [Format and mount the data disk](#format-and-mount-the-data-disk) and the shared
> directories, and `scripts/add-sandbox-user.sh` does
> [route B of Adding a user](#adding-a-user).

Verified end to end on a real GCP deployment: Debian 13, podman 5.4.2, a separate
data disk, multiple users. Every value below was checked against that deployment
rather than copied from Google's docs. Nothing is GCP-specific except the
instance-creation and SSH-key parts — the same layout works on any Linux host with
rootless podman ≥ 5.

Set the placeholders once:

```bash
PROJECT=my-project
ZONE=us-central1-c
VM=claude-sandbox
NETWORK=default          # see the note under "Create the instance"
```

## Contents

- [Choosing the OS](#choosing-the-os)
- [The data disk is mandatory](#the-data-disk-is-mandatory)
- [Create the instance](#create-the-instance)
- [Format and mount the data disk](#format-and-mount-the-data-disk)
- [SSH access and firewall](#ssh-access-and-firewall)
- [Host packages](#host-packages)
- [The shared image store](#the-shared-image-store)
- [Updating the image later](#updating-the-image-later)
- [Adding a user](#adding-a-user)
- [Sharing reference docs with everyone](#sharing-reference-docs-with-everyone)
- [Sharing agent output between users](#sharing-agent-output-between-users)
- [Attaching a GPU](#attaching-a-gpu)
- [Capacity, not disk, is the real limit](#capacity-not-disk-is-the-real-limit)
- [Rebuilding for more cores](#rebuilding-for-more-cores)

## Choosing the OS

The requirement is **podman ≥ 5** with a current **pasta**, and no SELinux to
relabel bind mounts for.

| Distro | Verdict |
|---|---|
| Debian 13 (trixie) | **Used here.** podman 5.4.2, current passt, no SELinux. |
| Debian 12 (bookworm) | **Cannot host this.** podman 4.3.1 and a passt snapshot from March 2023, so `--network=pasta:-T,<port>` does not exist and `setup_host.sh` refuses it. |
| Fedora / Nobara | Works; this is the local development platform. Not in GCP's standard image projects. |
| RHEL 10 / Rocky 10 | Version requirement met, but SELinux is enforcing and the bind mounts would need `:z`, which this fork does not handle yet. |

## The data disk is mandatory

The image is ~9.0 GB. A default 10 GB boot disk leaves ~6.4 GB free, so it does
not fit at all, and `make rebuild` transiently needs room for a second copy.
Create the disk **independently of the instance** so it survives a VM rebuild:

```bash
gcloud compute disks create sandbox-data \
  --project "$PROJECT" --zone "$ZONE" --size 200GB --type pd-balanced
```

Sizing is `8 GB image + 8 GB rebuild headroom + ~2 GB per user`. Measured
per-user footprint: fiss-mcp venv 122 MB, uv's pinned Python 112 MB, checkout
33 MB, plus workspaces and session transcripts (one real session was 3.8 MB).
200 GB covers 10-20 users comfortably; 100 GB is the floor. Use `pd-balanced`
rather than `pd-standard` — IOPS scale with size, and image builds plus CodeGraph
indexing are IO-bound.

## Create the instance

```bash
gcloud compute instances create "$VM" \
  --project "$PROJECT" --zone "$ZONE" \
  --machine-type e2-highmem-8 \
  --image-family debian-13 --image-project debian-cloud \
  --boot-disk-size 50GB --boot-disk-type pd-balanced \
  --network "$NETWORK" --subnet "$NETWORK" \
  --no-service-account --no-scopes \
  --disk name=sandbox-data,device-name=sandbox-data,mode=rw,auto-delete=no
```

Notes that each cost real debugging time:

* **`--network` / `--subnet` are required** if the project has no `default`
  network — many organisation-managed projects do not. Without them the create
  fails with `Invalid value for field 'resource.networkInterfaces[0].network' ...
  cannot be found`, which does not say what to do about it. Copy the values from a
  working instance in the same project:

  ```bash
  gcloud compute instances describe <existing-vm> --zone "$ZONE" \
    --format="yaml(networkInterfaces)"
  ```
* **`--no-service-account --no-scopes`** is worth doing at create time. The GCE
  metadata server is reachable from inside the container, so an attached service
  account is a cloud credential an agent could obtain. Both flags are required
  together — gcloud rejects `--no-service-account` alone. Doing it later costs
  another stop/start.
* **`auto-delete=no`** on the data disk. This is what makes future rebuilds cheap:
  delete the instance, keep the data.
* **50 GB boot, not 10.** Home directories live on the boot disk.
* **Keep the external IP.** With no Cloud NAT in the project, a `--no-address`
  instance has no outbound internet, and the sandbox needs egress for npm, GitHub
  and the Anthropic API. `--tunnel-through-iap` works for SSH, but only with an
  external IP present, absent a NAT.
* The instance gets a **fresh ephemeral IP**. Reserve one with
  `gcloud compute addresses create ... --region us-central1` and pass `--address`
  if several people will be connecting.

## Format and mount the data disk

Attaching a disk neither formats nor mounts it.

```bash
# The boot disk may enumerate as /dev/sdb, putting the data disk on /dev/sda.
# The by-id path is stable, so device order does not matter.
lsblk; ls -l /dev/disk/by-id/google-sandbox-data

sudo mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard \
  /dev/disk/by-id/google-sandbox-data

sudo mkdir -p /mnt/sandbox
echo "UUID=$(sudo blkid -s UUID -o value /dev/disk/by-id/google-sandbox-data) \
/mnt/sandbox ext4 discard,defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount -a && df -h /mnt/sandbox

sudo mkdir -p /mnt/sandbox/users
sudo chmod 755  /mnt/sandbox
sudo chmod 1777 /mnt/sandbox/users   # sticky, like /tmp
```

`nofail` is deliberate: without it a missing or renamed disk wedges boot, which is
painful on a box where you may only have root. Key fstab on **UUID** — the device
letter has been observed changing across reboots.

**Why `1777` on `users/`.** It is the only thing that makes per-user setup
self-service: each user creates their own `users/<name>/`, and the sticky bit
stops them removing or renaming anyone else's. With `755` only root could create
those directories, so onboarding anyone would need an admin.

Each user's own directory is then `chmod 700` by `provision-sandbox-user.sh`. That
stops casual reads by other users but **not** reads via `sudo`, and on a GCE VM
every metadata-SSH-key user lands in `google-sudoers`. Treat co-users as trusted
people, or control who has a key. This does not weaken the boundary that matters —
see [can an agent reach another user's sandbox](FAQ.md#can-an-agent-reach-another-users-sandbox-on-a-shared-host).

## SSH access and firewall

Check the **effective** firewalls, not just the VPC rules —
`gcloud compute firewall-rules list` does not show org-level policies:

```bash
gcloud compute instances network-interfaces get-effective-firewalls \
  "$VM" --zone "$ZONE" --network-interface nic0
```

On this org an org-level policy allows ingress from the institution's IP ranges
and from the IAP range `35.235.240.0/20`, with **no target tags**, so it covers
every VM. That is why these instances carry no network tags even though a
VPC-level tcp:22 rule requires a `broad-allow` tag — that rule is redundant here.
Do not assume tags are unnecessary on another org without running the command
above.

Access is by **project metadata SSH keys**, which is also what makes rootless
podman work: the Google guest agent creates each key's user with `useradd`, and
`useradd` allocates the `/etc/subuid` and `/etc/subgid` ranges that rootless
podman cannot work without.

```bash
grep "^$USER:" /etc/subuid /etc/subgid     # e.g. alice:624288:65536
```

**Do not switch to OS Login.** OS Login users resolve through NSS with no
`/etc/passwd` entry, so they get **no subuid ranges** and rootless podman fails
for them. There is no clean fix: shadow-utils ≥ 4.9 supports a pluggable `subid:`
NSS database, but the only shipped provider is SSSD's `libsubid_sss.so`, which
needs FreeIPA/LDAP; podman has ignored `subid: sss` outright in some versions
(containers/podman#25041); and Red Hat documents that enabling NSS subid *breaks*
rootless podman for local users (access.redhat.com/solutions/6961540). A
`pam_exec` hook allocating ranges at first login would work, but a broken PAM
stack locks everyone out.

## Host packages

Debian's cloud image is minimal — nothing container-related ships by default.
`sudo ./scripts/setup-debian-host.sh` installs all of this, plus `gh` and (off GCE)
`google-cloud-cli` from their vendors' repositories, and a pinned `uv`. By hand:

```bash
sudo apt-get update
sudo apt-get install -y \
  podman passt uidmap fuse-overlayfs crun \
  dbus-user-session slirp4netns \
  git jq fzf gh tmux
```

Every package is load-bearing:

| package | why |
|---|---|
| `podman` | 5.4.2 in trixie; the launcher requires ≥ 5 |
| `passt` | provides `pasta`, which `--network=pasta:-T` needs to reach host fiss-mcp |
| `uidmap` | `newuidmap`/`newgidmap`. **Rootless podman fails outright without it** |
| `fuse-overlayfs`, `crun` | rootless storage driver and OCI runtime |
| `dbus-user-session` | systemd user session; `loginctl enable-linger` does not hold without it |
| `git`, `jq`, `fzf` | repo operations, host-side JSON, the `start_sandbox.sh` menu |
| `gh` | GitHub CLI, for each user's own `gh auth login` |
| `tmux` | keeps a sandbox alive across an SSH drop. The launcher runs `--rm -it`, so losing the terminal kills the container and deletes it — see [the FAQ](FAQ.md#my-ssh-dropped-how-do-i-reconnect-to-the-session) |

Then **uv**, which Debian does not package. Install it once, system-wide, rather
than having each user run a `curl | sh`:

```bash
curl -LsSf https://github.com/astral-sh/uv/releases/download/0.12.3/uv-x86_64-unknown-linux-gnu.tar.gz \
  | sudo tar -xz -C /usr/local/bin --strip-components=1 --wildcards '*/uv' '*/uvx'
uv --version
```

That extracts a binary instead of piping a script into `sudo sh`. **uv is
required, not optional:** trixie's python3 is 3.13 and `terra-mcp` depends on
`firecloud` 0.16.x, a legacy `setup.py` package that will not build on 3.13. uv
fetches a pinned 3.12 interpreter, which is the only reason the host venv builds
at all. `host_fiss_mcp/install.sh` fails with instructions if uv is absent.

## The shared image store

Put the checkout where every user can read it, then build once:

```bash
# On the DATA disk, not /opt: the rebuild path relies on the checkout surviving a
# boot-disk replacement. Owned by you rather than root, so `git pull` later uses
# your own GitHub credentials and root never needs any.
sudo mkdir -p /mnt/sandbox/repo
sudo chown "$USER:$USER" /mnt/sandbox/repo
git clone https://github.com/broadinstitute/warp-sandbox-podman /mnt/sandbox/repo
chmod -R a+rX /mnt/sandbox/repo

cd /mnt/sandbox/repo
sudo ./scripts/build-shared-image.sh
```

One 9.0 GB copy instead of one per user, and everyone provably runs the same
image. Users cannot rebuild it, which is a feature: the image is the trust
boundary, and drift between users would make "it works for me" unfalsifiable.

The build must be **rootful**. A rootless build writes layer files owned by the
builder's subuid range, which no other user's namespace can map, so the image
would be readable only by whoever built it. Users then see it read-only through
`additionalimagestores` in their own `storage.conf`, which
`provision-sandbox-user.sh` writes — so provision each user *before* they try any
podman command.

## Updating the image later

Because users cannot build, a `docker/` change reaches nobody until an admin
re-runs the build. `git pull` is not enough — the store still holds the old
layers:

```bash
cd /mnt/sandbox/repo
git pull && chmod -R a+rX /mnt/sandbox/repo
sudo ./scripts/build-shared-image.sh
```

Users pick it up on their next launch with no action of their own: no
re-provisioning, no re-authentication. Anyone with a container already running
keeps the old image until they exit and relaunch.

Each rebuild leaves the previous image dangling as `<none>`, holding another
~8 GB. Reclaim it through the same script:

```bash
sudo ./scripts/build-shared-image.sh --prune
```

**Do not call `podman ... image prune` directly.** Prune rewrites the store
metadata as root `0600`, undoing the `chmod -R a+rX` the build applies, and every
user is then locked out with `configure storage: open .../images.json: permission
denied`. `--prune` restores permissions in the same breath. If you do touch the
store by hand, follow it with `sudo chmod -R a+rX /mnt/sandbox/imagestore`.

## Adding a user

Two routes. Both end with a real local Unix account, which matters because
`useradd` is what allocates the subuid ranges.

**Route A — a real person.** Append their public key to project metadata; the
guest agent creates the account on their first login.

```bash
# 1. Read the existing keys out. Use jq on the JSON: gcloud's value() formatter
#    renders the field as a Python-style list, e.g. ['user:ssh-rsa AAAA...'],
#    and writing THAT back would corrupt the metadata for everyone.
gcloud compute project-info describe --format=json \
  | jq -r '.commonInstanceMetadata.items[] | select(.key=="ssh-keys") | .value' \
  > keys.txt

# 2. Sanity-check before touching anything: one "user:ssh-..." per line, no
#    brackets or quotes, every existing user still present.
cat keys.txt

# 3. Append theirs.
printf '%s\n' "newuser:ssh-ed25519 AAAA... newuser@laptop" >> keys.txt

# 4. Write the whole set back.
gcloud compute project-info add-metadata --metadata-from-file ssh-keys=keys.txt
```

Check step 2 properly: `add-metadata` **replaces** the entire `ssh-keys` value, so
a malformed file removes everyone else's access — on a host where you may only
have root. Note that `gcloud compute ssh` maintains its own short-lived expiring
entries at the *instance* level; leave those alone.

That is the only admin action needed. They then run
[the five user steps](USER-SETUP.md)
themselves.

**Route B — a local account, no Google identity, no metadata change.** This is the
**recommended way to run agents**, not just a way to test, and the only route on
AWS. `sudo ./scripts/add-sandbox-user.sh <name> <pubkey>` does all of it, keys and
linger included. A metadata-key account
is placed in `google-sudoers` by the guest agent, so it can read every other
user's Claude token and credentials. An account created with `useradd` is not, and
cannot. Running the sandbox needs no sudo at all, so the agent account should not
have any:

```bash
sudo useradd -m -s /bin/bash testuser
grep '^testuser:' /etc/subuid /etc/subgid   # must print a range; useradd allocates it
sudo loginctl enable-linger testuser        # so /run/user/<uid> exists
```

The account has no password and no sudo, which is the point: if the sandbox works
for it, it works for a genuinely least-privilege user. To become that user you
need a real systemd session, not just `sudo -u` — without `XDG_RUNTIME_DIR`
podman fails with confusing runtime-directory errors:

```bash
sudo apt-get install -y systemd-container    # once, if machinectl is missing
sudo machinectl shell testuser@
```

Verify the isolation holds while you are there:

```bash
podman images                      # localhost/claude-sandbox, R/O = true
du -sh ~/.local/share/containers   # small: no private copy of the 9.0 GB image
```

### Logging in to a sudo-less agent account

Give it your own public key directly, in the account's `authorized_keys` rather
than in project metadata. Metadata is what triggers the guest agent to grant
`google-sudoers`; a file in the home directory does not.

```bash
sudo install -d -m 700 -o agentuser -g agentuser /home/agentuser/.ssh
sudo tee /home/agentuser/.ssh/authorized_keys < ~/.ssh/id_ed25519.pub >/dev/null
sudo chown agentuser:agentuser /home/agentuser/.ssh/authorized_keys
sudo chmod 600 /home/agentuser/.ssh/authorized_keys
id -nG agentuser        # must NOT list google-sudoers
```

Then reach it with **plain ssh through an IAP tunnel**, not `gcloud compute ssh`:

```bash
gcloud compute start-iap-tunnel "$VM" 22 --local-host-port=localhost:2222 --zone "$ZONE" &
ssh -p 2222 agentuser@localhost
```

**Why not `gcloud compute ssh`:** it ensures its key is in project metadata for
whatever username it is about to use, and adds it if absent. Two consequences,
both observed:

* Running it from a machine whose local username has no metadata entry
  **silently creates a new account** on every VM in the project — and that account
  lands in `google-sudoers`. A stray `gcloud compute ssh` from a workstation whose
  local user is `alice` gets you an `alice` account with passwordless sudo on the
  shared host.
* It re-adds a key you have just deleted, **in the same invocation** that you use
  to do the cleanup. Delete the metadata entry after your last `gcloud compute ssh`,
  not before.

`sudo gcloud compute project-info add-metadata --metadata=block-project-ssh-keys=TRUE`
closes this off entirely by making instance-level keys the only accepted ones. Note
that it also stops every existing metadata-key user from logging in, so plan the
switch rather than running it on a live host.

### Removing an account

```bash
sudo loginctl disable-linger olduser
sudo userdel -r olduser              # refuses while the user has live processes
sudo rm -rf /mnt/sandbox/users/olduser
sudo sed -i '/^olduser:/d' /etc/subuid /etc/subgid   # userdel leaves these behind
```

Linger means "logged out" is not the same as "no processes", so if `userdel`
refuses, stop the slice first — do not reach for `-f`, which leaves the account
half-removed:

```bash
sudo loginctl terminate-user olduser
```

You cannot `userdel` the account you are logged in as. Either do it from another
account, or defer it past your own session:

```bash
sudo systemd-run --on-active=15 --unit=remove-olduser /usr/local/sbin/remove-olduser.sh
```

If the account came from project metadata, remove its key too — and read, filter
and write back the **whole** value, because `add-metadata` replaces it wholesale:

```bash
gcloud compute project-info describe --format=json \
  | jq -r '.commonInstanceMetadata.items[] | select(.key=="ssh-keys") | .value' > keys.txt
grep -v '^olduser:' keys.txt > keys.new
diff keys.txt keys.new          # confirm ONLY olduser's lines went
gcloud compute project-info add-metadata --metadata-from-file ssh-keys=keys.new
```

Run that from a laptop, not from the VM: the instance's own credentials cannot
read project metadata (`Request had insufficient authentication scopes`).

## Sharing reference docs with everyone

To hand the same material to every sandbox — house standards, a data dictionary, a
pipeline spec — do **not** copy it into each `users/<name>/context/`. Those are
`chmod 700`, so it needs `sudo` per user, and every later edit has to be repeated N
times. Use one admin-owned directory instead:

```bash
sudo mkdir -p /mnt/sandbox/reference
sudo chmod 755 /mnt/sandbox/reference        # world-readable, admin-writable
sudo cp house-standards.md data-dictionary.md /mnt/sandbox/reference/
```

`provision-sandbox-user.sh` picks it up automatically: if `/mnt/sandbox/reference`
exists, the rendered env file gets

```bash
export CLAUDE_SANDBOX_RO_MOUNTS="/mnt/sandbox/reference"
```

and it appears in every sandbox at `/read-only-reference/reference`, read-only. Users
who provisioned *before* you created it just re-run step 1 — it is idempotent, and it
leaves a user's own `RO_MOUNTS` alone if they set one.

**It is enabled only when the directory exists**, and that gate is load-bearing: the
launcher treats a missing `CLAUDE_SANDBOX_RO_MOUNTS` path as fatal rather than letting
podman auto-create it, so shipping the line enabled by default would break every
launch on a host with no reference directory.

Edits show up live — bind mounts share inodes, so updating a file here changes what
running sandboxes see, with no relaunch.

## Sharing agent output between users

By default, nothing an agent produces is visible to anyone but its own user. Plans it
writes on its own go to `~/.claude/plans` inside the container, which is
`users/<user>/shared/.claude/plans/` on the host — and that tree is `chmod 700`.
(`$SHARED_HOME` means shared across *that user's* instances, not across people; the
name misleads.)

For a place agents can publish to, create one writable directory:

```bash
sudo mkdir -p /mnt/sandbox/plans
sudo chmod 1777 /mnt/sandbox/plans     # sticky, like /tmp and like users/
```

`provision-sandbox-user.sh` picks it up when it exists and adds

```bash
export CLAUDE_SANDBOX_RW_MOUNTS="/mnt/sandbox/plans"
```

so it appears in every sandbox at **`/projects/plans`**, read-write. Existing users
re-run step 1; a user who already set their own `RW_MOUNTS` is left alone.

**Why `1777` rather than a group.** It matches `users/` and needs no per-user admin
step: anyone can create files, and the sticky bit stops them removing or renaming
anyone else's. A `sandbox` group with `2775` would be tidier on paper but requires
`usermod -aG` for every new account, which breaks the self-service property that the
rest of this setup is built around.

**Permissions work out without intervention** — measured: the container's umask is
`0022`, so an agent writing `/projects/plans/foo.md` produces a `644` file owned by
its own user. Other users can read it; they cannot overwrite it, since `644` denies
group and other writes. That is usually what you want for a published plan.

Tell the agent explicitly to write there — `/projects/plans/2026-08-11-migration.md`
— because its default plan location is the private one.

For anything that should outlive a scratch directory, prefer committing the document
into the repo it concerns and pushing it: that gets review, history and attribution,
none of which a shared folder provides.

### Which directory for what

| | Owner | Agent sees it at | Agent can write? | Good for |
|---|---|---|---|---|
| `users/<user>/workspace/` | that user | `/workspace` | yes | their repos and working files |
| `users/<user>/context/` | that user | `/context` | no | *their own* plans and notes |
| `/mnt/sandbox/reference/` | admin | `/read-only-reference/reference` | no | material shared by everyone |
| `/mnt/sandbox/plans/` | whoever writes each file | `/projects/plans` | yes | agent output to hand to colleagues |

An admin *can* write into a user's `context/` with `sudo cp` followed by
`sudo chown <user>:<user>`, and that is fine for a one-off. **Do not skip the
`chown`.** It leaves a root-owned file the user cannot edit or delete in a directory
they otherwise own, and if the source file was mode 600 the agent cannot even read it
— measured: owned-by-another-account plus not-world-readable is the one combination
that is denied inside the container, and the only symptom is the agent saying it
cannot read the file.

```bash
sudo cp plan.md /mnt/sandbox/users/$U/context/
sudo chown "$U:$U" /mnt/sandbox/users/$U/context/plan.md   # not optional
```

## Attaching a GPU

Needed for `scvi-tools` and anything else that trains a model; the CPU wheels are
fine for inspecting data and for small runs, but not for real training.

> **Status: procedure, not a transcript.** Every *fact* below was checked against
> this project (zone inventory, quota, package availability, what the launcher
> does) and is marked as such. But no GPU VM has been built here, so unlike the
> rest of this document the sequence has not been run end to end. Expect to debug
> the driver step.

### It requires a rebuild, not an attach

Two independent reasons:

* **`e2-highmem-8` cannot host a GPU.** The E2 family supports no accelerators at
  all, so the current machine type is disqualified regardless.
* **gcloud has no way to attach one to an existing instance** — verified: neither
  `gcloud compute instances update` nor `set-machine-type` has an `--accelerator`
  flag.

So this folds into [Rebuilding for more cores](#rebuilding-for-more-cores) — same
procedure, extra flags at create time. The data disk carries everything across, so
no user loses work or has to re-authenticate.

### Picking the machine

Verified available in `us-central1-c`: L4, T4, V100, P100, P4, A100 40GB, H100.
Two sensible shapes:

| | machine type | GPU | notes |
|---|---|---|---|
| **Recommended** | `g2-standard-8` | 1 × **L4**, 24 GB VRAM, built in | Ada-generation, current, no `--accelerator` flag needed — the GPU is part of the machine type |
| Cheaper | `n1-standard-8` + `--accelerator` | 1 × **T4**, 16 GB VRAM | Older; T4 is still plenty for most scVI-scale models |

**Quota is already in place** — verified in this project for `us-central1`:
`NVIDIA_L4_GPUS` = 32, `NVIDIA_T4_GPUS` = 16, `NVIDIA_A100_GPUS` = 16. No quota
request needed. (`NVIDIA_A100_80GB_GPUS` is 0, so the 80 GB A100 *would* need one.)

Create it as in the rebuild runbook, with these differences:

```bash
gcloud compute instances create "$NEW" \
  --zone "$ZONE" \
  --machine-type g2-standard-8 \
  --maintenance-policy TERMINATE \
  --image-family debian-13 --image-project debian-cloud \
  --boot-disk-size 50GB --boot-disk-type pd-balanced \
  --network "$NETWORK" --subnet "$NETWORK" \
  --address sandbox-ip \
  --no-service-account --no-scopes \
  --disk name=sandbox-data,device-name=sandbox-data,mode=rw,auto-delete=no

# For the n1 + T4 route instead, add:
#   --machine-type n1-standard-8 \
#   --accelerator type=nvidia-tesla-t4,count=1
```

**`--maintenance-policy TERMINATE` is mandatory**, not a preference: GPU instances
cannot live-migrate, and the create is rejected without it.

### Host driver

Debian 13 ships one, which is the simplest route — verified present in the archive
as `nvidia-driver 550.163.01-2` (trixie, `non-free`):

```bash
sudo sed -i 's/ main$/ main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources 2>/dev/null \
  || sudo apt-edit-sources    # whichever your image uses; the point is to enable non-free
sudo apt-get update
sudo apt-get install -y nvidia-driver firmware-misc-nonfree
sudo reboot
```

After the reboot:

```bash
nvidia-smi        # must list the L4/T4 and report a CUDA version
```

Driver 550 gives a CUDA 12.4 runtime, which matters for the torch wheel choice
below. If you need newer, `trixie-backports` has `550.163.01-4~bpo13+1`, and NVIDIA
publishes its own repo for Debian 13 — verified live at
`developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/`. Google's
`compute-gpu-installation` installer script also exists, but I could not confirm it
claims Debian 13 support, so treat it as a fallback rather than the first choice.

### Container toolkit and the CDI spec

Rootless podman does **not** use `--gpus`; it needs a CDI spec, which is what
`nvidia-ctk` generates. The toolkit is **not in the Debian archive** (verified), so
it comes from NVIDIA's repo — which is distro-agnostic now, so trixie is fine:

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit

# The bit rootless podman actually consumes:
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
nvidia-ctk cdi list          # should show nvidia.com/gpu=all and nvidia.com/gpu=0
```

**Regenerate the CDI spec after every driver upgrade.** It pins device and library
paths, so a driver bump silently invalidates it and containers then fail to start
with missing-library errors.

Verify passthrough before telling users it works:

```bash
podman run --rm --device nvidia.com/gpu=all localhost/claude-sandbox:0.0.1 nvidia-smi -L
```

### Letting users have it

GPU passthrough is **opt-in and off by default**. Each user adds one line to their
own `env.<USER>.sh`:

```bash
export CLAUDE_SANDBOX_GPU=1
```

The launcher then looks for `/etc/cdi/nvidia.yaml` (or `/var/run/cdi/nvidia.yaml`)
and passes `--device nvidia.com/gpu=all`. If the spec is missing it prints the
`nvidia-ctk cdi generate` command and **continues without the GPU** rather than
failing — so a silently CPU-only run is possible; check the launch output.

Then `scvi-tools` should be installed against CUDA rather than CPU:

```bash
uv pip install --torch-backend auto scvi-tools    # 'auto' detects the driver
.venv/bin/python -c 'import torch; print(torch.cuda.is_available(), torch.version.cuda)'
```

`auto` picks a wheel matching the installed driver. Be careful pinning by hand: with
driver 550 (CUDA 12.4) a `cu13x` wheel will not run — CUDA 13 needs a 580-series
driver. `cu129` and below are safe on 550.

### Two things to think about before doing it

**One GPU, several users, no isolation between them.** `--device nvidia.com/gpu=all`
gives every sandbox the whole GPU. Nothing partitions VRAM, so one agent's training
run can OOM everyone else's, and GPU processes are visible across users. Enable
`CLAUDE_SANDBOX_GPU=1` for the people who need it rather than in the template, and
treat concurrent training as something to coordinate socially. Time-slicing or MIG
(A100 only) would be the technical fix, and neither is set up here.

**Cost.** A `g2-standard-8` is several times the price of `e2-highmem-8`, billed
whenever the VM is running, whether or not the GPU is busy. If GPU work is bursty,
consider a second, separate GPU instance that mounts its own data disk and gets
stopped when idle, rather than making the always-on shared host expensive for
everyone.

## Capacity, not disk, is the real limit

CPU is the ceiling. A live sandbox measures ~547 MB resident but ~147% CPU at
start-up, so on 8 vCPU roughly **five** concurrent sandboxes saturate the host —
fewer when people run parallel subagents, since fan-out multiplies CPU rather
than memory.

`e2-highmem-8` is 8 vCPU / 64 GB. At the template's `CLAUDE_SANDBOX_MEMORY=16g`
that is about **3 concurrent sandboxes** before the host is oversubscribed on
paper. Given measured usage of ~547 MB, dropping the per-user cap to `4g` or `8g`
is generous and stops one user reserving a quarter of the machine — a config
change, not a rebuild.

The cap is only real with cgroup v2 delegation; see
[the FAQ](FAQ.md#is-claude_sandbox_memory-actually-enforced).

## Rebuilding for more cores

This is also the procedure for [adding a GPU](#attaching-a-gpu), which cannot be
attached to an existing instance and is not supported by the E2 family at all.

`gcloud compute instances set-machine-type` can resize in place but requires a
stop/start anyway. Since you are taking an outage regardless, a fresh instance is
usually the better trade — you can also pin a static IP at create time instead of
as another stop/start.

**What survives is decided by which disk it lives on**, which is why the data disk
was created independently with `auto-delete=no`:

| on the data disk — survives | on the boot disk — must be redone |
|---|---|
| the checkout at `/mnt/sandbox/repo` | apt packages (podman, passt, uidmap, …) |
| the shared image store (~9.0 GB) | the system-wide `uv` binary |
| every user's workspace and state | each user's `~/.config/gcloud` (re-auth) |
| every user's Claude OAuth token | each user's `gh` auth |
| every user's fiss-mcp venv | the `/etc/fstab` entry |
| every user's `env.<USER>.sh` | `/etc/subuid` ranges (recreated by `useradd`) |

So the expensive parts — the image build and each user's `/login` — do **not**
repeat. What repeats is one apt line, one uv download, and each user's cloud
logins.

Run all of this from a laptop or Cloud Shell, **not from the VM**: the first
command severs your own SSH session, and anything after it in that shell never
executes.

```bash
ZONE=us-central1-c
OLD=warp-claude-sandbox-2
NEW=warp-claude-sandbox-3

# 1. A reserved IP, so the address stops changing on every rebuild.
gcloud compute addresses create sandbox-ip --region "${ZONE%-*}"

# 2. Release the data disk from the old instance, then delete it.
gcloud compute instances stop "$OLD" --zone "$ZONE"
gcloud compute instances detach-disk "$OLD" --zone "$ZONE" --disk sandbox-data
gcloud compute instances delete "$OLD" --zone "$ZONE"

# 3. Create the replacement with everything set correctly up front.
gcloud compute instances create "$NEW" \
  --zone "$ZONE" \
  --machine-type n2-standard-16 \
  --image-family debian-13 --image-project debian-cloud \
  --boot-disk-size 50GB --boot-disk-type pd-balanced \
  --network "$NETWORK" --subnet "$NETWORK" \
  --address sandbox-ip \
  --no-service-account --no-scopes \
  --disk name=sandbox-data,device-name=sandbox-data,mode=rw,auto-delete=no
```

Then on the new VM, once:

```bash
# Remount the data disk. Do NOT mkfs — it is already formatted and full of your
# state. The UUID is unchanged; only the device letter may differ, which is
# exactly why fstab keys on UUID.
sudo mkdir -p /mnt/sandbox
echo "UUID=$(sudo blkid -s UUID -o value /dev/disk/by-id/google-sandbox-data) \
/mnt/sandbox ext4 discard,defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount -a && findmnt /mnt/sandbox
```

Then redo [Host packages](#host-packages). Each user re-runs their own two cloud
logins and relaunches; `provision-sandbox-user.sh` is idempotent, so repeating it
leaves existing directories alone while recreating the
`~/.config/containers/storage.conf` that lived on the replaced boot disk.
