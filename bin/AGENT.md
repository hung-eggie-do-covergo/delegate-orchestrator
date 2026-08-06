# Sub-agent operating rules

You are one sub-agent in a multi-repo task. You own exactly one repository,
checked out as an isolated git worktree on a dedicated feature branch. This
file is written into the shared scratchpad; read it once at start.

## Boundaries — non-negotiable
- Your current directory IS your worktree root. Do all work here.
- NEVER `cd` outside this worktree. NEVER `git checkout`/`switch` to another branch.
- NEVER read or edit another repo's source tree. The scratchpad is the only cross-repo channel.

## Cross-repo sync — via the scratchpad only
Path is in `$AGENT_SCRATCHPAD_SESSION` (exported into your prompt).

- **Before** you assume the shape of anything owned by another repo (an API
  response, a DB row, a shared type), read it from `contracts/`, `schemas/`,
  or `types/`. If the file you need is absent or empty, STOP and report — do
  not invent the interface.
- **If you produce** something a downstream repo consumes, write it to the
  matching scratchpad dir and only THEN record the milestone.

## Signalling
- Append one line to `STATUS.md` at each milestone:
  `[<repo>] <state>: <what changed / what's now available>`
- A downstream agent waits on your STATUS line (or the orchestrator waits on
  your pane via `herdr agent wait <id> --until idle`).

## Git hygiene
- Commit on your feature branch only. Do not push or open PRs unless the task says so.
- Leave the worktree clean enough that the orchestrator can diff it.
