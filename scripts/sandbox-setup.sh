#!/usr/bin/env bash
# scripts/sandbox-setup.sh — guided per-user setup on a shared sandbox host.
# Usually run as `sandbox setup`. Run it as yourself: no root, no sudo.
#
# Safe to re-run at any time. Every step checks whether it is already done and
# skips it, so the same command finishes a setup that was interrupted, repairs one
# that broke, and is a no-op on one that is complete.
#
#   1. GitHub    gh auth login (a one-time code you enter on your laptop), then
#                gh auth setup-git, and your git name/email for commits.
#                First, so that step 2 can clone the PRIVATE seed repos too.
#   2. Provision your directories, Claude settings, env file, image-store config
#                and linger; clones warp, warp-tools and the other seed repos
#                (scripts/provision-sandbox-user.sh).
#   3. Google    gcloud auth login --update-adc: ONE browser sign-in that covers
#                both gcloud and the application-default credentials the
#                host-side Terra server (fiss-mcp) runs on. Skippable if you do
#                not use Terra.
#   4. fiss-mcp  builds your own venv for the Terra MCP server (setup_host.sh).
#   5. Agents    nothing to run here: `sandbox claude` and `sandbox agy` each ask
#                you to sign in on their first launch. This step reports status.
#
# Options
#   --check        report what is done and what is not; change nothing
#   --skip-google  skip step 3 (no Terra tools until you run it again)
#   -y, --yes      do not ask before each login, just start it
#
# USER-SETUP.md explains each step and its failure modes; this script is the
# automation of exactly that, so the two describe the same thing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SANDBOX_ROOT="${CLAUDE_SANDBOX_ROOT:-/mnt/sandbox}"
USER_ROOT="${SANDBOX_ROOT}/users/${USER}"
ENV_FILE="${USER_ROOT}/env.${USER}.sh"

CHECK=0; SKIP_GOOGLE=0; ASSUME_YES=0
for a in "$@"; do
    case "$a" in
        --check)       CHECK=1 ;;
        --skip-google) SKIP_GOOGLE=1 ;;
        -y|--yes)      ASSUME_YES=1 ;;
        -h|--help)     sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
    esac
done
# Logins need a person at a terminal. Without one, report instead of hanging.
[[ -t 0 && -t 1 ]] || CHECK=1

RED=$'\033[1;31m'; YEL=$'\033[1;33m'; GRN=$'\033[1;32m'; BLD=$'\033[1m'; RST=$'\033[0m'
ok()    { echo "  ${GRN}done${RST}    $*"; }
todo()  { echo "  ${YEL}todo${RST}    $*"; PENDING=1; }
info()  { echo "          $*"; }
step()  { echo; echo "${BLD}$*${RST}"; }
PENDING=0

if [[ "$(id -u)" == "0" ]]; then
    echo "Run this as yourself, not as root: it sets up whoever runs it." >&2
    exit 1
fi

