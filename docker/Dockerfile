# Base images are FULLY QUALIFIED (docker.io/library/...) rather than short
# names. Docker resolves bare `node:22-slim` to Docker Hub implicitly, but
# podman on Fedora/RHEL-family hosts ships
# /etc/containers/registries.conf with short-name-mode="enforcing" and a
# multi-registry search list, so a short name makes it stop and ask which
# registry to use — which hangs (then fails) a non-interactive build.
# Qualifying is a no-op for Docker and required for podman.
FROM docker.io/library/eclipse-temurin:17-jdk AS temurin

FROM docker.io/library/node:22-slim

################################################################################

# python3 is kept because assorted tooling shells out to it, but python3-pip
# and python3-venv are deliberately absent: all Python in this image is managed
# by uv, and leaving pip installed would leave a second, unmanaged way to
# install packages into the system interpreter.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git ca-certificates curl ripgrep vim sudo gosu jq wget \
      openssh-client \
      python3 \
      build-essential

# For email notifications, docker-in-a-docker and other utils:
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y postfix mailutils shellcheck docker.io procps

# Clean up APT stuff:
RUN rm -rf /var/lib/apt/lists/*

COPY --from=temurin /opt/java/openjdk /opt/java/openjdk

ENV CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
      sh -s -- -y --no-modify-path --default-toolchain stable

# Install claude code. Pinned — bumping CLAUDE_CODE_VERSION + `make
# rebuild` lands a newer release deterministically. Tracking "latest"
# silently here would make every rebuild non-reproducible, and a
# write-semantics change between unpinned builds is exactly the kind of
# thing that produced the bind-mounted-credentials persistence bug
# (see commit ee421d5).
ENV CLAUDE_CODE_VERSION=2.1.283
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && claude --version

# CodeGraph: pre-indexed code knowledge graph exposed as an MCP stdio server.
# Bundle ships its own Node runtime — no compile, no extra deps. Claude Code
# spawns `codegraph serve --mcp` as a subprocess when shared settings.json
# declares the mcpServers.codegraph entry (configured in
# claude-sandbox-shared/.claude/settings.json).
#
# Version pinned. Bump CODEGRAPH_VERSION and `make rebuild` (forces --no-cache
# --pull) when a newer release is wanted; tracking "latest" silently in the
# image would make builds non-reproducible.
ENV CODEGRAPH_VERSION=v0.9.9
RUN curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh \
    | CODEGRAPH_INSTALL_DIR=/opt/codegraph CODEGRAPH_BIN_DIR=/usr/local/bin sh \
    && /usr/local/bin/codegraph --version

# Default UID/GID baked at build. The runtime entrypoint
# (uid-fixup-entrypoint.sh) remaps these to match the host invoker via
# HOST_UID / HOST_GID env vars, so a single image is portable across hosts.
#
# The base node:22-slim image ships a "node" user at UID 1000. If the host
# invoker is also UID 1000 (typical first user on Ubuntu/Debian), usermod
# would leave two passwd entries fighting for UID 1000 — getpwuid() then
# returns "node" first, sudo sees the effective user as "node" instead of
# "claude", and demands a password (NOPASSWD applies to claude only).
# Delete the node user up front so the remap is unambiguous.
RUN userdel -r node 2>/dev/null || true && \
    groupdel node 2>/dev/null || true && \
    groupadd -g 1015 claude && \
    useradd -m -u 1015 -g 1015 -s /bin/bash claude && \
    echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude && \
    chmod 440 /etc/sudoers.d/claude && \
    chown -R claude:claude /usr/local/cargo /usr/local/rustup

# uv, pinned, copied from Astral's published image. Preferred over `curl | sh`
# (no network fetch inside a RUN layer) and over `pip install uv` (no pip
# bootstrap, which is the thing we are removing). Bump this tag to update uv.
COPY --from=ghcr.io/astral-sh/uv:0.12.3 /uv /uvx /usr/local/bin/

# Python environment, built by uv rather than `python3 -m venv` + pip.
#
# uv fetches its own pinned CPython into UV_PYTHON_INSTALL_DIR, so the venv no
# longer inherits whatever python3 the base image happens to ship. That matters:
# the base is Debian bookworm (python 3.11 today), and a base-image bump could
# silently move the interpreter under the whole scientific stack. Pinning it
# here makes the image reproducible in the same way CLAUDE_CODE_VERSION and
# CODEGRAPH_VERSION already are.
#
# 3.12 specifically, to match the interpreter host_fiss_mcp/install.sh pins —
# one Python version across host and container is one less thing to reason about.
ENV UV_PYTHON_INSTALL_DIR=/opt/uv-python \
    CLAUDE_VENV_PYTHON=3.12
# anndata and scanpy are baked; scvi-tools is not. The dividing line is whether the
# dependency closure is cheap and wanted by everyone. Measured with
# `uv pip install --dry-run`, which resolves without downloading:
#
#   anndata      ~15 MB with h5py. Every single-cell task starts by opening an
#                .h5ad, so baking it lets an agent inspect data in its first turn.
#   scanpy       48 packages against a bare venv, but most of them (numpy, pandas,
#                scikit-learn, matplotlib) are already here; the real additions are
#                numba, llvmlite, umap-learn and pynndescent. Universal enough for
#                this deployment's work to be worth the space. Installed as
#                scanpy[leiden] rather than bare scanpy: without that extra,
#                sc.tl.leiden raises "Please install the igraph package" the first
#                time anyone clusters, and igraph + leidenalg are only a few MB. A
#                scanpy that cannot cluster is not worth baking.
#   scvi-tools   109 packages, 15 of them nvidia-* CUDA wheels, several GB. Only
#                some projects want it, the version should be pinned per project,
#                and neither the shared VM nor most laptops here have a GPU -- so
#                it belongs in a per-project venv, installed with
#                `--torch-backend cpu` (90 packages, no CUDA). Worked example in
#                the README.
#
# Cheap and universal goes in the image; heavy and project-specific goes in a venv
# under /workspace. See "Installing packages" in CONFIG.md.
# The `numba<0.67` cap keeps a PRERELEASE out of the image, and it is load-bearing.
# Unconstrained, this set resolves to numpy 2.5.2 + numba 0.67.0rc1, because stable
# numba requires numpy < 2.5 and uv will reach for a prerelease when nothing stable
# fits. A release-candidate JIT compiler under everyone's numerics is a poor default
# for a shared image, so the cap trades numpy 2.5.2 for 2.4.6 and keeps numba on
# 0.66.0. scanpy stays current at 1.12.3 either way.
#
# `--prerelease=disallow` looks like the tidier way to say this and is NOT: measured,
# it holds numpy at 2.5.2 and instead backtracks scanpy to 1.9.8 and numba to 0.53.1
# (2021), which is far worse than the problem. Cap the one package that causes it.
RUN uv venv --python "${CLAUDE_VENV_PYTHON}" /opt/claude-venv && \
    uv pip install --python /opt/claude-venv/bin/python --no-cache \
      numpy pandas matplotlib scipy scikit-learn seaborn \
      ipython jupyter requests anndata "scanpy[leiden]" "numba<0.67" \
      "headroom-ai[proxy]==0.24.0" && \
    chown -R claude:claude /opt/claude-venv /opt/uv-python

# fiss-mcp lives on the HOST, not in the container. The launcher
# (run_claude_docker.sh) spawns it before docker run, passes the URL in via
# FISS_MCP_URL, and traps SIGEXIT to kill it after the container exits.
# This keeps gcloud, gsutil, google-cloud-* libs, and ~/.config/gcloud out
# of the container entirely, so the only reachable path from inside the
# sandbox to Terra/GCP is the MCP tools — read-only by default.

# Make the bulk dirs writable by any UID. The runtime entrypoint remaps the
# claude user to match the host invoker, but chown -R on hundreds of MB of
# wheels and toolchain files takes 10+ seconds on every container start. With
# world-writable perms baked at build time, the entrypoint can skip the chown
# entirely. Container is single-user (claude) so loosening perms here doesn't
# expand attack surface.
# /opt/uv-python is included: the venv symlinks its interpreter out of there, so
# it has to be traversable by whatever uid the container ends up running as.
#
# /home/claude is included for a subtler reason, and leaving it out was a real
# bug. Upstream relied on uid-fixup-entrypoint.sh doing `chown -R /home/claude`
# at start-up, but that runs only in the root-start branch, which the podman path
# skips (the container already starts unprivileged under --userns=keep-id).
#
# That was survivable with a per-user rootless image store, where the on-disk
# layer uids and the runtime user namespace are consistent, so /home/claude really
# did appear owned by container uid 1015. It breaks with the SHARED store, which
# is built by ROOTFUL podman: /home/claude is then owned by real uid 1015 on disk,
# a uid that is not in the consuming user's namespace map, so it appears unmapped
# and mode 755 denies the write. The symptom is any hook or tool writing to $HOME
# failing with EACCES, e.g.
#   /home/claude/.claude/hooks/record-task-start.sh: line 21:
#   /home/claude/claude_task_start_warp: Permission denied
#
# Making it world-writable at build time removes the dependency on uid mapping
# entirely. Same trade-off already accepted above: the container is single-user.
RUN chmod -R a+rwX /opt/claude-venv /opt/uv-python /usr/local/cargo /usr/local/rustup \
                   /home/claude

# Remove ensurepip, which is what actually eliminates pip. There are TWO
# interpreters in this image and both ship it:
#
#   /usr/bin/python3            Debian's, from the python3 apt package
#   /opt/uv-python/*/bin/python uv's pinned CPython, which /opt/claude-venv uses
#
# Dropping the python3-pip / python3-venv apt packages is not sufficient. With
# only that change, `pip`, `pip3` and `python3 -m pip` were all absent, yet
# `python3 -m venv <dir>` still succeeded and seeded a working pip INTO the new
# venv — pip was one command away rather than gone.
#
# Targeting only /usr/lib/python3* is also not sufficient, and is easy to get
# wrong: ENV PATH below puts /opt/claude-venv/bin first, so at RUNTIME `python3`
# is uv's 3.12, while during THIS build the ENV is not yet set and `python3` is
# Debian's. A check written as `python3 -m ensurepip` inside this layer therefore
# tests a different interpreter than the one a user gets. Hence the explicit
# absolute paths below.
#
# Nothing needs ensurepip: uv builds environments without it.
RUN rm -rf /usr/lib/python3*/ensurepip \
           /usr/lib/python3/dist-packages/pip* \
           /opt/uv-python/*/lib/python3*/ensurepip && \
    ! /usr/bin/python3 -m ensurepip --version >/dev/null 2>&1 && \
    ! /opt/claude-venv/bin/python -m ensurepip --version >/dev/null 2>&1 && \
    echo "ensurepip removed from both interpreters"

