---
name: coherence-da
description: Audit de cohérence de la DA d'AnhyWhere. À utiliser dès qu'une page « ne ressemble pas aux autres », avant une release, après une vague de migration, ou quand on demande un audit visuel/structurel multi-pages. Compare chaque page à la couche canonique du dépôt (tokens @theme, primitives ui/, anatomie Page, gardes) et rend la dérive en file:line classée par sévérité. Ne propose jamais une nouvelle DA — il mesure l'écart avec celle qui existe.
---

# Cohérence DA — audit de dérive

**Ce skill COMPARE. Il n'invente rien.** La DA d'AnhyWhere existe déjà et elle a une source
unique. Si une valeur manque, elle s'ajoute à `@theme`, pas dans ce fichier. Un skill qui
« propose une palette » est ici un bug : il créerait la seconde définition qu'on cherche à
supprimer.

## Étape 0 — la source de vérité (lecture seule)

| Quoi | Où |
|---|---|
| Tokens (couleurs, surfaces, rayons, opacités, échelle) | `web/src/index.css`, bloc `@theme` |
| Primitives + modules de classes | `web/src/components/ui/`, `*-classes.js` |
| Anatomie de page | `web/src/components/Page.jsx`, `docs/design/design-system/README.md` §4 |
| Exceptions déclarées | `web/src/pages/page-anatomy-exceptions.json` |
| Contrat des fenêtres | `docs/design/design-system/fenetres.md` |
| Règles mesurées | `UI-UX.md` |
| Galerie vivante | route interne `/design-system` (`web/src/pages/DesignSystem.jsx`) |
| Garde de dérive | `web/scripts/guard-ui.mjs` + `docs/design/ui-campaign/guards/baseline.json` |
| Checklist page | `web/AGENTS.md` § « Checklist — nouvelle page » |

Lire ces fichiers, **ne pas les recopier** dans un rapport : un rapport qui duplique les règles
devient une troisième définition, et c'est exactement la maladie qu'on soigne.

## Étape 1 — la mesure machine

```bash
node web/scripts/guard-ui.mjs --json     # 21 règles, count / baseline / delta / violations[file,line,snippet]
node web/scripts/guard-ui.mjs            # le même, lisible
node web/scripts/guard-page-anatomy.mjs  # Page utilisée ou exception déclarée
```

Trois lectures, dans cet ordre :

1. **`delta > 0`** → régression depuis la baseline. Bloquant, sans discussion.
2. **`delta < 0`** → la baseline est en retard sur le code. Ne PAS lancer `--baseline` : la baisse
   se constate en T3, et une hausse est refusée par `tests/guard/ui-baseline-ratchet.sh`.
3. **`count == baseline > 0`** → dette acceptée. Elle n'est pas un feu vert : c'est la liste des
   pages qui portent encore l'ancienne écriture. Chaque violation `file:line` est une page à
   migrer, pas un chiffre à ignorer.

`guard-ui` ne juge **que** ce qu'il sait compter. Il ne voit ni l'ordre des blocs, ni un état
manquant, ni deux pages sœurs construites différemment. D'où l'étape 2.

## Étape 2 — la dérive structurelle, page par page

Pour chaque page de `web/src/pages/` (hors `DesignSystem.jsx`) :

| Contrôle | Dérive |
|---|---|
| Anatomie | ni `Page`, ni exception motivée dans `page-anatomy-exceptions.json` → **bloquant** |
| En-tête | pas de `PageHeader` unique (titre, sous-titre utile, action principale unique) → haut |
| Conteneurs | `<div>` qui imite `Card`, table maison, encadré ad hoc → **bloquant** (règle `card-ad-hoc`, `table-fake`, `callout-raw`) |
| États | un seul état rendu : ni `Skeleton`, ni `EmptyState`, ni erreur → haut |
| Tokens | `#hex`, `rgb()`, `px` arbitraire, opacité littérale, classe inventée → **bloquant** |
| Échelle | `gap-0.5`, `gap-1.5`, `space-y-10`, rayon hors échelle → haut |
| Textes | clé absente d'un des deux dictionnaires `fr`/`en`, ou texte en dur → haut |
| Statut | une phrase là où un mot + couleur + icône suffisent ; une mesure sans son âge → haut |
| Fenêtre | zones hors contrat (contexte, corps, conséquence, actions) → haut |
| i18n/FR-EN | clé présente d'un seul côté → haut |

**La règle qui tranche les cas limites :** une exception déclarée avec `reason` + `wave` est une
décision ; une divergence non déclarée est une dérive. `reason` qui dit seulement « migration
vague N » = dette planifiée, pas conformité.

## Étape 3 — la dérive inter-pages (celle que la garde ne voit pas)

