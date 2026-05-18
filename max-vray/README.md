# GS_Capture

> Générateur de dataset synthétique pour Gaussian Splatting, à partir d'une scène 3ds Max + V-Ray.

Un script MaxScript autonome qui rend les images avec V-Ray et exporte un dossier `sparse/0/` au format COLMAP. Les poses caméra exactes sont exportées directement depuis Max — **pas besoin de COLMAP / SfM** côté trainer.

Compatible **LichtFeld Studio** (cible principale) et **Brush**.

---

## Sommaire

- [Prérequis](#prérequis)
- [Installation](#installation)
- [Étape 0 — Unités Max](#étape-0--unités-max)
- [Settings V-Ray](#settings-v-ray)
- [Utilisation rapide](#utilisation-rapide)
- [Paramètres clés](#paramètres-clés)
- [Smart cubemap](#smart-cubemap)
- [Workflow des boutons](#workflow-des-boutons)
- [Structure de sortie](#structure-de-sortie)
- [Convention de coordonnées](#convention-de-coordonnées)
- [Mode Spline](#mode-spline)
- [Troubleshooting](#troubleshooting)
- [Limitations connues](#limitations-connues)

---

## Prérequis

- **3ds Max** 2022 ou plus récent (testé sur 2026)
- **V-Ray** 5+ (testé sur V-Ray 7 GPU CUDA / RTX)
- Aucune dépendance externe (pas de Python, pas de plugin)

---

## Installation

**Lancement ponctuel** : drag-drop `GS_Capture.ms` dans le viewport Max.

**Installation permanente** : copier le fichier dans `C:\Program Files\Autodesk\3ds Max 2026\Scripts\Startup\`.

---

## Étape 0 — Unités Max

Tous les champs numériques de l'UI (spacing, jitter, distances murs, clip) sont exprimés en **unités système Max** (`Customize → Units Setup → System Unit Scale`).

Les ranges par défaut des spinners sont calibrés pour **centimètres**. Si tu travailles dans une autre unité, soit tu passes Max en cm, soit tu adaptes les `range:[…]` dans la section UI du script.

---

## Settings V-Ray

C'est **le point le plus important pour la qualité du splat final**. Le Gaussian Splatting apprend à partir d'images cohérentes entre elles — toute variation d'expo, de couleur ou de bruit entre frames sera interprétée comme de la géométrie qui bouge.

À configurer dans `Render Setup` (F10) **avant** lancement :

| Paramètre | Valeur | Pourquoi |
|---|---|---|
| Renderer | **V-Ray GPU** | Performance |
| Engine | CUDA ou **RTX** | Plus rapide sur RTX 20+ |
| Image Sampler → Type | **Progressive** | Cohérent entre frames |
| Image Sampler → Noise threshold | **0.01 – 0.02** | Ratio temps/qualité |
| Image Sampler → Time limit | **60 – 120 s** | Selon complexité |
| Image Sampler → Min subdivs | 1 | Cohérence inter-frame |
| Denoiser (VRay/NVIDIA/Intel) | **OFF** | Cause n°1 de flou GS |
| Camera → Auto exposure | **OFF / Locked** | Évite le flicker |
| Camera → Color mapping | sRGB ou Linear (cohérent) | |
| Output → DOF | **OFF** | Conflits reconstruction |
| Output → Motion blur | **OFF** | Idem |
| Output → File format | PNG (ou EXR linear si HDR) | |

**Tip expo** : fais 1 rendu test, ajuste l'expo V-Ray à la main pour ni cramer ni boucher, **lock cette valeur**, puis lance le batch.

---

## Utilisation rapide

Workflow recommandé : **Volume + Cubemap** (90% des cas en archviz intérieur).

1. **Créer une Box volume** dans Max
   - X et Y couvrent le footprint à capturer
   - Z définit la hauteur des caméras (l'`Eye height` est ignoré en mode Volume)
   - Rendre non-renderable : `Right-click → Object Properties → Renderable: OFF`

2. **Drag-drop `GS_Capture.ms`** dans Max.

3. Dans l'UI :
   - **Placement mode** : `Volume`
   - `Pick volume object` → sélectionner la Box
   - `Grid X` / `Grid Y` : 100
   - `Z layers` : 1 (ou 2-3 selon scène — voir plus bas)
   - **Camera mode** : `Cubemap 6 views`
   - **Lens** : 14 mm / 36 mm
   - `Avoid walls` activé, `Min distance = 30`

4. **Pick output folder** → dossier vide.

5. `1) Generate Cameras` → vérifier visuellement dans le viewport.

6. (optionnel) `Test render` pour valider qu'une image sort propre.

7. `RUN ALL` → laisser tourner.

8. Résultat : `<outputFolder>/images/` + `<outputFolder>/sparse/0/` prêts à drop dans LichtFeld ou Brush.

---

## Paramètres clés

### Position jitter

Décalage aléatoire ajouté à chaque station. Rompt la régularité de la grille pour éviter les bandes/moirés sur surfaces planes lors de l'entraînement.

**Valeurs conseillées** : 5–15. Ne pas dépasser 30% du grid spacing.

### Z layers

Nombre de niveaux verticaux de stations à l'intérieur du volume.

| Type de scène | Z layers |
|---|---|
| Vue debout uniquement | **1** |
| Showroom (plan de travail + meubles hauts) | **2** |
| Galerie avec plafond intéressant | **2** |
| Espace haut, mezzanine | **3-4** |
| Détail au sol (lit, sofa, expo basse) | **2** |

**Commence à 1**, augmente si sol/plafond mal reconstruits.

### Avoid walls + Min distance

À chaque station candidate, 10 raycasts sont lancés (6 cardinaux + 4 diagonaux). Si l'un d'eux tape une géométrie sous `Min distance`, la station est éliminée.

Évite : caméra collée à un mur (image floue inutile) ou à l'intérieur d'un meuble.

Si trop agressif : descends `Min distance` de 30 à 20 ou 15. Trop laxiste : monte à 50.

### Focal — pourquoi 14 mm par défaut

Pour le mode cubemap, le HFOV doit dépasser 90° sinon il y a des trous angulaires entre faces adjacentes :

| Focal (sensor 36mm) | HFOV | Note |
|---|---|---|
| 18 mm | 90° | ❌ Zéro overlap |
| 16 mm | 96° | OK, peu d'overlap |
| **14 mm** | **104°** | ✅ Sweet spot : ~14° d'overlap |
| 12 mm | 112° | + d'overlap, distorsion visible aux bords |
| 8 mm | 130° | Trop large, modèle pinhole imprécis |

### Mode Custom yaw + pitch

À utiliser **uniquement** dans 2 cas :
- Caméras à focale étroite (35 mm+) où le cubemap laisserait des trous
- Pattern d'angles non-standard

Avec `Yaw count = 8` et `Pitch list = "-15, 0, 15"` → 24 cams/station (vs 6 en cubemap). 4× plus de rendu pour un résultat marginalement meilleur. **Pour archviz standard : ignore ce mode.**

---

## Smart cubemap

Checkbox activée par défaut. Quand `Z layers ≥ 2`, désactive automatiquement :
- La face **`down`** sur la **layer la plus basse** (le sol est mieux vu depuis la layer du dessus)
- La face **`up`** sur la **layer la plus haute** (idem pour le plafond)

Économise 10-17% du temps de rendu sans perte de qualité géométrique.

**Cas où désactiver** :
- Plafond très haut (> 3 m) avec détails (suspensions, charpente) — garde l'`up`
- Sol avec détails au ras (tatami, expo basse) — garde le `down`

---

## Workflow des boutons

| Bouton | Action |
|---|---|
| **1) Generate Cameras** | Crée les caméras dans Max |
| **Preview cam 1** | Bascule le viewport sur la 1ère cam |
| **Delete cams** | Supprime toutes les cams générées |
| **Test render** | Rend 1 seule image avec VFB visible |
| **2) Render Dataset** | V-Ray rend toutes les cams en PNG |
| **3) Export COLMAP files** | Écrit `sparse/0/cameras.txt`, `images.txt`, `points3D.txt` |
| **RUN ALL** | Enchaîne 1 + 2 + 3 |

L'export COLMAP ne dépend pas du render — tu peux exporter immédiatement après Generate pour inspection.

**Resume mode** (checkbox du groupe 6) : permet de relancer `2) Render Dataset` après un Cancel/crash — le script saute les frames déjà sur disque. Ne modifie pas les paramètres de placement entre deux sessions, sinon les positions changent et le dataset devient incohérent.

**Phase test recommandée** :
```
1) Generate Cameras
→ Preview cam 1 (placement OK ?)
→ Test render (V-Ray OK ?)
→ ajuster settings
→ 2) Render Dataset
→ 3) Export COLMAP files
```

**Phase production** (settings validés) : `RUN ALL`.

---

## Structure de sortie

```
<outputFolder>/
├── images/
│   ├── 0001_back.png        ← format cubemap : <station>_<face>.png
│   ├── 0001_front.png
│   ├── 0001_left.png
│   ├── 0001_right.png
│   ├── 0001_up.png          ← smart cubemap : pas de "_down" sur la layer basse
│   ├── 0002_back.png
│   ├── ...
│   └── 0043_right.png       ← smart cubemap : pas de "_up" sur la layer haute
└── sparse/
    └── 0/
        ├── cameras.txt      ← intrinsics (OPENCV model)
        ├── images.txt       ← extrinsics (quaternions + translations)
        └── points3D.txt     ← 50 000 points d'init random
```

En mode `Custom yaw+pitch`, les images sont nommées séquentiellement `00001.png`, `00002.png`, etc.

---

## Convention de coordonnées

L'export est en **convention COLMAP / Y-down** (native LichtFeld) :
- World : X right, **Y down**, Z forward
- Camera : OpenCV (+X right, -Y up, +Z forward)
- Intrinsics : modèle `OPENCV` avec distorsion à zéro (caméras synthétiques parfaites)
- `fl_x = (resW / sensor_mm) * focal_mm` en pixels

La conversion d'axes Max (Z-up) → COLMAP (Y-down) est faite automatiquement par le script.

**Auto-recenter** : le centroïde des positions caméra sur les axes **horizontaux** (X et Y Max) est ramené à l'origine. L'axe **vertical** (Z Max) est **préservé** — le sol Max à Z=0 reste au sol dans LichtFeld (Y=0 en COLMAP).

Critique pour les scènes archviz importées de CAD (Revit, AutoCAD, Lambert) où les coordonnées peuvent être à des centaines de mètres de l'origine. Les trainers GS échouent silencieusement à initialiser dans ces cas.

**Points3D init** : 50 000 points aléatoires sont générés dans un cube de ±1.5× l'étendue des caméras recentrées. LichtFeld refuse les datasets avec `points3D.txt` vide ; ces points servent de seed initial pour les Gaussiennes (le trainer prune les inutiles dès les premières epochs).

> **Note Brush** : Brush attend une convention world Y-up. Avec l'export Y-down de v2.2, **le splat apparaîtra à l'envers verticalement dans Brush** — orbiter la caméra dans le viewer pour compenser, ou rouvrir le `.ply` dans SuperSplat et inverser l'axe Y.

---

## Mode Spline

Recommandé pour :
- Couloirs étroits où une grille pose trop de cams dans les murs
- Contrôle explicite du parcours
- Émulation d'une marche "naturelle"

**Procédure** :
1. Tracer une spline (`Shape → Line`) au niveau du sol, suivant le parcours désiré
2. Sélectionner la(s) spline(s)
3. `Pick selected splines`
4. Ajuster `Spline spacing` et `Eye height` (utilisé ici, contrairement au mode Volume)

Le mode `Cubemap` reste recommandé même en mode Spline. Les cams cardinales sont alignées sur le monde, pas sur la tangente de la spline.

Plusieurs splines peuvent être sélectionnées simultanément.

---

## Troubleshooting

| Symptôme | Cause probable | Fix |
|---|---|---|
| Erreur syntax au drag-drop | Caractères non-ASCII dans le path | Mettre le `.ms` dans un dossier sans accents |
| Ranges des spinners inadaptés | Unité Max ≠ centimètres | Change Max en cm ou modifie les `range:` dans le script |
| Estimation dit 168 cams mais j'en ai 72 | `Avoid walls` a filtré | Normal — baisse `Min wall dist` pour récupérer |
| Beaucoup de cams dans des meubles | `Avoid walls` désactivé ou min dist trop bas | Active + monte à 40-50 |
| Cams à hauteur 0 dans le viewport | Mode Volume, Box mal placée en Z | Repositionne la Box en hauteur |
| Le viewport ne montre rien | Calque `GS_Capture_Cameras` masqué | Active le calque dans le Layer Manager |
| Rendu plante / mémoire pleine | Trop de cams pour la VRAM V-Ray GPU | Réduire `Width`/`Height` ou nb stations |
| Frames rendues en noir | Caméra à l'intérieur d'un mur (clip plane) | Active `Avoid walls` |
| Frames avec expo qui varie | V-Ray auto-exposure activé | Lock l'expo dans Render Setup |
| Bruit/grain différent entre frames | Denoiser actif | Désactive le denoiser, fixe le noise threshold |
| LichtFeld refuse de charger | `points3D.txt` vide ou dossier mal structuré | v2.2 génère 50k points auto — sinon re-export |
| Splat à l'envers dans LichtFeld | Export < v2.2 (Y-up) | Re-export avec v2.2 |
| Splat à l'envers dans Brush | Normal (Brush = Y-up, export = Y-down) | Orbite la caméra dans le viewer |

---

## Limitations connues

- **Pas de raycast "champ visuel"** entre stations : une station validée (loin des murs) peut voir un mur à 50 cm dans sa vue cubemap → image avec 90% de mur. Gérable en agrandissant la Box volume.
- **Mode Spline + Cubemap** : les caméras cubemap restent world-aligned, pas tangent-aligned.
- **Resume mode fragile** : tout changement de paramètres de placement entre deux sessions invalide les frames déjà rendus.
- **Surfaces très réfléchissantes** : le GS échoue sur miroirs/chromes/aluminium poli (les reflets vue-dépendants violent les hypothèses du modèle). Utiliser un Material Override matte ou réduire la `glossiness` pour la passe GS.
- **Brush Y-up vs export Y-down** : voir note dans [Convention de coordonnées](#convention-de-coordonnées). Sera réglé par un toggle UI si besoin.

---

## Crédits

Développé pour le pipeline interne **Aioli Collective**. Architecture spécifique aux scènes archviz intérieures (shops, galeries, showrooms).
