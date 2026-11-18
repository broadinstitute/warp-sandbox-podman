#!/usr/bin/env bash
# scripts/setup_host_podman.sh — host bootstrap for rootless-podman hosts.
#
# Selected by setup_host.sh when SETUP_HOST_OS=podman, or automatically when
# the host is RHEL/Fedora-family with podman present and no docker.
#
# This is deliberately NOT a port of setup_host_linux.sh. That script installs,
# via apt: Docker CE pinned to 28.x, sysbox-runc, and postfix. None of those
# apply here and two of them would be actively wrong:
#
#   * Docker + sysbox-runc — sysbox is a Docker-only OCI runtime shim; it needs
#     sysbox-mgr/sysbox-fs daemons and a rootful dockerd. There is no podman
#     equivalent, and installing rootful Docker alongside an existing rootless
#     podman setup would fragment image storage for no gain. Rootless podman's
#     user namespace already provides the host-filesystem isolation this
#     sandbox depends on.
#
#   * postfix — only feeds the optional email-notify hooks, which no-op when
#     CLAUDE_NOTIFY_EMAIL is unset. Installing and configuring a system MTA is
#     not a reasonable price for a feature that is off.
#
# So this script VERIFIES rather than installs. It touches no system state: no
# package installs, no systemd units, no writes outside the sandbox tree. The
# only thing it creates is the sandbox directory layout and the host-side
# fiss-mcp venv.
#
# Nothing here handles authentication. Terra/GCP access uses whatever gcloud
# credentials already exist on the host, and the operator runs any
# `gcloud auth login` themselves. Claude Code authenticates itself inside the
# container on first launch, with its own token and no host credential.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED=$'\033[1;31m'; YEL=$'\033[1;33m'; GRN=$'\033[1;32m'; RST=$'\033[0m'
FAIL=0
note()  { echo "  ${GRN}ok${RST}      $*"; }
warn()  { echo "  ${YEL}warn${RST}    $*"; }
fatal() { echo "  ${RED}FAIL${RST}    $*"; FAIL=1; }

echo
echo "=== container engine ==="

ENGINE="${CLAUDE_SANDBOX_ENGINE:-podman}"
if ! command -v "$ENGINE" >/dev/null 2>&1; then
  fatal "'$ENGINE' not on PATH."
elif ! info_err="$("$ENGINE" info 2>&1 >/dev/null)"; then
  # Every check below reads `podman info`. When that call itself fails they
  # would each report a wrong conclusion ("NOT rootless", "pasta not found"),
  # so report the real error once instead.
  fatal "'$ENGINE info' fails:"
  printf '%s\n' "$info_err" | tail -3 | sed 's/^/            /'
  if grep -q 'imagestore' <<<"$info_err"; then
    echo "          The shared image store is not readable. Either an admin is building"
    echo "          the image right now (it opens up when the build finishes), or its"
    echo "          permissions need: sudo chmod -R a+rX ${CLAUDE_SANDBOX_IMAGE_STORE:-/mnt/sandbox/imagestore}"
  fi
else
  ENGINE_VER="$("$ENGINE" --version 2>/dev/null | awk '{print $3}')"
  note "$ENGINE $ENGINE_VER"

  # keep-id:uid=... syntax landed in podman 4.3; the pasta network backend and
  # its -T option are the podman 5 defaults. Below 5.0 the launcher's
  # assumptions do not hold.
  ENGINE_MAJ="${ENGINE_VER%%.*}"
  if [[ -n "$ENGINE_MAJ" ]] && (( ENGINE_MAJ < 5 )); then
    fatal "podman >= 5.0 required (found ${ENGINE_VER}); needs pasta + keep-id:uid=."
  fi

  if [[ "$("$ENGINE" info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" == "true" ]]; then
    note "running rootless"
  else
    warn "podman is NOT rootless — the userns isolation this sandbox relies on is weaker."
  fi

  if [[ "$("$ENGINE" info --format '{{.Host.NetworkBackend}}' 2>/dev/null)" == "netavark" ]]; then
    note "network backend: netavark"
  else
    warn "network backend is not netavark; the pasta port forward may not apply."
  fi

  if "$ENGINE" info --format '{{.Host.Pasta.Executable}}' 2>/dev/null | grep -q pasta; then
    note "pasta present (host services reached via loopback forward)"
  else
    fatal "pasta not found. The launcher forwards host fiss-mcp over pasta -T."
  fi
