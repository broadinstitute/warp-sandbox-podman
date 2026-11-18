#!/usr/bin/env bash
# scripts/bump-versions.sh — show, and optionally apply, newer versions of the
# tools pinned in docker/Dockerfile.
#
#   ./scripts/bump-versions.sh            # report pinned vs available; change nothing
#   ./scripts/bump-versions.sh --apply    # rewrite the pins in docker/Dockerfile
#   ./scripts/bump-versions.sh --apply --claude-channel latest
#
# Run it in a checkout on your laptop, review `git diff`, commit, push. Then on
# the host: git pull, and sudo ./scripts/build-shared-image.sh. Users pick the
# new image up on their next launch. (AWS.md and SERVER.md, "Updating the image".)
#
# Pins it manages, and where each "latest" comes from:
#   claude code  npm dist-tag (stable by default: trails latest by about a week
#                and skips releases with known regressions)
#   agy          Google's release manifest: version, URL and sha512 together
#   codegraph    GitHub releases/latest
#   uv           GitHub releases/latest (docker image tag; also setup-debian-host.sh)
#   headroom     PyPI
# Not managed: the vendored Claude plugins (claude-sandbox-shared/.claude/
# PLUGIN_PINS.md has their procedure) and fiss-mcp (host_fiss_mcp/install.sh pins
# a tag AND a commit; bump both there).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
DF="${REPO_ROOT}/docker/Dockerfile"
HOSTSETUP="${REPO_ROOT}/scripts/setup-debian-host.sh"
APPLY=0; CHANNEL=stable
while (( $# )); do
    case "$1" in
        --apply) APPLY=1 ;;
        --claude-channel) CHANNEL="$2"; shift ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

pinned() { sed -n "s|$1|\\1|p" "$DF" | head -1; }
cur_claude=$(pinned '^ENV CLAUDE_CODE_VERSION=\(.*\)$')
cur_agy=$(pinned '^ENV AGY_VERSION=\(.*\)$')
cur_cg=$(pinned '^ENV CODEGRAPH_VERSION=\(.*\)$')
cur_uv=$(pinned '^COPY --from=ghcr.io/astral-sh/uv:\([0-9.]*\) .*$')
cur_hr=$(pinned '.*"headroom-ai\[proxy\]==\([0-9.]*\)".*')

new_claude=$(curl -fsSL https://registry.npmjs.org/@anthropic-ai/claude-code \
    | jq -r --arg c "$CHANNEL" '."dist-tags"[$c] // empty')
manifest=$(curl -fsSL https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json)
new_agy=$(jq -r .version <<<"$manifest")
new_agy_url=$(jq -r .url <<<"$manifest")
new_agy_sha=$(jq -r .sha512 <<<"$manifest")
latest_tag() { curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" | sed 's#.*/tag/##'; }
new_cg=$(latest_tag colbymchenry/codegraph)
new_uv=$(latest_tag astral-sh/uv)
new_hr=$(curl -fsSL https://pypi.org/pypi/headroom-ai/json | jq -r .info.version)

[[ -n "$new_claude" && -n "$new_agy" && -n "$new_cg" && -n "$new_uv" && -n "$new_hr" ]] \
    || { echo "could not resolve every latest version; nothing changed" >&2; exit 1; }

changed=0
row() { # name pinned available
    local mark="  "
    [[ "$2" != "$3" ]] && { mark="->"; changed=1; }
    printf '  %-12s %-12s %s %s\n' "$1" "$2" "$mark" "$3"
}
echo "  tool         pinned          available"
row "claude code" "$cur_claude" "$new_claude"
row "agy"         "$cur_agy"    "$new_agy"
row "codegraph"   "$cur_cg"     "$new_cg"
row "uv"          "$cur_uv"     "$new_uv"
row "headroom"    "$cur_hr"     "$new_hr"
echo "  (claude channel: ${CHANNEL})"

if (( ! changed )); then echo "Everything is current."; exit 0; fi
if (( ! APPLY )); then echo; echo "Re-run with --apply to rewrite docker/Dockerfile."; exit 0; fi

sed -i \
    -e "s|^ENV CLAUDE_CODE_VERSION=.*|ENV CLAUDE_CODE_VERSION=${new_claude}|" \
    -e "s|^ENV AGY_VERSION=.*|ENV AGY_VERSION=${new_agy}|" \
    -e "s|^ARG AGY_URL=.*|ARG AGY_URL=${new_agy_url}|" \
    -e "s|^ARG AGY_SHA512=.*|ARG AGY_SHA512=${new_agy_sha}|" \
    -e "s|^ENV CODEGRAPH_VERSION=.*|ENV CODEGRAPH_VERSION=${new_cg}|" \
    -e "s|ghcr.io/astral-sh/uv:[0-9.]*|ghcr.io/astral-sh/uv:${new_uv}|" \
    -e "s|\"headroom-ai\[proxy\]==[0-9.]*\"|\"headroom-ai[proxy]==${new_hr}\"|" \
    "$DF"
# The host uv is pinned to the same version as the image's.
sed -i "s|^UV_VERSION=.*|UV_VERSION=${new_uv}|" "$HOSTSETUP"
echo
echo "Rewrote the pins. Review, then build and test before pushing:"
echo "  git -C ${REPO_ROOT} diff -- docker/Dockerfile scripts/setup-debian-host.sh"
echo "  A codegraph or headroom MAJOR bump can change their CLIs; check the"
echo "  container starts with HEADROOM=1 and that codegraph-init.sh still works."
