---
name: doc-triage
description: Transform any planning document (roadmap, PRD, spec, audit report, TODO list, migration plan) into atomic, gated, risk-classified tasks that an autonomous agent loop (Ralph loop / claude-autorun) can execute unattended. Use this skill whenever the user wants to run a document with an agent loop, asks "can Claude autorun this doc", wants to turn a roadmap/PRD/spec into tasks or GitHub issues for agents, mentions doc-triage, grilling a document, or preparing work for overnight/non-stop agent execution. Also trigger when a user drops a planning document and asks to "make this runnable", "split this into tasks", or "prepare this for the loop" — even if they don't name the skill.
---

# Doc Triage

Compile a human planning document into an execution queue for autonomous coding
agents. The output is a set of atomic tasks — each with a risk class, a gate
command, and dependencies — that a Ralph-style loop can work through unattended.

The core problem this skill solves: planning documents are written for humans
reading over weeks. Agents get a fresh context every iteration and ~30 turns.
"Migrate views in domain batches" is a fine roadmap line and a terrible task.
The gap between the two is closed by *interrogation*, not parsing — and the
questions must be answered by a human who knows the project, because guessing
at them poisons every downstream run.

## The three phases

Work through these in order. Do not skip the assessment; do not start emitting
tasks before the grilling has closed every gap the assessment found.

### Phase 1 — Assess (never a yes/no)

Read the document fully. Then explore the repository to verify its claims —
documents drift, and a task built on a stale claim fails confusingly at 3am.
Check: do the paths it names exist? Do the npm/CI scripts it references exist
in package.json? Are counts it cites ("70 edge functions") still true?

