# Grilling Guide

The grilling exists to extract the decisions that are in the owner's head and
NOT in the document. It is adversarial rubber-ducking: the goal is to make the
user decide, not to make them repeat themselves.

## Mechanics

- **One question per message.** The answer to each question determines the
  next one. Batched questions get batched, shallow answers.
- **Lead with your best guess.** "The doc says 'standardize error handling' —
  I'd read that as: all mutations surface errors via notificationContext
  toasts, queries via the per-section ErrorBoundary. Is that the standard, or
  is there more to it?" A guess to correct beats a blank to fill; it is
  faster for the user and it exposes YOUR misreadings early.
- **Count down out loud.** "8 gaps left, next: migrations." Progress you can
  feel is what keeps a 40-question session from being abandoned at 15.
- **Answers are commitments.** Once the user decides, restate it in one line,
  record it, and never re-ask. Re-asking a settled question destroys trust in
  the whole session.
- **Detect fatigue.** If answers get terse ("yes", "fine", "whatever you
  think"), offer to checkpoint: emit tasks for what is settled, park the rest
  as a named follow-up grilling. A half-grilled queue that is honest about
  its gaps beats a fully-grilled one built on "whatever you think".

## The question taxonomy — in priority order

Ask in this order. Early categories invalidate later ones (no point sizing a
task the repo contradicts).

### 1. Contradictions (doc vs repo, doc vs doc)
"The doc says the house style is raw inline queries, but it also says
react-query becomes the standard. Which wins for NEW code starting now, and
does the loop migrate old code or only stop the bleeding?"

### 2. Irreversibles hiding inside items
Scan every item for verbs that destroy: delete, remove, purge, rewrite,
rotate, squash, force. "Item 5 says 'root declutter' — that includes deleting
CSV dumps. Deletion is owner-only in this workflow. Do you want (a) the agent
to MOVE candidates to a `_trash/` folder for your review [auto-able], or
(b) the whole item parked for you [owner]?"

### 3. Boundary decisions (keep/discard, this-or-that, naming)
The doc says "keep the canon docs". "Give me the exhaustive keep-list, or a
rule a script can apply. 'The handful of living docs' is not something an
agent can evaluate at 3am."

### 4. Gates
For every would-be-auto task: "What command proves this worked?" Then the
bad-faith test, out loud: "Could the agent pass that command while botching
the task? Your build ignores types — so for the typing task, `npm run build`
is a rubber stamp. I propose a tsc-error ratchet instead. OK?"

### 5. Sizing and batch boundaries
"'Migrate views in domain batches' — the repo has 21 module folders. Batch =
one module? And which module first? I'd propose the smallest (looks like
`brand/`, 4 views) to prove the pattern cheaply."

### 6. Sequencing constraints not in the doc
"Anything that must NOT run before something else that the doc doesn't say?
E.g. does the lint rule land before or after the migration it enforces?"

### 7. Vocabulary
Every project-specific term an agent could misread goes to CONTEXT.md with a
one-line definition. "The doc says 'god-files' — your threshold is 800 lines
post-split, 1,500 to qualify for splitting. Recording that."

### 8. Budget and blast tolerance
"If the loop goes sideways overnight, what is the acceptable worst case?
That sets MAX_TURNS, per-run budget, and where I put `review` instead of
`auto`."

## What NOT to ask

- Anything answered in the document. Quote it back if you need confirmation,
  don't ask it as an open question.
- Anything the repo answers. Read the repo first; asking the user what
  `package.json` contains is wasted goodwill.
- Preferences that don't change any task ("do you prefer 2-space indent") —
  the codebase and its linters answer these.
- Permission for things the rubric already forbids. Reversibility-D is
  `owner`; do not ask "are you SURE you don't want the agent to run
  filter-repo?" The question itself invites a bad answer.

## CONTEXT.md maintenance

Create at repo root if absent. Format: one `## Term` heading + one-paragraph
definition, alphabetical. Append terms as they surface; never delete existing
entries (other sessions may rely on them). This file is read by every future
grilling session AND may be referenced by emitted tasks — it is the shared
vocabulary that keeps five developers' triage sessions consistent.
