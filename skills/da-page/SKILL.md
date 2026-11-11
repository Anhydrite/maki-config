---
name: da-page
description: Concevoir ou modifier une page d'AnhyWhere dans la DA existante, sans en inventer une. À utiliser pour créer une page, refondre un écran, ajouter une fenêtre modale ou un état (vide/chargement/erreur), et pour décider quelle primitive employer. Produit un brief fermé, un squelette avant pixels, la liste des primitives, puis la chaîne de preuves (test rouge d'abord, gardes, galerie, constat 1920x1080 sur le site publié).
---

# Concevoir une page dans la DA existante

**La DA est une décision déjà prise.** Ce skill ne cherche pas une direction : il choisit la page
existante la plus proche et il en hérite l'anatomie. Une page « originale » est ici un défaut.

## Étape 1 — le brief fermé (5 lignes, avant tout code)

```text
Route       : /<chemin>
Utilisateur : qui ouvre cette page, dans quel état d'esprit
Tâche       : la SEULE action principale (verbe + objet)
Données     : ce qui est lu, ce qui est écrit, ce qui peut manquer
États       : chargement / vide / erreur / succès — comment chacun se voit
```

S'il manque une ligne, la page n'est pas conçue : elle est devinée.

## Étape 2 — choisir la famille, puis la page souche

Ne jamais partir d'une page blanche. Trouver la famille (`coherence-da`, étape 3), ouvrir la page
la plus proche de la galerie, et **copier son anatomie** : ordre des blocs, choix de primitives,
place de l'action, forme des états.

| Besoin | Souche |
|---|---|
| Liste de ressources | `VMs.jsx`, `Networks.jsx`, `Projects.jsx` |
| Détail d'une ressource | `VMDetail.jsx`, `NetworkDetail.jsx`, `ProjectDetail.jsx` |
| Formulaire réglé par étapes | `Publish.jsx` |
| Compte / facturation | `Profile.jsx`, `Subscription.jsx` |
| Auth | `AuthLayout` (hors anatomie de page, exception déclarée) |
| Surface plein écran | `Dashboard.jsx`, `Cartography.jsx`, `Shell.jsx` (exception déclarée) |
| Galerie / référence de variante | `DesignSystem.jsx` |

Si la famille n'a pas de souche, c'est une **décision d'architecture** : s'arrêter, exposer les
deux ou trois options, attendre. Ne pas improviser un nouveau gabarit.

## Étape 3 — le squelette avant les pixels

Écrire l'arbre en texte, pas en JSX :

```text
Page
├─ PageHeader      (titre · sous-titre utile · action principale UNIQUE)
├─ Card            (bloc 1 : ce que l'utilisateur vient lire)
├─ Table | EmptyState
└─ Callout         (conséquence / mesure, seulement s'il y en a une)
```

Trois vérifications sur ce texte, avant d'écrire une ligne de JSX :

1. **la tâche principale** est atteignable en un clic depuis l'en-tête ;
2. **chaque bloc** a une primitive canonique (aucun `<div>` décoratif) ;
3. **un état explicite** est rendu — pas seulement le cas nominal.

Un bloc qui n'a pas de primitive est un signal : soit il n'est pas nécessaire, soit la primitive
manque et doit être **étendue dans `components/ui/` + la galerie**, jamais réécrite à côté.

## Étape 4 — les primitives (inventaire réel)

`Button` `Card` `Table` `Modal` `ConfirmDialog` `ConfirmBulkDeleteModal` `Callout` `Badge`
`EmptyState` `Skeleton` `FormInput` `FormSelect` `FormTextarea` `Checkbox` `NotificationDot`
`PageHeader` `ListFilter` `ResourceSlider` `InfoRow` `Toast` `BulkActionBar` `Terminal`
`SparklineChart` `TableRowActions` `MobileDataRow` `LanguageSwitcher` `Icons`

Règles d'emploi :

- une primitive porte **ses classes** dans son module `*-classes.js` ; le JSX ne fait que rendre ;
- une variante manquante s'ajoute à la primitive **et** à la galerie ;
- toute prop différente du défaut est un pas explicite et compté par la garde
  (`Card` : `radius=xs`, `pad=none`, `gap=none`, `border=all` par défaut).