C'est la passe qui répond à « je peine à l'appliquer uniformément ». Elle se fait par **famille**,
pas page par page :

| Famille | Pages |
|---|---|
| Ressources (liste + détail) | `VMs`, `VMDetail`, `Networks`, `NetworkDetail`, `Projects`, `ProjectDetail`, `Templates` |
| Publication | `Publish`, `PublishDetail` |
| Compte et facturation | `Profile`, `Settings`, `Subscription`, `Payments`, `Activity` |
| Authentification | `Login`, `Login2FA`, `Signup`, `ForgotPassword`, `ResetPassword`, `VerifyEmail`, `Setup2FAModal` |
| Contenu éditorial | `Articles`, `Article`, `Help`, `HelpGuide`, `Vitrine` |
| Documents légaux | `Terms`, `DPA`, `MentionsLegales`, `PolitiqueConfidentialite`, `PolitiqueCookies` |
| Coque et surfaces propres | `Shell`, `Dashboard`, `Cartography`, `DesignSystem` |

Méthode, par famille : relever pour chaque page la **suite des blocs de premier niveau** et le
**choix de primitive** par bloc. Deux pages de la même famille doivent rendre la même suite, à
une exception motivée près. Toute divergence non motivée se cite en `file:line` avec la page
sœur qui fait foi (la plus proche de la galerie).

Contrôles transversaux :

- le même concept porte-t-il **un seul** nom visuel (un « état » = même `Badge`, même couleur,
  même mot) sur toutes les pages ?
- la même action a-t-elle le même bouton (variante `primary`, même libellé i18n) partout ?
- les états de chargement ont-ils la même forme (Skeleton de la même taille) sur les listes ?
- une classe apparaît-elle dans un module `*-classes.js` **et** réécrite à côté ?

## Étape 4 — mesurer le site publié, pas seulement le source

Une dérive de source qui ne se voit pas à l'écran n'est pas prioritaire ; une cohérence de source
qui casse à l'écran est pire. Sur `https://alpha.robinzmuda.fr` (jamais `127.0.0.1`) :

```bash
npx -y chrome-devtools-axi open https://alpha.robinzmuda.fr/<route>
npx -y chrome-devtools-axi resize 1920 1080
npx -y chrome-devtools-axi eval "JSON.stringify([...document.querySelectorAll('main section, main > *')].map(e=>{const r=e.getBoundingClientRect();return {tag:e.tagName,cls:e.className,y:Math.round(r.y),h:Math.round(r.height)}}))"
```

Comparer les **profils de hauteur** de deux pages de la même famille : deux pages sœurs qui ne
donnent pas la même séquence `y/h` ont une dérive de composition, même si leur JSX se ressemble.

## Étape 5 — le rapport

Format imposé, sinon le rapport n'est pas utilisable :

```text
Périmètre      : web/src/pages (N pages), web/src/components
Mesure source  : <sortie guard-ui : total, delta par règle, N pages hors anatomie>
Mesure publiée : <url, révision, 1920x1080>

# | Sévérité | Page | Dérive | Preuve (file:line) | Correction | Règle
--|----------|------|--------|--------------------|------------|------
1 | bloquant | X.jsx | <ce qui diverge> | x.jsx:42 | <primitive/token attendu> | README §2
```

Puis, et seulement ensuite :

- **3 à 5 corrections à fort effet** (une famille entière, pas une page) ;
- la liste des **exceptions non motivées** à déclarer ou à corriger ;
- **la dette acceptée**, chiffrée, avec son wave.

Ne pas mélanger dette acceptée et régression : la première est un plan, la seconde un incident.

## Ce que ce skill ne fait pas

- Il ne touche **jamais** `baseline.json`, une garde, ni un test. Un faux vert ici est une faute.
- Il ne crée pas de token, de primitive ni de page.
- Il ne « modernise » pas la DA : la DA est la décision, le skill est l'inspection.
- Il n'applique pas de correctif sans demande : il rend la liste, l'humain choisit le lot.

## État mesuré au 2026-10-24 (à re-mesurer, jamais à croire)

- `guard-ui` : **271 violations** sur 21 règles, 280 fichiers, **delta 0** partout sauf
  `gutter-offscale` (−4) et `card-prop-offstep` (−6) : dette en baisse, pas de régression.
- `guard-page-anatomy` : **35 exceptions / 36 pages**. 18 sont « migration vague N » (dette
  planifiée), 17 ont une raison structurelle (légal, auth, plein écran, galerie). Les 18 sont le
  vrai chantier d'uniformité.
- Plus gros postes : `button-raw` 27, `button-padding` 28, `card-prop-offstep` 141, `gutter-offscale` 41.
