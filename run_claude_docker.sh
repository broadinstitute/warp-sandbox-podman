#!/usr/bin/env bash
set -euo pipefail

DOCKER_IMAGE_VERSION=latest
DOCKER_IMAGE_VERSION=0.0.1

# Here we set our directories and credentials so we can authenticate and have
# a proper sandbox.  It's VERY important that we don't let these agents run
# freely around our machine.
# `:-` default — under `set -u`, a bare ${VAR} on an unset var errors with
# "unbound variable" before our friendly message ever runs. ${VAR:-} expands
# to empty so the -z test fires the helpful branch instead.
if [[ -z "${CLAUDE_SANDBOX_PROJECTS_DIR:-}" ]] || [[ ! -d "${CLAUDE_SANDBOX_PROJECTS_DIR}" ]]; then
    echo "CRITICAL ERROR: CLAUDE_SANDBOX_PROJECTS_DIR is not set, is empty, or does not exist." >&2
    echo "                You must set this env var before starting the docker image." >&2
    echo "                Try: source env.example.sh   (or your env.<INSTANCE>.sh)" >&2
    exit 1
fi

if [[ -z "${CLAUDE_SANDBOX_CONTEXT_DIR:-}" ]] || [[ ! -d "${CLAUDE_SANDBOX_CONTEXT_DIR}" ]]; then
    echo "CRITICAL ERROR: CLAUDE_SANDBOX_CONTEXT_DIR is not set, is empty, or does not exist." >&2
    echo "                You must set this env var before starting the docker image." >&2
    echo "                Try: source env.example.sh   (or your env.<INSTANCE>.sh)" >&2
    exit 1
fi

if [[ -z "${CLAUDE_SANDBOX_INSTANCE:-}" ]]; then
    echo "CRITICAL ERROR: CLAUDE_SANDBOX_INSTANCE is not set, does not exist, or is empty." >&2
    echo "                Each sandbox needs a unique instance ID so concurrent" >&2
    echo "                inner dockerds don't share /var/lib/docker." >&2
    echo "                Try: source env.example.sh   (or your env.<INSTANCE>.sh)" >&2
    exit 1
fi

# Which agent the container runs. Same image, same mounts for /workspace and
# /context, same host-side fiss-mcp; what differs is the agent's own state:
#   claude  Claude Code (default). Mounts the Claude state described below.
#   agy     Antigravity CLI. Mounts ONLY agy's state (~/.gemini,
#           ~/.config/antigravity), never Claude's, so neither agent can read the
#           other's sign-in token.
#   shell   bash with the Claude mounts, for debugging the setup.
SANDBOX_AGENT="${SANDBOX_AGENT:-claude}"
case "$SANDBOX_AGENT" in
    claude|agy|shell) ;;
    *) echo "CRITICAL ERROR: SANDBOX_AGENT must be claude, agy or shell (got '${SANDBOX_AGENT}')." >&2
       exit 1 ;;
esac

# Per-instance suffix. Each sandbox gets its own DinD volume, container name,
# and persistent-state directory so concurrent instances don't fight over
# /var/lib/docker.
INSTANCE_SUFFIX="-${CLAUDE_SANDBOX_INSTANCE}"
# Non-default agents get their own container name, so a Claude session and an
# agy session can run side by side against the same /workspace. The
# "already running" guard below is per name, i.e. per agent.
CONTAINER_NAME="claude-sandbox-${CLAUDE_SANDBOX_INSTANCE}"
[[ "$SANDBOX_AGENT" == "claude" ]] || CONTAINER_NAME+="-${SANDBOX_AGENT}"

# Two layout modes, picked by CLAUDE_SANDBOX_USE_SHARED:
#
#   0 (default) — full per-instance state at $SANDBOX_HOME/.claude. Settings,
#                 skills, plugins, sessions, hot dirs all live here. One copy
#                 per instance. Original layout, fully self-contained.
#
#   1           — split layout. $SHARED_HOME holds settings/skills/plugins/
#                 hooks/projects/plans/tasks/sessions, one copy across all
#                 shared-mode instances. $SANDBOX_HOME holds write-hot dirs
#                 (cache, file-history, backups, shell-snapshots,
#                 session-env, history.jsonl) and .claude.json. Per-instance
#                 overlays bind-mount on top of the shared .claude.
#                 .claude.json stays per-instance because it is rewritten
#                 whole on every change and holds per-project state
#                 (allowedTools, mcpServers, history) that would race or
#                 collide if shared.
#
# Existing per-instance dirs are untouched when USE_SHARED=0, so old instances
# keep working exactly as before. Opt new instances into shared mode by
# exporting CLAUDE_SANDBOX_USE_SHARED=1 in their env.<INSTANCE>.sh.
USE_SHARED="${CLAUDE_SANDBOX_USE_SHARED:-0}"