fi

echo
echo "=== user namespace mapping ==="

# keep-id needs a subuid/subgid range wide enough to cover the image's uid
# plus the rest of the container's uid space.
for f in /etc/subuid /etc/subgid; do
  if line=$(grep -E "^${USER}:" "$f" 2>/dev/null); then
    count="${line##*:}"
    if (( count >= 65536 )); then
      note "$f: $line"
    else
      warn "$f range is only ${count} ids; 65536 recommended."
    fi
  else
    fatal "no entry for '${USER}' in $f. Run: sudo usermod --add-subuids 524288-589823 --add-subgids 524288-589823 ${USER}"
  fi
done

echo
echo "=== cgroup v2 resource delegation ==="

# CLAUDE_SANDBOX_MEMORY becomes --memory/--memory-swap. Rootless podman can
# only enforce those if systemd delegated the memory controller to the user
# slice; without it the flags are silently ignored and the RAM ceiling is a
# fiction.
CG_CTRL="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers"
if [[ -r "$CG_CTRL" ]]; then
  ctrls="$(cat "$CG_CTRL")"
  if grep -qw memory <<<"$ctrls"; then
    note "memory controller delegated ($ctrls)"
  else
    warn "memory controller NOT delegated ($ctrls) — CLAUDE_SANDBOX_MEMORY will not be enforced."
  fi
else
  warn "cannot read $CG_CTRL — unable to confirm cgroup v2 delegation."
fi

echo
echo "=== host tools ==="

command -v git >/dev/null 2>&1 && note "git $(git --version | awk '{print $3}')" \
                               || fatal "git not on PATH."
command -v jq  >/dev/null 2>&1 && note "jq present" \
                               || warn "jq missing on host (only needed in-container; image ships it)."
command -v uv  >/dev/null 2>&1 && note "uv $(uv --version 2>/dev/null | awk '{print $2}') (pins the fiss-mcp venv interpreter)" \
                               || warn "uv missing — fiss-mcp venv will fall back to system python3."
command -v fzf >/dev/null 2>&1 && note "fzf present (start_sandbox.sh menu available)" \
                               || warn "fzf missing — use ./run_claude_docker.sh directly, or install fzf for the menu."

if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
  warn "SELinux is $(getenforce). Bind mounts may need :z/:Z relabeling; if the"
  warn "container cannot read /workspace, that is the first thing to check."
fi

echo
echo "=== sandbox directory layout ==="

# Create exactly the directories the environment names, nothing else.
#
# Deliberately NOT derived from the checkout location: the code tree and the
# sandbox data tree are usually on different filesystems (code in ~/git, state
# and workspace on a data volume), and guessing from $REPO_ROOT would scatter
# empty workspace/ context/ state/ dirs next to the checkout.
#
# Source an env file first to have its paths picked up here:
#   source env.<INSTANCE>.sh && ./setup_host.sh
declare -a WANTED=()
[[ -n "${CLAUDE_SANDBOX_PROJECTS_DIR:-}" ]] && WANTED+=("${CLAUDE_SANDBOX_PROJECTS_DIR}")
[[ -n "${CLAUDE_SANDBOX_CONTEXT_DIR:-}"  ]] && WANTED+=("${CLAUDE_SANDBOX_CONTEXT_DIR}")
[[ -n "${CLAUDE_SANDBOX_HOME:-}"         ]] && WANTED+=("${CLAUDE_SANDBOX_HOME}")

SANDBOX_ROOT_GUESS="${CLAUDE_SANDBOX_ROOT:-/mnt/sandbox}"
USER_ENV_FILE="${SANDBOX_ROOT_GUESS}/users/${USER}/env.${USER}.sh"

