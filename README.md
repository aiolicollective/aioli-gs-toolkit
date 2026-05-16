# aioli-gs-toolkit

> Suite d'outils internes **Aioli Collective** pour les workflows Gaussian Splatting.

Ce monorepo regroupe les scripts et outils que le studio utilise pour produire des splats Gaussian Splatting à partir de scènes archviz, et les partager avec les clients via un viewer interactif.

L'idée directrice : pouvoir capturer un splat depuis n'importe quel outil de production utilisé en studio (3ds Max, Unreal, Blender), avec des poses caméra exactes générées synthétiquement — donc **sans dépendre de COLMAP** pour la phase Structure-from-Motion. Le trainer GS reçoit les images + les poses parfaites en un seul drag-drop.

## Composants

| Dossier | Description | Statut |
|---|---|---|
| [`max-vray/`](./max-vray) | Script MaxScript pour générer des datasets GS depuis 3ds Max + V-Ray. Volume placement, multi-Z layers, cubemap, smart cubemap, export Nerfstudio + COLMAP, recentrage automatique. | ✅ **v2.1 stable** |
| `viewer/` | Viewer HTML standalone (mkkellogg gaussian-splats-3d) pour partager un `.ply` avec un client sans installer quoi que ce soit. | 🚧 À venir |
| `unreal/` | Script Python pour Unreal Engine 5+ utilisant Movie Render Queue et le Path Tracer. Même logique que la version Max. | 🟡 Planifié |
| `blender/` | Add-on Blender pour Cycles. | 🟡 Planifié |

## Pipeline général

```
   Scène archviz (Max / Unreal / Blender)
                  │
                  ▼
  ┌─────────────────────────────────┐
  │  Script de capture (ce repo)    │
  │  → placement de caméras grid    │
  │  → render images cohérentes     │
  │  → export poses (JSON / COLMAP) │
  └─────────────────────────────────┘
                  │
                  ▼
   Dataset : images/ + transforms.json + sparse/0/
                  │
                  ▼
  ┌─────────────────────────────────┐
  │  Trainer Gaussian Splatting     │
  │  Brush / LichtFeld / Postshot   │
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

### Pour 3ds Max + V-Ray (disponible)

Voir [`max-vray/README.md`](./max-vray/README.md) pour la doc complète. TL;DR :

1. Drag-drop `max-vray/GS_Capture.ms` dans 3ds Max
2. Place une Box volume définissant la zone à capturer
3. Configure les paramètres (grid 50-100 cm, Z layers 1-3, cubemap 14mm)
4. **Pick output folder** → click **RUN ALL**
5. Récupère le dataset (images + COLMAP) pour le trainer de ton choix

### Pour Unreal Engine (à venir)

Voir la roadmap dans `unreal/` (vide pour l'instant).

## Recommandations trainer GS

| Outil | Avantages | Install | Recommandé pour |
|---|---|---|---|
| **[Brush](https://github.com/ArthurBrussee/brush)** | Zip + double-clic, pas de CUDA | ⭐ Très simple | Premiers tests, validation pipeline |
| **[LichtFeld Studio](https://lichtfeld.io)** | MCMC, bilateral grid, plus mature | ⚠️ CUDA 12.8 + binaires via portal | **Production studio** (gère mieux les variations d'éclairage V-Ray) |
| **[Postshot](https://www.jawset.com/)** | Workflow intégré GUI | 💰 €17/mois (PLY export inclus) | Clients qui veulent un outil all-in-one |
| **[Nerfstudio Splatfacto](https://docs.nerf.studio/)** | Le plus configurable | ⚠️ Long à installer (2-3h) | R&D / cas spéciaux |

## Convention d'export

Le toolkit produit deux formats en parallèle pour maximiser la compatibilité :

- **`transforms.json`** — Convention Nerfstudio, caméra OpenGL (-Z forward, +Y up). Lisible.
- **`sparse/0/*.txt`** — Convention COLMAP, caméra OpenCV (+Z forward, -Y up). Plus universel.

Les positions caméra sont **automatiquement recentrées** au centroïde (origine en 0,0,0). Critique pour les scènes archviz importées de CAD avec des coordonnées Lambert ou similaires.

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
- [ ] **v2.2** : Export OpenSplat (en cas de nouveau format support)
- [ ] Viewer HTML standalone avec SuperSplat preset
- [ ] Port Unreal Engine 5+ (Python + Movie Render Queue)
- [ ] Port Blender (Cycles)
- [ ] Profile presets (showroom, galerie, espace public, restaurant…)
- [ ] Documentation des matériaux V-Ray "GS-friendly"

## Credits

Développé pour le pipeline interne **Aioli Collective**. Architecture spécifique aux scènes archviz intérieures (shops, galeries, showrooms).