# Resolve the script's actual location, following symlinks, so SCRIPT_DIR
# points at the repo regardless of where the caller invoked from. Without
# `readlink -f` a `./run_claude_docker.sh` invocation from a directory that
# contains a *symlink* (or a copy) of the script resolved SCRIPT_DIR to the
# caller's CWD, redirecting shared state + persistent state lookups to a
# location that has none of the repo's content.
# Resolve SCRIPT_DIR by walking the symlink chain by hand rather than with
# `readlink -f`. Kept from upstream: it costs nothing and avoids depending on
# GNU readlink semantics.
__resolve_dir() {
    local src=${BASH_SOURCE[0]}
    while [ -L "$src" ]; do
        local d
        d=$(cd -P "$(dirname "$src")" && pwd)
        src=$(readlink "$src")
        [[ $src != /* ]] && src=$d/$src
    done
    cd -P "$(dirname "$src")" && pwd
}
SCRIPT_DIR=$(__resolve_dir)

# Container engine. `docker` keeps the original behaviour byte-for-byte;
# `podman` selects the rootless-podman path used on Fedora/RHEL-family hosts
# where Docker is not installed and sysbox-runc does not exist.
#
# What the podman path changes, and why:
#
#   * No --runtime=sysbox-runc. Sysbox is a Docker-only OCI runtime shim
#     (it needs sysbox-mgr/sysbox-fs daemons and a rootful dockerd). There
#     is no podman equivalent. Rootless podman's own user namespace already
#     puts the host filesystem out of reach, which is the isolation property
#     this sandbox actually depends on.
#
#   * No Docker-in-Docker. Without sysbox a nested dockerd cannot mount
#     overlay2, so SANDBOX_HAS_DIND=0 and the DinD volume is not created or
#     mounted. start_dockerd.sh self-skips on that flag.
#
#   * --userns=keep-id:uid=<IMAGE_UID>. Rootless podman maps the invoking
#     user to container root by default, which would land every file the
#     agent writes to /workspace under a high subuid the host user cannot
#     read. keep-id pins the invoker onto the image's baked `claude` uid
#     instead, so /workspace files come out owned by the invoking user.
#     Container uid 0 still resolves through the subuid range, so the
#     image's passwordless sudo keeps working.
#
#   * HOST_UID / HOST_GID are NOT forwarded. keep-id has already placed us
#     on the right uid before the entrypoint runs, and the usermod/groupmod
#     in uid-fixup-entrypoint.sh would need real root. Leaving both unset
#     makes that entrypoint a no-op that falls through to `exec gosu claude`.
#
#   * Host services are reached over a pasta port forward rather than
#     host.docker.internal — see resolve_host_bind_ip below.
ENGINE="${CLAUDE_SANDBOX_ENGINE:-podman}"
IS_PODMAN=0
[[ "$ENGINE" == *podman* ]] && IS_PODMAN=1

if ! command -v "$ENGINE" >/dev/null 2>&1; then
    echo "CRITICAL ERROR: container engine '$ENGINE' not found on PATH." >&2
    echo "                Set CLAUDE_SANDBOX_ENGINE to docker or podman." >&2
    exit 1
fi

# The uid/gid baked into the image for the `claude` user (docker/Dockerfile).
# Only consulted on the podman path, to build the keep-id mapping.
SANDBOX_IMAGE_UID="${CLAUDE_SANDBOX_IMAGE_UID:-1015}"

# Image reference. podman stores locally-built images under the `localhost/`
# prefix and runs with short-name-mode="enforcing" on Fedora/RHEL hosts, so
# qualify it there. Docker keeps the bare tag it has always used.
if [[ "$IS_PODMAN" == "1" ]]; then
    SANDBOX_IMAGE_REF="localhost/claude-sandbox:${DOCKER_IMAGE_VERSION}"
else
    SANDBOX_IMAGE_REF="claude-sandbox:${DOCKER_IMAGE_VERSION}"
fi

# Extra flags accumulated for the podman path (pasta port forwards).
PODMAN_NET_FLAGS=()
PASTA_FORWARDS=()

# Pick the IP that host-side services (fiss-mcp, vertex_proxy) should bind
# to so the container can reach them via host.docker.internal.
#
# Linux: bind only to the docker bridge gateway IP — the same address the
# container reaches us at via `host.docker.internal:host-gateway`. Keeps
# the listener off external interfaces (eth0/wlan0) without an iptables
# fence. Fail fast if the bridge IP can't be determined.
#
#
# rootless podman: bind to 127.0.0.1 and reach it from the container through a
# pasta port forward (`--network=pasta:-T,<port>`), which maps that port on the
# container's loopback to the same port on the host's loopback. Measured on
# this host with a loopback-only listener:
#     pasta -T <port>  -> reachable
#     host.containers.internal            -> connection refused
#     host.docker.internal:host-gateway   -> connection refused
# Both names resolve to a non-loopback host address, so they cannot see a
# listener bound to 127.0.0.1. Widening the bind to reach them would put the
# listener on an external interface, which is exactly what the Docker path
# avoids by using the bridge gateway. The pasta forward keeps the listener
# strictly on loopback — a tighter result than the Docker path, not a
# looser one. register_pasta_forward() below records the ports to forward.
resolve_host_bind_ip() {
    if [[ "$IS_PODMAN" == "1" ]]; then
        printf '127.0.0.1'
        return 0
    fi
    local ip
    ip=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)
    if [[ -z "$ip" ]]; then
        echo "host bind: could not determine docker bridge gateway IP via" >&2
        echo "           \`docker network inspect bridge\`. Refusing to bind 0.0.0.0." >&2
        echo "           Verify docker is running and the default bridge exists." >&2
        return 1
    fi
    printf '%s' "$ip"
}

# Pick the first free TCP port at or after $2 on $1, scanning up to $3 slots.
# Prints the port, or returns 1 if none is free.
#
# Multi-user hosts need the scan. The base port is hashed, and a hash over a
# 1000-slot space collides at a rate no amount of care avoids; the previous
# behaviour was to print "already in use" and exit, which on a shared box turns
# one unlucky hash into a user who simply cannot launch.
find_free_port() {
    local host="$1" base="$2" span="${3:-32}" p
    for (( p = base; p < base + span; p++ )); do
        if ! (echo > "/dev/tcp/${host}/${p}") 2>/dev/null; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 1
}

# Record a host port that the container must be able to reach, and set
# REGISTERED_HOSTNAME to the hostname the container should use to reach it.
# On the podman path this queues a pasta forward and yields 127.0.0.1;
# elsewhere it yields host.docker.internal, preserving the original URLs.
#
# Sets a global instead of printing, and must NOT be called via $(...):
# command substitution runs in a subshell, so the PASTA_FORWARDS append would
# be discarded and no forward would ever reach the run command line.
REGISTERED_HOSTNAME=""
register_pasta_forward() {
    local port="$1"
    if [[ "$IS_PODMAN" == "1" ]]; then
        PASTA_FORWARDS+=("$port")
        REGISTERED_HOSTNAME="127.0.0.1"
    else
        REGISTERED_HOSTNAME="host.docker.internal"
    fi
}
PERSISTENT_STATE_DIR="${SCRIPT_DIR}/claude-sandbox-persistent-state${INSTANCE_SUFFIX}"
SHARED_STATE_DIR="${SCRIPT_DIR}/claude-sandbox-shared"
SANDBOX_HOME="${CLAUDE_SANDBOX_HOME:-$PERSISTENT_STATE_DIR}"
SHARED_HOME="${CLAUDE_SANDBOX_SHARED:-$SHARED_STATE_DIR}"

if [[ "$SANDBOX_HOME" != /* ]]; then
    echo "CRITICAL ERROR: CLAUDE_SANDBOX_HOME must be an absolute path." >&2
    echo "                Got: '$SANDBOX_HOME'" >&2
    exit 1
fi
if [[ "$USE_SHARED" == "1" && "$SHARED_HOME" != /* ]]; then
    echo "CRITICAL ERROR: CLAUDE_SANDBOX_SHARED must be an absolute path." >&2
    echo "                Got: '$SHARED_HOME'" >&2
    exit 1
fi

# Defaults committed in the repo so a fresh clone has working hooks +
# settings on first launch. Source: claude-sandbox-shared/.claude/. Shared
# mode (USE_SHARED=1) bind-mounts the whole tracked dir; per-instance mode
# (USE_SHARED=0) copies these as seed on first launch only.
DEFAULT_HOOKS_DIR="${SCRIPT_DIR}/claude-sandbox-shared/.claude/hooks"
DEFAULT_SETTINGS_FILE="${SCRIPT_DIR}/claude-sandbox-shared/.claude/settings.json"

# Seed hooks dir from DEFAULT_HOOKS_DIR if target doesn't exist yet. First
# launch of a new instance gets the committed defaults; subsequent launches
# leave user customizations alone.
seed_hooks() {
  local target="$1"
  if [[ ! -d "$target" && -d "$DEFAULT_HOOKS_DIR" ]]; then
    mkdir -p "$(dirname "$target")"
    cp -a "$DEFAULT_HOOKS_DIR" "$target"
  fi
}

# Seed settings.json from the tracked default if target doesn't exist yet.
# Same semantics as seed_hooks — first-launch only, never overwrites user
# customization. Source is the in-repo tracked file, not SHARED_HOME (which
# the user may have remapped to a custom location).
seed_settings() {
  local target="$1"
  if [[ ! -f "$target" && -f "$DEFAULT_SETTINGS_FILE" ]]; then
    mkdir -p "$(dirname "$target")"
    cp -a "$DEFAULT_SETTINGS_FILE" "$target"
  fi
}

if [[ "$USE_SHARED" == "1" ]]; then
    # --- shared layout ---------------------------------------------------
    # SHARED_HOME defaults to the tracked claude-sandbox-shared/ in the repo,
    # so settings.json + hooks/ are already present from the clone. No
    # seeding needed unless the user remapped CLAUDE_SANDBOX_SHARED to an
    # empty dir; seed_hooks/seed_settings handle that as a courtesy.
    mkdir -p "$SHARED_HOME/.claude"
    seed_hooks "$SHARED_HOME/.claude/hooks"
    seed_settings "$SHARED_HOME/.claude/settings.json"

    # Per-instance hot-state dirs. Bind-mount sources must exist before
    # `docker run` or Docker creates them as the wrong type (dir vs file).
    # .claude.json stays per-instance: it's rewritten whole on every change
    # and holds per-project allowedTools/mcpServers/history that race under
    # concurrent shared-mode launches.
    mkdir -p \
      "$SANDBOX_HOME/.claude/cache" \
      "$SANDBOX_HOME/.claude/file-history" \
      "$SANDBOX_HOME/.claude/backups" \
      "$SANDBOX_HOME/.claude/shell-snapshots" \
      "$SANDBOX_HOME/.claude/session-env" \
      "$SANDBOX_HOME/.claude/projects"
    touch "$SANDBOX_HOME/.claude/history.jsonl"
    [ -s "$SANDBOX_HOME/.claude.json" ] || echo '{}' > "$SANDBOX_HOME/.claude.json"

    # history.jsonl redirect — keep per-instance without nesting a file
    # mount inside the shared dir mount. In the shared .claude/ dir, it is a
    # SYMLINK to /per-instance-history.jsonl — a container-only path. Each
    # instance bind-mounts ITS history.jsonl at that top-level path, so
    # ~/.claude/history.jsonl → symlink → /per-instance-history.jsonl →
    # per-instance host file. Keeping the mount at the top level, un-nested,
    # is what makes the redirect work; the earlier nested file mount did not
    # give reliable per-instance semantics.
    SHARED_HIST="$SHARED_HOME/.claude/history.jsonl"
    if [[ ! -L "$SHARED_HIST" ]]; then
        # Remove any pre-existing file/dir at the path (legacy state from
        # before the redirect). Replace with the symlink. Idempotent: a
        # subsequent launch finds the symlink already in place and skips.
        rm -rf "$SHARED_HIST"
        ln -s /per-instance-history.jsonl "$SHARED_HIST"
    fi
    echo "layout: shared (SHARED_HOME=${SHARED_HOME}, hot=${SANDBOX_HOME})"
else
    # --- original per-instance layout ------------------------------------
    mkdir -p "$SANDBOX_HOME/.claude"
    seed_hooks "$SANDBOX_HOME/.claude/hooks"
    seed_settings "$SANDBOX_HOME/.claude/settings.json"
    [ -s "$SANDBOX_HOME/.claude.json" ] || echo '{}' > "$SANDBOX_HOME/.claude.json"
    echo "layout: per-instance (SANDBOX_HOME=${SANDBOX_HOME})"
fi

# Defensive sanity check: any of these paths existing as a DIRECTORY is a
# silent killer. They're supposed to be regular files. The trap appears
# when an earlier `docker run -v <host_file>:<container_file>` ran without
# the host file existing — Docker creates the container destination as a
# directory by default, and that directory then persists inside whatever
# parent directory bind mount it landed in (e.g. the shared .claude/).
# Once present, claude code can't write `.credentials.json` because a
# directory with that name is in the way; /login appears to succeed in
# memory but the on-disk write fails. Same shape for `.claude.json`.
#
# Catch it here and shriek rather than letting the user debug another
# silent /login round trip. NEVER auto-rm — rm-on-someone-else's-state-
# dir is a footgun, and a real directory at these paths only happens via
# this bug, so the safe thing is to halt and ask.
#
# Prevention going forward: we don't bind-mount any single host file
# whose existence isn't pre-guaranteed by this script. The host
# credentials file mount that originally created this trap was removed
# in c7b0cab. This check is defense-in-depth against leftover state from
# the old code path and against any future regression.
check_not_directory() {
    local path="$1"
    if [ -d "$path" ]; then
        local RED=$'\033[1;31m' YEL=$'\033[1;33m' RST=$'\033[0m'
        echo
        echo "${RED}===== LAUNCH ABORTED: directory where a file should be =====${RST}"
        echo "${YEL}Path:    $path${RST}"
        echo "${YEL}Found:   directory${RST}"
        echo "${YEL}Wanted:  regular file (or absent)${RST}"
        echo
        echo "${YEL}This is leftover state from an older sandbox launcher that bind-${RST}"
        echo "${YEL}mounted a host file source that did not exist. Docker auto-created${RST}"
        echo "${YEL}the destination as a directory and that directory persisted inside${RST}"
        echo "${YEL}one of the directory bind mounts. claude code cannot write the file${RST}"
        echo "${YEL}while a directory blocks the path, so /login fails silently.${RST}"
        echo
        echo "${YEL}Fix:${RST}"
        echo "${YEL}    rm -rf '$path'${RST}"
        echo "${YEL}Then relaunch.${RST}"
        echo "${RED}=============================================================${RST}"
        echo
        exit 1
    fi
}
for candidate in \
    "$SHARED_HOME/.claude/.credentials.json" \
    "$SHARED_HOME/.claude.json" \
    "$SANDBOX_HOME/.claude/.credentials.json" \
    "$SANDBOX_HOME/.claude.json" ; do
    check_not_directory "$candidate"
done

# Refuse to launch if this instance's DinD volume is already in use — two
# dockerds writing the same /var/lib/docker corrupt the store.
DIND_VOLUME="claude-dind-lib${INSTANCE_SUFFIX}"
if [[ "$IS_PODMAN" == "1" ]]; then
    # No DinD on the podman path, so there is no shared /var/lib/docker to
    # corrupt. Guard on the container name instead — that is what actually
    # collides between two launches of the same instance.
    in_use=$("$ENGINE" ps -q --filter "name=^${CONTAINER_NAME}$")
    if [ -n "$in_use" ]; then
        echo "Error: instance '${CLAUDE_SANDBOX_INSTANCE}' is already running:" >&2
        "$ENGINE" ps --filter "name=^${CONTAINER_NAME}$" \
            --format '  {{.ID}}  {{.Names}}  ({{.Status}})' >&2
        echo "Pick a different CLAUDE_SANDBOX_INSTANCE to launch a parallel sandbox." >&2
        echo "If no session of yours is using it (sandbox status, tmux ls), stop it with:" >&2
        echo "    $ENGINE stop ${CONTAINER_NAME}" >&2
        exit 1
    fi
else
    in_use=$(docker ps -q --filter "volume=${DIND_VOLUME}")
    if [ -n "$in_use" ]; then
        echo "Error: instance '${CLAUDE_SANDBOX_INSTANCE}' is already running:" >&2
        docker ps --filter "volume=${DIND_VOLUME}" \
            --format '  {{.ID}}  {{.Names}}  ({{.Status}})' >&2
        echo "Pick a different CLAUDE_SANDBOX_INSTANCE to launch a parallel sandbox." >&2
        exit 1
    fi
fi

# Build the mount args based on layout. Later mounts shadow earlier ones, so
# in shared mode the per-instance hot dirs override the shared parent.
MOUNTS=( -v "${CLAUDE_SANDBOX_PROJECTS_DIR}:/workspace" )
if [[ "$SANDBOX_AGENT" == "agy" ]]; then
    # agy's state lives beside .claude in the same state directory (the per-user
    # shared dir in shared mode), so it is per user, survives relaunches and VM
    # rebuilds, and is backed up with everything else. Created here because a
    # bind-mount source must exist before `run`.
    AGY_STATE_BASE="$([[ "$USE_SHARED" == "1" ]] && echo "$SHARED_HOME" || echo "$SANDBOX_HOME")"
    mkdir -p "${AGY_STATE_BASE}/.gemini" "${AGY_STATE_BASE}/.config/antigravity"
    MOUNTS+=(
      -v "${AGY_STATE_BASE}/.gemini:/home/claude/.gemini"
      -v "${AGY_STATE_BASE}/.config/antigravity:/home/claude/.config/antigravity"
    )
    echo "agent: agy  (state ${AGY_STATE_BASE}/.gemini)"
elif [[ "$USE_SHARED" == "1" ]]; then
    MOUNTS+=(
      -v "${SHARED_HOME}/.claude:/home/claude/.claude"
      -v "${SANDBOX_HOME}/.claude.json:/home/claude/.claude.json"
      -v "${SANDBOX_HOME}/.claude/cache:/home/claude/.claude/cache"
      -v "${SANDBOX_HOME}/.claude/file-history:/home/claude/.claude/file-history"
      -v "${SANDBOX_HOME}/.claude/backups:/home/claude/.claude/backups"
      -v "${SANDBOX_HOME}/.claude/shell-snapshots:/home/claude/.claude/shell-snapshots"
      -v "${SANDBOX_HOME}/.claude/session-env:/home/claude/.claude/session-env"
      -v "${SANDBOX_HOME}/.claude/projects:/home/claude/.claude/projects"
      # Per-instance history.jsonl reached via the shared-dir symlink
      # `~/.claude/history.jsonl -> /per-instance-history.jsonl`. The mount
      # target is at the container's top level, NOT nested inside the shared
      # .claude/ dir mount, which keeps it a plain file bind.
      -v "${SANDBOX_HOME}/.claude/history.jsonl:/per-instance-history.jsonl"
    )
else
    MOUNTS+=(
      -v "${SANDBOX_HOME}/.claude:/home/claude/.claude"
      -v "${SANDBOX_HOME}/.claude.json:/home/claude/.claude.json"
    )
fi
MOUNTS+=(
  # No host credentials file bind-mounted. Each sandbox does its own
  # /login on first launch and stores the resulting token inside its
  # state dir's .claude/ (shared dir in USE_SHARED=1, per-instance dir
  # otherwise) — both of which are directory bind mounts where claude
  # code's atomic rename(2) works fine. Earlier attempts to bind the
  # host's ~/.claude/.credentials.json directly broke rename and
  # silently dropped post-/login tokens.
  # :ro enforced at the mount. The README describes /context as a "read-only
  # context dir", but without this flag the bind was writable, so the agent
  # could write back into the host directory it points at — by default the
  # repo's own context_reference/, i.e. inside the checkout. That matters most
  # in bypassPermissions mode, where Claude Code's protected-path guard is
  # explicitly disabled and nothing above the mount stops the write.
  # MS_RDONLY makes it fail at the syscall, independent of permission mode.
  -v "${CLAUDE_SANDBOX_CONTEXT_DIR}:/context:ro"
)
# The DinD volume only exists to give a nested dockerd its own
# /var/lib/docker. There is no nested dockerd on the podman path, so mounting
# it would just create a stray named volume.
if [[ "$IS_PODMAN" != "1" ]]; then
  MOUNTS+=( -v "${DIND_VOLUME}:/var/lib/docker" )
fi

# Optional caller-supplied read-only mounts. Space-separated list of
# host DIRECTORIES in CLAUDE_SANDBOX_RO_MOUNTS — no container path; the
# launcher picks one. Each host dir is mounted at
# /read-only-reference/<name>:ro inside the container, where <name>
# defaults to the host basename. On basename collision, the launcher
# prepends parent directory segments joined by underscores until every
# name is unique (e.g. /a/b/data + /x/y/data → b_data and y_data).
#
# Use for reference datasets, shared corpora, system config the agent
# should read but never mutate. Host path must already exist; we refuse
# to launch otherwise so Docker doesn't auto-create it as a directory
# (same trap the `check_not_directory` guard above protects against).
#
# Example env.<INSTANCE>.sh:
#   export CLAUDE_SANDBOX_RO_MOUNTS="/data/reference /srv/corpus /etc/shared-config"
# Container-name picker shared by the read-only and read-write mount handlers.
# Each entry's name is its last N path segments joined by underscores; N starts
# at 1 (basename only) and is bumped on collision.
#
#   name_at_depth /a/b/c 1  -> "c"
#   name_at_depth /a/b/c 2  -> "b_c"
#   name_at_depth /a/b/c 99 -> "a_b_c"   (caps at total segment count)
name_at_depth() {
    local path="$1" depth="$2"
    local -a segs=() cleaned=()
    local s
    IFS='/' read -ra segs <<< "$path"
    for s in "${segs[@]}"; do
        [[ -n "$s" ]] && cleaned+=("$s")
    done
    local n=${#cleaned[@]}
    (( depth > n )) && depth=$n
    local start=$(( n - depth ))
    local out="" i
    for (( i = start; i < n; i++ )); do
        if [[ -z "$out" ]]; then out=${cleaned[i]}; else out="${out}_${cleaned[i]}"; fi
    done
    printf '%s' "$out"
}

# Mount a space-separated list of host directories under a container prefix,
# naming each by basename with collision-driven depth bumping. Appends to the
# global MOUNTS array. Factored out of the original read-only-only version so
# the read-write list gets identical validation, canonicalization, dedupe and
# name-collision handling rather than a second, subtly different copy.
#
#   $1  raw space-separated host paths
#   $2  container prefix (e.g. /read-only-reference)
#   $3  mount option suffix (":ro", or "" for read-write)
#   $4  log label (e.g. ro-mount)
#   $5  env var name, for error messages
add_prefixed_mounts() {
    local raw="$1" prefix="$2" opts="$3" label="$4" varname="$5"
    [[ -n "$raw" ]] || return 0

    # Validate + canonicalize (resolve symlinks, strip trailing slashes, dedupe).
    local -a PATHS=()
    declare -A SEEN=()
    local rawp canon
    for rawp in $raw; do
        if [[ "$rawp" != /* ]]; then
            echo "CRITICAL ERROR: ${varname} entry '$rawp' must be an absolute path." >&2
            exit 1
        fi
        if [[ ! -e "$rawp" ]]; then
            echo "CRITICAL ERROR: ${varname} host path '$rawp' does not exist on this host." >&2
            echo "                Refusing to let the engine auto-create it as a directory." >&2
            exit 1
        fi
        # Portable canonicalization: `readlink -f` doesn't exist on BSD without
        # coreutils. `cd -P` resolves symlinks for a directory; for a file,
        # resolve the parent and re-append the basename.
        if [[ -d "$rawp" ]]; then
            canon=$(cd -P "$rawp" && pwd)
        else
            canon="$(cd -P "$(dirname "$rawp")" && pwd)/$(basename "$rawp")"
        fi
        if [[ -z "${SEEN[$canon]:-}" ]]; then
            SEEN[$canon]=1
            PATHS+=("$canon")
        fi
    done

    declare -A DEPTH=()
    local p
    for p in "${PATHS[@]}"; do
        DEPTH["$p"]=1
    done

    # Bump-on-collision loop. Capped at 32 as a paranoid backstop; real paths
    # never need anywhere near that.
    local iter n collision total cur s
    local -a segs=()
    for (( iter = 0; iter < 32; iter++ )); do
        # Reset per iteration. `declare -A x=()` does NOT clear an existing
        # associative array, so unset first or stale counts leak forward and
        # the loop can never see itself converge.
        unset NAME_COUNT NAME_PATHS
        declare -A NAME_COUNT=()
        declare -A NAME_PATHS=()
        for p in "${PATHS[@]}"; do
            n=$(name_at_depth "$p" "${DEPTH[$p]}")
            NAME_COUNT[$n]=$(( ${NAME_COUNT[$n]:-0} + 1 ))
            NAME_PATHS[$n]+="${p}"$'\n'
        done
        collision=0
        for n in "${!NAME_COUNT[@]}"; do
            (( NAME_COUNT[$n] > 1 )) || continue
            collision=1
            while IFS= read -r p; do
                [[ -z "$p" ]] && continue
                IFS='/' read -ra segs <<< "$p"
                total=0
                for s in "${segs[@]}"; do [[ -n "$s" ]] && total=$(( total + 1 )); done
                cur=${DEPTH[$p]}
                if (( cur < total )); then
                    DEPTH[$p]=$(( cur + 1 ))
                fi
            done <<< "${NAME_PATHS[$n]}"
        done
        (( collision == 0 )) && break
    done

    # Final collision assert — impossible after dedupe, but cheap.
    declare -A FINAL=()
    for p in "${PATHS[@]}"; do
        n=$(name_at_depth "$p" "${DEPTH[$p]}")
        if [[ -n "${FINAL[$n]:-}" ]]; then
            echo "CRITICAL ERROR: ${varname} — could not pick unique container names." >&2
            echo "                Both '$p' and '${FINAL[$n]}' resolve to '${prefix}/$n'." >&2
            exit 1
        fi
        FINAL[$n]=$p
        MOUNTS+=( -v "${p}:${prefix}/${n}${opts}" )
        echo "${label}: ${p} -> ${prefix}/${n}${opts:+ (}${opts:+read-only}${opts:+)}"
    done
}

add_prefixed_mounts "${CLAUDE_SANDBOX_RO_MOUNTS:-}" \
    /read-only-reference ":ro" "ro-mount" CLAUDE_SANDBOX_RO_MOUNTS

# Optional caller-supplied READ-WRITE mounts. Same naming convention as the
# read-only list, but mounted at /projects/<name> with no :ro so the agent can
# edit in place.
#
# Use for real project checkouts you want worked on directly instead of copied
# into /workspace. Under rootless podman the container runs with
# --userns=keep-id pinned to the image's claude uid, so files the agent writes
# come out owned by the invoking user on the host rather than by an unreadable
# subuid.
#
# Scope this deliberately. Everything listed is fully writable, and in
# bypassPermissions mode nothing prompts first. Remote state is safe by
# construction: the container carries no git credentials at all — no ssh keys,
# no ssh-agent socket, no ~/.git-credentials, no ~/.netrc, no gh, no
# GH_TOKEN/GITHUB_TOKEN, no credential helper — so `git push` to an
# authenticated remote cannot succeed from inside. Local history and
# uncommitted work in these checkouts are NOT protected.
#
#   export CLAUDE_SANDBOX_RW_MOUNTS="$HOME/git/warp $HOME/git/warp-tools"
add_prefixed_mounts "${CLAUDE_SANDBOX_RW_MOUNTS:-}" \
    /projects "" "rw-mount" CLAUDE_SANDBOX_RW_MOUNTS

# fiss-mcp (Terra MCP server) lifecycle. The server runs on the HOST (not in
# the container) over HTTP. The container only sees a URL; it has no gcloud,
# gsutil, ~/.config/gcloud, or google-cloud-* libs — the only path to GCP
# from inside the sandbox is via the MCP tools exposed by this server, which
# is read-only unless FISS_MCP_ALLOW_WRITES=1. We install/refresh the host
# venv on every launch (idempotent), spawn the server, wait for it to bind,
# and register a trap so the server dies when this script exits.
FISS_MCP_ENABLED="${FISS_MCP:-1}"
FISS_MCP_URL_FOR_CONTAINER=""
HOST_FISS_PID=""
HOST_FISS_LOG=""

cleanup_host_fiss() {
  if [[ -n "${HOST_FISS_PID}" ]] && kill -0 "${HOST_FISS_PID}" 2>/dev/null; then
    echo "host_fiss_mcp: stopping (pid=${HOST_FISS_PID})"
    kill "${HOST_FISS_PID}" 2>/dev/null || true
    wait "${HOST_FISS_PID}" 2>/dev/null || true
  fi
}
# Vertex proxy state — declared here so the cleanup function below is safe
# under `set -u` even when Vertex mode is off.
HOST_VERTEX_PID=""
cleanup_host_vertex() {
  if [[ -n "${HOST_VERTEX_PID:-}" ]] && kill -0 "${HOST_VERTEX_PID}" 2>/dev/null; then
    echo "vertex_proxy: stopping (pid=${HOST_VERTEX_PID})"
    kill "${HOST_VERTEX_PID}" 2>/dev/null || true
    wait "${HOST_VERTEX_PID}" 2>/dev/null || true
  fi
}
cleanup_host_services() {
  cleanup_host_fiss
  cleanup_host_vertex
  # A normal exit: the container is already gone, so stand the watchdog down
  # (see "Cleanup watchdog" below) before it goes looking for it.
  if [[ -n "${WATCHDOG_PID:-}" ]]; then kill "${WATCHDOG_PID}" 2>/dev/null || true; fi
  rm -f "${CIDFILE:-}"
}
trap cleanup_host_services EXIT INT TERM

if [[ "$FISS_MCP_ENABLED" == "1" ]]; then
  # fiss-mcp source (install.sh, run-server.py) is repo content and may be
  # read-only. Its state (the venv and the pinned clone) is per-user and must
  # be writable, so on a shared host they are different paths. Defaults keep
  # both inside the checkout, which is the single-user layout unchanged.
  FISS_SRC_DIR="${SCRIPT_DIR}/host_fiss_mcp"
  FISS_STATE_DIR="${CLAUDE_SANDBOX_FISS_ROOT:-$FISS_SRC_DIR}"
  # Warn loudly rather than let every GCS tool fail at call time with an
  # opaque OSError from deep inside google-cloud-storage.
  if [[ -z "${CLAUDE_SANDBOX_GCP_PROJECT:-}" ]]; then
    YEL=$'\033[1;33m'; RST=$'\033[0m'
    echo "${YEL}fiss-mcp: CLAUDE_SANDBOX_GCP_PROJECT is unset.${RST}"
    echo "${YEL}          Terra/Cromwell tools will work, but the GCS tools${RST}"
    echo "${YEL}          (list_gcs_objects, read_gcs_object, download_gcs_file,${RST}"
    echo "${YEL}          get_gcs_object_metadata) will fail with${RST}"
    echo "${YEL}          \"Project was not passed and could not be determined\".${RST}"
    echo "${YEL}          Set it in env.<INSTANCE>.sh to a project where you have${RST}"
    echo "${YEL}          serviceusage.services.use.${RST}"
  fi

  if [[ ! -x "${FISS_STATE_DIR}/venv/bin/python" ]]; then
    echo "ERROR: fiss-mcp venv not found at ${FISS_STATE_DIR}/venv." >&2
    echo "       Run ./setup_host.sh on this machine first to build it," >&2
    echo "       or export FISS_MCP=0 to launch without Terra access." >&2
    exit 1
  fi
  if [[ ! -f "${FISS_SRC_DIR}/run-server.py" ]]; then
    echo "ERROR: fiss-mcp launcher missing at ${FISS_SRC_DIR}/run-server.py." >&2
    echo "       The checkout looks incomplete." >&2
    exit 1
  fi

  # Per-user, per-instance port so concurrent sandboxes don't collide. The uid
  # is mixed into the hash: on a shared host every user tends to run instance
  # "main", so hashing the instance name alone gave them all the same port and
  # only the first to launch would get it.
  PORT_OFFSET=$(printf '%s:%s' "$(id -u)" "${CLAUDE_SANDBOX_INSTANCE}" | cksum | awk '{print $1 % 1000}')
  HOST_FISS_PORT="${FISS_MCP_PORT:-$((39000 + PORT_OFFSET))}"
  HOST_FISS_PATH="/mcp/"

  # Resolve the bind IP via the helper at the top of this script: podman →
  # 127.0.0.1 reached through a pasta forward; docker → the bridge gateway IP,
  # off external interfaces and needing no iptables rule.
  if ! HOST_BIND_IP=$(resolve_host_bind_ip); then
    echo "fiss-mcp: refusing to bind without a known-safe IP." >&2
    exit 1
  fi

  # Only scan when the port was derived. An explicit FISS_MCP_PORT is honoured
  # exactly, and still fails loudly if taken, because silently moving a port the
  # operator pinned would be worse than refusing.
  if [[ -n "${FISS_MCP_PORT:-}" ]]; then
    if (echo > "/dev/tcp/${HOST_BIND_IP}/${HOST_FISS_PORT}") 2>/dev/null; then
      echo "fiss-mcp: ${HOST_BIND_IP}:${HOST_FISS_PORT} already in use." >&2
      echo "          FISS_MCP_PORT was set explicitly, so it is not moved." >&2
      exit 1
    fi
  else
    if ! HOST_FISS_PORT=$(find_free_port "${HOST_BIND_IP}" "${HOST_FISS_PORT}" 32); then
      echo "fiss-mcp: no free port in 32 slots from the derived base." >&2
      echo "          Set FISS_MCP_PORT explicitly." >&2
      exit 1
    fi
  fi

  HOST_FISS_LOG="${SANDBOX_HOME}/.claude/host_fiss_mcp.log"
  mkdir -p "$(dirname "${HOST_FISS_LOG}")"

  # GOOGLE_CLOUD_PROJECT is required for fiss-mcp's GCS tools, not optional.
  # Every one of them builds a bare `storage.Client()` with no project= and no
  # user_project, and google-cloud-storage refuses to construct without a
  # project:
  #     OSError: Project was not passed and could not be determined
  #              from the environment.
  #
  # With end-user ADC (type "authorized_user") there is nothing for the library
  # to infer from. Note specifically that
  #     gcloud auth application-default set-quota-project <p>
  # does NOT fix this: it sets quota_project_id, which google.auth reports as
  # the credentials' quota project and which silences the "no quota project"
  # warning, but google.auth.default() still returns project=None. Measured on
  # this host with quota_project_id populated. The project comes from
  # GOOGLE_CLOUD_PROJECT/GCLOUD_PROJECT or from a configured gcloud
  # core/project, so set it explicitly here rather than depending on the
  # operator's global gcloud default.
  #
  # This is a project id, not a credential. The container never sees it; only
  # the host-side server process does, and it stays scoped to that process
  # instead of mutating the host's gcloud configuration.
  # Built as an array and handed to `env` rather than written as a command
  # prefix. A shell recognizes assignment-prefixes syntactically, before
  # expansion, so a word produced by ${VAR:+NAME=value} is NOT treated as an
  # assignment -- it becomes the command name, and the spawn dies with
  #     GOOGLE_CLOUD_PROJECT=... : command not found
  # `env` takes assignments as ordinary arguments, so a conditionally-appended
  # entry works. nohup and env both exec through, so $! is still the python pid
  # and the EXIT trap's kill continues to reach the server.
  FISS_ENV=(
    "FISS_MCP_HOST=${HOST_BIND_IP}"
    "FISS_MCP_PORT=${HOST_FISS_PORT}"
    "FISS_MCP_PATH=${HOST_FISS_PATH}"
    "FISS_MCP_ALLOW_WRITES=${FISS_MCP_ALLOW_WRITES:-0}"
  )
  if [[ -n "${CLAUDE_SANDBOX_GCP_PROJECT:-}" ]]; then
    FISS_ENV+=( "GOOGLE_CLOUD_PROJECT=${CLAUDE_SANDBOX_GCP_PROJECT}" )
  fi

  nohup env "${FISS_ENV[@]}" \
    "${FISS_STATE_DIR}/venv/bin/python" "${FISS_SRC_DIR}/run-server.py" \
    > "${HOST_FISS_LOG}" 2>&1 &
  HOST_FISS_PID=$!

  echo -n "fiss-mcp: waiting for host server on ${HOST_BIND_IP}:${HOST_FISS_PORT} "
  READY=0
  for _ in $(seq 1 30); do
    if (echo > "/dev/tcp/${HOST_BIND_IP}/${HOST_FISS_PORT}") 2>/dev/null; then
      READY=1; echo " OK"; break
    fi
    echo -n "."; sleep 1
  done
  if [[ "$READY" != "1" ]]; then
    echo " FAILED"
    echo "fiss-mcp: server did not come up — last 20 lines of ${HOST_FISS_LOG}:" >&2
    tail -20 "${HOST_FISS_LOG}" >&2 || true
    exit 1
  fi

  register_pasta_forward "${HOST_FISS_PORT}"
  FISS_MCP_URL_FOR_CONTAINER="http://${REGISTERED_HOSTNAME}:${HOST_FISS_PORT}${HOST_FISS_PATH}"
  echo "fiss-mcp: host server pid=${HOST_FISS_PID} url=${FISS_MCP_URL_FOR_CONTAINER}"
fi

# Vertex AI proxy lifecycle (Option B — chained).
#
# Activated when the parent shell has sourced SET_VERTEX_MODE.sh, which
# exports CLAUDE_CODE_USE_VERTEX=1 + ANTHROPIC_VERTEX_PROJECT_ID + CLOUD_ML_REGION.
# Those env vars are LAUNCHER-side signals only — claude-code inside the
# container runs in standard Anthropic mode, not Vertex SDK mode. We do not
# forward CLAUDE_CODE_USE_VERTEX into the container.
#
# Flow:
#   claude (in container, Anthropic mode)
#     → headroom (in container, optional, when HEADROOM=1)
#         (reads ANTHROPIC_TARGET_API_URL from env, forwards Anthropic-shape
#          body to the host vertex_proxy at that URL)
#     → vertex_proxy.py (on host, bound to docker bridge gateway IP)
#         (strips incoming Authorization, mints fresh GCP token, rebuilds
#          Vertex URL from project/region/model, forwards)
#     → Vertex AI
#
# With HEADROOM=0, claude hits vertex_proxy directly via ANTHROPIC_BASE_URL
# (set inside the container by start_script.sh when no headroom is running).
VERTEX_ENABLED="${CLAUDE_CODE_USE_VERTEX:-0}"
VERTEX_PROXY_URL_FOR_CONTAINER=""
HOST_VERTEX_LOG=""

if [[ "$VERTEX_ENABLED" == "1" ]]; then
  if ! command -v gcloud >/dev/null 2>&1; then
    echo "vertex_proxy: gcloud not on PATH; cannot mint Vertex access tokens." >&2
    echo "              Install Google Cloud SDK + run 'gcloud auth login' and" >&2
    echo "              'gcloud auth application-default login', or unset" >&2
    echo "              CLAUDE_CODE_USE_VERTEX to launch in Anthropic-API mode." >&2
    exit 1
  fi
  if [[ -z "${ANTHROPIC_VERTEX_PROJECT_ID:-}" ]]; then
    echo "vertex_proxy: ANTHROPIC_VERTEX_PROJECT_ID is unset." >&2
    echo "              Source SET_VERTEX_MODE.sh (with your project id) first." >&2
    exit 1
  fi
  if [[ -z "${CLOUD_ML_REGION:-}" ]]; then
    echo "vertex_proxy: CLOUD_ML_REGION is unset." >&2
    echo "              Source SET_VERTEX_MODE.sh (with your region) first." >&2
    exit 1
  fi
  if [[ ! -f "${SCRIPT_DIR}/vertex_proxy.py" ]]; then
    echo "vertex_proxy: ${SCRIPT_DIR}/vertex_proxy.py not found." >&2
    exit 1
  fi

  # Per-instance port in the 38000-38999 range so concurrent sandboxes don't
  # collide. Hashed from the instance name. Disjoint from fiss-mcp's 39xxx.
  VERTEX_PORT_OFFSET=$(printf '%s:%s' "$(id -u)" "${CLAUDE_SANDBOX_INSTANCE}" | cksum | awk '{print $1 % 1000}')
  HOST_VERTEX_PORT="${VERTEX_PROXY_PORT:-$((38000 + VERTEX_PORT_OFFSET))}"

  # Same bind-IP rules as fiss-mcp — see resolve_host_bind_ip at the top.
  if ! VERTEX_BIND_IP=$(resolve_host_bind_ip); then
    echo "vertex_proxy: refusing to bind without a known-safe IP." >&2
    exit 1
  fi

  if (echo > "/dev/tcp/${VERTEX_BIND_IP}/${HOST_VERTEX_PORT}") 2>/dev/null; then
    echo "vertex_proxy: ${VERTEX_BIND_IP}:${HOST_VERTEX_PORT} already in use." >&2
    echo "              Set VERTEX_PROXY_PORT to a free port or stop the conflict." >&2
    exit 1
  fi

  HOST_VERTEX_LOG="${SANDBOX_HOME}/.claude/host_vertex_proxy.log"
  mkdir -p "$(dirname "${HOST_VERTEX_LOG}")"

  VERTEX_PROXY_HOST="${VERTEX_BIND_IP}" \
  VERTEX_PROXY_PORT="${HOST_VERTEX_PORT}" \
  ANTHROPIC_VERTEX_PROJECT_ID="${ANTHROPIC_VERTEX_PROJECT_ID}" \
  CLOUD_ML_REGION="${CLOUD_ML_REGION}" \
  ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-}" \
  nohup python3 "${SCRIPT_DIR}/vertex_proxy.py" \
    > "${HOST_VERTEX_LOG}" 2>&1 &
  HOST_VERTEX_PID=$!

  echo -n "vertex_proxy: waiting for host server on ${VERTEX_BIND_IP}:${HOST_VERTEX_PORT} "
  VREADY=0
  for _ in $(seq 1 30); do
    if (echo > "/dev/tcp/${VERTEX_BIND_IP}/${HOST_VERTEX_PORT}") 2>/dev/null; then
      VREADY=1; echo " OK"; break
    fi
    echo -n "."; sleep 1
  done
  if [[ "$VREADY" != "1" ]]; then
    echo " FAILED"
    echo "vertex_proxy: server did not come up — last 20 lines of ${HOST_VERTEX_LOG}:" >&2
    tail -20 "${HOST_VERTEX_LOG}" >&2 || true
    exit 1
  fi

  # No /v1 suffix: Anthropic-SDK convention (and headroom's ANTHROPIC_TARGET_API_URL)
  # is base URL only — clients append /v1/messages. The proxy ignores the path
  # anyway, so it's purely about not confusing headroom's URL builder.
  register_pasta_forward "${HOST_VERTEX_PORT}"
  VERTEX_PROXY_URL_FOR_CONTAINER="http://${REGISTERED_HOSTNAME}:${HOST_VERTEX_PORT}"
  echo "vertex_proxy: host server pid=${HOST_VERTEX_PID} url=${VERTEX_PROXY_URL_FOR_CONTAINER}"
fi

# Loud warning when fiss-mcp is launching with write access. Writes can
# submit workflows, mutate workspace attributes, and spend real money. The
# banner below is pre-rendered figlet output (font: standard) baked into
# the script so we don't need figlet on the host. The in-container
# start_script prints a matching banner so the warning is unavoidable on
# both sides.
if [[ "${FISS_MCP_ENABLED}" == "1" && "${FISS_MCP_ALLOW_WRITES:-0}" == "1" ]]; then
  RED=$'\033[1;31m'; YEL=$'\033[1;33m'; RST=$'\033[0m'
  echo
  printf '%s' "${RED}"
  cat <<'BANNER'
 _____ ___ ____ ____   __        ______  ___ _____ _____   __  __  ___  ____  _____
|  ___|_ _/ ___/ ___|  \ \      / /  _ \|_ _|_   _| ____| |  \/  |/ _ \|  _ \| ____|
| |_   | |\___ \___ \   \ \ /\ / /| |_) || |  | | |  _|   | |\/| | | | | | | |  _|
|  _|  | | ___) |__) |   \ V  V / |  _ < | |  | | | |___  | |  | | |_| | |_| | |___
|_|   |___|____/____/     \_/\_/  |_| \_\___| |_| |_____| |_|  |_|\___/|____/|_____|
BANNER
  printf '%s' "${RST}"
  echo
  echo "${YEL}fiss-mcp is launching with --allow-writes.${RST}"
  echo "${YEL}The agent CAN submit workflows, mutate workspace attributes,${RST}"
  echo "${YEL}and otherwise spend money on your Terra/GCP account.${RST}"
  echo "${YEL}Unset FISS_MCP_ALLOW_WRITES to disable.${RST}"
  echo
  sleep 2
fi

# Runtime + GPU selection.
#
# Linux: sysbox-runc gives us docker-in-docker, user-namespace remap, and
# stronger isolation. It does NOT support NVIDIA GPU passthrough
# (https://github.com/nestybox/sysbox/issues/50), so if the host has GPUs
# we fall back to the default runc runtime and forward them with --gpus all.
#
RUNTIME_FLAG=(--runtime=sysbox-runc)
GPU_FLAGS=()
HAVE_GPU=0

# Optional --shm-size override. Docker defaults /dev/shm to 64MB, which is
# too small for Chromium/Playwright, PyTorch DataLoader workers, and other
# multi-process consumers. Set CLAUDE_SANDBOX_SHM_SIZE=2g (or 512m, 4g, …)
# to bump it. Unset → don't emit the flag → Docker default.
SHM_FLAGS=()
if [[ -n "${CLAUDE_SANDBOX_SHM_SIZE:-}" ]]; then
  SHM_FLAGS=(--shm-size="${CLAUDE_SANDBOX_SHM_SIZE}")
fi

# Memory / CPU ceiling. Rootless podman can enforce these because cgroup v2
# delegates the `memory` controller to the user slice; verified on this host
# (memory.max reads back exactly). Applied on the Docker path too — same flags.
LIMIT_FLAGS=()
if [[ -n "${CLAUDE_SANDBOX_MEMORY:-}" ]]; then
  # --memory-swap equal to --memory disables swap beyond the limit, so the
  # ceiling is a real ceiling rather than a soft push into swap.
  LIMIT_FLAGS+=(--memory="${CLAUDE_SANDBOX_MEMORY}" --memory-swap="${CLAUDE_SANDBOX_MEMORY}")
fi
if [[ -n "${CLAUDE_SANDBOX_CPUS:-}" ]]; then
  LIMIT_FLAGS+=(--cpus="${CLAUDE_SANDBOX_CPUS}")
fi

if [[ "$IS_PODMAN" == "1" ]]; then
  YEL=$'\033[1;33m'; RST=$'\033[0m'
  echo "${YEL}podman host: rootless userns isolation, no sysbox-runc, no DinD.${RST}"
  RUNTIME_FLAG=()

  # Pin the invoking user onto the image's `claude` uid so /workspace files
  # land owned by the invoker on the host instead of an unreadable subuid.
  RUNTIME_FLAG+=(--userns="keep-id:uid=${SANDBOX_IMAGE_UID},gid=${SANDBOX_IMAGE_UID}")

  # GPU passthrough under rootless podman needs a CDI spec
  # (/etc/cdi/nvidia.yaml, generated by `nvidia-ctk cdi generate`) and is
  # requested with --device rather than --gpus. Opt-in only: the sandbox has
  # no GPU workload by default, and silently failing over would be worse
  # than not offering it.
  if [[ "${CLAUDE_SANDBOX_GPU:-0}" == "1" ]]; then
    if [[ -e /etc/cdi/nvidia.yaml || -e /var/run/cdi/nvidia.yaml ]]; then
      GPU_FLAGS=(--device nvidia.com/gpu=all)
      HAVE_GPU=1
      echo "${YEL}podman: forwarding all NVIDIA GPUs via CDI.${RST}"
    else
      echo "${YEL}WARNING: CLAUDE_SANDBOX_GPU=1 but no CDI spec found.${RST}"
      echo "${YEL}Generate one with: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml${RST}"
      echo "${YEL}Continuing WITHOUT GPU passthrough.${RST}"
    fi
  fi

  # Queue the pasta forwards collected by register_pasta_forward(). Each
  # `-T <port>` maps that port on the container's loopback to the same port
  # on the host's loopback, which is where the host services are bound.
  #
  # Syntax is `pasta:<opt>,<opt>,...` — a COLON separates the network name
  # from its options, and commas separate the option tokens after that. Each
  # `-T,<port>` pair therefore becomes two argv tokens to pasta.
  if (( ${#PASTA_FORWARDS[@]} )); then
    pasta_opts=""
    for p in "${PASTA_FORWARDS[@]}"; do
      [[ -n "$pasta_opts" ]] && pasta_opts+=","
      pasta_opts+="-T,${p}"
    done
    PODMAN_NET_FLAGS=(--network="pasta:${pasta_opts}")
    echo "podman: pasta forwards to host loopback -> ${PASTA_FORWARDS[*]}"
  fi
else
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    HAVE_GPU=1
  fi

  # Don't switch runtimes if Docker has no 'nvidia' runtime registered — the
  # --gpus flag would just error out and we'd lose sysbox for no gain.
  if [[ "${HAVE_GPU}" == "1" ]]; then
    if ! docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
      RED=$'\033[1;31m'; YEL=$'\033[1;33m'; RST=$'\033[0m'
      echo
      echo "${YEL}WARNING: GPU detected but Docker has no 'nvidia' runtime registered.${RST}"
      echo "${YEL}Install nvidia-container-toolkit and run:${RST}"
      echo "${YEL}    sudo nvidia-ctk runtime configure --runtime=docker${RST}"
      echo "${YEL}    sudo systemctl restart docker${RST}"
      echo "${YEL}Falling back to sysbox-runc with NO GPU passthrough.${RST}"
      echo
      HAVE_GPU=0
    fi
  fi

  if [[ "${HAVE_GPU}" == "1" ]]; then
    RED=$'\033[1;31m'; YEL=$'\033[1;33m'; RST=$'\033[0m'
    echo
    echo "${YEL}========================================================================${RST}"
    echo "${YEL}GPU DETECTED — switching container runtime from sysbox-runc to runc.${RST}"
    echo "${YEL}    * --gpus all will be forwarded to the container${RST}"
    echo "${YEL}    * docker-in-docker (DinD) inside the sandbox WILL NOT WORK${RST}"
    echo "${YEL}    * user-namespace remap and extra sysbox isolation: DISABLED${RST}"
    echo "${YEL}    * upstream issue: https://github.com/nestybox/sysbox/issues/50${RST}"
    echo "${YEL}If you need DinD instead, hide nvidia-smi from PATH before launching.${RST}"
    echo "${YEL}========================================================================${RST}"
    echo
    RUNTIME_FLAG=()
    GPU_FLAGS=(--gpus all)
  fi
fi

# Agent-specific environment, forwarded BY NAME (`-e VAR` with no value), so a
# key's value never appears on the podman command line, where `ps` would show it
# to every user on the host.
#   GEMINI_API_KEY          agy with a Gemini API key instead of Google sign-in
#   GOOGLE_GEMINI_BASE_URL  agy against a Gemini-compatible endpoint
# Only an agy container gets them.
AGENT_ENV=()
if [[ "$SANDBOX_AGENT" == "agy" ]]; then
  [[ -n "${GEMINI_API_KEY:-}" ]] && AGENT_ENV+=(-e GEMINI_API_KEY)
  [[ -n "${GOOGLE_GEMINI_BASE_URL:-}" ]] && AGENT_ENV+=(-e GOOGLE_GEMINI_BASE_URL)
fi

# Make it so. Any args ($@) are passed to the agent inside the container —
# e.g. --resume <id>, --continue, --dangerously-skip-permissions.
# To drop into a shell instead, swap `claude "$@"` below for `/bin/bash`.
# Note: not using `exec` so the EXIT trap can still fire to clean up the
# host fiss-mcp process after the container exits.
# `${arr[@]+"${arr[@]}"}` is the empty-array-safe expansion: a plain
# "${arr[@]}" on an empty array raises "unbound variable" under `set -u` on
# older bash. Several of these arrays are legitimately empty, so keep the guard.
#
# SANDBOX_GIT_USER_NAME / _EMAIL forward ONLY the host's git identity, so the
# agent can commit in read-write project mounts. Without them `git commit` dies
# with "Author identity unknown", since /home/claude/.gitconfig does not exist
# in the image and is not bind-mounted.
#
# Identity is not a credential — it is the name and email already stamped on
# every public commit. The host ~/.gitconfig is deliberately NOT mounted: it
# also carries `credential.helper = !gh auth git-credential` entries, and
# mounting credential configuration into the sandbox is exactly what this
# design avoids. Forwarding two scalars carries no such risk.
#
# start_script.sh writes these into the container's GLOBAL git config rather
# than exporting GIT_AUTHOR_*/GIT_COMMITTER_*, because those env vars outrank
# repository-local config. Global config ranks below it, so a mounted repo that
# sets its own user.email still wins.
#
# DISABLE_AUTOUPDATER defaults to 1 because the auto-updater cannot succeed in
# this image and its warning ("Can't auto-update: npm global folder isn't
# writable") is pure noise every session. `npm install -g` ran as root at build
# time, so /usr/local/lib/node_modules is root:root 755, while the container
# runs as claude. Making it writable would be worse, not better: that path is
# baked into the image layer with no bind mount, and the container runs --rm, so
# any update would be downloaded into the ephemeral overlay, thrown away on
# exit, and re-downloaded on every launch — while silently drifting off the
# version the image records (CLAUDE_CODE_VERSION), the one every user shares.
#
# The supported upgrade path is an image rebuild, which installs the newest
# release (scripts/resolve-latest.sh). Set DISABLE_AUTOUPDATER=0 to get the
# warning back.
#
# On the podman path: HOST_UID / HOST_GID are deliberately passed empty.
# --userns=keep-id has already put us on the image's claude uid before the
# entrypoint runs, and uid-fixup-entrypoint.sh's usermod/groupmod would need
# real root. Empty values make that entrypoint skip both remaps and the
# chown -R, falling straight through to `exec gosu claude`.
# host.docker.internal is still declared so anything in the container that
# hardcodes the name resolves rather than erroring; host services are reached
# through the pasta loopback forward instead (see resolve_host_bind_ip).
# Cleanup watchdog. The EXIT trap stops the host services when this script ends
# normally, but bash runs no trap when a signal it does not handle kills it, and
# SIGHUP is how sessions usually end: an SSH drop, a closed laptop, a killed tmux
# session. Measured after `tmux kill-session`: this script was gone, its fiss-mcp
# server orphaned to PID 1, and the container still running with no terminal,
# so the next launch failed with "already running". Trapping HUP here does not
# help: bash defers a trap until the foreground `podman run` returns, and that
# client survives SIGHUP.
#
# So a background process outlives the launcher. It ignores HUP and INT, polls for
# the launcher, and when it is gone stops what it left behind: the container, by
# the ID podman wrote to --cidfile (never by name, which a quick relaunch may have
# reused already), then the host services. On a normal exit the EXIT trap kills
# the watchdog first, so it acts only when that trap never ran.
CIDFILE="${XDG_RUNTIME_DIR:-${SANDBOX_HOME}}/${CONTAINER_NAME}.cid"
rm -f "$CIDFILE"
LAUNCHER_PID=$$
(
  trap '' HUP INT
  while kill -0 "$LAUNCHER_PID" 2>/dev/null; do sleep 2; done
  if [[ -s "$CIDFILE" ]]; then
    "$ENGINE" stop -t 10 "$(cat "$CIDFILE")" >/dev/null 2>&1 || true
    rm -f "$CIDFILE"
  fi
  for p in "${HOST_FISS_PID}" "${HOST_VERTEX_PID}"; do
    if [[ -n "$p" ]]; then kill "$p" 2>/dev/null || true; fi
  done
) &
WATCHDOG_PID=$!

"$ENGINE" run --rm -it \
  --name "${CONTAINER_NAME}" \
  --cidfile "${CIDFILE}" \
  "${MOUNTS[@]}" \
  --add-host=host.docker.internal:host-gateway \
  ${PODMAN_NET_FLAGS[@]+"${PODMAN_NET_FLAGS[@]}"} \
  ${RUNTIME_FLAG[@]+"${RUNTIME_FLAG[@]}"} \
  ${SHM_FLAGS[@]+"${SHM_FLAGS[@]}"} \
  ${LIMIT_FLAGS[@]+"${LIMIT_FLAGS[@]}"} \
  ${GPU_FLAGS[@]+"${GPU_FLAGS[@]}"} \
  -e HOST_UID="$([[ "$IS_PODMAN" == "1" ]] || id -u)" \
  -e HOST_GID="$([[ "$IS_PODMAN" == "1" ]] || id -g)" \
  -e HEADROOM="${HEADROOM:-0}" \
  -e HEADROOM_PORT="${HEADROOM_PORT:-8787}" \
  -e CLAUDE_NOTIFY_EMAIL="${CLAUDE_NOTIFY_EMAIL:-}" \
  -e CLAUDE_NOTIFY_FROM="${CLAUDE_NOTIFY_FROM:-claude-sandbox}" \
  -e CLAUDE_NOTIFY_HOSTNAME="${CLAUDE_NOTIFY_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}" \
  -e SANDBOX_HAS_DIND="$([[ "${HAVE_GPU}" == "1" || "${IS_PODMAN}" == "1" ]] && echo 0 || echo 1)" \
  -e FISS_MCP="${FISS_MCP_ENABLED}" \
  -e FISS_MCP_ALLOW_WRITES="${FISS_MCP_ALLOW_WRITES:-0}" \
  -e FISS_MCP_URL="${FISS_MCP_URL_FOR_CONTAINER}" \
  -e CODEGRAPH="${CODEGRAPH:-1}" \
  -e DISABLE_AUTOUPDATER="${DISABLE_AUTOUPDATER:-1}" \
  -e SANDBOX_GIT_USER_NAME="${SANDBOX_GIT_USER_NAME:-$(git config --global user.name 2>/dev/null || true)}" \
  -e SANDBOX_GIT_USER_EMAIL="${SANDBOX_GIT_USER_EMAIL:-$(git config --global user.email 2>/dev/null || true)}" \
  -e ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-}" \
  -e CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS="${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}" \
  -e ANTHROPIC_TARGET_API_URL="${VERTEX_PROXY_URL_FOR_CONTAINER}" \
  -e SANDBOX_AGENT="${SANDBOX_AGENT}" \
  ${AGENT_ENV[@]+"${AGENT_ENV[@]}"} \
  -w /workspace \
  "${SANDBOX_IMAGE_REF}" /home/claude/start_script.sh "$@"

