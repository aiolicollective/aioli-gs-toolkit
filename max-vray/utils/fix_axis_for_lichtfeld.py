#!/usr/bin/env python3
"""
fix_axis_for_lichtfeld.py
=========================

⚠️ OBSOLÈTE depuis GS_Capture.ms v2.2.

Le fix d'axes (Y-up Nerfstudio → Y-down COLMAP/LichtFeld) est désormais
intégré directement au MaxScript via la matrice `gscMaxToColmapWorld`
(section 3 de GS_Capture.ms). Les datasets exportés avec v2.2+ sont
nativement dans la convention LichtFeld, plus besoin de post-fix.

Ce fichier ne sert que pour les vieux datasets exportés avec v2.1 ou
antérieur. Pour ceux-là, restaurer la version précédente du script
depuis l'historique git :

    git show HEAD~1:max-vray/utils/fix_axis_for_lichtfeld.py > fix_old.py
    python fix_old.py <chemin_dataset_root>

Sinon, le plus simple est de relancer l'export 3) Export COLMAP files
depuis Max avec la v2.2 — pas de re-rendu nécessaire si les images
existent déjà.

À supprimer du repo une fois que toutes les machines ont migré v2.2 :

    git rm max-vray/utils/fix_axis_for_lichtfeld.py
    git commit -m "remove obsolete utility, fix integrated in v2.2"
"""
import sys

print(__doc__)
sys.exit(0)
