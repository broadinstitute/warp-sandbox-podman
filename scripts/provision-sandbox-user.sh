#!/usr/bin/env bash
# provision-sandbox-user.sh — one-time per-user setup on a shared host.
#
# Run it as yourself, not as root, not with sudo:
#     ./scripts/provision-sandbox-user.sh
#
# It does the mechanical parts of getting one user ready and nothing else:
# checks the prerequisites that fail confusingly when absent, creates that
# user's directories on the data disk, enables linger, and writes their
# env.<USER>.sh from the GCP template.
#
# It deliberately does NOT authenticate anything. gcloud and GitHub logins are
# interactive, belong to the user, and are listed at the end as the steps only
# they can perform. No credential is read, written, copied or forwarded here.
#
# It also needs NO root. Everything it touches is either the user's own home or
# their own directory under the data disk. That is a deliberate constraint: an
# admin sets the host up once, and every user after that onboards themselves.
# The only prerequisites that need root are the one-time host steps in SERVER.md
# (packages, uv, the data disk, `chmod 1777` on users/, and building the shared
# image store). This script checks each of those and names the exact command an
# admin should run if one is missing, rather than failing obscurely.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SANDBOX_ROOT="${CLAUDE_SANDBOX_ROOT:-/mnt/sandbox}"
USER_ROOT="${SANDBOX_ROOT}/users/${USER}"

RED=$'\033[1;31m'; YEL=$'\033[1;33m'; GRN=$'\033[1;32m'; RST=$'\033[0m'
FAIL=0
ok()    { echo "  ${GRN}ok${RST}      $*"; }
warn()  { echo "  ${YEL}warn${RST}    $*"; }
fatal() { echo "  ${RED}FAIL${RST}    $*"; FAIL=1; }

if [[ "$(id -u)" == "0" ]]; then
    echo "Run this as your own user, not root — it provisions whoever invokes it." >&2
    exit 1
fi

echo
echo "Provisioning sandbox for ${USER} (uid $(id -u))"
echo

# ---------------------------------------------------------------- checks ----
echo "=== prerequisites ==="

# fuse-overlayfs is in this list because the shared image store does not work
# without it — see the storage.conf written further down.
for b in podman pasta uv git fuse-overlayfs; do
    if command -v "$b" >/dev/null 2>&1; then
        ok "$b present"
    else
        fatal "$b missing — the admin needs to install it (see SERVER.md, \"Host packages\")"
    fi
done

if command -v podman >/dev/null 2>&1; then
    # `|| true` matters: under `set -o pipefail` a failing `podman --version`
    # makes this assignment non-zero, and `set -e` then kills the script with no
    # output at all -- exactly when the user most needs to be told what is wrong.
    v="$(podman --version 2>/dev/null | awk '{print $3}')" || true
    if [[ -z "$v" ]]; then
        fatal "podman is on PATH but \`podman --version\` produced nothing."
        echo "          It is probably misconfigured. Try running it directly to"
        echo "          see the error: podman --version"
    elif [[ -n "${v%%.*}" ]] && (( ${v%%.*} >= 5 )); then
        ok "podman $v (>= 5 required for keep-id:uid= and pasta)"
    else
        fatal "podman $v is too old; >= 5.0 required"
    fi
fi

# subuid/subgid: the thing that silently breaks rootless podman. On a GCP VM
# using metadata SSH keys these are allocated by the guest agent's useradd. They
# are absent for OS Login users, which is why this host does not use OS Login.
for f in /etc/subuid /etc/subgid; do
    if line=$(grep -E "^${USER}:" "$f" 2>/dev/null); then
        count="${line##*:}"
        if (( count >= 65536 )); then
            ok "$f: $line"
        else
            warn "$f range is only ${count} ids; 65536 recommended"
        fi
    else
        fatal "no entry for '${USER}' in $f — rootless podman cannot work."
        echo "          An admin can add one with:"
        echo "            sudo usermod --add-subuids 100000-165535 \\"
        echo "                         --add-subgids 100000-165535 ${USER}"
        echo "          (pick a range that does not overlap another user's)"
    fi
done

# --memory is silently ignored without the memory controller delegated.
CG="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers"
if [[ -r "$CG" ]] && grep -qw memory "$CG"; then
    ok "cgroup v2 memory controller delegated ($(cat "$CG"))"