## Étape 5 — tokens et échelle, sans exception

- Couleur, surface, rayon, opacité : **uniquement** les classes issues de `@theme`
  (`bg-bg-card`, `text-accent`, `rounded-card`, `/[var(--alpha-10)]`).
- Espacement sur **4 / 8 / 12 / 16 px** : `gap-1/2/3/4`. `gap-0.5`, `gap-1.5`, `space-y-10` sont
  hors échelle et bloquants.
- Un séparateur se pose **au milieu** de l'écart déjà déclaré (`outline-offset` = moitié
  négative), jamais en ajoutant une marge.
- Aucun `#hex`, `rgb()`, `px` arbitraire, `text-[13px]` inventé.

## Étape 6 — le contenu

- **Un statut est un mot**, la couleur porte le verdict, l'icône le confirme. Une mesure porte son
  âge (« Rien n'écoute, il y a 12 s »). L'explication va au guide, jamais dans la ligne d'état.
- **Un texte d'interface parle de ce que l'utilisateur peut faire**, jamais de la technique.
  Le test : « cette phrase aide-t-elle l'utilisateur à faire quelque chose ? » Sinon elle part.
- **i18n fr + en** : les deux dictionnaires, aucune chaîne en dur.
- Rien d'administration dans `web/src` : ça part dans le bundle public.

## Étape 7 — la chaîne de preuves (dans cet ordre)

1. **Test rouge d'abord** — `web/src/pages/__tests__/<Page>.test.jsx` : rendu, état vide,
   action principale, erreur. Il doit échouer avant le code.
2. `cd web && bun test src/pages/__tests__/<Page>.test.jsx --isolate --timeout 30000`
3. `node web/scripts/guard-ui.mjs --strict` → **0 dépassement** de baseline.
4. `node web/scripts/guard-page-anatomy.mjs` → `Page` utilisée, ou exception déclarée
   (`reason` + `wave`) dans `pages/page-anatomy-exceptions.json`.
5. Galerie : entrée dans `pages/DesignSystem.jsx` si la page introduit une variante.
6. Mobile 390 px et 1440 px : aucun débordement horizontal.
7. **Après déploiement uniquement**, constat visuel sur `https://alpha.robinzmuda.fr` :

```bash
npx -y chrome-devtools-axi open https://alpha.robinzmuda.fr/<route>
npx -y chrome-devtools-axi resize 1920 1080
npx -y chrome-devtools-axi eval "JSON.stringify([...document.querySelectorAll('<selecteur>')].map(e=>{const r=e.getBoundingClientRect();return {x:r.x,y:r.y,w:r.width,h:r.height,html:e.outerHTML}}))"
```

```text
Fenêtre      : 1920x1080
URL publiée  : https://alpha.robinzmuda.fr/<route>
Révision     : <sha publié>
Bloc         | avant (x, y, w, h)      | après (x, y, w, h)
HTML         | changements : <…> ; inchangé : <…>
```

`resize` **avant** la lecture. Une capture seule ne compare rien ; un test de composant ne voit
aucun pixel (happy-dom rend `getBoundingClientRect()` à zéro).

## Anti-patrons (chacun est une violation mesurée)

- `<button className="…">` stylé à la main au lieu de `Button` ;
- `<div>` qui imite `Card`, table maison, encadré ad hoc ;
- une page sans `PageHeader`, ou deux actions principales ;
- un écran qui ne montre que le cas nominal ;
- une classe du registre réécrite dans un composant au lieu d'être lue depuis son `*-classes.js` ;
- une valeur brute introduite « juste ici, c'est un cas particulier » ;
- une page recopiée depuis une autre puis modifiée : elle divergera au prochain lot.

## Quand s'arrêter

- **Architecture** : aucune souche dans la famille, ou deux gabarits valides → exposer et attendre.
- **Destructif** : suppression d'une page, d'un état ou d'une primitive → confirmer.
- **Hors périmètre** : un défaut découvert ailleurs devient une ligne `REQ-…` dans
  `docs/design/SUIVI.md`, il ne remplace pas la demande du lot.
