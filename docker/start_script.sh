#!/usr/bin/env bash
set -euo pipefail

# Which agent this container runs, set by the launcher from SANDBOX_AGENT:
#   claude  Claude Code (the default)
#   agy     Antigravity CLI, Google's terminal agent
#   shell   bash, with the Claude setup below applied, for debugging
SANDBOX_AGENT="${SANDBOX_AGENT:-claude}"

# Start the postfix service for mail notifications.
#
# Non-fatal. Mail is optional (the notify hooks no-op when CLAUDE_NOTIFY_EMAIL
# is unset) and postfix's relay target is the host's MTA, which may not exist.
# More importantly this script runs as the unprivileged `claude` user, so
# under rootless podman `service postfix start` cannot bind and exits
# non-zero — with `set -e` that would abort startup before claude ever runs.
# Swallow the failure and keep going.
if ! service postfix start 2>/dev/null; then
  echo "postfix: not started (mail notifications unavailable) — continuing"
fi

# Start the docker service so we can run docker in a docker for tests.
# Self-skips when SANDBOX_HAS_DIND=0, which the podman launcher always sets
# (no sysbox-runc equivalent exists, so a nested dockerd cannot mount overlay2).
~/start_dockerd.sh

# Git identity for read-write project mounts. /home/claude/.gitconfig is not in
# the image and not bind-mounted, so without this `git commit` fails outright
# with "Author identity unknown". The launcher forwards the host's name/email
# (identity only -- no credential helper, no token, and the host ~/.gitconfig is
# never mounted).
#
# Written to GLOBAL config on purpose: GIT_AUTHOR_*/GIT_COMMITTER_* env vars
# would outrank a mounted repository's own user.email, silently mislabelling
# commits there. Global config ranks below repo-local, so per-repo identity wins.
if [[ -n "${SANDBOX_GIT_USER_NAME:-}" ]]; then
  git config --global user.name "${SANDBOX_GIT_USER_NAME}"
fi
if [[ -n "${SANDBOX_GIT_USER_EMAIL:-}" ]]; then
  git config --global user.email "${SANDBOX_GIT_USER_EMAIL}"
fi
if [[ -n "${SANDBOX_GIT_USER_EMAIL:-}${SANDBOX_GIT_USER_NAME:-}" ]]; then
  echo "git identity: ${SANDBOX_GIT_USER_NAME:-?} <${SANDBOX_GIT_USER_EMAIL:-?}> (commits local only; no push credentials in sandbox)"
fi

# ======================================================= Claude Code setup ==
# Everything from here to "end Claude Code setup" configures claude: the
# Anthropic routing (Vertex, Headroom), its MCP entries in ~/.claude.json, and
# the plugins it loads. None of it applies to agy, whose container does not
# even mount the Claude state, so it is skipped there. (Not re-indented, to keep
# the history of this block readable.)
if [[ "$SANDBOX_AGENT" != "agy" ]]; then

# Vertex routing signal (Option B). When the host launcher spawned
# vertex_proxy.py and forwarded its URL via ANTHROPIC_TARGET_API_URL, that
# becomes the upstream for Anthropic-shape traffic instead of api.anthropic.com.
# Headroom (when on) natively reads ANTHROPIC_TARGET_API_URL via its
# --backend anthropic / --anthropic-api-url path, so we just export it and
# the headroom spawn below picks it up. With headroom OFF we point claude at
# vertex_proxy directly via ANTHROPIC_BASE_URL further down.
if [[ -n "${ANTHROPIC_TARGET_API_URL:-}" ]]; then
  export ANTHROPIC_TARGET_API_URL
  echo "vertex routing: ON  upstream=${ANTHROPIC_TARGET_API_URL}"
fi