else
    warn "memory controller not delegated — CLAUDE_SANDBOX_MEMORY will be ignored"
fi

# Optional, but the closing message tells the user to run both, so a missing
# binary belongs here rather than surfacing as "command not found" three steps
# later.
for b in gcloud gh; do
    if command -v "$b" >/dev/null 2>&1; then
        ok "$b present"
    else
        warn "$b not installed — needed for the auth steps printed at the end."
        warn "  install with: sudo apt-get install -y $b"
    fi
done

if [[ ! -d "$SANDBOX_ROOT" ]]; then
    fatal "$SANDBOX_ROOT does not exist. The admin must format and mount the"
    echo "          data disk first (SERVER.md, \"Format and mount the data disk\")."
elif [[ ! -d "${SANDBOX_ROOT}/users" ]]; then
    fatal "${SANDBOX_ROOT}/users does not exist. One-time admin step:"
    echo "            sudo mkdir -p ${SANDBOX_ROOT}/users"
    echo "            sudo chmod 1777 ${SANDBOX_ROOT}/users"
elif [[ ! -w "${SANDBOX_ROOT}/users" ]]; then
    # This is the check that keeps user setup root-free. Without a writable
    # parent, every new user would need an admin to mkdir for them.
    fatal "${SANDBOX_ROOT}/users is not writable by you, so you cannot create"
    echo "          your own directory. One-time admin step:"
    echo "            sudo chmod 1777 ${SANDBOX_ROOT}/users"
    echo "          The sticky bit means you can create your own directory but"
    echo "          cannot remove or rename anyone else's."
else
    ok "${SANDBOX_ROOT}/users is writable — no root needed for your setup"
fi

if [[ "$FAIL" == "1" ]]; then
    echo
    echo "${RED}Stopping: fix the failures above first.${RST}"
    exit 1
fi

# ------------------------------------------------------------------ dirs ----
echo
echo "=== directories on ${SANDBOX_ROOT} ==="
# Everything per-user lives on the data disk, NOT in $HOME: home directories are
# on the small boot disk, and the image plus workspaces do not fit there.
for d in "${USER_ROOT}/workspace" "${USER_ROOT}/state" "${USER_ROOT}/shared" \
         "${USER_ROOT}/fiss-mcp" "${USER_ROOT}/context"; do
    if [[ -d "$d" ]]; then
        ok "exists: $d"
    else
        mkdir -p "$d" && ok "created: $d"
    fi
done
chmod 700 "$USER_ROOT"
ok "chmod 700 ${USER_ROOT}"
warn "700 stops other users reading this directly, but NOT via sudo. On a GCP"
warn "VM every metadata-SSH-key user is in google-sudoers, so anyone who can log"
warn "in can read your Claude token and gcloud credentials. Treat co-users as"
warn "trusted, or restrict who has a key."

# Seed the shared-state dir from the repo so this user gets working hooks,
# settings and the vendored plugins. Copied, not symlinked: the container mounts
# it read-write, and users must not write into a shared checkout.
if [[ ! -e "${USER_ROOT}/shared/.claude" ]]; then
    cp -a "${REPO_ROOT}/claude-sandbox-shared/.claude" "${USER_ROOT}/shared/.claude"
    ok "seeded ${USER_ROOT}/shared/.claude from the checkout"
else
    ok "shared state already present (left alone)"
fi

# -------------------------------------------------------- workspace repos ---
echo
echo "=== workspace repos ==="
# Clone the repos people are actually here to work on, so the very first launch
# opens onto something instead of an empty /workspace. This used to be a manual
# step AFTER the launch step, which is the wrong order: the first thing a new user
# saw inside the sandbox was nothing to do.
#
# Deliberately HTTPS and deliberately here, before the GitHub step: both repos are
# public, so cloning needs no credentials. Pushing later does, which is what
# `gh auth login` + `gh auth setup-git` are for -- and it stays a host-side action.
# The container never gets a credential either way.
#
# NOT shallow. --depth 1 would save ~180 MB per user and break the documented
# review-then-push workflow, which needs `git log origin/HEAD..HEAD` and real
# branch history. Measured full-clone cost is ~234 MB (warp) + ~99 MB (warp-tools);
# against a 200 GB data disk that is the cheaper side of the trade.
#
# Set CLAUDE_SANDBOX_SEED_REPOS to a space-separated list of clone URLs to change
# this, or to the empty string to skip cloning entirely.
SEED_REPOS="${CLAUDE_SANDBOX_SEED_REPOS-https://github.com/broadinstitute/warp https://github.com/broadinstitute/warp-tools https://github.com/broadinstitute/optimus_starsolo_multiome https://github.com/broadinstitute/warp-private}"

