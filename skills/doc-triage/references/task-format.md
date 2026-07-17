# Task Output Format

One contract, two transports. The runner (`autorun-queue.sh` / `ralph.sh`)
parses the frontmatter; the agent reads the body; the human reads
PLAN-SUMMARY.md.

## Frontmatter contract (both modes)

```
---
id: p1-03                 # stable, short, unique; phase-prefix convention
title: One line, verb-first
risk: auto|review|owner
deps: p1-00, p1-01        # ids; empty if none
gate: npm test && ./scripts/check-ratchet.sh
---
```

Rules:
- `gate` is ONE shell line, exit 0 = proven. Compose with `&&`. It must
  already exist in the repo (verified during triage, never invented).
- `deps` are ids, not titles. A task with an unmet dep is skipped, not failed.
- `risk` follows references/readiness-rubric.md §"Risk class decision table".

## Body template

```markdown
## Goal
What done looks like, in the agent's terms. 2–5 lines. Include the WHY in one
sentence — agents make better micro-decisions when they know the intent.

## Context
Repo facts the agent needs and could not cheaply discover: real paths, the
pattern to imitate (point at an exemplar file), decisions from the grilling
that bind this task. If CONTEXT.md defines relevant terms, name them.

## Rules
The task-specific discipline. E.g. TDD: one failing test → minimal code to
pass → refactor → repeat; never write tests in bulk against imagined behavior.
E.g. ratchet: the error count may never rise; never trade it for `as any` /
`@ts-ignore` / config loosening.

## Steps
- [ ] Numbered, checkable, each independently committable if possible.

## Done when
Restate the gate in words + anything the gate can't check (the agent should
self-verify these and record them in PROGRESS.md).

## NEVER
The load-bearing list. Copy faithfully from the triage session; do not
soften. Standard floor for every task:
- git push, force-push, rebase, reset --hard, filter-repo
- rm / git rm — deletion is owner-only
- anything touching prod, live DB, deploys, secrets, .env*
- editing generated files (name them)
Plus task-specific NEVERs from the grilling.

If any step seems to require a NEVER item, the task is mis-specified:
write the blocker to PROGRESS.md and stop. Do not improvise around it.
```

## Mode selection — ask, never infer

ALWAYS ask the user which mode before emitting. Offer a recommendation
("team + GitLab remote → gitlab mode?") but the choice is theirs. Verify the
relevant CLI is authenticated before emitting into it; a half-emitted queue in
a broken mode is worse than no queue.

The frontmatter contract is IDENTICAL in all three modes — only the transport
changes. In issue modes the full frontmatter block stays at the TOP of the
issue body; the runner parses it from there.

## local

Files: `queue/NNN-slug.md`, NNN in dependency-respecting order (gaps of 10 so
insertions don't renumber). State lives in `.autorun/state/<id>`. Prefer when:
solo, no remote, experimentation, or the team tracker must stay clean.

## github

Requires `gh` authenticated (`gh auth status`). Emit each task as:

```bash
gh issue create \
  --title "[<id>] <title>" \
  --label "agent-<risk>" \
  --body-file <tmpfile-with-frontmatter-and-body>
```

- Labels `agent-auto`, `agent-review`, `agent-owner`, `agent-parked` must
  exist; create missing ones once (`gh label create agent-auto --color 0E8A16`).
- deps reference ids; additionally write "Blocked by #<number>" in the body so
  humans see the chain in the UI.
- Runner behavior: list open `agent-auto` issues, same dep/state logic,
  progress as issue comments, close on gate pass, `agent-parked` label + log
  tail comment on failure.

## gitlab

Requires `glab` authenticated (`glab auth status`). Emit each task as:

```bash
glab issue create \
  --title "[<id>] <title>" \
  --label "agent-<risk>" \
  --description "$(cat <tmpfile-with-frontmatter-and-body>)"
```

- Same four labels; create missing ones once
  (`glab label create --name agent-auto --color "#0E8A16"`).
- deps reference ids; additionally write "Blocked by #<iid>" in the
  description for human visibility. GitLab issue references use the iid.
- Runner behavior mirrors github mode: `glab issue list --label agent-auto`,
  progress via `glab issue note`, `glab issue close` on gate pass,
  `agent-parked` label + log tail note on failure.

Prefer an issue mode when: >1 developer, a remote exists, or the user wants
review threads and assignment. GitHub vs GitLab follows where the repo lives —
check `git remote -v` before recommending.

## PLAN-SUMMARY.md (always, both modes)

```markdown
# Plan summary — <doc> / <scope> — <date>

## Queue
| id | title | risk | gate | deps |

## Execution order
Linearized dep order; parallel-safe groups marked.

## Splits
What was one doc item → N tasks, and the boundary logic.

## Owner items
Everything classified owner, with the reason. These are YOURS; the loop will
not touch them.

## Gate debt
Tasks capped at review because no honest gate exists; what gate would need
to be built to promote them.

## Doc drift
Every claim in the source document contradicted by the repo.

## Grilling decisions
The binding decisions made in the session, one line each. (Also reflected in
CONTEXT.md where they define vocabulary.)
```

## Recon tasks

When sizing is unknowable (rubric Atomicity C), emit exactly one task whose
deliverable is a plan file, not code:

```
id: p1-02-recon
title: Map the type-error fallout and propose batches
risk: auto
gate: test -s docs/plans/p1-02-batches.md
```

Body instructs the agent to produce the batch plan (groups, counts, file
lists, proposed order) and NOT to fix anything. The next triage pass consumes
that file and emits the real batch tasks — with the human approving the plan
in between.