# Headroom proxy (opt-in, set HEADROOM=1 at launch).
# When on, intercepts Claude Code traffic on localhost:$HEADROOM_PORT and
# compresses prompts/tool outputs before forwarding upstream — either to
# api.anthropic.com (default) or to the URL in ANTHROPIC_TARGET_API_URL when
# the launcher set one (Vertex mode). Process dies with the container; no
# persistent state.
HEADROOM_PORT="${HEADROOM_PORT:-8787}"
if [[ "${HEADROOM:-0}" == "1" ]]; then
  if ! command -v headroom >/dev/null 2>&1; then
    echo "headroom: binary missing — image needs rebuild with headroom-ai[proxy]" >&2
    exit 1
  fi
  echo "headroom: starting on :${HEADROOM_PORT}"
  headroom proxy --no-telemetry --port "${HEADROOM_PORT}" >/tmp/headroom.log 2>&1 &
  HR_PID=$!
  trap 'kill "${HR_PID}" 2>/dev/null || true' EXIT

  # Startup is slow on purpose: headroom-ai[proxy] imports transformers for
  # tokenization, which costs ~25-30s in this image before the port binds. A
  # 25s budget used to just barely fit and now races — allow 90s. The loop
  # also bails early if headroom died, so a genuine crash still fails fast
  # instead of burning the full timeout.
  echo -n "Waiting for headroom proxy to start "
  for _ in {1..90}; do
    curl -fsS "http://127.0.0.1:${HEADROOM_PORT}/readyz" >/dev/null 2>&1 && break
    kill -0 "${HR_PID}" 2>/dev/null || break
    echo -n "."
    sleep 1
  done
  echo

  if ! curl -fsS "http://127.0.0.1:${HEADROOM_PORT}/readyz" >/dev/null 2>&1; then
    if kill -0 "${HR_PID}" 2>/dev/null; then
      echo "headroom: still not ready after 90s (process alive) — see /tmp/headroom.log" >&2
    else
      echo "headroom: process exited during startup — see /tmp/headroom.log" >&2
    fi
    tail -20 /tmp/headroom.log >&2 || true
    exit 1
  fi

  export ANTHROPIC_BASE_URL="http://127.0.0.1:${HEADROOM_PORT}"
  echo "headroom: ON  ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}"
else
  if [[ -n "${ANTHROPIC_TARGET_API_URL:-}" ]]; then
    # No headroom layer — claude talks to vertex_proxy directly. Skip the
    # compression step but keep the gcloud-token-on-host routing.
    export ANTHROPIC_BASE_URL="${ANTHROPIC_TARGET_API_URL}"
    echo "headroom: OFF  vertex direct  ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}"
  else
    echo "headroom: OFF"
  fi
fi

# fiss-mcp (Terra MCP). Server lives on the HOST; the launcher (run script)
# spawned it and passed its URL via FISS_MCP_URL. We register an HTTP MCP
# entry in ~/.claude.json pointing at that URL. FISS_MCP=0 removes the entry.
# Mutating .claude.json here is race-free — claude has not started yet.
#
# Note: ~/.claude.json is bind-mounted from the host, so rename(2) (`mv`) on
# it fails with EBUSY. We write the temp file, then overwrite in place with
# `cat > ...` to preserve the bind-mounted inode.
CLAUDE_JSON="${HOME}/.claude.json"
[ -s "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"

if [[ "${FISS_MCP:-1}" == "1" ]]; then
  if [[ -z "${FISS_MCP_URL:-}" ]]; then
    echo "fiss-mcp: WARNING — FISS_MCP=1 but FISS_MCP_URL is empty." >&2
    echo "          The host launcher did not advertise an MCP server. Skipping registration." >&2
    jq 'if .mcpServers? then .mcpServers |= del(.["fiss-mcp"]) else . end' \
       "$CLAUDE_JSON" > "${CLAUDE_JSON}.tmp" && cat "${CLAUDE_JSON}.tmp" > "$CLAUDE_JSON" && rm "${CLAUDE_JSON}.tmp"
  else
    jq --arg url "${FISS_MCP_URL}" \
       '.mcpServers["fiss-mcp"] = {
          type: "http",
          url: $url
        }' "$CLAUDE_JSON" > "${CLAUDE_JSON}.tmp" && cat "${CLAUDE_JSON}.tmp" > "$CLAUDE_JSON" && rm "${CLAUDE_JSON}.tmp"

    if [[ "${FISS_MCP_ALLOW_WRITES:-0}" == "1" ]]; then
      # Second banner inside the container so the warning shows up even when
      # the host launcher's output has scrolled off, or when somebody execs
      # into a running container and restarts claude. Banner is pre-rendered
      # figlet output (font: standard) — no runtime figlet dependency.
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
      echo "${YEL}fiss-mcp (host) running with --allow-writes.${RST}"
      echo "${YEL}Agent can submit workflows and mutate workspace state.${RST}"
      echo "fiss-mcp: ON  ${FISS_MCP_URL}  (WRITE MODE)"
    else
      echo "fiss-mcp: ON  ${FISS_MCP_URL}  (read-only)"
    fi
  fi
else
  jq 'if .mcpServers? then .mcpServers |= del(.["fiss-mcp"]) else . end' \
     "$CLAUDE_JSON" > "${CLAUDE_JSON}.tmp" && cat "${CLAUDE_JSON}.tmp" > "$CLAUDE_JSON" && rm "${CLAUDE_JSON}.tmp"
  echo "fiss-mcp: OFF"