if [[ -z "${SEED_REPOS// /}" ]]; then
    ok "CLAUDE_SANDBOX_SEED_REPOS is empty — skipping repo clone"
else
    for url in $SEED_REPOS; do
        name="$(basename "${url%.git}")"
        dest="${USER_ROOT}/workspace/${name}"
        if [[ -d "$dest" ]]; then
            ok "already present: workspace/${name} (left alone)"
            continue
        fi
        echo "          cloning ${name} ..."
        # Non-fatal: a network hiccup or a repo that has gone private must not
        # abort provisioning, because everything above it has already succeeded and
        # a user can clone by hand.
        if env GIT_TERMINAL_PROMPT=0 git clone --quiet "$url" "$dest"; then
            ok "cloned workspace/${name} ($(du -sh "$dest" | cut -f1), branch $(git -C "$dest" rev-parse --abbrev-ref HEAD))"
        else
            warn "could not clone ${url} — clone it by hand into ${USER_ROOT}/workspace"
        fi
    done
fi

# --------------------------------------------------------------- env file ---
echo
echo "=== env file ==="
# One location, always: the user's own tree. It is always writable, it is on the
# data disk so it survives a boot-disk rebuild, and it keeps per-user files out of
# a shared checkout. An earlier version put it in the checkout when that happened
# to be writable, so two users on one host could have it in different places.
ENV_FILE="${USER_ROOT}/env.${USER}.sh"
LEGACY_ENV="${REPO_ROOT}/env.${USER}.sh"

# CONTEXT_DIR used to default to ${REPO_ROOT}/context_reference — the ADMIN's
# checkout, read-only to everyone else. Users who provisioned before that changed
# have a /context they cannot write to, which defeats the one mount that exists for
# handing files to the agent. Repair it rather than leaving them to notice.
repoint_context_dir() {
    local f="$1"
    grep -q "^export CLAUDE_SANDBOX_CONTEXT_DIR=${REPO_ROOT}" "$f" 2>/dev/null || return 0
    sed -i "s|^export CLAUDE_SANDBOX_CONTEXT_DIR=.*|export CLAUDE_SANDBOX_CONTEXT_DIR=${USER_ROOT}/context|" "$f"
    ok "repointed CLAUDE_SANDBOX_CONTEXT_DIR to ${USER_ROOT}/context"
    warn "  it pointed into the shared checkout, which you cannot write to."
    warn "  Put files for the agent in ${USER_ROOT}/context (appears as /context, read-only)."
}

if [[ -e "$ENV_FILE" ]]; then
    ok "env file already exists, left alone: ${ENV_FILE}"
    repoint_context_dir "$ENV_FILE"
elif [[ -e "$LEGACY_ENV" ]]; then
    # An older version wrote the env file into the checkout. That file is the
    # user's ONLY config, so migrate it instead of rendering a fresh one on top:
    # rendering first would silently discard whatever they had customised, and
    # telling them to delete the old copy before migrating it -- which this script
    # used to do -- would destroy their setup outright.
    cp -a "$LEGACY_ENV" "$ENV_FILE"
    ok "migrated your env file out of the shared checkout:"
    ok "  ${LEGACY_ENV} -> ${ENV_FILE}"
    repoint_context_dir "$ENV_FILE"
    warn "the old copy is still in the checkout. Launch once from the new one, then"
    warn "  remove it:  rm ${LEGACY_ENV}"
    warn "  Leaving it is a footgun: anyone who sources it gets YOUR paths."
else
    sed -e "s|__USER_ROOT__|${USER_ROOT}|g" \
        -e "s|__REPO_ROOT__|${REPO_ROOT}|g" \
        -e "s|__USER__|${USER}|g" \
        "${REPO_ROOT}/env.gcp.example.sh" > "$ENV_FILE"
    ok "wrote ${ENV_FILE}"
fi

