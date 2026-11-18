#!/usr/bin/env bash
# env.gcp.example.sh — template for one user on a shared sandbox server (AWS or
# GCP; the name predates the AWS host).
#
# scripts/provision-sandbox-user.sh renders this into env.<USER>.sh with the
# __USER__ / __USER_ROOT__ placeholders filled in. You normally do not copy it
# by hand.
#
#   source env.<USER>.sh && ./run_claude_docker.sh
#
# Differences from env.podman.example.sh (the single-user local template):
#   * every path lives under a per-user directory on the DATA DISK, because
#     home directories are on the small boot disk and the 8.3 GB image plus
#     workspaces do not fit there;
#   * the fiss-mcp venv is moved out of the checkout, so one read-only clone
#     can be shared by every user;
#   * the shared-state dir is per-user, since the container mounts it
#     read-write and users must not write into a shared checkout.

# ---------------------------------------------------------------- engine ----

export CLAUDE_SANDBOX_ENGINE=podman

# Per-container RAM ceiling. Enforced for real only when the cgroup v2 memory
# controller is delegated to your user slice — provision-sandbox-user.sh checks
# that and warns if not.
#
# Sizing on a shared host: this is the limit that decides how many people can
# run at once, not disk. The host has 64 GB (r6a.2xlarge on AWS, e2-highmem-8 on
# GCP), so 16g allows about three concurrent sandboxes before it is
# oversubscribed on paper. Drop to 8g if more people need to work at once.
export CLAUDE_SANDBOX_MEMORY=16g

# Leave CPU unrestricted by default; the scheduler shares 8 vCPU fairly enough.
# Set this if one user's builds are starving everyone else.
#export CLAUDE_SANDBOX_CPUS=4

# 64 MB default /dev/shm is too small for the image's matplotlib/jupyter stack.
export CLAUDE_SANDBOX_SHM_SIZE=2g

# ----------------------------------------------------------------- paths ----

export CLAUDE_SANDBOX_INSTANCE=__USER__

# Per-instance write-hot state: cache, history, projects, .claude.json.
export CLAUDE_SANDBOX_HOME=__USER_ROOT__/state

# Settings, hooks, skills, vendored plugins, and the Claude OAuth token. Seeded
# from the checkout by provision-sandbox-user.sh. Per-user on purpose: this is
# mounted read-write, and it holds your token.
export CLAUDE_SANDBOX_USE_SHARED=1
export CLAUDE_SANDBOX_SHARED=__USER_ROOT__/shared

# Project workspace, bind-mounted to /workspace. Yours alone (the parent is
# chmod 700), so put whatever the agent needs in here.
export CLAUDE_SANDBOX_PROJECTS_DIR=__USER_ROOT__/workspace

# Read-only context, bind-mounted to /context. This is where you put material the
# agent should READ but never modify: plans, specs, notes, a data dictionary.
#
# Deliberately your own directory, not the shared checkout. It used to point at
# __REPO_ROOT__/context_reference, which is the ADMIN's tree: read-only to everyone
# else, so the one channel meant for "drop a file in for the agent" was the one
# channel a user could not write to. Now provisioning creates this for you.
#
# The mount is :ro, so the agent cannot change what you put here — that is the
# difference from /workspace, and the reason to use it for a plan you do not want
# rewritten.
export CLAUDE_SANDBOX_CONTEXT_DIR=__USER_ROOT__/context

# The fiss-mcp venv and its pinned clone. MUST be outside the checkout on a
# shared host: the clone may be read-only, and two users cannot share one venv.
export CLAUDE_SANDBOX_FISS_ROOT=__USER_ROOT__/fiss-mcp

# Where SESSION_ARCHIVE/archive_sessions.sh looks for transcripts.
export CLAUDE_SANDBOX_STATE_ROOT=__USER_ROOT__

# Read-write project mounts, each at /projects/<basename>. Real checkouts the
# agent edits in place. The container holds no git credentials, so `git push`
# from inside cannot succeed — commit inside, push from the host.
#export CLAUDE_SANDBOX_RW_MOUNTS="$HOME/git/warp $HOME/git/warp-tools"

# Extra read-only reference mounts, at /read-only-reference/<basename>.
#export CLAUDE_SANDBOX_RO_MOUNTS="/mnt/sandbox/reference"

# -------------------------------------------------------------- features ----

# REQUIRED for fiss-mcp's GCS tools. They build a bare storage.Client(), which
# refuses to construct without a project, so without this
# list_gcs_objects / read_gcs_object / download_gcs_file /
# get_gcs_object_metadata all fail with
#   OSError: Project was not passed and could not be determined from the environment
#
# Note that `gcloud auth application-default set-quota-project` does NOT satisfy
# this: it sets quota_project_id, but google.auth.default() still reports
# project=None. Set a project where YOU have serviceusage.services.use.
#
# Default for the WARP deployment. A GCP project id is not a secret and grants
# nothing on its own — reach comes from your own IAM on the buckets. Change it if
# you are deploying elsewhere; the only requirement is that you hold
# serviceusage.services.use on whatever you name.
export CLAUDE_SANDBOX_GCP_PROJECT=warp-pipeline-dev

# Terra MCP. The server runs on the HOST as you, using your own gcloud ADC. The
# container has no gcloud, no gsutil, no google-cloud-* libraries and no
# ~/.config/gcloud mount, so these tools are its only route to Terra/GCP.
export FISS_MCP=1

# Read-only. All 21 tools stay visible in tools/list; the 5 write tools are
# blocked at call time by a _check_write_access guard. Set to 1 only if you
# intend the agent to submit workflows and spend money.
export FISS_MCP_ALLOW_WRITES=0

# In-container stdio MCP server for symbol/graph navigation.
export CODEGRAPH=1

# Headroom token-compression proxy. Be aware of what it does: start_script.sh
# points ANTHROPIC_BASE_URL at it, so every Anthropic request — including its
# OAuth bearer — passes through this third-party binary before egress. Set to 0
# to talk to api.anthropic.com directly.
export HEADROOM=1

# Claude Code's auto-updater cannot succeed here (npm global is root-owned and
# the container is --rm), and its warning is noise. Upgrade by bumping
# CLAUDE_CODE_VERSION in docker/Dockerfile and rebuilding.
#export DISABLE_AUTOUPDATER=0

# Email notifications are not configured on the VM (no MTA). The notify hooks
# no-op while this is unset.
#export CLAUDE_NOTIFY_EMAIL=

# ------------------------------------------------------------ Antigravity ----

# `sandbox agy` runs Google's Antigravity CLI in the same sandbox. By default it
# signs in with a Google account on its first run. A Gemini API key instead
# (https://aistudio.google.com/apikey) keeps any Google account sign-in out of the
# container; USER-SETUP.md, "Antigravity sign-in", explains why that can matter.
# Forwarded by name, and only into agy containers. This file is in your chmod 700
# directory, which is what keeps the key from other users.
#export GEMINI_API_KEY=
