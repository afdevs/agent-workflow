# agent-workflow

Transformer un document de planification (roadmap, PRD, spec, audit) en une
queue de tâches atomiques, puis les faire exécuter par une boucle d'agents
Claude Code **sans supervision** — nuit comprise.

Testé en conditions réelles sur la Phase 4 du reshape Cookpit (26 tâches,
69 edge functions, kernel `_shared/`, tests de caractérisation money-math).

---

## La règle d'or

> **Aucune tâche ne reçoit la classe `auto` sans être passée par le grilling.**

Le runner n'est pas la pièce importante — c'est une boucle bash volontairement
bête. La pièce importante est le triage : l'interrogatoire qui extrait les
décisions qui sont dans TA tête et pas dans le document. Exemple réel : la
roadmap disait « 96 tables artisanales à migrer » ; le grilling a révélé que
les `<table>` de `views/landing/blocks/` sont du **contenu client de landing
pages**, pas des tables de l'app — exclues à vie. Une nuit de boucle sans
cette décision aurait cassé des pages clients.

Si tu labellises `auto` sans grilling, tu obtiens du travail vague la nuit et
tu concluras « ça marche pas ». Ça marche. C'est le triage qui était absent.

## Le workflow

```
Document ──► /doc-triage ──► Revue humaine ──► autorun-queue.sh ──► Revue matin
             (assess +        (PLAN-SUMMARY,    (tourne seul,        (diffs, inbox,
              grilling +       10 min)           dort pendant         tâches parkées)
              émission)                          les rate limits)
```

