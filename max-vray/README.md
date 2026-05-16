# GS_Capture

> Générateur de dataset synthétique pour Gaussian Splatting / NeRF, à partir d'une scène 3ds Max + V-Ray.

Un script MaxScript autonome qui génère un ensemble d'images rendues avec V-Ray, accompagné soit d'un `transforms.json` (format Nerfstudio), soit d'un dossier `sparse/0/` (format COLMAP). Les poses caméra exactes sont exportées directement depuis Max, ce qui permet de **bypasser complètement COLMAP** lors de l'entraînement du splat.

Le dataset produit est compatible avec tout outil d'entraînement Gaussian Splatting : **Brush**, **LichtFeld Studio**, **Postshot**, **Nerfstudio** (Splatfacto / gsplat), etc.

---

## Sommaire

- [Prérequis](#prérequis)
- [Installation](#installation)
- [⚠️ Étape 0 — Vérifier les unités Max](#-étape-0--vérifier-les-unités-max)
- [⚠️ Settings V-Ray](#-settings-v-ray)
- [Utilisation rapide](#utilisation-rapide)
- [Comprendre les paramètres](#comprendre-les-paramètres)
- [Smart cubemap (multi-Z layers)](#smart-cubemap-multi-z-layers)
- [Workflow des boutons d'action](#workflow-des-boutons-daction)
- [Structure de sortie](#structure-de-sortie)
- [Export COLMAP (alternative à JSON)](#export-colmap-alternative-à-json)
- [Mode Spline (alternatif)](#mode-spline-alternatif)
- [Troubleshooting](#troubleshooting)
- [Limitations connues](#limitations-connues)

---

## Prérequis

- **3ds Max** 2022 ou plus récent (testé sur 2026)
- **V-Ray** 5+ (testé sur V-Ray 7 GPU CUDA / RTX)
- Aucune dépendance externe (pas de Python, pas de plugin)

---

## Installation

Le script est un seul fichier `GS_Capture.ms`.

**Lancement ponctuel** :
- Drag-and-drop `GS_Capture.ms` dans le viewport Max
- OU `Scripting → Run Script…` → choisir `GS_Capture.ms`

**Installation permanente** (script disponible à chaque démarrage de Max) :
- Copier `GS_Capture.ms` dans `C:\Program Files\Autodesk\3ds Max 2026\Scripts\Startup\`

La fenêtre du script est redimensionnable — tire un coin si elle dépasse de ton écran.

---

## ⚠️ Étape 0 — Vérifier les unités Max

**Critique.** Tous les champs numériques de l'UI (spacing, hauteur, jitter, distances murs, clip planes) sont exprimés en **scene units** — c-à-d ce que Max considère comme unité système.

Dans Max : **`Customize → Units Setup…`** → regarder le **"System Unit Scale"** (pas le "Display Unit Scale").

**Selon ton unité, convertis ainsi :**

| Unité système | 1m60 = | 100 cm = | 5 cm de jitter = |
|---|---|---|---|
| Centimeters (recommandé) | `160` | `100` | `5` |
| Millimeters | `1600` | `1000` | `50` |
| Meters | `1.6` | `1.0` | `0.05` |
| Inches | `63` | `39` | `2` |

⚠️ Les ranges par défaut des spinners sont calibrés pour **centimètres**. Si tu es en mm ou m, soit :
- Tu changes Max en cm (`Customize → Units → System Unit Scale = 1.0 cm`) — recommandé pour archviz
- Soit tu modifies les `range:[…]` dans la section UI du script

**Test rapide** : crée un objet de taille connue (ex. cube de 200 = porte) et lis sa dimension dans les Properties.

---

## ⚠️ Settings V-Ray

C'est **le point le plus important pour la qualité du splat final**. Sans ça, le splat sera flou ou plein d'artefacts.

Le Gaussian Splatting apprend à partir d'images **cohérentes entre elles**. Si V-Ray varie subtilement l'expo, la couleur ou le bruit entre deux frames, le modèle interprète cette variation comme de la géométrie qui bouge.

**À configurer dans `Render Setup` (F10) AVANT lancement :**

| Paramètre | Valeur | Pourquoi |
|---|---|---|
| Renderer | **V-Ray GPU** | Performance et cohérence |
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

Workflow recommandé : **Volume + Cubemap** (pour 90% des cas en archviz intérieur).

1. **Créer une Box volume** dans Max
   - X et Y couvrent le footprint à capturer
   - **Z définit la hauteur des caméras** (en mode Volume, le spinner "Eye height" est ignoré)
   - Pour 1m60 d'œil : Box centrée à Z=160 (en cm), ou bornes [150, 170] pour 1 layer, [130, 190] pour 2 layers
   - Rendre non-renderable : `Right-click → Object Properties → Renderable: OFF`

2. **Lancer le script** (drag-drop `GS_Capture.ms`)

3. Dans l'UI :
   - **Placement mode** : `Volume`
   - `Pick volume object` → sélectionner la Box
   - `Grid X` / `Grid Y` : 100 (en cm)
   - `Z layers` : 1
   - **Camera mode** : `Cubemap 6 views`
   - Garder les 6 faces cochées
   - **Lens** : 14 mm / 36 mm (= 104° HFOV)
   - `Avoid walls` activé, `Min distance = 30`

4. **Pick output folder** → dossier vide

5. `1) Generate Cameras` → vérifier visuellement dans le viewport

6. (optionnel) `Test render` pour valider qu'une image sort propre

7. `RUN ALL` — laisser tourner

8. Résultat : `dataset/images/*.png` + `transforms.json` prêts à l'emploi pour entraînement.

---

## Comprendre les paramètres

### Position jitter (units)

Décalage aléatoire ajouté à chaque station de caméra. Avec `5`, chaque station est déplacée d'une valeur random entre `-5` et `+5` unités en X et Y.

```
sans jitter (grille parfaite)        avec jitter 5 units

   •   •   •   •                     •   •  •    •

   •   •   •   •                    •    •   •  •

   •   •   •   •                     •  •    •   •
```

**Pourquoi** : une grille trop régulière produit des artefacts (bandes, moirés) sur les surfaces planes lors de l'entraînement GS. Le jitter rompt la régularité → reconstruction plus propre.

**Valeurs conseillées** : 5–15 (en cm). Ne pas dépasser 30% du grid spacing.

### Z layers

Nombre de niveaux verticaux de stations à l'intérieur du volume.

| Type de scène | Z layers | Notes |
|---|---|---|
| Shop simple, vue debout uniquement | **1** | Défaut, plus rapide |
| Showroom cuisine (plan travail + meubles hauts) | **2** | ex. 90 cm et 160 cm |
| Galerie avec plafond intéressant | **2** | ex. 160 cm et 220 cm |
| Espace haut, mezzanine | **3-4** | |
| Détail au sol important (lit, sofa, expo basse) | **2** | ex. 50 cm et 160 cm |

**Commence à 1**, regarde le résultat → augmente si sol/plafond mal reconstruits.

### Avoid walls + Min distance to walls

À chaque station candidate, le script lance 10 raycasts (6 directions cardinales + 4 diagonales horizontales). Si **n'importe quel** raycast tape de la géométrie à moins de `Min distance`, la station est éliminée.

**Pourquoi** : une caméra à 20 cm d'un mur ne voit qu'une texture floue → image inutile, temps de rendu gâché. Pire, une caméra à l'intérieur d'un mur ne voit rien.

**Effet visible** : l'estimation au bas de l'UI dit "(max)" — c'est le compte *avant* filtrage. Après filtrage, tu peux te retrouver avec significativement moins de stations. C'est normal et bénéfique.

Si trop agressif : descends `Min distance` de 30 à 20 ou 15. Trop laxiste : monte à 50.

### Focal (mm) — pourquoi 14 mm par défaut

Pour le **mode cubemap** (6 vues cardinales), le HFOV doit dépasser 90° sinon il y a des trous angulaires entre cubes adjacents :

| Focal (sensor 36mm) | HFOV | Effet sur le cubemap |
|---|---|---|
| 18 mm | 90° | ❌ Zéro overlap, mauvais pour GS |
| 16 mm | 96° | OK, peu d'overlap |
| **14 mm** | **104°** | ✅ **Sweet spot** : ~14° d'overlap par face |
| 12 mm | 112° | + d'overlap mais distorsion visible aux bords |
| 8 mm | 130° | Trop large, modèle pinhole imprécis |

**14 mm est le défaut conseillé**, garde-le sauf cas particulier.

### Cubemap faces

6 directions cardinales en world space (Z-up Max) : Front (+Y), Back (-Y), Left (-X), Right (+X), Up (+Z), Down (-Z).

- **Décocher Up** : gain ~17% temps si plafond uniforme
- **Décocher Down** : gain similaire si sol simple
- **Tout coché** : couverture max, défaut recommandé

### Smart cubemap

Checkbox dans le groupe 4A (activé par défaut). Quand `Z layers ≥ 2`, désactive automatiquement :
- La face **`down`** sur la **layer la plus basse** (le sol est déjà couvert par les layers du dessus, avec un meilleur angle)
- La face **`up`** sur la **layer la plus haute** (idem pour le plafond)

Économise ~10-17% de temps de rendu sans aucune perte de qualité géométrique pour les scènes archviz indoor standard. Voir la section dédiée plus bas.

### Mode Custom yaw + pitch

À utiliser **uniquement** dans 2 cas :
- Caméras à focale étroite (35 mm +) où le cubemap laisserait des trous
- Pattern d'angles non-standard

Avec `Yaw count = 8` et `Pitch list = "-15, 0, 15"` → 8 × 3 = 24 caméras par station (vs 6 en cubemap). 4× plus de rendu pour un résultat marginalement meilleur. **Pour archviz standard : ignore ce mode.**

---

## Workflow des boutons d'action

| Bouton | Action | Prérequis |
|---|---|---|
| **1) Generate Cameras** | Crée les caméras dans Max | — |
| **Preview cam 1** | Bascule le viewport sur la 1ère cam | Generate |
| **Delete cams** | Supprime toutes les cams générées | Generate |
| **Test render** | Rend 1 seule image avec VFB visible | Generate + output folder |
| **2) Render Dataset** | V-Ray rend toutes les cams en PNG | Generate + output folder |
| **3a) Export transforms.json** | Écrit le JSON Nerfstudio | Generate + output folder |
| **3b) Export COLMAP files** | Écrit `sparse/0/cameras.txt`, `images.txt`, `points3D.txt` | Generate + output folder |
| **RUN ALL** | Enchaîne 1 + 2 + 3a + 3b | — |

**Les exports JSON/COLMAP ne dépendent pas du render** — tu peux exporter immédiatement après Generate pour inspection, même si les images n'existent pas encore.

**Quel format choisir ?**
- **`transforms.json`** : format Nerfstudio. Lisible, plus moderne. Idéal pour Nerfstudio, Postshot.
- **`sparse/0/`** : format COLMAP. Plus universel, mieux supporté par Brush et LichtFeld Studio. Recommandé si tu utilises ces trainers (en particulier si Brush bloque sur le JSON — issue #269 connue).

Le RUN ALL exporte les deux par défaut. Tu choisis lequel utiliser au moment du training.

**Resume mode** (case cochée par défaut, groupe 6) : si tu Cancel à mi-chemin pendant le rendu, tu peux relancer `2) Render Dataset` plus tard — il skippe les frames déjà écrits sur disque et reprend où tu t'étais arrêté. Très utile pour les longs batches (ou en cas de crash Max).

⚠️ Pour que le Resume fonctionne, ne modifie pas les paramètres de placement (volume, grid, jitter) entre deux sessions, sinon les positions de cams changent et tu auras un dataset incohérent. Si tu changes le placement : vide le dossier `images/` et recommence.

**Phase test recommandée** :
```
1) Generate Cameras
→ Preview cam 1 (vérifier placement)
→ Test render (valider V-Ray)
→ ajuster settings si besoin
→ 2) Render Dataset
→ 3) Export transforms.json
```

**Phase production** (settings validés) : `RUN ALL` et laisser tourner.

---

## Structure de sortie

```
<outputFolder>/
├── images/
│   ├── 0001_back.png            ← format cubemap : <station_idx>_<face>.png
│   ├── 0001_front.png
│   ├── 0001_left.png
│   ├── 0001_right.png
│   ├── 0001_up.png              ← smart cubemap : pas de "_down" pour la layer basse
│   ├── 0002_back.png
│   ├── ...
│   ├── 0022_back.png
│   ├── 0022_down.png            ← layer mid : toutes les 6 faces
│   ├── 0022_front.png
│   ├── 0022_left.png
│   ├── 0022_right.png
│   ├── 0022_up.png
│   ├── ...
│   ├── 0043_back.png
│   ├── 0043_down.png
│   ├── 0043_front.png
│   ├── 0043_left.png
│   └── 0043_right.png           ← smart cubemap : pas de "_up" pour la layer haute
├── transforms.json              ← Nerfstudio (si 3a ou RUN ALL)
└── sparse/                      ← COLMAP (si 3b ou RUN ALL)
    └── 0/
        ├── cameras.txt          ← intrinsics (OPENCV model)
        ├── images.txt           ← extrinsics (quaternions + translations)
        └── points3D.txt         ← vide (init aléatoire par le trainer)
```

(En mode `Custom yaw+pitch`, les images sont nommées séquentiellement `00001.png`, `00002.png`, etc.)

Avec smart cubemap activé sur 3 Z layers : les stations 1..N₁ ont 5 faces (no down), les N₁+1..N₂ ont 6 faces, les N₂+1..N₃ ont 5 faces (no up). Les indices sont continus à travers les layers.

### Format de transforms.json

```json
{
  "camera_model": "OPENCV",
  "fl_x": 466.67,
  "fl_y": 466.67,
  "cx": 640.0,
  "cy": 360.0,
  "w": 1280,
  "h": 720,
  "k1": 0.0, "k2": 0.0, "p1": 0.0, "p2": 0.0,
  "frames": [
    {
      "file_path": "images/0001_front.png",
      "transform_matrix": [
        [r00, r01, r02, tx],
        [r10, r11, r12, ty],
        [r20, r21, r22, tz],
        [0,   0,   0,   1]
      ]
    }
  ]
}
```

**Conventions** :
- `transform_matrix` : matrice 4×4 camera-to-world en convention **OpenGL** (caméra regarde -Z local, +Y up, +X right)
- World coordinates : **Y-up** (converti depuis Max Z-up via une rotation -90° autour de X)
- `camera_model` : `OPENCV` avec distorsion à zéro (caméras synthétiques parfaites)
- `fl_x = (resW / sensor_mm) * focal_mm` en pixels

La conversion d'axes Max → Nerfstudio est appliquée automatiquement par le script — pas de manipulation à faire côté trainer.

**Auto-recenter** (v2.1+) : le centroïde des positions caméra est automatiquement remis à l'origine lors de l'export. Critique pour les scènes archviz importées de CAD (Revit, AutoCAD, Lambert) où les coordonnées peuvent être à des centaines de mètres de l'origine — les trainers GS échouent silencieusement à initialiser quand la scène est si loin de l'origine.

---

## Smart cubemap (multi-Z layers)

**Quand l'activer** : dès que tu utilises `Z layers ≥ 2`. Décoché par défaut sans effet, activé avec ≥ 2 layers tu économises automatiquement 10-17% du temps de rendu.

**Principe** :

| Layer | Faces gardées | Faces skippées | Justification |
|---|---|---|---|
| Plus basse | front, back, left, right, up | **down** | Le sol est mieux vu depuis la layer mid (angle plus rasant = plus d'info géométrique) |
| Intermédiaires | les 6 | aucune | Couverture complète |
| Plus haute | front, back, left, right, down | **up** | Idem inversé pour le plafond |

**Exemple concret** — pièce 5 × 8m, grid 60cm, 3 Z layers :

| Sans smart cubemap | Avec smart cubemap |
|---|---|
| 3 × 50 stations × 6 faces = **900 frames** | 50 × 5 + 50 × 6 + 50 × 5 = **800 frames** |
| ~15h de rendu (à 1 min/frame) | ~13h30 |

Tu gardes 100% de la qualité géométrique du splat tout en gagnant 1h30 de rendu sur cet exemple.

**Cas où désactiver** :
- Plafond très haut (> 3m) avec détails importants (suspensions, charpente, etc.) — la layer haute n'est pas assez proche du plafond, garde l'`up`
- Sol bas avec détails (tatami, expo basse) — la layer basse mérite son `down`

---

## Export COLMAP (alternative à JSON)

Bouton `3b) Export COLMAP files` dans la section Actions. Génère un dossier `sparse/0/` à côté du dossier `images/` avec 3 fichiers texte standard COLMAP.

**Pourquoi avoir les deux formats** :
- **Brush** (≤ v0.3) a une issue connue ([#269](https://github.com/ArthurBrussee/brush/issues/269)) qui plante sur certains transforms.json Nerfstudio. Le COLMAP passe systématiquement.
- **LichtFeld Studio** lit prioritairement le COLMAP.
- **Postshot / Nerfstudio** lisent les deux.

**Conventions appliquées** (vérifié à la main sur cubemap faces) :
1. Pose Nerfstudio (OpenGL : -Z forward, +Y up) convertie en convention COLMAP (OpenCV : +Z forward, -Y up) via flip Y et Z axes locales
2. World-to-camera matrix décomposée en quaternion `(qw, qx, qy, qz)` + translation `(tx, ty, tz)`
3. Auto-recenter appliqué (même centroïde que pour le JSON)
4. Intrinsics au format `OPENCV` avec distorsion à zéro

**Format dans `sparse/0/`** :

```
cameras.txt:
1 OPENCV <w> <h> <fl_x> <fl_y> <cx> <cy> 0.0 0.0 0.0 0.0

images.txt:
1 <qw> <qx> <qy> <qz> <tx> <ty> <tz> 1 0001_back.png

points3D.txt:
# vide — initialisation random par le trainer
```

**Utilisation côté trainer** : drag-drop le dossier parent (qui contient `images/` et `sparse/`). Brush et LichtFeld détectent automatiquement le format COLMAP grâce à la présence de `sparse/0/`.

---

## Mode Spline (alternatif)

Recommandé pour :
- Couloirs étroits où une grille pose trop de cams dans les murs
- Tu veux explicitement contrôler le parcours suivi
- Tu veux émuler une marche "naturelle"

**Procédure** :
1. Tracer une spline (`Shape → Line`) au niveau du sol, suivant le parcours désiré
2. Sélectionner la(s) spline(s)
3. `Pick selected splines`
4. Ajuster `Spline spacing` (distance entre stations le long de la spline) et `Eye height` (utilisé ici, contrairement au mode Volume)

Le mode `Cubemap` reste recommandé même en mode Spline. Les cams cardinales sont alignées sur le monde, pas sur la tangente de la spline.

Plusieurs splines peuvent être sélectionnées simultanément.

---

## Troubleshooting

| Symptôme | Cause probable | Fix |
|---|---|---|
| Erreur syntax au drag-drop | Caractères non-ASCII dans le path | Mettre le `.ms` dans un dossier sans accents |
| Spinners affichent 500 max alors qu'il faut 1600 | Tu es en millimeters, range pour cm | Change Max en cm OU modifie les `range:` dans le script |
| Estimation dit 168 cams mais j'en ai 72 | `Avoid walls` a filtré les stations trop proches | Normal — baisse `Min wall dist` pour récupérer |
| Beaucoup de cams dans des objets/meubles | `Avoid walls` désactivé ou min dist trop bas | Active + monte à 40-50 |
| Cams à hauteur 0 dans le viewport | Mode Volume mais Box mal placée en Z | Repositionne la Box à Z=160 (cm) |
| Le viewport ne montre rien de "GSCam_…" | Calque `GS_Capture_Cameras` masqué | Active le calque dans le Layer Manager |
| Le rendu plante / mémoire pleine | Trop de cams pour la mémoire V-Ray GPU | Réduire `Width`/`Height` ou nb de stations |
| Frames rendues en noir | Caméra à l'intérieur d'un mur (clip plane) | Active `Avoid walls` |
| Frames avec expo qui varie | V-Ray auto-exposure activé | Lock l'expo dans Render Setup |
| Bruit/grain différent entre frames | Denoiser actif ou noise threshold instable | Désactive le denoiser, fixe le noise threshold |

---

## Limitations connues

- **Pas de raycast "champ visuel"** entre stations : une station peut être validée (loin des murs) mais voir un mur à 50 cm dans sa vue cubemap → image avec 90 % de mur. Gérable manuellement en agrandissant la Box volume.
- **Mode Spline + Cubemap** : les caméras cubemap restent world-aligned (pas tangent-aligned). Voulu pour cohérence mais non configurable actuellement.
- **Resume mode est fragile** : les noms de fichiers doivent matcher exactement entre runs. Tout changement de paramètres de placement invalide les frames déjà rendus.
- **Pas de gestion des surfaces très réfléchissantes** : le GS échoue sur miroirs/chromes/aluminium poli (les reflets vues-dépendants violent les hypothèses du modèle). Utiliser un Material Override matte ou réduire la `glossiness` des matériaux concernés pour la passe GS.

---

## Crédits

Développé pour le pipeline interne **Aioli Collective**. Architecture spécifique aux scènes archviz intérieures (shops, galeries, showrooms).