if (( ${#WANTED[@]} == 0 )) && [[ ! -f "$USER_ENV_FILE" && -d "${SANDBOX_ROOT_GUESS}/users" ]]; then
  # Shared host, but this user has no env file at all: step 1 has not been run.
  # Do not just warn. Pasting the step-4 block into a shell runs `./setup_host.sh`
  # even after `source` fails ("No such file or directory") because a failed source
  # does not abort an interactive shell, so the run continues and dies further down
  # in fiss-mcp with a git ownership error that says nothing about the real problem.
  fatal "you have not been provisioned yet — step 1 has not run."
  echo "          There is no env file at:"
  echo "            ${USER_ENV_FILE}"
  echo
  echo "          Run step 1 first, then step 4 (all in the same shell):"
  echo
  echo "            cd ${REPO_ROOT}"
  echo "            ./scripts/provision-sandbox-user.sh"
  echo "            source ${USER_ENV_FILE}"
  echo "            ./setup_host.sh"
  echo
  echo "          Step 1 creates your directories, clones warp and warp-tools, and"
  echo "          writes that env file. It needs no root and touches nothing of"
  echo "          anyone else's."
elif (( ${#WANTED[@]} == 0 )) && [[ -f "$USER_ENV_FILE" ]]; then
  # A provisioned per-user env file exists but was not sourced. This used to be a
  # warning that then let the run continue, which was worse than useless: the very
  # next step (fiss-mcp) reads CLAUDE_SANDBOX_FISS_ROOT from that same file, and
  # without it the installer falls back to the SHARED checkout and dies with
  #     fatal: detected dubious ownership in repository at
  #            '<repo>/host_fiss_mcp/fiss-mcp'
  # because that clone belongs to whoever set the host up. One unsourced file, two
  # confusing failures, neither of which names the cause. So: stop here.
  fatal "your env file exists but has not been sourced into this shell."
  echo "          Run all three commands together (step 4 in USER-SETUP.md):"
  echo
  echo "            cd ${REPO_ROOT}"
  echo "            source ${USER_ENV_FILE}"
  echo "            ./setup_host.sh"
  echo
  echo "          Sourcing it is what sets CLAUDE_SANDBOX_PROJECTS_DIR,"
  echo "          CLAUDE_SANDBOX_HOME and CLAUDE_SANDBOX_FISS_ROOT. Without them"
  echo "          this script cannot tell your directories from anyone else's."
elif (( ${#WANTED[@]} == 0 )); then
  warn "no CLAUDE_SANDBOX_{PROJECTS_DIR,CONTEXT_DIR,HOME} in the environment."
  warn "Nothing to create. Source your env.<INSTANCE>.sh first if you want"
  warn "this step to provision the sandbox directories."
else
  for d in "${WANTED[@]}"; do
    if [[ -d "$d" ]]; then
      note "exists: $d"
    else
      mkdir -p "$d" && note "created: $d"
    fi
  done
fi

echo
echo "=== host-side fiss-mcp (Terra MCP) ==="

if [[ "${FISS_MCP:-1}" == "1" ]]; then
  if [[ "$FAIL" == "1" ]]; then
    warn "skipping fiss-mcp install while checks above are failing."
  else
    "${REPO_ROOT}/host_fiss_mcp/install.sh"
    note "fiss-mcp venv ready"
  fi

  # Report credential state; never mutate it. Auth is the operator's job --
  # this script must not run `gcloud auth login`, and no credential ever
  # enters the container.
  if command -v gcloud >/dev/null 2>&1; then
    note "gcloud: $(command -v gcloud)"
    active="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
    if [[ -n "$active" ]]; then
      note "active gcloud account: $active"
    else
      warn "no active gcloud account. Run: gcloud auth login"
    fi
    adc="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"
    if [[ -f "$adc" ]]; then
      note "application-default credentials present"
    else
      warn "no ADC at $adc. fiss-mcp needs it. Run: gcloud auth application-default login"
    fi
  else
    warn "gcloud not on PATH — fiss-mcp cannot reach Terra. Set FISS_MCP=0 to launch without it."
  fi
else
  note "FISS_MCP=0 — skipping Terra MCP setup."
fi

echo
if [[ "$FAIL" == "1" ]]; then
  echo "${RED}setup_host_podman.sh: one or more required checks FAILED (see above).${RST}"
  exit 1
fi

cat <<EOF
${GRN}setup_host_podman.sh: host is ready.${RST}

Nothing was installed and no system state was changed.

This is step 4 of "Per-user setup" in USER-SETUP.md. Continue there with step 5.

The README is the single source of truth for the ordering; this script does not
repeat it, so the two cannot drift apart.

Note: you do NOT build the container image. An admin builds it once into a shared
read-only store (scripts/build-shared-image.sh), so every user provably runs the
same image, and 'make' is deliberately absent from the host.

No log-out/log-in is needed: rootless podman uses no docker group.
EOF
