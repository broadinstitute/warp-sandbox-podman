#!/usr/bin/env bash
# env.podman.example.sh — template for a rootless-podman instance.
#
# Copy to env.<INSTANCE>.sh, adjust the paths, then:
#   source env.<INSTANCE>.sh && ./run_claude_docker.sh
#
# Verified on Nobara 44 (Fedora 44 base) with podman 5.8.4 rootless.
#
# Differences from env.example.sh, all forced by the engine:
#   * CLAUDE_SANDBOX_ENGINE=podman — selects the launcher's podman path
#     (no sysbox-runc, no DinD, --userns=keep-id, pasta loopback forward).
#   * State lives on the data volume next to the other container storage
#     rather than inside the checkout.
#   * CLAUDE_NOTIFY_EMAIL stays unset — no postfix on this host.

__ENV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------- engine ----

# Rootless podman. Docker is not installed on this host and sysbox-runc does
# not exist for podman, so the launcher drops the sysbox runtime and
# Docker-in-Docker, and pins the container to the image's claude uid with
# --userns=keep-id so /workspace files stay owned by the invoking user.
export CLAUDE_SANDBOX_ENGINE=podman

# Hard RAM ceiling for the container. Enforced for real: cgroup v2 delegates
# the memory controller to this user's slice, so --memory/--memory-swap read
# back inside the container (verified: memory.max = 17179869184).
#
# Sized to stay portable to a GCP VM — 16g fits an n2-standard-4 (4 vCPU /
# 16 GB) with nothing to spare for the host, and sits comfortably on an
# n2-standard-8 (8 vCPU / 32 GB). This host has 31 GB.
export CLAUDE_SANDBOX_MEMORY=16g

# Leave CPU unrestricted (host has 20 cores). Set to e.g. 8 to cap.
#export CLAUDE_SANDBOX_CPUS=8

# /dev/shm. The 64 MB default is too small for the image's matplotlib /
# jupyter / scikit-learn stack and for any Playwright or DataLoader work.
export CLAUDE_SANDBOX_SHM_SIZE=2g

# GPU passthrough is opt-in and off. This host has an NVIDIA card, but
# rootless podman needs a CDI spec (/etc/cdi/nvidia.yaml, generated with
# `sudo nvidia-ctk cdi generate`) which is not installed. Setting this to 1
# without that spec prints a warning and continues without the GPU.
#export CLAUDE_SANDBOX_GPU=1

# ----------------------------------------------------------------- state ----

# Shared layout: settings, skills, hooks and the OAuth token come from
# claude-sandbox-shared/ in the checkout. (The caveman and ponytail plugins come
# from the image.)
export CLAUDE_SANDBOX_USE_SHARED=1

export CLAUDE_SANDBOX_INSTANCE=main

# Parent of every instance state dir, read only by
# SESSION_ARCHIVE/archive_sessions.sh (the launcher ignores it). Set this when
# CLAUDE_SANDBOX_HOME points outside the checkout, or the archiver will scan
# only the repo-relative defaults and find nothing.
#export CLAUDE_SANDBOX_STATE_ROOT=/path/to/state

# Per-instance write-hot state (cache, history, projects, .claude.json) on the
# data volume, beside the podman image store.
export CLAUDE_SANDBOX_HOME=/mnt/data/claude-sandbox/state/main

# Project workspace, bind-mounted to /workspace. Provisioned per project —
# copy in only what the agent needs. Nothing else on the host is reachable.
export CLAUDE_SANDBOX_PROJECTS_DIR=/mnt/data/claude-sandbox/workspace

# Read-only context, bind-mounted to /context.
export CLAUDE_SANDBOX_CONTEXT_DIR="${__ENV_SCRIPT_DIR}/context_reference"

# Optional extra read-only reference mounts, each surfacing at
# /read-only-reference/<basename>. Nothing by default.
#export CLAUDE_SANDBOX_RO_MOUNTS="/mnt/data/warp_development/scanvi_benchmark/results"

