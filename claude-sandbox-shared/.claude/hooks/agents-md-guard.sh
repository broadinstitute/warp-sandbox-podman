#!/usr/bin/env bash
# PreToolUse hook (matcher: Write|Edit|MultiEdit).
#
# Refuses to write a CLAUDE.md (or CLAUDE.local.md, or .claude/CLAUDE.md) into a
# repository that already has an AGENTS.md. That AGENTS.md is the only home for
# agent guidance in the repo; a CLAUDE.md beside it duplicates it and goes
# stale. This is what turns `/init` or "remember this" into an edit of AGENTS.md
# instead of a new CLAUDE.md. Symlinks are fine and are not affected: they are
# not created through these tools.
#
# Exit 2 blocks the tool call and shows stderr to Claude. Anything unexpected
# (no jq, bad JSON, no file_path) exits 0: a guard must never break a session.

f=$(jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
case "$(basename -- "$f")" in
    CLAUDE.md|CLAUDE.local.md) ;;
    *) exit 0 ;;
esac

dir=$(dirname -- "$f")
[[ "$(basename -- "$dir")" == ".claude" ]] && dir=$(dirname -- "$dir")
root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || root=$dir

for agents in "$dir/AGENTS.md" "$root/AGENTS.md"; do
    if [[ -e "$agents" ]]; then
        echo "Blocked: ${root} has an AGENTS.md, which is the only place for agent guidance in this repository. Do not create or edit a CLAUDE.md here. Put the content in ${agents} instead, or propose the change to the user." >&2
        exit 2
    fi
done
exit 0
