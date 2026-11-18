VERSION = 0.0.1
TAG1 = claude-sandbox:$(VERSION)
TAG2 = claude-sandbox:latest

# Container engine. Override for rootless podman hosts (Fedora/RHEL family,
# where Docker is not installed and sysbox-runc does not exist):
#     make ENGINE=podman
# or export CLAUDE_SANDBOX_ENGINE=podman before calling make. Base images in
# the Dockerfile are fully qualified (docker.io/library/...) because podman
# runs with short-name-mode="enforcing" on those distros and would otherwise
# block on an interactive registry prompt.
ENGINE ?= $(if $(CLAUDE_SANDBOX_ENGINE),$(CLAUDE_SANDBOX_ENGINE),podman)

# Centralized build flags so `build` and `rebuild` share everything except
# cache behavior.
BUILD_FLAGS = -t $(TAG1) -t $(TAG2)

.PHONY: all build rebuild clean

all: build

# The newest Claude Code, agy, caveman and ponytail, resolved when the recipe
# runs (scripts/resolve-latest.sh; set CLAUDE_CODE_VERSION etc. to hold one back).
# If resolving fails, the args come out empty and the build stops at the first
# step that needs them, saying so.
LATEST_ARGS = $$(../scripts/resolve-latest.sh | sed 's/^/--build-arg /')

# Cache-friendly build. Use this 99% of the time. It still picks up every newer
# release of the tools above: each version is a build arg, so a new one rebuilds
# its layer.
build:
	$(ENGINE) build $(BUILD_FLAGS) $(LATEST_ARGS) .

# Forced rebuild: ignore layer cache AND re-pull the base image. Use when:
#   - base image security updates need to land
#   - cache feels stale (mystery breakages, "but it works locally")
rebuild:
	$(ENGINE) build --no-cache --pull $(BUILD_FLAGS) $(LATEST_ARGS) .

# Drop the image tags so the next `build` starts clean. Does NOT prune
# dangling layers — run `docker image prune` separately if you want that.
clean:
	-$(ENGINE) rmi $(TAG1) $(TAG2)
