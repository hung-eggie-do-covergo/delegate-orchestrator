#!/usr/bin/env bash
# Install the herdr multi-repo agent orchestrator into your Claude Code + PATH.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

skills_dst="$HOME/.claude/skills"
bin_dst="$HOME/.local/bin"

for dep in herdr jq claude; do
  command -v "$dep" >/dev/null || { echo "missing dep on PATH: $dep" >&2; exit 1; }
done

mkdir -p "$skills_dst/delegate-orchestrator" "$skills_dst/delegate-cleanup" "$bin_dst"
install -m644 "$here/skills/delegate-orchestrator/SKILL.md" "$skills_dst/delegate-orchestrator/SKILL.md"
install -m644 "$here/skills/delegate-cleanup/SKILL.md"      "$skills_dst/delegate-cleanup/SKILL.md"
install -m755 "$here/bin/delegate"                 "$bin_dst/delegate"
install -m755 "$here/bin/orchestrate"              "$bin_dst/orchestrate"
install -m644 "$here/bin/AGENT.md"                 "$bin_dst/AGENT.md"
install -m644 "$here/bin/orchestrator-README.md"   "$bin_dst/orchestrator-README.md"
mkdir -p "$HOME/.agent_scratchpad"

echo "installed. ensure ~/.local/bin is on PATH, then restart Claude Code."
echo "skills: $skills_dst/{delegate-orchestrator,delegate-cleanup}"
echo "clis:   $bin_dst/{orchestrate,delegate}"