# Ask before starting an interactive login. Default yes.
confirm() {
    (( ASSUME_YES )) && return 0
    local reply
    read -r -p "          $1 [Y/n] " reply || return 1
    [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

echo "${BLD}Sandbox setup for ${USER} on $(hostname)${RST}$( (( CHECK )) && echo '  (check only: nothing will change)')"

# ----------------------------------------------------------------- GitHub ----
step "1. GitHub — so you can push what the agent commits, and clone private repos"
gh_logged_in() { gh auth status --hostname github.com >/dev/null 2>&1; }
if ! command -v gh >/dev/null 2>&1; then
    todo "gh is not installed on this host — ask the admin (scripts/setup-debian-host.sh installs it)"
else
    if ! gh_logged_in && (( ! CHECK )) && confirm "Log in to GitHub now?"; then
        info "gh prints a one-time code. Open ${BLD}https://github.com/login/device${RST} on your laptop and"
        info "enter it there. (If gh says it cannot open a browser, that is expected on a server.)"
        echo
        gh auth login --hostname github.com --git-protocol https --web || true
    fi
    if gh_logged_in; then
        ok "logged in to GitHub as $(gh api user --jq .login 2>/dev/null || echo '?')"
        # Login alone does not make `git push` use the token; setup-git does.
        if ! git config --global --get-all credential.helper 2>/dev/null | grep -q 'gh auth git-credential'; then
            if (( CHECK )); then
                todo "git is not wired to gh: gh auth setup-git"
            else
                gh auth setup-git && ok "git push now uses your GitHub login (gh auth setup-git)"
            fi
        else
            ok "git uses it for push (credential.helper)"
        fi
        # The launcher forwards your host git identity into the container, which
        # is how the agent's commits are attributed to you. Without one,
        # `git commit` inside fails with "Author identity unknown".
        name="$(git config --global user.name || true)"
        email="$(git config --global user.email || true)"
        if [[ -z "$name" || -z "$email" ]] && (( ! CHECK )); then
            gh_name="$(gh api user --jq '.name // empty' 2>/dev/null || true)"
            gh_mail="$(gh api user --jq '.email // empty' 2>/dev/null || true)"
            info "Commits need a name and email (use the address your team's repos expect)."
            [[ -n "$name" ]]  || { read -r -p "          git user.name [${gh_name}]: " name || true;  name="${name:-$gh_name}"; }
            [[ -n "$email" ]] || { read -r -p "          git user.email [${gh_mail}]: " email || true; email="${email:-$gh_mail}"; }
            [[ -n "$name" ]]  && git config --global user.name "$name"
            [[ -n "$email" ]] && git config --global user.email "$email"
        fi
        if [[ -n "$(git config --global user.name || true)" && -n "$(git config --global user.email || true)" ]]; then
            ok "git identity: $(git config --global user.name) <$(git config --global user.email)>"
        else
            todo "set a git identity: git config --global user.name ...; git config --global user.email ..."
        fi
    else
        todo "not logged in to GitHub — re-run 'sandbox setup' (private seed repos are skipped until then)"
    fi
fi

# -------------------------------------------------------------- provision ----
step "2. Your sandbox — directories, settings, env file, repos"
if (( CHECK )); then
    if [[ -f "$ENV_FILE" ]]; then ok "provisioned (${ENV_FILE})"; else todo "not provisioned yet"; fi
else
    "${REPO_ROOT}/scripts/provision-sandbox-user.sh" --no-next-steps \
        || { echo "${RED}Provisioning stopped; fix what it reports above, then re-run: sandbox setup${RST}"; exit 1; }
fi
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

# ----------------------------------------------------------------- Google ----
step "3. Google Cloud — for the Terra tools (fiss-mcp), which run on the host as you"
adc="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"
gcloud_account() { gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true; }
if ! command -v gcloud >/dev/null 2>&1; then
    todo "gcloud is not installed on this host — ask the admin"
elif (( SKIP_GOOGLE )); then
    info "skipped (--skip-google). Terra tools will not work until you run 'sandbox setup' without it."
else
    if [[ -z "$(gcloud_account)" || ! -f "$adc" ]] && (( ! CHECK )) \
       && confirm "Log in to Google Cloud now (the Google account registered with Terra)?"; then
        info "gcloud prints a URL. Open it on your laptop, sign in, and paste the code it shows back here."
        echo
        if [[ -z "$(gcloud_account)" ]]; then
            # --update-adc: the same sign-in also writes the application-default
            # credentials fiss-mcp uses. One browser round trip instead of two.
            gcloud auth login --update-adc --no-launch-browser || true
        else
            gcloud auth application-default login --no-launch-browser || true
        fi
    fi
    acct="$(gcloud_account)"
    if [[ -n "$acct" && -f "$adc" ]]; then
        ok "gcloud: ${acct}, with application-default credentials"
    elif [[ -n "$acct" ]]; then
        todo "gcloud is logged in as ${acct} but has no application-default credentials (fiss-mcp needs them)"
    else
        todo "not logged in to Google Cloud (only the Terra tools need it)"
    fi
fi

# --------------------------------------------------------------- fiss-mcp ----
step "4. Terra MCP server — your own venv"
if [[ -z "${CLAUDE_SANDBOX_FISS_ROOT:-}" ]]; then
    todo "needs step 2 first"
elif [[ -x "${CLAUDE_SANDBOX_FISS_ROOT}/venv/bin/python" ]] && (( CHECK )); then
    ok "venv present (${CLAUDE_SANDBOX_FISS_ROOT}/venv)"
elif (( CHECK )); then
    todo "venv not built yet"
else
    # setup_host.sh is idempotent: it re-installs only when the pinned fiss-mcp
    # version changed. Its full output is long; keep it, but in a log.
    log="${USER_ROOT}/setup_host.log"
    if (cd "$REPO_ROOT" && ./setup_host.sh) >"$log" 2>&1; then
        ok "venv ready (${CLAUDE_SANDBOX_FISS_ROOT}/venv; log: ${log})"
    else
        todo "setup_host.sh failed — see ${log}"
        tail -15 "$log" | sed 's/^/          /'
    fi
fi

# ----------------------------------------------------------------- agents ----
step "5. Agents — each asks you to sign in on its first launch"
state="${CLAUDE_SANDBOX_SHARED:-${USER_ROOT}/shared}"
if [[ -s "${state}/.claude/.credentials.json" ]]; then
    ok "Claude Code: signed in"
else
    info "Claude Code: run ${BLD}sandbox claude${RST}. Pick the first login option (Claude account with"
    info "subscription), open the URL it prints on your laptop, paste the code back."
fi
if [[ -n "${GEMINI_API_KEY:-}" ]]; then
    ok "Antigravity: GEMINI_API_KEY is set in your env file"
elif [[ -n "$(find "${state}/.gemini" "${state}/.config/antigravity" -maxdepth 3 -name '*oauth-token*' -size +0 2>/dev/null | head -1)" ]]; then
    ok "Antigravity: signed in"
else
    info "Antigravity: run ${BLD}sandbox agy${RST}. It prints a sign-in URL to open on your laptop and"
    info "waits for the code. Which Google account to use matters: see USER-SETUP.md,"
    info "\"Antigravity sign-in\", before you pick one."
fi

echo
if (( PENDING )); then
    echo "${YEL}Some steps are not done yet (todo above).${RST} Re-run ${BLD}sandbox setup${RST} any time; it skips what is done."
else
    echo "${GRN}Setup complete.${RST}"
fi
cat <<EOF

  sandbox claude          start Claude Code     (sandbox claude --continue to resume)
  sandbox agy             start Antigravity     (sandbox agy -c to resume)
  sandbox status          what is set up and running
  sandbox help            everything else

  Your files: ${USER_ROOT}/workspace is /workspace inside (repos live there);
  ${USER_ROOT}/context is /context, read-only to the agent.
EOF
