# agent-workflow

Transformer un document de planification en tâches, et laisser un agent les
coder tout seul — la nuit, pendant que tu dors.

## 4 commandes, c'est tout

```bash
agent run          # lance la boucle
agent status       # où j'en suis + quoi faire maintenant   ← EN CAS DE DOUTE : ÇA
agent logs         # regarder l'agent travailler en direct
agent retry <id>   # relancer une tâche en échec
agent finish       # vérifier + merger quand c'est fini
```

`agent status` répond toujours à « et maintenant ? ». Tu n'as pas besoin de
connaître les fichiers internes.

## Installation (une fois par poste)

```bash
git clone <remote>/agent-workflow ~/tools/agent-workflow
ln -s ~/tools/agent-workflow/skills/doc-triage ~/.claude/skills/doc-triage
echo 'export PATH="$HOME/tools/agent-workflow/scripts:$PATH"' >> ~/.zshrc && source ~/.zshrc
# macOS : brew install coreutils jq
```

## Utilisation

```bash
# 1. Un worktree dédié (jamais sur main)
cd ~/devlab/monprojet
git worktree add ../monprojet-agent -b agent/ma-tranche
cd ../monprojet-agent

# 2. Trier UNE tranche du document (une phase, pas tout le doc)
claude
> Trie la Phase 4 de docs/ROADMAP.md avec doc-triage pour la boucle autonome.
#   → il t'interroge (~30 questions), c'est l'étape qui compte
#   → il produit queue/ + PLAN-SUMMARY.md

# 3. Relire PLAN-SUMMARY.md (~10 min) — sections Gate debt et Doc drift

# 4. Lancer, et aller dormir
agent run

# 5. Le matin
agent status       # il te dit exactement quoi faire
agent finish       # quand tout est vert
```

## Quand ça se passe mal

| Situation | Quoi faire |
|---|---|
| Je ne sais pas où j'en suis | `agent status` |
| Une tâche a échoué | `agent status` te donne la raison. Corrige le fichier de la tâche dans `queue/`, puis `agent retry <id>` |
| Je veux voir ce qu'il fait | `agent logs` |
| Rien ne s'affiche depuis 20 min | Normal : une tâche prend 10-30 min. `agent logs` pour vérifier qu'il bosse |
| Il dort | Normal : limite d'usage atteinte, il reprend tout seul au reset |
| Il s'est arrêté seul | 3 échecs de suite = panne systémique. `agent status`, corrige, `agent run` |
| Le travail d'une tâche ratée | Préservé sur la branche `parked/<id>` |
| Une tâche ne doit PAS tourner | Passe `risk: auto` → `owner` dans **le fichier de la tâche** (pas dans PLAN-SUMMARY) |

## Ce que l'agent ne fera JAMAIS tout seul

Deploys, suppressions de fichiers, réécriture d'historique git, migrations en
prod, secrets. Ces tâches sont classées `owner` au triage et t'attendent dans
`HUMAN-INBOX.md` — `agent status` te les compte.

---

# Annexe — pour comprendre le pourquoi

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

## Par système d'exploitation

Un seul runner bash pour tous les OS — pas de double implémentation à maintenir.

**Linux / serveur (recommandé pour les runs longs)** — tout est natif :

```bash
tmux new -s agent
QUEUE_MODE=local MODEL=sonnet BUDGET_TOTAL=15.00 \
  ~/tools/agent-workflow/scripts/autorun-queue.sh
```

**macOS** — le runner se relance tout seul sous `caffeinate` (le Mac ne dort
pas pendant le run ; garder le capot OUVERT et le secteur branché) :

```bash
# recommandé une fois : parsing exact des resets + timeout des agents bloqués
brew install coreutils jq

# lancement simple (laisser l'onglet ouvert) :
~/tools/agent-workflow/scripts/autorun-queue.sh
# ou détaché (onglet fermable) :
nohup ~/tools/agent-workflow/scripts/autorun-queue.sh > run.out 2>&1 &
tail -f .autorun/queue.log
```

Sans coreutils, le runner fonctionne en mode dégradé (annoncé au démarrage) :
attente forfaitaire de 5 min au lieu de l'heure exacte de reset, pas de kill
des agents bloqués. Sans jq : suivi des coûts désactivé (mode local seulement).

**Windows** — via Git Bash (déjà requis par Claude Code sur Windows) :

```bat
cd \chemin\du\worktree
set QUEUE_MODE=local
set BUDGET_TOTAL=15.00
\chemin\agent-workflow\scripts\autorun-queue.cmd
```

Le `.cmd` est un simple wrapper qui lance le script bash dans Git Bash.
Alternative pour les runs de plusieurs jours : WSL, qui se comporte comme le
cas Linux. Dans tous les cas Windows : désactiver la mise en veille pendant
le run (Paramètres → Alimentation).

## Conventions équipe

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

## Crédits & lectures

Architecture : « Ralph loop » (Geoffrey Huntley — contexte frais par
itération, l'état dans les fichiers, boucle bash bête) ; grilling adversarial
et TDD-in-the-loop (Matt Pocock, aihero.dev) ; classes de risque, gates
honnêtes, ratchet et tâches recon : maison.