1. **Triage** : `claude` puis demander de trier UNE phase/section du document
   avec le skill `doc-triage`. Réponds aux questions — 15 à 50 selon le doc.
   Le skill DEMANDE le mode d'émission (il ne devine jamais) :
   - **local** — fichiers `queue/NNN-*.md` dans le repo (solo, expérimentation,
     tracker d'équipe intouché)
   - **github** — issues GitHub via `gh`, labels `agent-auto|review|owner`
   - **gitlab** — issues GitLab via `glab`, mêmes labels
   Sortie : la queue (fichiers ou issues), `PLAN-SUMMARY.md`, `CONTEXT.md` enrichi.
2. **Revue** (la seule étape humaine avant le lancement, ~10 min) : lire
   `PLAN-SUMMARY.md`, sections **Gate debt** et **Doc drift** en priorité.
   Chercher trois choses : une tâche `auto` qui touche de l'irréversible, un
   gate qu'un agent pourrait satisfaire en bâclant, une tâche qui en cache dix.
3. **Lancement** : sur un **worktree**, jamais sur `main` (voir Quickstart).
4. **Revue du matin** : `git log` (un commit par tâche ?), `HUMAN-INBOX.md`
   (refus et échecs, avec raisons), branches `parked/<id>` (travail raté
   préservé, ligne principale propre), `.autorun/cost_usd`.

## Classes de risque

| Classe | Qui exécute | Critère |
|---|---|---|
| `auto` | La boucle, sans surveillance | Mécanique, réversible, gate honnête |
| `review` | La boucle code, un humain valide avant merge | Jugement, sécurité, API publique, pas de gate honnête |
| `owner` | Un humain, jamais la boucle | Irréversible ou hors repo : deploy, suppression, prod, secrets, réécriture d'historique |

Le risque = réversibilité × rayon d'impact, **pas** la difficulté. Un
`rm -rf docs/old/` trivial est `owner` ; un triage de 400 erreurs de types
pénible est `auto`.

## Concepts à connaître

- **Gate** : une commande shell, exit 0 = travail prouvé. Un gate en prose
  n'est pas un gate. Test de mauvaise foi : « l'agent peut-il passer ce gate
  en bâclant ? » Si oui, le gate est malhonnête → classe `review`.
- **Ratchet** : gate sur un métrique qui part sale (ex. 541 erreurs `tsc`) —
  le compte ne doit jamais remonter, et se resserre quand il descend.
  `scripts/check-ratchet.sh`.
- **Agent amnésique** : chaque itération démarre avec un contexte vierge.
  L'état vit dans les fichiers (`PROGRESS.md`, la queue, git), jamais dans la
  conversation. C'est un principe (Ralph loop, Huntley/Pocock), pas une limite.
- **CONTEXT.md** : glossaire liant à la racine du repo. On ajoute, on ne
  supprime jamais. Lu par les agents ET les sessions de triage futures.
- **Tâche recon** : quand la taille d'un chantier est inconnaissable avant de
  commencer, on émet UNE tâche dont le livrable est le plan de découpage —
  jamais cinquante tâches devinées.

## Exemple complet (déroulé illustratif, issu d'un test du skill)

```bash
# 0. Préparation — worktree dédié, jamais main
cd ~/devlab/cookpit
git worktree add ../cookpit-p4 reshape/phase-4
cd ../cookpit-p4
cp <agent-workflow>/scripts/autorun-queue.sh . 
cp <agent-workflow>/scripts/check-ratchet.sh scripts/

# 1. Triage — une phase, pas le document entier
claude
> Trie la Phase 4 de docs/RESHAPE-ROADMAP.md avec doc-triage pour la boucle autonome.
#   → assess : vérifie le doc contre le repo (a détecté "Deno tests" alors que
#     le pattern réel est Vitest, 69 fonctions et non 70…)
#   → grilling : ~30 questions, une à la fois. Exemple de décision extraite :
#     les <table> de views/landing/blocks/ sont du contenu client de landing
#     pages, PAS des tables de l'app → exclues à vie (gravé dans CONTEXT.md).
#   → le skill DEMANDE le mode : local / github / gitlab → local (branche perso)
#   → émission : queue/010…260 (26 tâches : 14 auto / 4 review / 8 owner),
#     PLAN-SUMMARY.md, CONTEXT.md

# 2. Revue humaine (~10 min) — PLAN-SUMMARY.md, sections Gate debt et Doc drift
#    Chercher : un auto qui touche l'irréversible ? un gate satisfiable en
#    bâclant ? une tâche qui en cache dix ?

# 3. Lancement — la boucle tourne seule, dort pendant les rate limits
tmux new -s p4
QUEUE_MODE=local MODEL=sonnet BUDGET_TOTAL=15.00 ./autorun-queue.sh
# Ctrl-b d — et bonne nuit

# 4. Le matin
git log --oneline              # un commit par tâche
cat HUMAN-INBOX.md             # refus + échecs, avec raisons ; tâches owner (deploys)
git branch --list 'parked/*'   # travail raté préservé, ligne principale propre
cat .autorun/cost_usd          # coût réel de la nuit
```

## Tout le document d'un coup, ou tranche par tranche ?

Tranche par tranche — mais la vraie règle n'est pas « une phase » : c'est
**une passe = une tranche dont TOUTES les tâches s'ancrent dans le repo tel
qu'il est AUJOURD'HUI.**

Compiler tout le document d'un coup casse quatre choses :

1. **Les phases tardives référencent un état qui n'existe pas encore.** Cas
   réel : les tests RPC de la Phase 4 ont été parkés parce que leur gate est
   malhonnête *tant que le squash de la Phase 2 n'a pas atterri*. Une passe
   document-entier les aurait émis quand même, ancrés dans un repo futur.
2. **La queue périme pendant qu'elle s'exécute.** 100+ tâches émises
   aujourd'hui décrivent les chemins d'aujourd'hui ; à la tâche 60, quarante
   commits ont tout déplacé.
3. **Fatigue de grilling.** Une phase = ~12 décisions. Le document entier =
   50+ d'un coup → réponses « fais comme tu veux » → queue poubelle.
4. **La revue cesse d'être réelle.** 26 tâches en 10 minutes, c'est une revue.
   120, c'est un tampon — et la revue est TON seul garde-fou avant l'exécution
   sans surveillance.

**Exception** : un petit document (PRD d'une feature, liste de bugs) dont tout
s'ancre dans le repo actuel se trie en une passe — l'assess du skill te le
dira. Le cycle normal : trier une tranche → run → merge → re-trier la
suivante, qui ramasse les tâches parkées et les sorties des tâches recon.
Le document se consomme par vagues, chaque vague ancrée dans le réel.

## Quickstart

```bash
# Prérequis : bash 4+, GNU date, jq, git, claude CLI. Skill doc-triage installé.

cd ~/devlab/<projet>
git worktree add ../<projet>-agent <branche-agent>
cd ../<projet>-agent
cp <ce-repo>/scripts/{autorun-queue.sh,check-ratchet.sh} .

# 1+2. Triage puis revue (voir workflow ci-dessus) — queue/ doit exister

# 3. Lancement, sous tmux pour survivre à la déconnexion SSH
tmux new -s agent
QUEUE_MODE=local  MODEL=sonnet BUDGET_TOTAL=15.00 ./autorun-queue.sh
# ou : QUEUE_MODE=github (gh authentifié) / QUEUE_MODE=gitlab (glab authentifié)
# En mode issues : le runner ne prend QUE les issues ouvertes labellisées
# agent-auto, commente sa progression, ferme au gate vert, labellise
# agent-parked en cas d'échec.
# Ctrl-b d pour détacher

# Suivi à distance
tail -f .autorun/queue.log
```

Variables utiles : `QUEUE_MODE` (local | github | gitlab), `MODEL` (sonnet par
défaut — haiku pour le mécanique pur, opus pour le triage, jamais nécessaire
pour la boucle), `BUDGET_TOTAL` / `BUDGET_PER_RUN` (coupe-circuit dépenses),
`MAX_TURNS` (30 par défaut), `CONSEC_FAIL_LIMIT` (3 échecs consécutifs =
arrêt : panne systémique probable).

## Garde-fous intégrés (ne pas désactiver)

- **Rate limits** : la boucle détecte « session limit », parse l'heure de
  reset, dort jusque-là et reprend. C'est une attente, pas un contournement —
  les limites d'abonnement s'appliquent normalement.
- **`--disallowedTools`** : `git push`, `filter-repo`, `reset`, `rebase`,
  `rm`, `supabase *` sont bloqués mécaniquement, pas juste interdits en prose.
- **Parking** : une tâche qui échoue 2 fois est parkée sur `parked/<id>`
  (travail préservé), la ligne principale est nettoyée, la boucle continue.
  3 parkings consécutifs = arrêt complet.
- **NEVER lists** : chaque tâche porte sa liste. Si une étape semble exiger un
  item NEVER, l'agent écrit le blocage dans PROGRESS.md et s'arrête — il
  n'improvise pas autour.

## Conventions équipe

Communes à tous les projets :

- Boucle sur **worktree + branche dédiée**, jamais sur `main`.
- Journal de la boucle = `PROGRESS.md` (par branche). Au merge, reverser dans
  le journal du projet selon sa convention.
- Les fichiers de gouvernance du projet (journal, kanban, `CLAUDE.md`, version
  du `package.json`…) sont dans le NEVER de chaque tâche — à adapter par
  projet lors du triage.
- Les corrections de drift constatées au triage (doc source vs repo)
  s'appliquent au doc **au merge**, sinon le triage suivant les redécouvre.
- Le choix du mode appartient à celui qui triage : mode local tant que
  l'équipe du projet n'est pas onboardée (pas de pollution du tracker), mode
  issues (github/gitlab selon le remote) dès qu'elle l'est.

Spécifique Cookpit : agents interdits sur `KANBAN.md`, `LOG.md`, `CLAUDE.md` ;
premier projet validé (Phase 4, 26 tâches).

## Dépannage

| Symptôme | Cause probable | Action |
|---|---|---|
| Boucle arrêtée « consecutive failures » | Panne systémique (kernel cassé, tests down) | Lire les 3 dernières entrées de HUMAN-INBOX.md, corriger, relancer |
| Tâche parkée en boucle | Tâche mal dimensionnée | Ne pas insister : émettre une tâche recon à la place |
| « reset time unparseable » dans le log | Anthropic a changé le libellé du message de limite | Backoff 5 min prend le relais (bénin) ; mettre à jour la regex `seconds_until_reset` |
| `gh`/`glab not authenticated` au démarrage | CLI non connecté au bon compte/instance | Le runner **bascule seul en mode local** si `queue/` existe (avec avertissement : le tracker ne sera pas mis à jour ce run). Sinon : `gh auth login` / `glab auth login` (préciser l'instance self-hosted si besoin) |
| Issues émises mais runner ne voit rien | Labels absents ou mauvais repo courant | Vérifier `agent-auto` existe et que le cwd est le bon repo (`git remote -v`) |
| Gate vert mais travail douteux | Gate malhonnête | Reclasser `review`, noter dans Gate debt, durcir le gate |
| L'agent demande une confirmation et bloque | Prompt de tâche incomplet | La tâche doit être auto-suffisante ; compléter Context/Rules |

## Contenu du repo

```
skills/doc-triage/        # le compilateur document → queue (assess/grill/emit)
scripts/autorun-queue.sh  # la boucle : queue → commits, dort pendant les limites
scripts/check-ratchet.sh  # gate ratchet pour les métriques qui partent sales
```

Installation du skill sur un poste : `ln -s "$PWD/skills/doc-triage" ~/.claude/skills/doc-triage`
(symlink : un `git pull` du repo met le skill à jour, sans réinstallation).

## Crédits & lectures

Architecture : « Ralph loop » (Geoffrey Huntley — contexte frais par
itération, l'état dans les fichiers, boucle bash bête) ; grilling adversarial
et TDD-in-the-loop (Matt Pocock, aihero.dev) ; classes de risque, gates
honnêtes, ratchet et tâches recon : maison.
