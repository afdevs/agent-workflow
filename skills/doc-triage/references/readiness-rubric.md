# Readiness Rubric

Score each item of the document individually on five axes. The document's
"readiness" is the distribution of its items, never a single verdict.

## The five axes

### 1. Atomicity — can a fresh agent finish it in one session?
- **A**: One commit, ≤30 turns, named files. ("Add ownership guard to
  `save_offer` RPC")
- **B**: Splittable mechanically — the item enumerates or implies its own
  parts. ("Decompose these 5 functions" → 5 tasks)
- **C**: Size unknowable until work starts. ("Triage the type errors" — how
  many? what kinds?) → emit a `recon` task first.
- **D**: A program, not a task. ("Migrate views in domain batches") → needs
  grilling to find the batch boundaries, then splits into many tasks.

### 2. Verifiability — does an honest gate exist?
- **A**: A repo command proves the work. (`npm test`, `check:routes`)
- **B**: A gate exists but is dishonest for this task — passing it does not
  prove the work. Classic: build uses esbuild (ignores types), task is about
  typing. → prescribe a stricter command or a ratchet.
- **C**: The metric starts dirty (pre-existing failures) → ratchet: the count
  may never rise; tightens as it falls.
- **D**: No verification exists and none can be scripted (visual/judgment
  outcomes). → `review` at best; flag in PLAN-SUMMARY.md.

### 3. Reversibility — what does a bad run cost?
- **A**: Fully contained in a branch; `git branch -D` undoes everything.
- **B**: Contained but expensive to review if wrong (huge diffs).
- **C**: Touches shared state that's awkward to roll back (lockfiles,
  generated code committed elsewhere, CI config).
- **D**: Irreversible or external: history rewrite, deletion, prod, secrets,
  live DB, team coordination. → `owner`, no exceptions.

### 4. Groundedness — does the doc match the repo?
- **A**: Spot-checks pass (paths exist, scripts exist, counts roughly hold).
- **B**: Minor drift (counts off, files moved) → correct in the task body,
  note in PLAN-SUMMARY.md.
- **C**: The item references things that don't exist → grill or drop; never
  emit a task against phantom state.

### 5. Decision-completeness — are the judgment calls made?
- **A**: No open decisions; the item says exactly what and how.
- **B**: Open decisions with an obvious default → propose the default during
  grilling, get a yes/no.
- **C**: Open decisions that only the owner can make (what to keep vs delete,
  which of two patterns wins, naming, API shape) → these ARE the grilling
  agenda. An item is not emittable until its C-decisions are answered.

## Mapping scores to action

| Profile | Action |
|---|---|
| A across the board | Compile directly (Phase 3), light or no grilling |
| Atomicity B/D, rest fine | Split during Phase 3; confirm boundaries in grilling |
| Atomicity C | Emit one `recon` task; re-triage after it runs |
| Verifiability B/C | Prescribe stricter gate / ratchet; confirm with user |
| Verifiability D | Cap at `review`; say why in PLAN-SUMMARY.md |
| Reversibility D | `owner`. Grilling cannot change this. |
| Groundedness B/C | Verify against repo; correct or drop |
| Decision C | Grill until answered; do not emit before |

## Risk class decision table

Start from `auto` and demote on the first match:

1. Reversibility D → **owner**
2. The source document marks it manual / live-DB / team-coordination → **owner**
3. Decides what to keep vs discard (files, deps, data) → **owner**
4. Security-sensitive logic, auth contracts, tenancy/RLS changes → **review**
5. Public API / schema shape decisions → **review**
6. No honest gate (Verifiability D) → **review**
7. Blast radius > ~20 files in one task → **review** (or split until under)
8. Otherwise, with an honest gate → **auto**

Rules 1–3 are absolute. Rules 4–7 may be relaxed ONLY by the user explicitly,
during grilling, per-task — record the relaxation in PLAN-SUMMARY.md.
