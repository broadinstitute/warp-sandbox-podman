#!/usr/bin/env bash
# build-shared-image.sh — build the sandbox image once into a shared, read-only
# image store so N users do not each hold their own 9.0 GB copy.
#
# Run as root (the store must be populated by a real uid, not by one user's
# subuid range — see the note on ownership below):
#
#     sudo ./scripts/build-shared-image.sh
#
# Users then get the image read-only through `additionalimagestores` in their
# own containers-storage.conf, which scripts/provision-sandbox-user.sh writes.
#
# Why a shared store rather than each user building or pulling:
#   * 9.0 GB once instead of 9.0 GB x N users.
#   * Everyone provably runs the same image. Users cannot rebuild it, which is
#     a feature here: the image is the trust boundary, and drift between users
#     would make "it works for me" unfalsifiable.
#
# Verified mechanism: with an empty graphroot plus an additional store, podman
# lists the image as ReadOnly=true, runs it without copying, and the local
# graphroot stays at ~150 KB.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

STORE="${CLAUDE_SANDBOX_IMAGE_STORE:-/mnt/sandbox/imagestore}"
TAG_VERSION="$(awk -F'= *' '/^VERSION/{print $2}' "${REPO_ROOT}/docker/Makefile" | tr -d ' ')"
: "${TAG_VERSION:=0.0.1}"

if [[ "$(id -u)" != "0" ]]; then
    echo "build-shared-image.sh: run as root (sudo)." >&2
    echo "" >&2
    echo "  The store has to be populated by a real uid. A rootless build writes" >&2
    echo "  layer files owned by the builder's SUBUID range, and another user's" >&2
    echo "  user namespace cannot map those, so the image would be unreadable to" >&2
    echo "  everyone but the person who built it." >&2
    exit 1
fi

# --prune reclaims the ~8 GB each rebuild leaves behind as a dangling <none>
# image. It lives in this script rather than as a documented two-command pair
# because the chmod afterwards is mandatory and easy to omit: prune rewrites
# overlay-images/images.json as root 0600, which undoes the chmod below, and every
# user then gets
#     Error: configure storage: open .../overlay-images/images.json: permission denied
# Splitting the two across a README is how that happens, so they are one command.
if [[ "${1:-}" == "--prune" ]]; then
    echo "Pruning dangling images in ${STORE}"
    echo
    echo "  NOTE: this cannot see users' rootless containers. An image still in use"
    echo "  by someone's running container is safe from prune only within this"
    echo "  store's own view, so prefer running it when nobody has a live session."
    echo
    podman --root "$STORE" image prune --force
    chmod -R a+rX "$STORE"
    echo
    du -sh "$STORE" | sed 's/^/  store size: /'
    echo "  permissions restored (a+rX) — verify with: podman images (as a normal user)"
    exit 0
fi

echo "Building claude-sandbox:${TAG_VERSION} into shared store ${STORE}"
echo

# The newest Claude Code, agy, caveman and ponytail, resolved now. To hold one
# back, set it first, e.g. `sudo CLAUDE_CODE_VERSION=2.1.326 ./scripts/build-shared-image.sh`
# (resolve-latest.sh lists the variables). If anything cannot be resolved, stop
# here: the image in use stays as it is.
if ! latest="$("${SCRIPT_DIR}/resolve-latest.sh")"; then
    echo "build-shared-image.sh: could not resolve the newest versions; nothing built." >&2
    exit 1
fi
BUILD_ARGS=()
echo "Newest versions, going into this build:"
while IFS= read -r kv; do
    BUILD_ARGS+=(--build-arg "$kv")
    [[ "$kv" == *_VERSION=* ]] && printf '  %-20s %s\n' "${kv%%=*}" "${kv#*=}"
done <<<"$latest"
echo

mkdir -p "$STORE"

# --root redirects the whole storage tree, so this build never touches the
# invoking user's ~/.local/share/containers.
podman --root "$STORE" build \
    -t "claude-sandbox:${TAG_VERSION}" \
    -t "claude-sandbox:latest" \
    "${BUILD_ARGS[@]}" \
    "${REPO_ROOT}/docker"

# Readable and traversable by every user. Layer contents are root-owned; users
# read them by permission bits, so a+rX is what makes the store usable from
# another user's namespace. No write bit: the store is read-only to users by
# design, and podman enforces that too.
chmod -R a+rX "$STORE"

echo
echo "=== store contents ==="
podman --root "$STORE" images --format "  {{.Repository}}:{{.Tag}}  {{.Size}}"
echo
du -sh "$STORE" | sed 's/^/  store size: /'
# The versions baked into this build. Read from image metadata, not by running a
# container: a rootful run would write container state into the shared store.
# (Each tool's --version already ran inside its own build step.)
echo
echo "=== tool versions ==="
podman --root "$STORE" image inspect "claude-sandbox:${TAG_VERSION}" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | awk -F= '$1 ~ /^(CLAUDE_CODE|AGY|CODEGRAPH|CAVEMAN|PONYTAIL)_VERSION$/ {printf "  %-22s %s\n", $1, $2}'

cat <<EOF

Done. Each user picks this up through ~/.config/containers/storage.conf.

IMPORTANT ordering: a user sees nothing from this store until that file exists.
provision-sandbox-user.sh writes it, so run that FIRST. Checking \`podman images\`
before provisioning shows an empty list and \`podman run\` falls back to a registry
pull -- which looks like the shared store failing when it is simply not
configured yet.

The file it writes:

    [storage]
    driver = "overlay"
    [storage.options]
    additionalimagestores = [ "${STORE}" ]
    [storage.options.overlay]
    mount_program = "/usr/bin/fuse-overlayfs"

The mount_program line is REQUIRED. This store is built by rootful podman, whose
overlay layers carry trusted.overlay.* xattrs; a rootless consumer mounts with
userxattr and cannot read them, so the container starts with an incomplete
rootfs and fails with "OCI runtime attempted to invoke a command that was not
found". The image lists fine in that state -- only running breaks -- so the
symptom is easy to misread. fuse-overlayfs handles ownership in userspace and
fixes it.

scripts/provision-sandbox-user.sh writes that automatically. Verify as a
NON-admin user with:

    podman images                      # should list claude-sandbox, ReadOnly=true
    podman run --rm localhost/claude-sandbox:${TAG_VERSION} claude --version
    du -sh ~/.local/share/containers   # should stay small: no local copy

To update the image later, re-run this script. Users need do nothing; they pick
up the new layers on their next launch. Anyone with a container already running
keeps the old image until they exit and relaunch.

Each rebuild leaves the previous image dangling as <none>, holding another ~8 GB.
Reclaim it with:

    sudo ./scripts/build-shared-image.sh --prune

Use that rather than calling podman prune directly. prune rewrites the store
metadata as root 0600, which undoes the chmod this script applies, and users then
hit "configure storage: open .../overlay-images/images.json: permission denied" on
every command. --prune restores the permissions in the same breath. The same
hazard applies to ANY rootful operation on this store: if you touch it by hand,
re-run \`sudo chmod -R a+rX ${STORE}\` afterwards.
EOF
