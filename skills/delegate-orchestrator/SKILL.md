---
name: delegate-orchestrator
description: >
  Orchestrate a task that spans MULTIPLE git repositories by fanning out one isolated
  sub-agent per repo, each in its own herdr worktree workspace, syncing across repos
  through a shared scratchpad. Discovers which repos a task touches, then delegates
  scoped work to each via the `delegate` CLI (herdr worktree + agent start + prompt).
  Use when a change spans more than one repo, when the user says "delegate", "fan out
  across repos", "multi-repo change", "orchestrate this across services", or asks to
  coordinate work in several repositories at once. Do NOT use for single-repo changes —
  work in the repo directly, or use one worktree-isolated subagent.
---

# Multi-repo orchestration via `delegate`

You are the **orchestrator**: a Claude session that coordinates isolated sub-agents,
one per repository. You discover the repo set, delegate scoped work, and keep the agents
in sync through a shared scratchpad.

**Never do the work yourself — always delegate it.** Your ONLY actions are: read-only
discovery (scan, grep, `git`/`herdr` inspection), asking the user, calling `delegate`,
and reporting what the sub-agents did. You do NOT edit code, write files in any repo, run
builds/tests/migrations, `cd` into a repo, or `git commit` — every change to every repo
is done by that repo's delegated sub-agent, in its own worktree. If you catch yourself
about to touch a repo's files, stop and `delegate` that work instead. The one exception
is your own read-only scratch (planning notes in the shared scratchpad).

The runtime is herdr + git worktrees. `delegate` (a bash script on PATH) wraps the three
per-repo herdr calls; you drive discovery and sequencing.

## When this applies
- A task genuinely touches **2+ repos** with some dependency between them (e.g. an API
  repo that publishes a contract a web repo consumes).
- Single-repo work does NOT apply — just edit the repo, or spawn one `isolation:'worktree'`
  subagent. Delegating one repo is pure overhead.

## Flow

### 0. Ticket-first: reuse existing worktrees before starting anything
When the task carries a ticket id (e.g. `PROJ-1234`, `ABC-42`), scan the workspace for
work already in progress on it BEFORE reading the ticket or planning repos:
```sh
# every git repo under the workspace (default: cwd)
fd -HI -t d '^\.git$' "${WS:-.}" | xargs -n1 dirname | sort -u
# per repo, branches or worktrees whose name carries the ticket
git -C <repo> branch -a --list "*PROJ-1234*"
herdr worktree list --cwd <repo> --json | jq -r '.result.worktrees[]?
  | select(.branch|test("PROJ-1234";"i")) | "\(.branch)\t\(.path)\t\(.open_workspace_id // "closed")"'
```
If any repo has a matching branch/worktree, **STOP and ask the user** (AskUserQuestion):
list each match (repo, branch, open|closed) and ask which are the real in-progress
worktrees to reopen vs ignore. `delegate` reopens a chosen one automatically — same branch
name means it reuses that checkout instead of creating. Only after this:
- Matches confirmed usable → delegate those repos with the existing branch; they reopen.
- No matches, or user says start fresh → fall through to discovery below.

Skip step 0 entirely when the task has no ticket id.

### 1. Discover the repo set — do NOT ask the user to list repos
Find which repos the task touches (read the ticket first if you have one — its text names
the services/areas, which narrows the scan):
- **Literal concept** (a type, endpoint, symbol): `rg -l '<pattern>' <workspace>` and reduce
  hits to repo roots. A repo with zero hits is out of scope.
- **Conceptual** (touches things sharing no keyword): spawn one read-only `Explore` or
  `general-purpose` subagent — "which repos under <workspace> must change to do X? Return
  repo paths + the role of each." Its answer is the delegate list.
- Only ask the user when discovery is genuinely ambiguous between plausible owners.

### 2. Plan branch + base + ordering
- One feature branch name, reused across all repos (keeps the change traceable).
- Determine the dependency order: a producer repo (publishes a contract) goes first with
  `--wait`; consumer repos follow.

### 3. Delegate per repo
```sh
delegate <repo_path> <branch> "<scoped prompt>" --session <shared-id> [--wait]
```
- `--session <shared-id>` MUST be identical across all repos in one task — it selects the
  shared scratchpad they sync through.
- `--wait` on a producer blocks until its sub-agent is idle, so a consumer never reads a
  contract that isn't written yet.
- Scope each prompt to ONE repo. Tell a producer to write its contract to
  `$AGENT_SCRATCHPAD_SESSION/contracts|schemas|types/…` before finishing; tell a consumer
  to read the exact shape from there and NOT invent it.
- `delegate --dry-run …` prints the herdr calls without mutating anything — use it to
  preview before a real fan-out.
- **Model per repo** — `delegate … --model <opus|sonnet|haiku>` picks the sub-agent's
  model. Default the real code work to `opus`; downgrade a small/mechanical repo (rename,
  config bump, doc edit) to `sonnet` or `haiku` to save tokens; upgrade only when genuinely
  hard. `orchestrate --delegate-model` sets your default; state the model you chose per repo
  when you report. Your own orchestrator model stays cheap (you never edit).

**Fan out independent repos concurrently.** Each `delegate` is one repo (own git, own
workspace), so calls to *different* repos never race — run them in parallel and wall-clock
drops from sum-of-repos to slowest single repo. Only serialize a real dependency:
```sh
# independent repos: background them, one wait barrier
delegate ~/work/web  feat/x "…" --session $S &
delegate ~/work/docs feat/x "…" --session $S &
wait
# producer→consumer: producer with --wait first, then fan out the consumers
delegate ~/work/api  feat/x "publish contract to \$scratch/contracts/user.yaml" --session $S --wait
delegate ~/work/web  feat/x "consume \$scratch/contracts/user.yaml" --session $S &
delegate ~/work/sdk  feat/x "consume \$scratch/contracts/user.yaml" --session $S &
wait
```
Never parallelize two branches of the SAME repo — concurrent `worktree create` on one
`.git` races. One repo per delegate keeps them independent.

### 4. Completeness check
After delegating, re-grep the workspace for the concept and confirm no matching repo was
missed. If one was, delegate it too. Silent partial coverage is the main failure mode.

## Watching / steering
- `herdr workspace list` — the per-repo workspaces you created.
- `herdr agent attach <pane>` — jump into a sub-agent live.
- `herdr agent wait <pane> --until idle` — block on one manually.

## Teardown (per repo, when merged/abandoned)
To review which sub-agents have finished and tear them down safely (with confirmation),
invoke the **delegate-cleanup** skill. The manual sequence, per repo — remove the worktree
BEFORE closing its workspace:
```sh
herdr worktree remove --workspace <id> --force
herdr workspace close <id>
# if already closed, fall back to git:
#   git -C <repo> worktree remove --force <checkout>; git -C <repo> branch -D <branch>
rm -rf ~/.agent_scratchpad/<session>
```

## Guardrails
- Orchestrator delegates, never does. No editing repo files, running builds/tests, or
  committing — all of it goes to a delegated sub-agent (see the rule up top). You only
  discover, ask, `delegate`, and report.
- Keep the orchestrator the ONLY caller of `delegate`. A sub-agent that calls it nests
  agents-spawning-agents — hard to track past one level.
- Sub-agent rules live in `~/.local/bin/AGENT.md`; `delegate` copies it into each session
  scratchpad and points the sub-agent at it. Don't restate them in prompts.
- Reference: `~/.local/bin/orchestrator-README.md`.
