#!/usr/bin/env bash
# Idempotent installer for the host-side fiss-mcp server.
#
# Why host-side: keeping fiss-mcp out of the container removes gcloud, gsutil,
# google-cloud-* libs, and ~/.config/gcloud from the agent's reach. The only
# path to Terra/GCP from inside the sandbox is the MCP tools exposed by this
# server, which is read-only by default.
#
# Installs alongside this script (the host_fiss_mcp/ directory in the repo
# checkout), or under CLAUDE_SANDBOX_FISS_ROOT on a shared multi-user host.
# Re-run any time; skips work that is already done.
#
# Requires uv. All Python here is managed by uv — no pip, no `python3 -m venv`,
# and no dependency on the host's system interpreter.
set -euo pipefail

# Source dir: where this script and run-server.py live. Repo content, and on a
# shared multi-user host it may be a read-only checkout.
SRC_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# State dir: the venv and the pinned clone, both writable and per-user.
# CLAUDE_SANDBOX_FISS_ROOT moves them off a read-only checkout; unset keeps the
# original single-user layout with everything inside the repo.
STATE_ROOT="${CLAUDE_SANDBOX_FISS_ROOT:-$SRC_ROOT}"
mkdir -p "$STATE_ROOT"

SRC_DIR="${STATE_ROOT}/fiss-mcp"
VENV_DIR="${STATE_ROOT}/venv"

# Refuse to put per-user state in a directory belonging to someone else. On a
# shared host, STATE_ROOT falling back to SRC_ROOT means writing into the admin's
# checkout, and the failure it produces names neither the cause nor the fix:
#
#   fatal: detected dubious ownership in repository at
#          '/mnt/sandbox/repo/host_fiss_mcp/fiss-mcp'
#
# That is git refusing to touch the admin's clone -- correctly. Even if permissions
# allowed it, `git fetch`/`checkout` below would be mutating a clone other users
# share. Catching it here turns a confusing git error into an instruction.
if [[ -e "$STATE_ROOT" ]]; then
    _owner_uid="$(stat -c %u "$STATE_ROOT" 2>/dev/null || echo "")"
    if [[ -n "$_owner_uid" && "$_owner_uid" != "$(id -u)" ]]; then
        _owner_name="$(stat -c %U "$STATE_ROOT" 2>/dev/null || echo "uid ${_owner_uid}")"
        echo "host_fiss_mcp: refusing to install into a directory owned by ${_owner_name}:" >&2
        echo "                 ${STATE_ROOT}" >&2
        echo "" >&2
        if [[ -z "${CLAUDE_SANDBOX_FISS_ROOT:-}" ]]; then
            _guess="${CLAUDE_SANDBOX_ROOT:-/mnt/sandbox}/users/${USER}/env.${USER}.sh"
            echo "  CLAUDE_SANDBOX_FISS_ROOT is unset, so this defaulted to the shared" >&2
            echo "  checkout. Your env file sets it -- source it first:" >&2
            echo "" >&2
            echo "    source ${_guess}" >&2
            echo "    ./setup_host.sh" >&2
        else
            echo "  CLAUDE_SANDBOX_FISS_ROOT points at a directory you do not own." >&2
            echo "  Point it somewhere in your own tree." >&2
        fi
        exit 1
    fi
fi
REPO_URL="https://github.com/broadinstitute/fiss-mcp.git"

# Pinned release. Bump together with anything that depends on new fiss-mcp
# features. The marker file below keys off this string, so any change here
# triggers a full reinstall on the next setup_host.sh run.
FISS_MCP_REF="1.0.6"
FISS_MCP_REF_COMMIT="a4becf1cfadd0a94678f2383b6de9273a0bbebd5"

# Interpreter version for the venv.
#
# fiss-mcp declares requires-python >=3.10, but its dependency `firecloud`
# (0.16.x) is a legacy setup.py package and terra-mcp's own classifiers stop
# at 3.12. Hosts whose system python has moved ahead of that — Fedora 44 /
# Nobara 44 ship 3.14 — cannot build the dependency tree. Pin the venv to a
# known-good interpreter instead of inheriting whatever `python3` happens to
# be, and let uv fetch it if the host does not have it.
#
# Override with FISS_MCP_PYTHON=3.11 etc. if a specific version is needed.
FISS_MCP_PYTHON="${FISS_MCP_PYTHON:-3.12}"

