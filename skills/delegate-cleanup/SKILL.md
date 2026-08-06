---
name: delegate-cleanup
description: >
  In an orchestrator session, review the delegated per-repo sub-agents and tear down the
  ones that have genuinely finished — closing their herdr workspace and worktree — after
  checking their work is saved and CONFIRMING with the user. Use when the user says "clean
  up finished agents", "clean up the delegates", "tear down done worktrees", "cleanup", or
  asks which sub-agents can be closed. Only in a session that fanned out sub-agents via the
  delegate-orchestrator skill. Never runs unattended: idle does not mean finished.
---

# Cleaning up finished delegated sub-agents

You are the orchestrator that delegated work across repos. This skill reviews those
sub-agents and tears down the finished ones. It is a **judgement + confirmation** loop,
never a blind sweep — `idle` means "not typing right now", NOT "done". A sub-agent can be
idle because it finished, or because it is waiting on the next instruction with work still
open. Only YOU (with the user) can tell which.

## Scope — only your own delegated sub-agents
Clean only the per-repo agents this session delegated (herdr agents named `claude-*`,
each running in a linked git worktree). NEVER touch:
- the orchestrator/main session or any agent you did not spawn,
- an agent whose workspace is the main checkout (not a linked worktree),
- anything the user is actively using.

## 1. Gather the state — do not act yet
List the candidates and, for each, read the signals that say whether it is safe to drop:
```sh
herdr agent list | jq -r '.result.agents[]? | select((.name//"")|startswith("claude-"))
  | [.name,.pane_id,.workspace_id,.agent_status,.cwd] | @tsv'
```
For each candidate worktree `<cwd>`:
```sh
git -C <cwd> status --porcelain          # non-empty = uncommitted work → NOT safe
git -C <cwd> rev-list @{u}..HEAD          # non-empty = unpushed commits
git -C <cwd> symbolic-ref --short HEAD    # its branch
# merged into base? (base = origin default branch)
base=$(git -C <cwd> symbolic-ref -q --short refs/remotes/origin/HEAD || echo origin/main)
git -C <cwd> merge-base --is-ancestor HEAD "$base" && echo merged || echo not-merged
```

## 2. Classify, then ASK — never auto-tear-down
Build one summary and put it to the user. Sort each agent into:
- **Busy** — `agent_status` is working/blocked → keep, it is mid-task.
- **Unsaved** — uncommitted changes, or commits neither pushed nor merged → keep; losing
  these destroys work. Flag it, don't offer to clean it (unless the user insists).
- **Looks finished** — idle + clean tree + merged (or pushed). Even here, present it and
  **ask the user to confirm** it is actually done before touching it. Prefer *merged* as
  the real "done" signal; treat *pushed-but-not-merged* as "probably still in review —
  confirm".

Present it plainly, e.g. "these 2 look done (merged, clean); these 3 are still busy or have
unsaved work — which should I tear down?" Then act ONLY on what the user confirms.

## 3. Tear down (confirmed agents only)
Order matters — remove the worktree before closing its workspace:
```sh
herdr worktree remove --workspace <workspace_id> --force
herdr workspace close <workspace_id>
# delete the branch ONLY if it was merged (safe -d refuses an unmerged branch):
git -C <main_repo_root> branch -d <branch>
```
Leave the shared scratchpad (`~/.agent_scratchpad/<session>`) in place until every
sub-agent of the session is gone — other agents may still read it.

## Guardrails
- Confirm before each destructive batch. When unsure whether an agent is finished, ask —
  do not guess.
- Never clean an agent with uncommitted or un-integrated work unless the user explicitly
  accepts the loss.
- `idle` is not "done". Merged is the only strong "done"; pushed means "backed up", not
  finished.
