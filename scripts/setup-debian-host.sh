#!/usr/bin/env bash
# scripts/setup-debian-host.sh — one-time host setup for a shared sandbox server
# on Debian 13. Root only. Idempotent: re-running it is safe, and it is also how
# a rebuilt VM gets its boot-disk state back.
#
#   sudo ./scripts/setup-debian-host.sh --data-device /dev/disk/by-id/<data-disk>
#
# Self-contained (it reads no other file from the checkout), so it also runs
# before the checkout exists, which it then clones onto the data disk:
#
#   ssh admin@HOST 'sudo bash -s -- --data-device /dev/disk/by-id/...' \
#       < scripts/setup-debian-host.sh
#
# It automates the host half of SERVER.md: "Host packages", "Format and mount the
# data disk", the shared directories, and the checkout. What it does NOT do:
# build the image (scripts/build-shared-image.sh, ~30 min, run it next) or
# create users (scripts/add-sandbox-user.sh).
#
# Options
#   --data-device DEV   block device for /mnt/sandbox. FORMATTED ONLY IF BLANK:
#                       a device that already carries a filesystem is mounted
#                       as-is, which is what makes a VM rebuild safe.
#   --repo-url URL      checkout to clone (default: this project on GitHub)
#   --repo-owner USER   owner of /mnt/sandbox/repo (default: the sudo invoker)
#   --no-imds-block     do not install the EC2 metadata-service block (below)
set -euo pipefail

DATA_DEVICE=""
REPO_URL="https://github.com/broadinstitute/warp-sandbox-podman.git"
REPO_OWNER="${SUDO_USER:-}"
IMDS_BLOCK=auto
SANDBOX_ROOT=/mnt/sandbox
# uv is pinned and checksum-verified. Keep in step with the uv image tag in
# docker/Dockerfile, so host and container run one uv version.
UV_VERSION=0.13.9

while (( $# )); do
    case "$1" in
        --data-device)   DATA_DEVICE="$2"; shift ;;
        --repo-url)      REPO_URL="$2"; shift ;;
        --repo-owner)    REPO_OWNER="$2"; shift ;;
        --no-imds-block) IMDS_BLOCK=no ;;
        -h|--help)       sed -n '2,30p' "$0" 2>/dev/null || true; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" == 0 ]] || die "run as root (sudo)."
. /etc/os-release
[[ "${ID:-}" == debian && "${VERSION_ID:-}" == 13 ]] \
    || echo "warning: written for Debian 13; this is ${PRETTY_NAME:-unknown}. Continuing." >&2

export DEBIAN_FRONTEND=noninteractive
VENDOR="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"

# ------------------------------------------------------------- packages ----
say "packages"
# What adding the two third-party repositories below needs. The Debian cloud
# image has no gpg, and the Google key has to be dearmored.
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg >/dev/null
install -d -m 0755 /etc/apt/keyrings

# GitHub CLI from GitHub's own repository. Debian 13 ships gh 2.46 (early 2024);
# GitHub's repo tracks current releases, and unattended-upgrades keeps it there.
if [[ ! -f /etc/apt/sources.list.d/github-cli.list ]]; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
    chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list
fi

# Google Cloud CLI. GCE images ship it already; everywhere else (AWS) it comes
# from Google's repository. Each user's own `gcloud auth login` is what the
# host-side fiss-mcp (Terra) server runs on.
if ! command -v gcloud >/dev/null 2>&1 && [[ ! -f /etc/apt/sources.list.d/google-cloud-sdk.list ]]; then
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor --yes -o /etc/apt/keyrings/cloud.google.gpg
    chmod 0644 /etc/apt/keyrings/cloud.google.gpg
    echo "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list
fi

# Every package is load-bearing; SERVER.md "Host packages" has the table.
# nftables: the metadata-service block. systemd-container: machinectl, for
# becoming a sudo-less user with a real session. unattended-upgrades: security
# updates on a long-lived, shared host.
PKGS=(podman passt uidmap fuse-overlayfs crun dbus-user-session slirp4netns
      git jq fzf gh tmux curl ca-certificates gnupg nftables systemd-container
      unattended-upgrades)