Score the document against the readiness rubric in
`references/readiness-rubric.md` (read it now if you haven't). The rubric
yields a per-item verdict, not a document verdict: some items in a doc may be
ready while others need heavy grilling. Produce a short assessment summary for
the user:

- Items already atomic + gateable (can compile directly)
- Items too big (need splitting — say into roughly how many)
- Items with no honest gate (the gate exists but wouldn't prove the work,
  or no verification command exists at all)
- Items that are irreversible or outside the repo (prod, history, deletion,
  secrets) — these will be classified `owner` no matter what
- Claims in the doc that contradict the actual repo state
- Vocabulary that is ambiguous or project-specific (candidates for CONTEXT.md)

If EVERY item lands in the first bucket, say so, skip Phase 2, and go straight
to Phase 3. This almost never happens with real documents.

### Phase 2 — Grill

Interrogate the user to close every gap from Phase 1. Full protocol in
`references/grilling-guide.md` — read it before asking your first question.
The essentials:

- **One question at a time.** Never a wall of questions. Each answer changes
  what to ask next.
- **Adversarial, not clerical.** Do not ask the user to restate the document.
  Ask the questions whose answers are NOT in the document: the sharp edges,
  the "what happens when", the "which of these two contradictory things wins".
- **Every answer becomes an artifact.** Decisions go into the emitted tasks.
  Vocabulary goes into `CONTEXT.md` (create it if absent, append if present) —
  a glossary of project terms so future agents and future grilling sessions
  use 1 word where 20 would drift.
- **Track a visible countdown.** Tell the user roughly how many open gaps
  remain so they can feel progress. Expect 15–50 questions for a strategy
  document; a tight PRD might need 5.
- **Stop when saturated,** not when tired: when every planned task has an
  owner-approved size, gate, and risk class, the grilling is done.

### Phase 3 — Emit

Produce the task queue. Format spec and templates in
`references/task-format.md` (read it before emitting). Three modes — ALWAYS
ask the user which one before emitting anything; never infer silently. Frame
the question with a recommendation based on context (solo vs team, which
remote the repo has, whether the tracker should stay clean), but the user
decides:

- **local**: `.agent/queue/NNN-slug.md` files in the repo (solo work, experiments,
  or keeping the team tracker unpolluted)
- **github**: GitHub issues via `gh`, labeled by risk class (team visibility,
  review threads, assignment)
- **gitlab**: GitLab issues via `glab`, labeled by risk class (same benefits,
  GitLab-hosted projects)

Before promising an issue mode, verify the CLI is present and authenticated
(`gh auth status` / `glab auth status`). If it isn't, offer two paths and let
the user pick: pause while they authenticate, or **fall back to local mode
now** — emit `.agent/queue/NNN-slug.md` files instead. The fallback loses nothing:
deps resolve by task id, not issue number, so a local queue can be re-emitted
as issues later without breaking the graph. Never emit half a queue into a
broken mode, and never silently switch modes — say what happened and why.

Every task, regardless of mode, carries the same frontmatter contract:
`id`, `title`, `risk` (auto|review|owner), `deps`, `gate`. The runner refuses
anything that isn't `auto`, so a wrong risk class is the single most dangerous
mistake this skill can make. When unsure, classify stricter: a wrong `owner`
costs a human ten minutes; a wrong `auto` can cost a codebase.

Always finish by writing `.agent/PLAN-SUMMARY.md`: the task table, dependency order,
what was split and why, everything classified `owner` and why, every gate you
could not find an honest version of, and every doc-vs-repo contradiction found
in Phase 1. This is the document the human reviews before launching the loop —
optimize it for a fast, high-confidence review.

## Rules that hold across all phases

**Ground every task in files you actually read.** A task naming an invented
path or a fabricated npm script fails at runtime and wastes a session window.
If the document references something that doesn't exist, record it in
.agent/PLAN-SUMMARY.md; never invent it.

**No gate, no auto.** The gate must be a real command that already exists in
the repo, and it must genuinely prove the work. Apply the "bad-faith test":
could an agent satisfy this gate while doing the task badly? (Classic trap:
a build that ignores types passing a typing task.) If the metric starts dirty
and can't reach zero yet, prescribe a ratchet — count may never rise — rather
than pretending it can pass clean. If no honest gate exists, the task is
`review` at best, and .agent/PLAN-SUMMARY.md says why.

**Size for one session.** One task ≈ one commit, ≤ ~30 agentic turns, a
handful of files. When an item's true size is unknowable until work starts,
emit a single `recon` task whose deliverable is the split itself (a plan
written to a file), consumed by the next triage pass. Do not guess at fifty
unknown files.

**Irreversible means owner. Always.** Git history rewrites, force-push, file
or secret deletion, production deploys, live-DB migrations, key rotation,
dependency removal, anything the source document itself marks as needing a
human / a live system / team coordination. No amount of grilling converts
these to `auto` — the human does them, the skill just puts them in the queue
so they aren't forgotten.

**Already-done work is not re-emitted.** Check git log and the repo state for
items the document lists but that have already landed.

**Write for the amnesiac.** Every emitted task will be read by an agent with
zero memory of this conversation, this document, or the grilling. The task
body must be self-sufficient: goal, rules, steps, done-when, and a NEVER list.
If understanding a task requires reading the source document, the task is
not finished.

## Anti-patterns (each of these has burned someone)

- Emitting the whole document in one pass. Triage ONE phase/section per pass;
  re-run after it lands. Later phases depend on knowledge that only exists
  after earlier ones execute.
- Letting the user skip the grilling "because the doc is detailed". Detail is
  not the same as decisions. A detailed doc can still contain "delete the
  unneeded files" — which file is unneeded is a decision.
- Gates written as prose ("verify the view still works"). A gate is a shell
  command with an exit code, nothing else.
- Classifying by effort instead of risk. A trivial `rm -rf docs/old/` is
  `owner`; a grueling 400-error type-triage is `auto`. Risk = reversibility ×
  blast radius, not difficulty.
- Softening a NEVER list to make a task self-contained. The NEVER list is
  load-bearing; copy it faithfully into every task it applies to.