ENV JAVA_HOME=/opt/java/openjdk \
    PATH=/opt/claude-venv/bin:/usr/local/cargo/bin:/opt/java/openjdk/bin:$PATH

# ENV PATH is not enough on its own: a LOGIN shell sources /etc/profile, which
# assigns PATH outright rather than appending to it, so `bash -l` starts with
#     /usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games
# and `python`, `cargo` and `java` all vanish. Measured:
#     bash -c  'command -v python'  -> /opt/claude-venv/bin/python
#     bash -lc 'command -v python'  -> not found
# Claude Code's own Bash tool uses a non-login shell, so this is invisible in normal
# operation and then bites anyone who ssh's in, runs `bash -l`, or writes a hook that
# does -- with "python: command not found" in an image that plainly has python.
#
# /etc/profile.d is sourced by /etc/profile AFTER it clobbers PATH, so prepending
# here is what actually survives.
RUN printf '%s\n' \
      '# Keep the image toolchain ahead of the distro one in login shells too.' \
      'export PATH=/opt/claude-venv/bin:/usr/local/cargo/bin:/opt/java/openjdk/bin:$PATH' \
      > /etc/profile.d/10-claude-toolchain.sh && \
    chmod 644 /etc/profile.d/10-claude-toolchain.sh

################################################################################