command -v gcloud >/dev/null 2>&1 || PKGS+=(google-cloud-cli)
apt-get update -qq
apt-get install -y -qq "${PKGS[@]}" >/dev/null
note "podman $(podman --version | awk '{print $3}'), gh $(gh --version | awk 'NR==1{print $3}'), $(gcloud --version 2>/dev/null | head -1)"

# ------------------------------------------------------------------- uv ----
# Debian does not package uv. A pinned, checksum-verified binary in
# /usr/local/bin, rather than every user running `curl | sh`.
if [[ "$(uv --version 2>/dev/null | awk '{print $2}')" != "$UV_VERSION" ]]; then
    tmp=$(mktemp -d)
    base="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}"
    tarball="uv-$(uname -m)-unknown-linux-gnu.tar.gz"
    curl -fsSL -o "${tmp}/${tarball}" "${base}/${tarball}"
    curl -fsSL -o "${tmp}/${tarball}.sha256" "${base}/${tarball}.sha256"
    (cd "$tmp" && sha256sum -c "${tarball}.sha256" >/dev/null) || die "uv checksum mismatch"
    tar -xzf "${tmp}/${tarball}" -C /usr/local/bin --strip-components=1 --wildcards '*/uv' '*/uvx'
    rm -rf "$tmp"
fi
say "uv $(uv --version | awk '{print $2}')"

# ------------------------------------------------------------ data disk ----
say "data disk"
if [[ -n "$DATA_DEVICE" ]]; then
    dev=$(readlink -f "$DATA_DEVICE")
    [[ -b "$dev" ]] || die "$DATA_DEVICE is not a block device."
    root_src=$(findmnt -no SOURCE /)
    [[ "$root_src" != "$dev"* ]] || die "$DATA_DEVICE is the boot disk."
    fstype=$(blkid -o value -s TYPE "$dev" || true)
    if [[ -z "$fstype" ]]; then
        # Blank device: first boot of a new deployment. -m 0: no root reserve on
        # a data disk. Eager init so the disk is not slow for its first hours.
        mkfs.ext4 -q -m 0 -L sandbox-data -E lazy_itable_init=0,lazy_journal_init=0,discard "$dev"
        note "formatted $DATA_DEVICE (was blank)"
    else
        note "$DATA_DEVICE already has a ${fstype} filesystem; mounting it as-is"
    fi
    uuid=$(blkid -o value -s UUID "$dev")
    mkdir -p "$SANDBOX_ROOT"
    # Keyed on UUID: device names move between boots (the NVMe order on EC2, the
    # sda/sdb order on GCE). nofail: a missing disk must not wedge boot.
    if ! grep -q "UUID=${uuid}" /etc/fstab; then
        echo "UUID=${uuid} ${SANDBOX_ROOT} ext4 discard,defaults,nofail 0 2" >> /etc/fstab
        systemctl daemon-reload
    fi
    findmnt "$SANDBOX_ROOT" >/dev/null || mount "$SANDBOX_ROOT"
fi
findmnt "$SANDBOX_ROOT" >/dev/null \
    || die "$SANDBOX_ROOT is not a mount. Pass --data-device (SERVER.md: the data disk is mandatory)."
note "$(df -h --output=source,size,avail,target "$SANDBOX_ROOT" | tail -1)"

# Shared directories. users/ and plans/ are 1777 (sticky, like /tmp): anyone can
# create their own entry, nobody can remove anyone else's. That is what makes
# per-user setup need no admin. reference/ is admin-writable, world-readable.
chmod 755 "$SANDBOX_ROOT"
install -d -m 1777 "${SANDBOX_ROOT}/users" "${SANDBOX_ROOT}/plans"
install -d -m 0755 "${SANDBOX_ROOT}/reference"
note "users/ (1777), plans/ (1777), reference/ (755)"

