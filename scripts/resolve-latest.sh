#!/usr/bin/env bash
# scripts/resolve-latest.sh — the newest version of each tool the image takes
# fresh on every build, printed as KEY=VALUE lines for `podman build --build-arg`.
# scripts/build-shared-image.sh and docker/Makefile call it, so every image build
# gets the newest:
#
#   Claude Code   npm dist-tag `latest`
#   agy           Google's release manifest (version, URL and sha512 together;
#                 the Dockerfile checks the download against the sha512)
#   caveman       newest GitHub release of JuliusBrussee/caveman
#   ponytail      newest GitHub release of DietrichGebert/ponytail
#   uv            newest GitHub release of astral-sh/uv (the image copies it from
#                 Astral's published ghcr.io/astral-sh/uv:<version>; the build
#                 puts the same version on the host, setup-debian-host.sh --uv-only)
#
# The plugin releases resolve to a commit, which is what the image downloads, so
# the build gets exactly the release that was resolved.
#
# To hold one back for a build, set it in the environment; it is used as given:
#   CLAUDE_CODE_VERSION=2.1.326                        an npm version
#   CAVEMAN_VERSION=v4.0.0   PONYTAIL_VERSION=v5.3.0   a release tag
#   UV_VERSION=0.13.9                                  a uv release
#   AGY_VERSION + AGY_URL + AGY_SHA512                 all three, from an older manifest
#
# Exits non-zero, having printed nothing, if anything cannot be resolved. A build
# then never starts, and the image in use stays as it is.
#
# codegraph and headroom are not here: they stay pinned in docker/Dockerfile
# (scripts/bump-versions.sh moves them).
set -euo pipefail

die() { echo "resolve-latest.sh: $*" >&2; exit 1; }
for c in curl jq git; do command -v "$c" >/dev/null 2>&1 || die "needs $c"; done

claude="${CLAUDE_CODE_VERSION:-}"
if [[ -z "$claude" ]]; then
    claude=$(curl -fsSL https://registry.npmjs.org/@anthropic-ai/claude-code/latest | jq -r '.version // empty') \
        || die "could not reach the npm registry"
    [[ -n "$claude" ]] || die "npm returned no latest version of @anthropic-ai/claude-code"
fi

if [[ -n "${AGY_VERSION:-}${AGY_URL:-}${AGY_SHA512:-}" ]]; then
    [[ -n "${AGY_VERSION:-}" && -n "${AGY_URL:-}" && -n "${AGY_SHA512:-}" ]] \
        || die "set AGY_VERSION, AGY_URL and AGY_SHA512 together, or none of them"
    agy_v=$AGY_VERSION agy_url=$AGY_URL agy_sha=$AGY_SHA512
else
    m=$(curl -fsSL https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json) \
        || die "could not read agy's release manifest"
    agy_v=$(jq -r '.version // empty' <<<"$m")
    agy_url=$(jq -r '.url // empty' <<<"$m")
    agy_sha=$(jq -r '.sha512 // empty' <<<"$m")
    [[ -n "$agy_v" && -n "$agy_url" && -n "$agy_sha" ]] || die "agy's manifest lacks version, url or sha512"
fi

# release REPO [TAG] -> "TAG COMMIT"; the newest release when TAG is empty.
release() {
    local repo="$1" tag="${2:-}" commit
    if [[ -z "$tag" ]]; then
        tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/${repo}/releases/latest" \
              | sed -n 's#.*/releases/tag/##p') || die "could not reach GitHub for ${repo}"
        [[ -n "$tag" ]] || die "${repo} has no GitHub release"
    fi
    # An annotated tag lists twice: the tag object, then ^{} with the commit it
    # points to. Prefer the commit.
    commit=$(git ls-remote "https://github.com/${repo}" "refs/tags/${tag}" "refs/tags/${tag}^{}" \
             | awk '$2 ~ /\^\{\}$/ {p=$1} $2 !~ /\^\{\}$/ {c=$1} END {print (p ? p : c)}') \
        || die "could not list ${repo}'s tags"
    [[ -n "$commit" ]] || die "${repo} has no tag ${tag}"
    echo "$tag $commit"
}
uv="${UV_VERSION:-}"
if [[ -z "$uv" ]]; then
    uv=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/astral-sh/uv/releases/latest \
         | sed -n 's#.*/releases/tag/##p') || die "could not reach GitHub for uv"
    [[ -n "$uv" ]] || die "could not find uv's newest release"
fi

# Assigned, not read from a here-string: die() runs in the $( ) subshell, and only
# an assignment carries its failure out to set -e.
cav=$(release JuliusBrussee/caveman "${CAVEMAN_VERSION:-}")
pon=$(release DietrichGebert/ponytail "${PONYTAIL_VERSION:-}")
read -r cav_v cav_c <<<"$cav"
read -r pon_v pon_c <<<"$pon"

cat <<EOF
CLAUDE_CODE_VERSION=${claude}
AGY_VERSION=${agy_v}
AGY_URL=${agy_url}
AGY_SHA512=${agy_sha}
CAVEMAN_VERSION=${cav_v}
CAVEMAN_COMMIT=${cav_c}
PONYTAIL_VERSION=${pon_v}
PONYTAIL_COMMIT=${pon_c}
UV_VERSION=${uv}
EOF