# Files baked into the claude home dir. Container starts as root so the uid
# fixup entrypoint can usermod the claude user before dropping privileges.
#
# These COPYs land AFTER the chmod a+rwX layer above, so their modes are what
# they say here. start_script.sh / start_dockerd.sh are 755 and .bash_aliases is
# 644, all of which stay usable no matter which uid the container runs as.
#
# .msmtprc is the one exception and is knowingly left as-is: 600 owned by uid
# 1015 means it is UNREADABLE when the runtime uid does not map to 1015, which
# is the shared-image-store case described above. It cannot get the same
# treatment, because msmtp refuses to use a config file that is group- or
# world-readable. The blast radius is limited to the optional email-notify hooks,
# which no-op unless CLAUDE_NOTIFY_EMAIL is set, and the file holds no secret
# (auth off, no password). If email notification is ever wanted on a shared
# store, the fix is to bind-mount an msmtprc from the host rather than to loosen
# this mode.
COPY --chown=claude:claude msmtprc /home/claude/.msmtprc
RUN chmod 600 /home/claude/.msmtprc

COPY --chown=claude:claude start_dockerd.sh /home/claude/start_dockerd.sh
RUN chmod +x /home/claude/start_dockerd.sh

COPY --chown=claude:claude start_script.sh /home/claude/start_script.sh
RUN chmod +x /home/claude/start_script.sh

COPY uid-fixup-entrypoint.sh /usr/local/bin/uid-fixup-entrypoint.sh
RUN chmod +x /usr/local/bin/uid-fixup-entrypoint.sh

# Set up some helpful aliases:
RUN echo "alias ll='ls -l'" >> /home/claude/.bash_aliases

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/uid-fixup-entrypoint.sh"]
CMD ["/home/claude/start_script.sh"]

