# Multi-repo orchestration — native adaptation

The original ask was a custom Python orchestrator + `delegate_task` CLI. Almost
all of it already exists in Claude Code + herdr. This is the thin layer that
doesn't.

## What maps to what

| Original requirement | Native mechanism |
|---|---|
| Orchestrator / meta-agent | **A Claude Code session** driving the herdr skill (+ the `Workflow` tool for deterministic fan-out). Not a script. |
| `git worktree add` + open a pane in it | `herdr worktree create --cwd <repo> --branch <b> --base <ref>` — one call, and with no `--workspace` it makes a **new workspace per repo** (your topology). |
| Spawn agent CLI in the pane | `herdr agent start claude --kind claude --pane <id>` |
| Monitor `working/blocked/idle` | `herdr agent wait <t> --until idle` / `herdr agent get <t>` |
| `delegate_task` (trigger + wait) | `herdr agent prompt <t> "<text>" --wait --until idle` |
| Agent never `cd`s out / breaks git ctx | Guaranteed by isolation: the agent's cwd **is** the worktree root. |
| Shared scratchpad | `~/.agent_scratchpad/<session>/` — a directory convention, below. |

The only retyped-per-repo sequence (create → start → prompt+wait) is wrapped by
`./delegate`. That's the entire custom surface.

## Architecture

```
        ORCHESTRATOR  (a Claude session, this one)
        analyses the cross-repo task, picks branch + base per repo,
        writes the shared contract stub, then per repo:
             │
             │  ./delegate <repo> <branch> "<scoped prompt>" [--wait]
             ▼
   ┌─────────────────────────┐   ┌─────────────────────────┐
   │ herdr workspace  (api)  │   │ herdr workspace  (web)  │   … one per repo
   │  worktree: api/         │   │  worktree: web/         │
   │  branch:  feat/x        │   │  branch:  feat/x        │
   │  pane: Claude Code CLI  │   │  pane: Claude Code CLI  │
   └───────────┬─────────────┘   └───────────┬─────────────┘
               │  read/write contracts        │
               └──────────────┬───────────────┘
                              ▼
              ~/.agent_scratchpad/<session>/
                 contracts/  schemas/  types/  STATUS.md
```

Isolation is the whole point: each sub-agent's cwd is its own worktree on its
own branch, so file tracking, lint, and git context never collide — and no
agent can `cd` into another's checkout because it has no reason to.

## Scratchpad protocol

`~/.agent_scratchpad/<session>/` is the only cross-repo channel. Agents do NOT
read each other's source trees; they read the scratchpad.

```
<session>/
  contracts/   API/RPC contracts a producer publishes for a consumer
  schemas/     DB / message schemas
  types/       shared type definitions (openapi, .proto, .d.ts, …)
  STATUS.md    append-only milestone log; how one agent knows a dep is ready
```

Rules the sub-agents are told (see below):
- Read a dependency from the scratchpad **before** assuming its shape. No guessing across repos.
- A producer writes its contract to the scratchpad **before** signalling done in STATUS.md.
- A consumer that finds a missing/empty contract stops and reports, rather than inventing one.

## Ordering dependent work

Two native options depending on how much determinism you want:

- **Ad-hoc / you steer** — call `./delegate` per repo. For "web must wait for
  api", delegate api with `--wait`, then delegate web once it returns.
- **Deterministic pipeline** — the `Workflow` tool. `pipeline(repos, produce, consume)`
  runs each repo through stages with no barrier; a producer's contract lands in
  the scratchpad before the consumer stage reads it. Use when the dependency
  graph is fixed.

## Setup

```sh
# delegate needs: herdr (running session), jq, claude — all already on PATH via mise
install -m755 delegate ~/.local/bin/delegate
mkdir -p ~/.agent_scratchpad
```

Optional, to carry across machines: `chezmoi add ~/.local/bin/delegate`.

## Run

```sh
# from anywhere, inside a herdr session:
delegate ~/work/api   feat/add-user-field "Add `phone` to the User API + OpenAPI. Publish the updated contract to \$scratch/contracts/user.yaml." --wait
delegate ~/work/web   feat/add-user-field "Consume phone from \$scratch/contracts/user.yaml in the user form. Do not invent fields."

# dry-run first to see the exact herdr calls, mutating nothing:
delegate ~/work/api feat/x "…" --dry-run
```

## Teardown

```sh
# order matters: remove the worktree by workspace id BEFORE closing the workspace
herdr worktree remove --workspace <id> --force
herdr workspace close <id>
# if the workspace was already closed, fall back to git:
#   git -C <repo> worktree remove --force <checkout>; git -C <repo> branch -D <branch>
rm -rf ~/.agent_scratchpad/<session>
```