# Leave a note in the context dir. Someone who has ssh'd in and is standing in an
# empty directory wondering what it is for should not have to find the README on
# GitHub. Written once, only while the directory is empty, so it never fights with
# real content.
if [[ -d "${USER_ROOT}/context" ]] && [[ -z "$(ls -A "${USER_ROOT}/context" 2>/dev/null)" ]]; then
    cat > "${USER_ROOT}/context/README.md" <<CTXNOTE
# Your read-only context directory

Drop files here for the agent to READ: plans, specs, notes, a data dictionary.
They appear inside the sandbox at \`/context/<name>\` and the mount is \`:ro\`, so the
agent cannot change or delete them. Refer to them in a prompt by that path, e.g.
\`/context/plan.md\`.

For files the agent should be able to EDIT, use \`${USER_ROOT}/workspace\` instead,
which appears as \`/workspace\`.

## Permissions

The agent runs as you, so anything you own is readable and nothing further is needed.
One combination fails, silently:

| Owner on the host | Mode | Agent can read it |
|---|---|---|
| you | 644 or 600 | yes |
| someone else (e.g. an admin used \`sudo cp\`) | 644 | yes |
| someone else | 600 | **NO** |

If a file was placed here by someone else and the agent cannot see it:

    chmod 644 <file>            # if you own it
    sudo chown ${USER}:${USER} <file>   # if you do not

Files you copy or upload yourself are already correct.
CTXNOTE
    ok "seeded ${USER_ROOT}/context/README.md explaining what the directory is for"
fi

# Shared reference material, if an admin has set some up. This is the right
# mechanism for "the same docs for everyone": one admin-owned directory, mounted
# read-only into every sandbox, instead of copying files into N per-user trees that
# are chmod 700 and therefore need sudo to write into.
#
# Enabled only when the directory actually EXISTS. The launcher treats a missing
# CLAUDE_SANDBOX_RO_MOUNTS path as fatal — it refuses to let the engine auto-create
# it — so shipping this enabled by default would break every launch on a host where
# no admin ever created it.
REFERENCE_DIR="${SANDBOX_ROOT}/reference"
if [[ -d "$REFERENCE_DIR" ]]; then
    if grep -q "^export CLAUDE_SANDBOX_RO_MOUNTS=" "$ENV_FILE"; then
        ok "you already set CLAUDE_SANDBOX_RO_MOUNTS — left alone"
    else
        # Replace the commented template line if present, else append.
        if grep -q "^#export CLAUDE_SANDBOX_RO_MOUNTS=" "$ENV_FILE"; then
            sed -i "s|^#export CLAUDE_SANDBOX_RO_MOUNTS=.*|export CLAUDE_SANDBOX_RO_MOUNTS=\"${REFERENCE_DIR}\"|" \
                "$ENV_FILE"
        else
            printf '\nexport CLAUDE_SANDBOX_RO_MOUNTS="%s"\n' "$REFERENCE_DIR" >> "$ENV_FILE"
        fi
        ok "shared reference dir found; mounted read-only at /read-only-reference/reference"
    fi
fi

# A shared, WRITABLE directory for handing work between users -- plans, findings,
# a scratch report. Everything else a user owns is chmod 700, and the plans the agent
# writes by itself land in ~/.claude/plans inside their own state dir, so without
# this there is no path from one person's agent to another person's eyes.
#
# Same existence gate as the reference dir, and for the same reason: the launcher
# treats a missing CLAUDE_SANDBOX_RW_MOUNTS path as fatal.
PLANS_DIR="${SANDBOX_ROOT}/plans"
if [[ -d "$PLANS_DIR" ]]; then
    if grep -q "^export CLAUDE_SANDBOX_RW_MOUNTS=" "$ENV_FILE"; then
        ok "you already set CLAUDE_SANDBOX_RW_MOUNTS — left alone"
    else
        if grep -q "^#export CLAUDE_SANDBOX_RW_MOUNTS=" "$ENV_FILE"; then
            sed -i "s|^#export CLAUDE_SANDBOX_RW_MOUNTS=.*|export CLAUDE_SANDBOX_RW_MOUNTS=\"${PLANS_DIR}\"|" \
                "$ENV_FILE"
        else
            printf '\nexport CLAUDE_SANDBOX_RW_MOUNTS="%s"\n' "$PLANS_DIR" >> "$ENV_FILE"
        fi
        ok "shared plans dir found; mounted read-write at /projects/plans"
        ok "  tell the agent to write there for anything colleagues should see;"
        ok "  its own plans go to ~/.claude/plans, which is private to you"
    fi
fi

# ------------------------------------------------------------- staleness ----
echo
echo "=== checkout freshness ==="
# The instructions printed at the end come from THIS checkout. If it is behind
# its remote, a user follows outdated steps and hits problems that were already
# fixed upstream -- which has happened repeatedly. Read-only check: fetch into
# FETCH_HEAD without touching any branch, so it is safe for a user who does not
# own the checkout.
# Deliberately `ls-remote`, not `fetch`. A shared checkout is owned by the admin,
# so a normal user has no write access to .git and `fetch` dies with
# "cannot open '.git/FETCH_HEAD': Permission denied" — measured. That would make
# this check useless for exactly the users who most need it. `ls-remote` queries
# the remote and writes nothing locally.
if [[ -d "${REPO_ROOT}/.git" ]]; then
    # -c safe.directory is required, not defensive. The shared checkout is owned
    # by the admin, and git refuses to run in a repository owned by another user:
    #   fatal: detected dubious ownership in repository at '<path>'
    # That applies to plain reads like rev-parse too, so without this the check
    # silently degrades to "could not reach the remote" for exactly the
    # non-owning users it exists to help. Passing it with -c affects this
    # invocation only and writes nothing to the user's gitconfig.
    _git=(git -c "safe.directory=${REPO_ROOT}" -C "$REPO_ROOT")
    _branch=$("${_git[@]}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    _local=$("${_git[@]}" rev-parse HEAD 2>/dev/null || true)
    _remote=$("${_git[@]}" ls-remote origin "refs/heads/${_branch}" 2>/dev/null | cut -f1)

    if [[ -z "$_remote" ]]; then
        warn "could not reach the remote to check if this checkout is current"
    elif [[ "$_local" != "$_remote" ]]; then
        warn "this checkout differs from origin/${_branch}."
        warn "  local  ${_local:0:8}"
        warn "  remote ${_remote:0:8}"
        warn "  The steps printed at the end come from THIS checkout, so some may"
        warn "  be out of date. This is not something you can fix unless you own"
        warn "  the checkout — a non-owner cannot pull it. Ask its owner to run:"
        warn "    git -C ${REPO_ROOT} pull && chmod -R a+rX ${REPO_ROOT}"
        warn "  then re-run this script."
    else
        ok "checkout matches origin/${_branch} (${_local:0:8})"
    fi
else
    warn "${REPO_ROOT} is not a git checkout; cannot check freshness"
fi

# ------------------------------------------------------- shared image store --
echo
echo "=== container image store ==="
IMAGE_STORE="${CLAUDE_SANDBOX_IMAGE_STORE:-${SANDBOX_ROOT}/imagestore}"
STORAGE_CONF="${HOME}/.config/containers/storage.conf"

if [[ -d "$IMAGE_STORE" ]]; then
    # Treat a storage.conf that references the store but lacks mount_program as
    # INCOMPLETE and rewrite it, rather than skipping. An earlier version of this
    # script wrote the file without mount_program, and the result is not a
    # cosmetic difference -- containers fail to start with
    #   Error: creating container storage: error during chown: remove
    #   usr/bin/bzcat: permission denied
    # because a rootless consumer cannot chown layers written by rootful podman.
    # Skipping on "additionalimagestores is present" left those users broken with
    # no indication why, and re-running the script did not repair them.
    if [[ -e "$STORAGE_CONF" ]] \
       && grep -q "additionalimagestores" "$STORAGE_CONF" \
       && ! grep -q "mount_program" "$STORAGE_CONF"; then
        warn "storage.conf references the image store but has no mount_program."
        warn "That combination fails at container start. Rewriting it."
        rm -f "$STORAGE_CONF"
    fi

    if [[ -e "$STORAGE_CONF" ]] && grep -q "additionalimagestores" "$STORAGE_CONF"; then
        ok "storage.conf already references an additional image store (with mount_program)"
    else
        if [[ -e "$STORAGE_CONF" ]]; then
            cp -a "$STORAGE_CONF" "${STORAGE_CONF}.bak"
            warn "existing storage.conf backed up to $(basename "${STORAGE_CONF}").bak"
        fi
        mkdir -p "$(dirname "$STORAGE_CONF")"
        cat > "$STORAGE_CONF" <<CONF
# Written by scripts/provision-sandbox-user.sh.
#
# The sandbox image is ~9.0 GB. additionalimagestores exposes one shared,
# root-populated copy read-only, so this account does not hold its own: podman
# lists it as R/O=true, runs it without copying, and this user's own graphroot
# stays at a couple of hundred KB.
#
# Consequence, and it is intended: you cannot rebuild or modify the image. An
# admin owns it via scripts/build-shared-image.sh, so everyone provably runs the
# same one.
#
# mount_program is REQUIRED, not a tuning knob. The shared store is populated by
# ROOTFUL podman, whose overlay layers carry trusted.overlay.* xattrs. A rootless
# consumer mounts overlay with userxattr and cannot interpret those, so the
# merged rootfs comes up incomplete and the container dies with something
# thoroughly unhelpful:
#
#   crun: open '.../merged/run/.containerenv': No such file or directory:
#   OCI runtime attempted to invoke a command that was not found
#
# The image still LISTS fine in that state, because its metadata is readable —
# only running fails, which makes it easy to believe the store is working when it
# is not. fuse-overlayfs resolves layer ownership in userspace instead of relying
# on kernel xattr semantics, and fixes it. Verified end to end on a second,
# sudo-less account: image R/O=true, \`claude --version\` runs, local store 196K.
[storage]
driver = "overlay"

[storage.options]
additionalimagestores = [ "${IMAGE_STORE}" ]

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
CONF
        ok "wrote ${STORAGE_CONF} -> ${IMAGE_STORE}"
    fi

    if podman images --format '{{.Repository}}' 2>/dev/null | grep -q claude-sandbox; then
        ok "claude-sandbox image visible from the shared store"
    else
        warn "shared store exists but no claude-sandbox image is visible."
        warn "An admin may still need to run: sudo ./scripts/build-shared-image.sh"
    fi
else
    warn "no shared image store at ${IMAGE_STORE}."
    warn "You will need your own copy of the image (~9.0 GB), or ask an admin to"
    warn "run: sudo ./scripts/build-shared-image.sh"
fi

# ---------------------------------------------------------------- linger ----
echo
echo "=== linger ==="
# Without this, systemd tears down your user slice at logout and kills both the
# container and the host-side fiss-mcp — so a long agent run dies when you
# disconnect.
if [[ "$(loginctl show-user "$USER" --property=Linger --value 2>/dev/null)" == "yes" ]]; then
    ok "linger already enabled"
elif loginctl enable-linger "$USER" 2>/dev/null; then
    ok "linger enabled (your containers survive logout)"
else
    warn "could not enable linger; run: sudo loginctl enable-linger $USER"
fi

# ------------------------------------------------------------- what's left --
echo
echo "${GRN}Step 1 done.${RST}  This script is step 1 of \"Per-user setup\" in USER-SETUP.md."
echo
echo "Nothing was authenticated. Steps 2-5 are yours, and USER-SETUP.md has the"
echo "details and the reasons — this script does not repeat them, so the two"
echo "cannot drift apart."
cat <<EOF

Your paths, which USER-SETUP.md cannot know:

  env file    ${ENV_FILE}
  workspace   ${USER_ROOT}/workspace     (mounted inside as /workspace, rw)
  context     ${USER_ROOT}/context       (mounted inside as /context, READ-ONLY)
  state       ${USER_ROOT}/state
  repo        ${REPO_ROOT}

What is left, per USER-SETUP.md:

  Step 2  Google Cloud     gcloud auth login + application-default login
                           (both --no-launch-browser; answer Y to the
                           "not necessary" prompt on a GCE VM)
  Step 3  GitHub           gh auth login --web, THEN gh auth setup-git
  Step 4  fiss-mcp venv    cd ${REPO_ROOT} && source ${ENV_FILE} && ./setup_host.sh
  Step 5  Launch           ./run_claude_docker.sh
                           first run asks you to pick a login method: choose the
                           first one, then open the URL it prints and paste the code

Your workspace is already populated, so step 5 opens onto real code. Add more
repos any time with:

  cd ${USER_ROOT}/workspace && git clone <url>

Read USER-SETUP.md before running steps 2 and 3. Both have non-obvious failure
modes that cost real time if you skip the explanation.
EOF