fi

# CodeGraph MCP (local stdio). Binary baked into image at /usr/local/bin/codegraph.
# Claude Code spawns `codegraph serve --mcp` per-session via the mcpServers entry
# we drop into ~/.claude.json here. Disable by setting CODEGRAPH=0.
if [[ "${CODEGRAPH:-1}" == "1" ]] && command -v codegraph >/dev/null 2>&1; then
  jq '.mcpServers["codegraph"] = {
        type: "stdio",
        command: "codegraph",
        args: ["serve", "--mcp"]
      }' "$CLAUDE_JSON" > "${CLAUDE_JSON}.tmp" && cat "${CLAUDE_JSON}.tmp" > "$CLAUDE_JSON" && rm "${CLAUDE_JSON}.tmp"
  echo "codegraph: ON  $(codegraph --version 2>/dev/null || echo '(version unknown)')"
else
  jq 'if .mcpServers? then .mcpServers |= del(.["codegraph"]) else . end' \
     "$CLAUDE_JSON" > "${CLAUDE_JSON}.tmp" && cat "${CLAUDE_JSON}.tmp" > "$CLAUDE_JSON" && rm "${CLAUDE_JSON}.tmp"
  echo "codegraph: OFF"
fi

# caveman and ponytail come from the image (/opt/sandbox/plugins: each one's
# newest release as of the image build) and load with --plugin-dir, added to the
# claude command line at the bottom of this script. Nothing is installed into the
# user's own state, so there is nothing per user to go stale. A plugin of the
# same name that an older settings.json still installs from a marketplace is
# overridden by these (Claude Code: "--plugin-dir ... local dev copies now
# override installed marketplace plugins with the same name").
CLAUDE_PLUGIN_ARGS=()
plugin_names=""
for d in /opt/sandbox/plugins/*/; do
  [[ -f "${d}.claude-plugin/plugin.json" ]] || continue
  CLAUDE_PLUGIN_ARGS+=(--plugin-dir "${d%/}")
  plugin_names="${plugin_names:+${plugin_names}, }$(basename "$d") $(jq -r '.version // "?"' "${d}.claude-plugin/plugin.json" 2>/dev/null || echo '?')"
done
echo "plugins: ${plugin_names:-none} (from the image)"

fi  # ================================================= end Claude Code setup ==

# ========================================================= Antigravity setup ==
# agy keeps its state in ~/.gemini (settings, sign-in token, conversations) and
# ~/.config/antigravity (plugin secrets). The launcher bind-mounts both from the
# user's own state directory, and only into an agy container, so a Claude
# session never sees the Antigravity token and vice versa.
#
# Nothing here signs in. The first `agy` run asks how to sign in and, with no
# browser in the container, prints a URL to open on your laptop and waits for the
# code; with no D-Bus session it stores the token in a file under ~/.gemini
# (measured: "Using file-based token storage because no D-Bus session bus
# detected"), which is what makes it persist across launches.
AGY_DEFAULTS=/opt/sandbox/agy

# Point $1 at $2 with a symlink, unless $1 is the user's own regular file.
link_rule() {
  local link="$1" target="$2"
  if [[ -e "$link" && ! -L "$link" ]]; then
    echo "agy: keeping your own $(basename "$link") (not linking it to ${target})"
    return 0
  fi
  ln -sfn "$target" "$link"
}

# caveman and ponytail. Claude gets them as plugins whose hooks switch each mode
# on in every session. agy runs neither plugin, so it gets each one's own
# always-on rule text instead, read from the image's copy of the plugin
# (/opt/sandbox/plugins, the newest release as of the image build): the file each
# plugin ships for agents without hooks. Each is written to
# ~/.gemini/config/rules/sandbox-<name>.md with the frontmatter agy requires (a
# rule file without it is silently dropped), unless the plugin's file already has
# frontmatter of its own. Rewritten every launch; a user's other rule files are not
# touched. A plugin release that moved its file is skipped with a warning.
write_mode_rules() {
  local dir="${HOME}/.gemini/config/rules" spec name src names=""
  mkdir -p "$dir"
  rm -f "$dir"/sandbox-*.md
  for spec in caveman:src/rules/caveman-activate.md ponytail:.agents/rules/ponytail.md; do
    name="${spec%%:*}" src="/opt/sandbox/plugins/${spec%%:*}/${spec#*:}"
    if [[ ! -f "$src" ]]; then
      echo "agy: WARNING — this image's ${name} has no ${spec#*:}; agy runs without ${name}." >&2
      continue
    fi
    if [[ "$(head -n 1 "$src")" == "---" ]]; then
      cp "$src" "${dir}/sandbox-${name}.md" || return 1
    else
      { printf -- '---\ntrigger: always_on\ndescription: "%s mode, from the %s plugin (sandbox default)"\n---\n\n' "$name" "$name"
        cat "$src"; } > "${dir}/sandbox-${name}.md" || return 1
    fi
    names="${names:+${names}, }${name}"
  done
  echo "agy: always-on rules: ${names:-none}"
}

setup_agy() {
  local settings="${HOME}/.gemini/antigravity-cli/settings.json" tmp
  mkdir -p "${HOME}/.gemini/antigravity-cli" "${HOME}/.gemini/config" "${HOME}/.config/antigravity"

  # Settings: seed on first launch, then on every launch re-assert only the
  # sandbox's own entries (the deny rules and the trusted /workspace), merged
  # into whatever the user has set. A user's model choice, allow rules and other
  # preferences survive; the deny rules cannot be removed by editing the file.
  [[ -s "$settings" ]] || cp "${AGY_DEFAULTS}/settings.json" "$settings"
  tmp="${settings}.sandbox-tmp"
  # GEMINI_API_KEY decides the model provider. With a key, agy needs
  # "modelProvider": "gemini" in settings or it ignores the key; without one,
  # that same setting makes agy refuse to start. So derive it from the env.
  # toolPermission "always-proceed" is agy's no-prompts mode (what
  # --dangerously-skip-permissions sets), the counterpart of Claude's
  # bypassPermissions here. Set only when absent, so a user's own choice in
  # /config (Tool Permission) stays. Deny rules still apply under it.
  if jq -s --arg key "${GEMINI_API_KEY:+set}" '
        .[1] as $sbx | .[0]
        | .permissions.deny = (((.permissions.deny // []) + ($sbx.permissions.deny // [])) | unique)
        | .trustedWorkspaces = (((.trustedWorkspaces // []) + ($sbx.trustedWorkspaces // [])) | unique)
        | .toolPermission //= "always-proceed"
        | if $key == "set" then .modelProvider = "gemini"
          elif .modelProvider == "gemini" then del(.modelProvider)
          else . end' \
        "$settings" "${AGY_DEFAULTS}/settings.json" > "$tmp" 2>/dev/null; then
    cat "$tmp" > "$settings"
  else
    echo "agy: WARNING — ${settings} is not valid JSON; sandbox deny rules NOT applied." >&2
  fi
  rm -f "$tmp"
  if [[ -n "${GEMINI_API_KEY:-}" ]]; then
    echo "agy: model provider = Gemini API key (GEMINI_API_KEY)"
  else
    echo "agy: model provider = Google sign-in (first run prints a URL to open on your laptop)"
  fi
  echo "agy: tool permission = $(jq -r '.toolPermission // "request-review"' "$settings" 2>/dev/null || echo unknown)  (change: /config → Tool Permission)"

  # Global rules. ~/.gemini/GEMINI.md and ~/.gemini/AGENTS.md are both read as
  # global rules (symlinks allowed). GEMINI.md carries the sandbox rules;
  # AGENTS.md is warp/AGENTS.md, the role ~/.claude/CLAUDE.md's @import plays
  # for Claude. A user's own regular file at either path is left alone.
  link_rule "${HOME}/.gemini/GEMINI.md" "${AGY_DEFAULTS}/GEMINI.md"
  local agents_md
  for agents_md in /workspace/warp/AGENTS.md /projects/warp/AGENTS.md; do
    if [[ -f "$agents_md" ]]; then
      link_rule "${HOME}/.gemini/AGENTS.md" "$agents_md"
      break
    fi
  done

  write_mode_rules || echo "agy: WARNING — could not write the caveman/ponytail rules; agy starts without them." >&2

  # MCP servers, through agy's own CLI rather than by writing its config file,
  # so a change of format between agy releases cannot silently break them.
  # `agy mcp add` replaces an existing entry; `remove` of a missing one exits 1.
  if [[ "${FISS_MCP:-1}" == "1" && -n "${FISS_MCP_URL:-}" ]]; then
    agy mcp add fiss-mcp "${FISS_MCP_URL}" >/dev/null
    if [[ "${FISS_MCP_ALLOW_WRITES:-0}" == "1" ]]; then
      echo $'\033[1;31m'"fiss-mcp: ON  ${FISS_MCP_URL}  (WRITE MODE — the agent can submit workflows and spend money)"$'\033[0m'
    else
      echo "fiss-mcp: ON  ${FISS_MCP_URL}  (read-only)"
    fi
  else
    agy mcp remove fiss-mcp >/dev/null 2>&1 || true
    echo "fiss-mcp: OFF"
  fi
  if [[ "${CODEGRAPH:-1}" == "1" ]] && command -v codegraph >/dev/null 2>&1; then
    agy mcp add codegraph codegraph serve --mcp >/dev/null
    echo "codegraph: ON  $(codegraph --version 2>/dev/null || echo '(version unknown)')"
  else
    agy mcp remove codegraph >/dev/null 2>&1 || true
    echo "codegraph: OFF"
  fi
}

if [[ "$SANDBOX_AGENT" == "agy" ]]; then
  setup_agy
fi
# ===================================================== end Antigravity setup ==

# Agent instructions. warp/AGENTS.md is loaded by an @import in
# ~/.claude/CLAUDE.md (claude-sandbox-shared/.claude/CLAUDE.md), so this script
# writes nothing into /workspace and never touches a repo's files.
#
# One-time migration: the previous version of this script symlinked
# /workspace/CLAUDE.md -> warp/AGENTS.md and appended an "Other Repositories"
# section to warp/AGENTS.md, which dirtied every user's warp checkout (and
# blocks their `git pull` once upstream edits that file). Undo exactly those two
# changes and nothing else. Safe to delete once every user has booted this image.
if [[ -L /workspace/CLAUDE.md && "$(readlink /workspace/CLAUDE.md)" == "warp/AGENTS.md" ]]; then
  rm -f /workspace/CLAUDE.md
  echo "agents-md: removed the old /workspace/CLAUDE.md symlink; warp/AGENTS.md is imported instead."
fi
OLD_AGENTS_APPEND=$'\n\n## Other Repositories\n\nPlease also refer to [warp-tools/AGENTS.md](../warp-tools/AGENTS.md) for related tools and context.\n'
# Revert only when the ENTIRE local change to warp/AGENTS.md is that appended
# block: the file minus its tail must equal HEAD's version byte for byte.
if [[ -f /workspace/warp/AGENTS.md ]] \
   && ! git -C /workspace/warp diff --quiet HEAD -- AGENTS.md 2>/dev/null \
   && cmp -s <(printf '%s' "$OLD_AGENTS_APPEND") <(tail -c "${#OLD_AGENTS_APPEND}" /workspace/warp/AGENTS.md) \
   && cmp -s <(head -c "-${#OLD_AGENTS_APPEND}" /workspace/warp/AGENTS.md) \
             <(git -C /workspace/warp show HEAD:AGENTS.md 2>/dev/null); then
  if git -C /workspace/warp checkout -- AGENTS.md 2>/dev/null; then
    echo "agents-md: reverted the section an older start_script appended to warp/AGENTS.md."
  fi
fi
# Anything else at /workspace/CLAUDE.md was written by a person or an agent (a
# copy of AGENTS.md, /init output). Not ours to delete — say so loudly, because it
# duplicates the imported warp/AGENTS.md and silently goes stale.
if [[ -e /workspace/CLAUDE.md ]]; then
  YEL=$'\033[1;33m' RST=$'\033[0m'
  echo "${YEL}agents-md: WARNING — /workspace/CLAUDE.md exists.${RST}"
  echo "${YEL}  warp/AGENTS.md is already loaded via ~/.claude/CLAUDE.md, so this file duplicates it${RST}"
  echo "${YEL}  and goes stale. Agent guidance belongs in each repo's AGENTS.md. Delete CLAUDE.md${RST}"
  echo "${YEL}  from your workspace directory on the host (see FAQ.md).${RST}"
fi

# Run the agent. claude is not exec'd: the EXIT trap above still has to stop
# headroom. agy is, so that it becomes PID 1 and receives the container's
# signals: bash as PID 1 ignores SIGTERM and SIGHUP, which made `podman stop`
# wait out its timeout and left the container running when its terminal closed.
case "$SANDBOX_AGENT" in
  claude) claude "${CLAUDE_PLUGIN_ARGS[@]}" "$@" ;;
  agy)    exec agy "$@" ;;
  shell)  bash ;;
  *)      echo "start_script: unknown SANDBOX_AGENT '${SANDBOX_AGENT}' (claude, agy or shell)" >&2
          exit 2 ;;
esac