# Read-write project mounts, each surfacing at /projects/<basename>. Use for
# real host checkouts the agent should edit in place rather than copies staged
# into /workspace. Under rootless podman keep-id keeps the written files owned
# by the invoking user on the host.
#
# The container holds no git credentials (no ssh keys, no ssh-agent socket, no
# ~/.git-credentials, no ~/.netrc, no gh, no tokens, no credential helper), so
# `git push` to an authenticated remote cannot succeed from inside; remote
# state stays host-controlled. Local history and uncommitted work in these
# checkouts are NOT protected, especially in bypassPermissions mode.
#
#export CLAUDE_SANDBOX_RW_MOUNTS="$HOME/git/projectA $HOME/git/projectB"

# -------------------------------------------------------------- features ----

# Headroom token-compression proxy, ON.
#
# Be aware of what this does: start_script.sh sets
# ANTHROPIC_BASE_URL=http://127.0.0.1:8787, so every Anthropic API request
# from inside the container — including its Authorization header — passes
# through the third-party `headroom` binary (pip headroom-ai, upstream
# github.com/chopratejas/headroom) before egress. Set to 0 to have claude
# talk to api.anthropic.com directly.
export HEADROOM=1

# fiss-mcp: Terra/GCP access. The server runs on the HOST and is reached over
# a pasta loopback forward; the container has no gcloud, no gsutil, no
# google-cloud-* libraries and no ~/.config/gcloud mount, so these MCP tools
# are the only path from the sandbox to Terra.
#
# Auth is entirely host-side: the server inherits this host's gcloud ADC.
# Nothing is injected into the container.
export FISS_MCP=1

# GCP project for the host fiss-mcp server's GCS tools. REQUIRED for those
# tools: they construct a bare storage.Client(), which refuses to build without
# a project ("Project was not passed and could not be determined from the
# environment"). Note that `gcloud auth application-default set-quota-project`
# does NOT satisfy this -- it sets quota_project_id, but google.auth.default()
# still reports project=None. Pick a project where you have
# serviceusage.services.use; it is a quota/API-enablement project only and
# grants no bucket access of its own.
#
#export CLAUDE_SANDBOX_GCP_PROJECT=my-project

# Read-only.
#
# Note how this is actually enforced, because the upstream README describes it
# imprecisely. All 21 tools stay REGISTERED and visible in tools/list at 0 --
# including the five write tools (submit_workflow, abort_submission,
# update_method_config, copy_method_config, upload_entities). The block happens
# at call time: each of those five begins with _check_write_access(ctx), which
# raises ToolError when ALLOW_WRITES is false. Verified against this install by
# calling submit_workflow and abort_submission with valid arguments -- both
# returned "This server is running in read-only mode."
#
# Practical consequence: the agent can see the write tools and may try one; it
# will be refused rather than being unable to name it. The protection is real
# but it is a runtime guard, not absence from the tool list.
export FISS_MCP_ALLOW_WRITES=0

# CodeGraph MCP (in-container stdio server, symbol/graph navigation).
export CODEGRAPH=1

# Claude Code auto-updater. Off, because it cannot work in this image and the
# warning is noise on every launch: npm global (/usr/local/lib/node_modules) is
# root-owned from build time while the container runs as claude, the path is not
# bind-mounted, and the container runs --rm -- so an update would be discarded
# on exit and re-downloaded next launch, drifting off the image's
# CLAUDE_CODE_VERSION. Upgrade by re-running make: it installs the newest release.
#export DISABLE_AUTOUPDATER=0

# Email notifications: intentionally disabled. There is no postfix or MTA on
# this host, and setting up a system MTA is not worth it for this. The
# notify-if-long / notify-if-rate-limited hooks no-op while this is unset.
#export CLAUDE_NOTIFY_EMAIL=

unset __ENV_SCRIPT_DIR