# uv is REQUIRED. There is deliberately no `python3 -m venv` + pip fallback.
#
# The fallback used to exist for hosts without uv, but it is a trap on any
# current distro: it builds against the system python3, and firecloud 0.16.x is
# a legacy setup.py package that does not build on 3.13+. Debian 13 ships
# python 3.13, so the fallback would emit a warning and then produce a venv that
# fails at `import terra_mcp.server` — a slower, more confusing failure than
# simply requiring uv. uv also fetches the pinned interpreter itself, so it
# needs nothing from the host beyond its own binary.
UV_BIN="$(command -v uv 2>/dev/null || true)"
if [[ -z "$UV_BIN" ]]; then
  echo "host_fiss_mcp/install.sh: uv not found on PATH, and it is required." >&2
  echo "" >&2
  echo "  uv is not packaged in Debian/Ubuntu. Install it system-wide with:" >&2
  echo "    curl -LsSf https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz \\" >&2
  echo "      | sudo tar -xz -C /usr/local/bin --strip-components=1 --wildcards '*/uv' '*/uvx'" >&2
  echo "" >&2
  echo "  Why it is required: this venv is pinned to python ${FISS_MCP_PYTHON}." >&2
  echo "  fiss-mcp depends on firecloud 0.16.x, a legacy setup.py package that" >&2
  echo "  does not build on python 3.13+, which is what current distros ship." >&2
  exit 1
fi

if [[ ! -d "${SRC_DIR}/.git" ]]; then
  echo "host_fiss_mcp: cloning fiss-mcp into ${SRC_DIR} (ref=${FISS_MCP_REF})"
  git clone "${REPO_URL}" "${SRC_DIR}"
fi

# Pin to the expected release. Fetch the tag if missing (e.g. older clone),
# checkout, then verify the resolved commit matches the recorded SHA. Mismatch
# means the upstream tag was moved — abort rather than silently building a
# different version.
git -C "${SRC_DIR}" fetch --tags --quiet origin
git -C "${SRC_DIR}" checkout --quiet "${FISS_MCP_REF}"
RESOLVED="$(git -C "${SRC_DIR}" rev-parse HEAD)"
if [[ "${RESOLVED}" != "${FISS_MCP_REF_COMMIT}" ]]; then
  echo "host_fiss_mcp: tag ${FISS_MCP_REF} resolved to ${RESOLVED}," >&2
  echo "              expected ${FISS_MCP_REF_COMMIT}. Refusing to build a" >&2
  echo "              non-pinned revision. Re-confirm the upstream tag and" >&2
  echo "              update FISS_MCP_REF_COMMIT in this script." >&2
  exit 1
fi

# Treat a venv as usable only if its interpreter is actually there, and wipe a
# partial one so the create step is forced. Upstream's guard checked pyvenv.cfg,
# which a half-finished venv writes before failing, so a broken venv looked
# complete and the next step failed with "No such file or directory".
#
# The completeness test is bin/python, not bin/pip: `uv venv` deliberately does
# not seed pip into the venv (uv installs into it from outside). Testing for
# bin/pip would wipe and recreate a perfectly good venv on every run.
if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  if [[ -e "${VENV_DIR}" ]]; then
    echo "host_fiss_mcp: removing incomplete venv at ${VENV_DIR}"
    rm -rf "${VENV_DIR}"
  fi
  echo "host_fiss_mcp: creating venv at ${VENV_DIR} (uv, python ${FISS_MCP_PYTHON})"
  "$UV_BIN" venv --python "${FISS_MCP_PYTHON}" "${VENV_DIR}"
fi

# Marker file lets us skip the heavy pip step on repeat runs. The marker
# encodes the pinned ref + resolved commit, so any pin bump forces a
# reinstall on the next setup_host.sh run.
MARKER="${VENV_DIR}/.installed.marker"
EXPECTED_MARKER="fiss-mcp@${FISS_MCP_REF}+${FISS_MCP_REF_COMMIT}"
if [[ ! -f "${MARKER}" ]] || ! grep -q -x -F "${EXPECTED_MARKER}" "${MARKER}"; then
  echo "host_fiss_mcp: installing fiss-mcp + fastmcp into venv"
  # setuptools<80 first: firecloud builds via legacy setup.py and breaks on
  # setuptools 80+. --no-build-isolation then makes the editable build of
  # fiss-mcp reuse that pinned setuptools instead of pulling a fresh one.
  "$UV_BIN" pip install --python "${VENV_DIR}/bin/python" --quiet "setuptools<80"
  "$UV_BIN" pip install --python "${VENV_DIR}/bin/python" --quiet \
    --no-build-isolation -e "${SRC_DIR}"
  echo "${EXPECTED_MARKER}" > "${MARKER}"
fi

# Import check. The launcher only tests that venv/bin/python exists, so a venv
# that built but cannot import terra_mcp would fail later, inside the 30-second
# server-readiness wait, with a much less obvious error.
if ! "${VENV_DIR}/bin/python" -c 'import terra_mcp.server' 2>/dev/null; then
  echo "host_fiss_mcp: venv built but 'import terra_mcp.server' failed." >&2
  "${VENV_DIR}/bin/python" -c 'import terra_mcp.server' || true
  exit 1
fi

echo "host_fiss_mcp: ready — venv ${VENV_DIR}, source ${SRC_ROOT}"
