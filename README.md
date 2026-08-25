# herdr multi-repo orchestrator

Fan out one isolated [Claude Code](https://claude.com/claude-code) sub-agent per
repository — each in its own **herdr** worktree workspace — for changes that
span several repos at once. An orchestrator agent discovers
which repos a task touches, then delegates scoped work to a sub-agent per repo,
syncing them through a shared scratchpad.

Built on **herdr** because each sub-agent lands in a real, focusable workspace
you can watch live and jump between — with herdr's agent-state model
(ready / working / idle) driving the producer→consumer sync.

## Why

A change that touches an API repo and the web repo that consumes it is painful
to drive from one session: you lose git context switching between checkouts, and
there's no clean way to run and watch several agents at once. This gives each
repo its own worktree, its own branch, and its own Claude agent — coordinated,
isolated, and navigable.

## Requirements

`herdr`, `jq`, and your agent runtime on `PATH`, run inside a herdr session. The
runtime is **Hermes** (`hermes`) by default, or **Claude Code** (`claude`) — pass
`--kind claude` (see [Runtime](#runtime-claude-or-hermes)).

## Install

```sh
git clone https://github.com/hung-eggie-do-covergo/delegate-orchestrator.git
cd delegate-orchestrator
./install.sh
```

`install.sh` verifies `herdr`, `jq`, and an agent runtime (`hermes` or `claude`) are on `PATH`, then copies:

| From | To |
|---|---|
| `skills/delegate-orchestrator/`, `skills/delegate-cleanup/` | `~/.claude/skills/` |
| `bin/orchestrate`, `bin/delegate` | `~/.local/bin/` (executable) |
| `bin/AGENT.md`, `bin/orchestrator-README.md` | `~/.local/bin/` |

Make sure `~/.local/bin` is on your `PATH`, then **restart Claude Code** so it
picks up the new skill.

Prefer to do it by hand? Copy those files to the same locations — that's all
`install.sh` does.

Uninstall: delete the copied files and the skill directory.

## Quickstart

From your workspace root (the directory holding your repos):

```sh
orchestrate PROJ-1234
```

This adds a tab in a shared `orchestrators` workspace (created once, so orchestrators group under one collapsible sidebar entry instead of a flat pile), starts a **constrained** orchestrator agent
(file-editing tools disabled — it can only discover and delegate, never edit a
repo itself), and invokes the orchestration skill for the ticket. The
orchestrator scans your repos for the ticket, asks which worktrees to reopen,
then delegates to each.

## Walkthrough

Say ticket `PROJ-1234` spans an `api` repo and the `web` repo that consumes it.
From the directory that holds both:

```sh
orchestrate PROJ-1234
```

The orchestrator scans your repos and shows what it found, then asks which
worktrees to reopen:

```
Found 2 repos with PROJ-1234:

  repo   branch          worktree                              herdr workspace
  api    local + origin  ~/.herdr/worktrees/api-PROJ-1234      closed
  web    local + origin  none                                  —

Which PROJ-1234 repos should delegate reopen?
  > api (existing worktree, closed)
    web (branch only — delegate creates a worktree)
    both
```

Pick, and it delegates to each. Typical output:

```
api — reused worktree ~/.herdr/worktrees/api-PROJ-1234, resumed session
      9f3c… (the one that did PROJ-1234 before), prompt sent → pane w7:p1
web — created worktree on PROJ-1234, started a fresh agent → pane w8:p1
```

Watch or take over any sub-agent live:

```sh
herdr workspace focus w7        # jump into api's agent
herdr agent wait w7:p1 --until idle   # block until it's done
```

If a repo's prior session is **already running**, delegate won't spawn a
duplicate — it tells you to attach (`claude agents`) or branch a copy
(`--fork-session`).

When the work is done, ask the orchestrator to **clean up** (the
`delegate-cleanup` skill): it reviews the sub-agents, checks each one's work is
saved and integrated, and — after you confirm — closes the finished workspaces
and worktrees. It never tears anything down unattended (idle ≠ finished).

### Driving `delegate` directly

Skip the orchestrator and delegate a repo yourself. Producer first (blocks until
idle so its contract is ready), then consumers fan out in parallel:

```sh
S=proj-1234
delegate ~/src/api PROJ-1234 "Add the phone field + publish the OpenAPI to \$scratch/contracts/user.yaml" --session $S --wait
delegate ~/src/web PROJ-1234 "Consume phone from \$scratch/contracts/user.yaml in the user form" --session $S &
delegate ~/src/sdk PROJ-1234 "Regenerate the client from \$scratch/contracts/user.yaml" --session $S &
wait
```

`--session` must match across repos — it selects the shared scratchpad they sync
through. `--dry-run` previews the herdr calls without touching anything.

## How it works

```
orchestrator  (constrained Claude agent — discovers + delegates, never edits)
     │  delegate <repo> <branch> "<scoped prompt>" --session <id>
     ▼
 ┌───────────────┐   ┌───────────────┐
 │ herdr ws: api │   │ herdr ws: web │   … one worktree + agent per repo
 │  branch: feat │   │  branch: feat │
 │  Claude agent │   │  Claude agent │
 └──────┬────────┘   └──────┬────────┘
        └──────── scratchpad ────────┘
             ~/.agent_scratchpad/<session>/
```

- **`orchestrate <ticket>`** — launches the constrained orchestrator for a ticket.
- **`delegate <repo> <branch> "<prompt>" --session <id>`** — the primitive: opens
  or reuses a worktree for the branch, starts (or resumes) a Claude agent in it,
  and sends the scoped prompt. Independent repos fan out concurrently; a producer
  runs with `--wait` before its consumers.

## Key behaviours

- **Worktree reuse** — an existing checkout for the branch is reopened, not
  recreated.
- **Session resume** — reopening a worktree resumes the exact prior Claude
  session that did that ticket's work (matched by recorded `gitBranch`), so
  context carries over. `--fresh` forces a new session.
- **No duplicate on a live session** — if the matching session is already
  running, delegate reports it instead of spawning a conflicting copy
  (`--fork-session` to branch one deliberately).
- **Constrained orchestrator** — the orchestrator is launched without file-editing
  capability (Claude: `Edit`/`Write`/`NotebookEdit` disabled; Hermes: a toolset
  allowlist with no `file`/`code_execution`), so "only delegate, never edit" is a
  capability boundary, not a fragile instruction.
- **Model per role** — the orchestrator only coordinates, so it runs on a cheap
  model (`orchestrate --model`, default `sonnet`); each delegate does the real
  code work on a stronger one (`--delegate-model`, default `opus`), and the
  orchestrator downgrades small/mechanical repos to save tokens. Drive it
  directly with `delegate … --model <name>` (or the `DELEGATE_MODEL` env var).

## Runtime: Claude or Hermes

Both `orchestrate` and `delegate` take `--kind hermes` (default) or `--kind
claude`. `orchestrate` runs the orchestrator on Hermes and tells it
to delegate every repo with `--kind hermes` too, so the whole fan-out stays on one
runtime.

```sh
orchestrate PROJ-1234                            # whole orchestration on Hermes (default)
orchestrate PROJ-1234 --kind claude            # ... on Claude Code instead
delegate ~/src/api PROJ-1234 "…" --kind claude # one repo on Claude Code
```

What changes per runtime:

| | Claude | Hermes |
|---|---|---|
| launched as | `claude …` | `hermes --tui …` |
| model flag | `--model` | `-m` |
| session resume | exact prior session matched by recorded `gitBranch` | `--resume latest` (the worktree's own cwd scopes its session store) |
| worker autonomy | pane permission mode | `--yolo` (disable with `delegate --no-yolo`) |
| orchestrator no-edit | `--disallowedTools Edit Write NotebookEdit` | toolset allowlist without `file`/`code_execution` |

Everything else — herdr worktree reuse, the shared `orchestrators` workspace,
prompt-submission verification, concurrent fan-out — is identical across runtimes.

## Layout

| File | Role |
|---|---|
| `skills/delegate-orchestrator/` | the orchestration skill Claude loads |
| `skills/delegate-cleanup/` | in-chat skill to review + tear down finished sub-agents (with confirmation) |
| `bin/orchestrate` | launch a constrained orchestrator for a ticket |
| `bin/delegate` | per-repo primitive (worktree + agent + prompt) |
| `bin/AGENT.md` | operating rules copied into each sub-agent's scratchpad |
| `bin/orchestrator-README.md` | architecture + how it maps to native herdr |

## License

MIT — see [LICENSE](LICENSE).
