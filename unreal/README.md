# Unreal Engine — `gs_capture.py`

> Port Python du script MaxScript `GS_Capture.ms`, pour Unreal Engine 5+.
> **v0.1.1** : génération de caméras (volume + cubemap), export COLMAP, rendu Lumen-aware.

Le rendu se fait via HighResShot (Lumen ou Path Tracer en view mode du viewport), ou via Movie Render Queue pour le contrôle fin.

## Pré-requis

- **Unreal Engine 5.3+** (testé en cible : 5.4, 5.5, 5.6)
- Plugin **Python Editor Script** activé (`Edit → Plugins → "Python Editor Script Plugin"`, redémarrer l'éditeur)
- Pour Lumen : `Project Settings → Engine → Rendering` :
  - **Global Illumination** = Lumen
  - **Reflections** = Lumen
  - Software Lumen suffit, Hardware Ray Tracing si tu veux pousser la qualité
- Pour Path Tracer (optionnel) : Hardware Ray Tracing obligatoire

NumPy est requis. Il est bundlé avec la distribution Python d'Unreal depuis 5.0 — si l'import échoue (rare), installer via :
```
<UE_install>/Engine/Binaries/ThirdParty/Python3/Win64/python.exe -m pip install --user numpy
```

## Installation

1. Cloner ou télécharger ce repo
2. Copier `gs_capture.py` et `run_example.py` dans `<YourProject>/Content/Python/`
3. Lancer l'éditeur sur ton projet

Le dossier `Content/Python/` est automatiquement ajouté au `sys.path` d'Unreal, donc `import gs_capture` fonctionnera sans configuration supplémentaire.

## Workflow

### 1. Placer le volume de capture

Ajouter une **TriggerBox** (ou n'importe quel acteur dont la bounding box couvre la zone à capturer) :

- `Place Actors → Volumes → TriggerBox`
- Positionner et scaler pour englober la zone d'intérêt
- Le volume n'a pas besoin d'être visible au rendu — il sert uniquement à délimiter la grille de caméras

> ⚠️ La AABB world-aligned du volume est utilisée. Évite de pivoter le volume — préfère un cube non-rotaté que tu redimensionnes sur les 3 axes.

### 2. Générer les caméras + export COLMAP

- Sélectionner le volume dans l'Outliner
- Éditer `run_example.py` (au minimum `OUTPUT_FOLDER`)
- Dans la fenêtre **Output Log** d'Unreal, basculer le menu déroulant **Cmd** sur **Python**
- Taper : `py run_example.py`

Le script va :
1. Supprimer les caméras existantes dans le dossier `GS_Capture_Cameras` de l'Outliner
2. Générer la nouvelle grille de caméras (cubemap 6 faces par station)
3. Skipper les stations trop proches d'un mur (raycast)
4. Écrire les fichiers COLMAP dans `<OUTPUT_FOLDER>/sparse/0/`

Tu peux aussi piloter le script ligne par ligne dans le REPL :
```python
import gs_capture
params = gs_capture.GSCaptureParams(
    grid_x=150, grid_y=150, z_layer_count=2,
    output_folder=r"D:/datasets/my_scene",
)
cams = gs_capture.generate_cameras(params)   # spawn cameras
gs_capture.export_colmap_files(params, cams) # write sparse/0/
```

### 3. Rendre les images

**Voie principale recommandée pour v0.1 : Lumen via HighResShot.**

#### Option A — Lumen + HighResShot (recommandé)

C'est la vraie force d'Unreal : GI temps réel + reflections Lumen, sans étape d'attente comme le Path Tracer.

1. Vérifier dans `Project Settings → Engine → Rendering` : Global Illumination = **Lumen**, Reflections = **Lumen**
2. Régler le viewport en view mode **Lit** (raccourci `Alt+4`, ou Viewport menu → View Mode → Lit) — c'est le défaut
3. Pour la qualité max : `Settings → Engine Scalability Settings → Cinematic`
4. Dans le REPL Python :
   ```python
   gs_capture.render_batch_screenshots(params)
   ```

Le script va :
1. Bumper `r.HighResScreenshotDelay` à 60 frames (≈1s à 60fps) pour que Lumen ait le temps de converger entre 2 caméras
2. Itérer les caméras une par une et écrire `<OUTPUT_FOLDER>/images/0001_front.png`, etc.

Si tu vois des frames sombres ou bruitées au début après un changement de caméra (gros niveau ou GPU lent) :
```python
gs_capture.setup_for_lumen_capture(warmup_frames=120)  # ~2s à 60fps
gs_capture.render_batch_screenshots(params, lumen_warmup_frames=0)  # skip re-bump
```

#### Option B — Path Tracer via HighResShot

Pour la qualité offline (caustiques, réflexions parfaites, GI ground-truth) :

1. Activer Hardware Ray Tracing dans `Project Settings → Engine → Rendering`
2. Basculer le viewport en **Path Tracing** (Viewport menu → View Mode → Path Tracing)
3. Attendre que le viewport converge sur la première vue (qq secondes)
4. Lancer avec un warmup généreux :
   ```python
   gs_capture.render_batch_screenshots(params, lumen_warmup_frames=0)
   ```
   (`lumen_warmup_frames=0` car le Path Tracer gère sa convergence différemment ; tu peux quand même bumper manuellement `r.HighResScreenshotDelay 200` si besoin de plus de samples par shot)

Le Path Tracer est plus lent (~10× Lumen) mais le résultat est ground-truth pour la quasi-totalité des matériaux.

#### Option C — Movie Render Queue (contrôle fin, optionnel)

Pour les renders de production avec config Path Tracer cinématique :

1. Créer un Level Sequence
2. Ajouter une **Camera Cuts** track
3. Pour chaque caméra dans le dossier `GS_Capture_Cameras` (Outliner) : ajouter un cut de 1 frame
4. Dans MRQ :
   - Output filename pattern : `{camera_name}`
   - Output directory : `<OUTPUT_FOLDER>/images/`
   - Render Pass : **Path Tracer**
   - SPP : 64 minimum (128+ recommandé pour archviz), AA activé
5. Lancer

Les fichiers sortiront nommés `GSCam_0001_front.png`, etc. (parce que `{camera_name}` retourne le label complet de l'acteur). **L'export COLMAP de v0.1 référence les fichiers sans le préfixe** (`0001_front.png`). Donc deux options :
- Renommer les fichiers de sortie pour supprimer le préfixe `GSCam_`
- Ou éditer `sparse/0/images.txt` avec un search/replace `GSCam_` → ``

Une option `keep_camera_prefix` arrivera en v0.2 pour automatiser ça.

### 4. Lancer l'entraînement

Une fois `<OUTPUT_FOLDER>` qui contient :
```
<OUTPUT_FOLDER>/
├── images/
│   ├── 0001_front.png
│   ├── 0001_back.png
│   └── ...
└── sparse/0/
    ├── cameras.txt
    ├── images.txt
    └── points3D.txt
```

Drop le dossier dans LichtFeld Studio ou Brush — même workflow que pour les datasets Max+V-Ray.

## Référence des paramètres

Identiques à la version Max sauf pour les unités (toujours **cm** en Unreal, là où Max dépend de l'unité système).

| Paramètre | Défaut | Notes |
|---|---:|---|
| `grid_x`, `grid_y` | 100 | cm, espacement horizontal de la grille |
| `z_layer_count` | 1 | nombre de couches verticales dans le volume |
| `jitter_pos` | 5 | cm, jitter XY par station |
| `avoid_walls` | True | active le raycast de validation |
| `min_wall_dist` | 30 | cm, distance min aux obstacles |
| `cube_faces` | [T]×6 | F/B/L/R/U/D (front, back, left, right, up, down) |
| `smart_cubemap` | True | skip down/up sur layers extrêmes |
| `focal_mm` | 14 | mm, focale (14 mm sur 36 mm = ~104° HFOV) |
| `sensor_mm` | 36 | mm, largeur capteur |
| `near_clip` | 1 | cm |
| `far_clip` | 50000 | cm (500 m) |
| `res_w`, `res_h` | 1280×720 | px |
| `output_folder` | "" | chemin absolu, créé s'il n'existe pas |

Paramètres de la fonction `render_batch_screenshots(params, cameras=None, lumen_warmup_frames=60)` :

| Paramètre | Défaut | Notes |
|---|---:|---|
| `lumen_warmup_frames` | 60 | bumpe `r.HighResScreenshotDelay`. Mettre à 0 pour skip (Path Tracer ou config custom) |

## Convention de coordonnées

Output identique au format COLMAP Y-down de la version Max v2.2 (donc LichtFeld-natif, splat à l'endroit) :

- **Unreal world** : +X forward, +Y right, +Z up, **gauche-main** (LH)
- **Unreal cam local** : +X = direction de visée
- **COLMAP world** : +X right, +Y down, +Z forward, **droite-main** (RH)
- **OpenCV cam local** : +X right, +Y down, +Z forward

La conversion d'axes est :
```
CM +X (right) =  UE +Y
CM +Y (down)  = -UE +Z
CM +Z (fwd)   =  UE +X
```

Cette matrice a `det = -1` (LH → RH flipe la chiralité). Combinée à la conversion cam-UE → cam-OpenCV (aussi `det = -1`), la matrice c2w finale est une rotation propre (`det = +1`).

**Auto-recenter** : centroïde des positions caméra sur les axes **horizontaux uniquement** (X et Z dans le repère COLMAP, qui correspondent à Y et X dans le repère UE) ramené à l'origine. L'axe vertical (Y COLMAP = -Z UE) est préservé — le sol UE (Z=0) reste à Y=0 dans le splat LichtFeld.

**points3D init** : 50 000 points aléatoires dans un cube de ±1.5× l'étendue des caméras recentrées (LichtFeld refuse les datasets avec `points3D.txt` vide).

## Structure de sortie

```
<output_folder>/
├── images/
│   ├── 0001_front.png      # cubemap : <station4>_<face>.<ext>
│   ├── 0001_back.png
│   ├── 0001_left.png
│   ├── 0001_right.png
│   ├── 0001_up.png         # absent si smart_cubemap + layer haute
│   ├── 0001_down.png       # absent si smart_cubemap + layer basse
│   ├── 0002_back.png
│   └── ...
└── sparse/0/
    ├── cameras.txt          # OPENCV intrinsics, distorsion zéro
    ├── images.txt           # extrinsics quaternion + translation
    └── points3D.txt         # 50 000 points d'init random
```

## Troubleshooting

**`ImportError: cannot import name 'numpy'`** — la distribution Python d'Unreal n'a pas numpy. Installer via pip (voir la section Pré-requis).

**`AttributeError: 'NoneType' object has no attribute 'get_actor_label'`** — pas de volume sélectionné. Sélectionne ton TriggerBox dans l'Outliner avant de lancer, ou passe `volume_actor=` explicitement.

**Toutes les stations sont skippées par le raycast** — le `min_wall_dist` est trop grand pour ton volume, ou le volume est trop petit. Baisser `min_wall_dist`, ou agrandir le volume, ou désactiver `avoid_walls=False` pour tester.

**Frames Lumen dim / bruitées après changement de caméra** — Lumen n'a pas eu le temps de converger. Augmenter `lumen_warmup_frames` à 120, 180 voire 240. Vérifier aussi que `Engine Scalability` est sur Cinematic (sinon Lumen tourne à qualité réduite).

**Le splat sort à l'envers / décalé** — vérifier que l'origine du splat est cohérente avec le recentrage horizontal. Le sol UE (Z=0) doit être au sol dans le viewer (Y=0 en COLMAP). Si le sol UE est à Z=200 (par exemple), le splat sera 2 m au-dessus du sol viewer — c'est normal, le script ne décale pas la verticale.

**MRQ filenames** — voir la section "Option C" ci-dessus.

## Limites de v0.1

- Pas d'UI Editor Utility Widget (CLI Python seulement — UI en v0.2)
- Pas de mode spline ni de mode yaw+pitch custom (volume + cubemap uniquement)
- Pas d'intégration Movie Render Queue automatique (le user configure son propre Level Sequence + MRQ config)
- Pas de toggle pour les filenames `GSCam_*` vs `<station>_<face>`
- AABB world-aligned du volume — pas d'OBB (à éviter de pivoter le volume)
- Le near clip plane requiert `r.SetNearClipPlane=1` au runtime pour être respecté

## Roadmap

- [x] **v0.1** : volume + cubemap + raycast + export COLMAP + HighResShot
- [x] **v0.1.1** : helper Lumen-aware (`setup_for_lumen_capture`, `lumen_warmup_frames`)
- [ ] **v0.2** : Editor Utility Widget UI (équivalent du rollout Max)
- [ ] **v0.2** : Mode spline + mode yaw+pitch custom (parité avec Max v2.2)
- [ ] **v0.2** : Génération automatique de Level Sequence + lancement MRQ avec config Path Tracer
- [ ] **v0.2** : Option de naming `keep_camera_prefix=True/False` pour matcher MRQ {camera_name}
- [ ] **v0.3** : Support OBB (oriented bounding box) pour les volumes pivotés
- [ ] **v0.3** : Profil de presets (showroom, galerie, restaurant…)

## Limitations transverses (toutes plateformes)

Les mêmes que la version Max — surfaces miroir, verre transparent, sources lumineuses très contrastées posent problème au GS. Voir le README racine du repo pour les détails.

## Credits

Port du `GS_Capture.ms` v2.2 (3ds Max + V-Ray) vers Python + Unreal Engine 5+.
Développé pour le pipeline interne **Aioli Collective**, en vibecodant avec **ai.claude** (Claude Opus 4.7, Anthropic).