# ------------------------------------------------------------- checkout ----
say "checkout"
REPO="${SANDBOX_ROOT}/repo"
if [[ ! -d "${REPO}/.git" ]]; then
    [[ -n "$REPO_OWNER" ]] || die "no --repo-owner and not run via sudo; cannot pick an owner for ${REPO}."
    install -d -o "$REPO_OWNER" -g "$REPO_OWNER" "$REPO"
    sudo -u "$REPO_OWNER" env GIT_TERMINAL_PROMPT=0 git clone --quiet "$REPO_URL" "$REPO"
    note "cloned ${REPO_URL} as ${REPO_OWNER}"
fi
chmod -R a+rX "$REPO"
note "${REPO} at $(git -c safe.directory="$REPO" -C "$REPO" log --oneline -1)"

# One command for users, on everyone's PATH. A symlink, so a `git pull` of the
# checkout updates it with no reinstall.
ln -sfn "${REPO}/scripts/sandbox" /usr/local/bin/sandbox
note "/usr/local/bin/sandbox -> ${REPO}/scripts/sandbox"

# A login hint, so nobody has to find the docs to know the first command.
cat > /etc/profile.d/zz-sandbox-hint.sh <<'HINT'
# Installed by scripts/setup-debian-host.sh.
case $- in *i*) ;; *) return 0 ;; esac
if [ "$(id -u)" -ne 0 ] && command -v sandbox >/dev/null 2>&1; then
    if [ -f "/mnt/sandbox/users/$USER/env.$USER.sh" ]; then
        echo "sandbox: 'sandbox claude' or 'sandbox agy' to start an agent, 'sandbox help' for more."
    else
        echo "sandbox: you are not set up yet. Run:  sandbox setup"
    fi
fi
HINT

# ----------------------------------------------------- metadata service ----
# EC2's instance metadata service (169.254.169.254) is reachable from inside a
# rootless container: pasta opens ordinary sockets on the host for it, so the
# IMDSv2 hop limit does not stop it. This instance has no IAM role, so there is
# no credential to steal, but user-data and instance details are still there.
# Close it to everything except root (cloud-init, which needs it at boot): pasta
# runs as the invoking user, so its sockets carry that user's uid.
if [[ "$IMDS_BLOCK" == auto && "$VENDOR" == "Amazon EC2" ]]; then
    say "metadata-service block (EC2)"
    install -d -m 0755 /etc/sandbox
    cat > /etc/sandbox/imds-block.nft <<'NFT'
# Installed by scripts/setup-debian-host.sh. Non-root users (and therefore every
# rootless container) cannot reach the EC2 instance metadata service.
table inet sandbox_imds
delete table inet sandbox_imds
table inet sandbox_imds {
    chain output {
        type filter hook output priority filter; policy accept;
        meta skuid != 0 ip daddr 169.254.169.254 counter reject
        meta skuid != 0 ip6 daddr fd00:ec2::254 counter reject
    }
}
NFT
    cat > /etc/systemd/system/sandbox-imds-block.service <<'UNIT'
[Unit]
Description=Block the EC2 instance metadata service for non-root users (sandbox)
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/sandbox/imds-block.nft
ExecStop=/usr/sbin/nft delete table inet sandbox_imds

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now sandbox-imds-block.service >/dev/null 2>&1
    systemctl restart sandbox-imds-block.service
    note "non-root access to 169.254.169.254 rejected (nft table inet sandbox_imds)"
fi

cat <<EOF

$(say "host ready")
Next (AWS.md / SERVER.md):
  1. Build the image, ~30 min:  sudo ${REPO}/scripts/build-shared-image.sh
  2. Add each user:             sudo ${REPO}/scripts/add-sandbox-user.sh <name> <pubkey-file>
  3. Each user logs in and runs: sandbox setup
EOF
