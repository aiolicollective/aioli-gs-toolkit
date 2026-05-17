#!/usr/bin/env python3
"""
fix_axis_for_lichtfeld.py
=========================

Convertit un dataset COLMAP existant exporté par GS_Capture.ms v2.1
de la convention Y-up world (Nerfstudio) vers Y-down world (COLMAP/LichtFeld
Studio), sans avoir besoin de re-rendre les images ni de relancer 3ds Max.

Mathématiquement :
    On applique une rotation de 180° autour de l'axe X à toutes les poses
    caméra. Pour un quaternion w2c (qw, qx, qy, qz) :

        q_new = q_old * q_x180   où q_x180 = (0, 1, 0, 0)

    En composantes :
        qw_new = -qx_old
        qx_new =  qw_old
        qy_new =  qz_old
        qz_new = -qy_old

    La translation (tx, ty, tz) reste inchangée, car elle représente la
    position du repère monde dans le repère caméra, qui ne dépend pas du
    sens de l'axe Y du monde.

Usage (depuis PowerShell ou cmd) :
    python fix_axis_for_lichtfeld.py "C:\\Users\\victor\\Desktop\\Test03"

Le script :
    1. Sauvegarde sparse/0/images.txt sous le nom images.txt.bak
    2. Réécrit sparse/0/images.txt avec les quaternions corrigés
    3. Ne touche pas à cameras.txt, ni à points3D.txt, ni au dossier images/

Ce script est nécessaire uniquement si tu as un dataset exporté avec
GS_Capture v2.1 (Y-up). Les datasets exportés avec v2.1.1+ sont déjà
en Y-down, pas besoin de fix.

Compatible avec Python 3.7+ (pas de dépendances externes).
"""

import sys
import shutil
from pathlib import Path


def flip_quaternion_x180(qw: float, qx: float, qy: float, qz: float) -> tuple:
    """
    Compose le quaternion d'entrée avec une rotation de 180° autour de X.
    Convention Hamilton, (qw, qx, qy, qz).
    Équivaut à R_new = R_old * diag(1, -1, -1) côté matrice de rotation,
    soit "négation des colonnes 2 et 3 de R".
    """
    return (-qx, qw, qz, -qy)


def main():
    if len(sys.argv) != 2:
        print("Usage : python fix_axis_for_lichtfeld.py <chemin_dataset_root>")
        print()
        print("Exemple :")
        print('    python fix_axis_for_lichtfeld.py "C:\\Users\\victor\\Desktop\\Test03"')
        print()
        print("Le dataset doit contenir sparse/0/images.txt")
        sys.exit(1)

    dataset_root = Path(sys.argv[1])
    img_file = dataset_root / "sparse" / "0" / "images.txt"

    if not img_file.exists():
        print(f"ERREUR : fichier introuvable -> {img_file}")
        print(f"Vérifie que {dataset_root} contient bien sparse/0/images.txt")
        sys.exit(1)

    # Backup
    backup = img_file.with_suffix(".txt.bak")
    if backup.exists():
        print(f"INFO : un backup existait déjà ({backup.name}), il sera écrasé.")
    shutil.copy(img_file, backup)
    print(f"OK   : backup créé -> {backup}")

    with open(img_file, "r", encoding="utf-8") as f:
        lines = f.readlines()

    out_lines = []
    n_converted = 0
    n_skipped_blank = 0

    for line in lines:
        stripped = line.strip()

        # Commentaires et lignes vides : on garde tel quel
        if not stripped or stripped.startswith("#"):
            out_lines.append(line)
            if not stripped:
                n_skipped_blank += 1
            continue

        # Ligne caméra attendue :
        #   IMAGE_ID QW QX QY QZ TX TY TZ CAMERA_ID NAME
        parts = stripped.split()

        is_camera_line = (
            len(parts) >= 10
            and parts[0].isdigit()
        )

        if is_camera_line:
            try:
                image_id = parts[0]
                qw = float(parts[1])
                qx = float(parts[2])
                qy = float(parts[3])
                qz = float(parts[4])
                tx = parts[5]  # On garde en string pour éviter perte de précision
                ty = parts[6]
                tz = parts[7]
                camera_id = parts[8]
                name = " ".join(parts[9:])

                qw_new, qx_new, qy_new, qz_new = flip_quaternion_x180(qw, qx, qy, qz)

                new_line = (
                    f"{image_id} {qw_new} {qx_new} {qy_new} {qz_new} "
                    f"{tx} {ty} {tz} {camera_id} {name}\n"
                )
                out_lines.append(new_line)
                n_converted += 1
            except (ValueError, IndexError) as e:
                # Ligne mal formée -> on garde sans transformer
                print(f"AVERTISSEMENT : ligne non convertie ({e}) : {stripped[:80]}")
                out_lines.append(line)
        else:
            # Probablement une ligne POINTS2D[] (vide ou avec des coords 2D)
            out_lines.append(line)

    with open(img_file, "w", encoding="utf-8") as f:
        f.writelines(out_lines)

    print(f"OK   : {n_converted} poses caméra converties")
    print(f"INFO : {n_skipped_blank} lignes vides préservées (POINTS2D)")
    print()
    print("--- Étapes suivantes ---")
    print(f"1. Re-drag-drop le dossier {dataset_root.name} dans LichtFeld Studio")
    print("2. Lance un nouveau training (le précédent est obsolète)")
    print("3. La verticale du splat devrait maintenant correspondre à Max")
    print()
    print(f"Si tu veux annuler : renomme {backup.name} en images.txt.")


if __name__ == "__main__":
    main()
