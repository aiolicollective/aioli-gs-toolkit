# aioli-gs-toolkit

> Suite d'outils internes **Aioli Collective** pour les workflows Gaussian Splatting.

Ce monorepo regroupe les scripts et outils que le studio utilise pour produire des splats Gaussian Splatting à partir de scènes archviz, et les partager avec les clients via un viewer interactif.

L'idée directrice : capturer un splat depuis n'importe quel outil de production utilisé en studio (3ds Max, Unreal, Blender), avec des poses caméra exactes générées synthétiquement — donc **sans dépendre de COLMAP** pour la phase Structure-from-Motion. Le trainer GS reçoit images + poses parfaites en un seul drag-drop.

## Composants

| Dossier | Description | Statut |
|---|---|---|
| [`max-vray/`](./max-vray) | Script MaxScript pour générer des datasets GS depuis 3ds Max + V-Ray. Volume placement, multi-Z layers, cubemap, smart cubemap, export COLMAP Y-down (LichtFeld-natif), points3D init, recentrage horizontal. | ✅ **v2.2 stable** |
| `viewer/` | Viewer HTML standalone (mkkellogg gaussian-splats-3d) pour partager un `.ply` avec un client sans installer quoi que ce soit. | 🚧 À venir |
| `unreal/` | Script Python pour Unreal Engine 5+ (Movie Render Queue + Path Tracer). | 🟡 Planifié |
| `blender/` | Add-on Blender pour Cycles. | 🟡 Planifié |

## Pipeline général

```
   Scène archviz (Max / Unreal / Blender)
                  │
                  ▼
  ┌─────────────────────────────────┐
  │  Script de capture (ce repo)    │
  │  → placement caméras grid       │
  │  → render images cohérentes     │
  │  → export poses COLMAP          │
  └─────────────────────────────────┘
                  │
                  ▼
   Dataset : images/ + sparse/0/
                  │
                  ▼
  ┌─────────────────────────────────┐
  │  Trainer Gaussian Splatting     │
  │  LichtFeld Studio / Brush       │
  └─────────────────────────────────┘
                  │
                  ▼
              .ply splat
                  │
                  ├──→ SuperSplat (cleanup, crop, compression)
                  │            │
                  │            ▼
                  │       .compressed.ply
                  │            │
                  ▼            ▼
        Viewer HTML statique (./viewer)
                  │
                  ▼
      Lien partageable client
```

## Démarrage rapide

### 3ds Max + V-Ray (disponible)

Voir [`max-vray/README.md`](./max-vray/README.md) pour la doc complète. TL;DR :

1. Drag-drop `max-vray/GS_Capture.ms` dans 3ds Max
2. Place une Box volume définissant la zone à capturer
3. Configure les paramètres (grid 50-100, Z layers 1-3, cubemap 14mm)
4. **Pick output folder** → click **RUN ALL**
5. Drop le dossier de sortie dans LichtFeld Studio ou Brush

### Unreal Engine (à venir)

Voir la roadmap dans `unreal/` (vide pour l'instant).

## Trainers GS supportés

| Outil | Install | Notes |
|---|---|---|
| **[LichtFeld Studio](https://lichtfeld.io)** | Via le portal | **Cible principale** du studio. L'export v2.2 est en convention Y-down native, le splat s'ouvre droit. |
| **[Brush](https://github.com/ArthurBrussee/brush)** | Zip + double-clic, pas de CUDA | Pratique pour les tests rapides. ⚠️ Attend Y-up : le splat apparaît à l'envers verticalement avec l'export v2.2 — orbite la caméra dans le viewer pour compenser. |

## Convention d'export

Format unique : COLMAP `sparse/0/` (cameras.txt, images.txt, points3D.txt).

- World : Y-down (convention COLMAP / LichtFeld native)
- Camera : OpenCV
- Intrinsics : modèle `OPENCV` distorsion zéro (caméras synthétiques parfaites)
- Recentrage automatique des positions caméra sur les axes **horizontaux** uniquement — le sol Max (Z=0) reste au sol dans le splat (Y=0 en COLMAP).
- `points3D.txt` : 50 000 points aléatoires d'init (LichtFeld refuse les datasets avec points3D vide).

## Limitations transverses (toutes plateformes)

Le Gaussian Splatting partage les limites de la photogrammétrie classique :

- ❌ Surfaces miroir / chromées : artefacts streaks blancs
- ❌ Verre transparent + caustiques : fantômes, faux reflets
- ❌ Sources lumineuses très contrastées (windows blown out)
- ✅ Murs / sols / mobilier mat ou satiné : excellent
- ✅ Plantes, tissus, bois : très bon

→ Pour les "money shots" client, garde V-Ray en photoreal classique. Le splat sert au **preview interactif**, pas au remplacement du V-Ray.

## Roadmap

- [x] **v2.1** : Multi-Z layers, smart cubemap, export COLMAP, auto-recenter
- [x] **v2.2** : Y-down natif (fix LichtFeld intégré), points3D auto-rempli, recentrage horizontal seul, suppression export JSON Nerfstudio
- [ ] Toggle UI Y-up / Y-down (si demande Brush forte)
- [ ] Viewer HTML standalone avec SuperSplat preset
- [ ] Port Unreal Engine 5+ (Python + Movie Render Queue)
- [ ] Port Blender (Cycles)
- [ ] Profile presets (showroom, galerie, espace public, restaurant…)

## Credits

Développé pour le pipeline interne **Aioli Collective**. Architecture spécifique aux scènes archviz intérieures (shops, galeries, showrooms).
