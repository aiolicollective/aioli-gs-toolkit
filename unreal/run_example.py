# -*- coding: utf-8 -*-
"""
GS_Capture for Unreal -- example runner.

Usage:
    1) Copy this file and gs_capture.py to <YourProject>/Content/Python/
    2) Open your level in the editor.
    3) Place a TriggerBox (or any Box actor) sized to cover the capture zone.
       Select it in the World Outliner.
    4) Edit the parameters below (especially OUTPUT_FOLDER).
    5) In Unreal Output Log, switch the Cmd dropdown to "Python", then run:
           py run_example.py
       Alternatively, paste this whole file into the Python REPL.
"""

import gs_capture


# ---- 1) WHERE TO WRITE THE DATASET --------------------------------------
OUTPUT_FOLDER = r"D:/datasets/my_scene"   # absolute path; will be created if missing


# ---- 2) CAPTURE PARAMETERS ----------------------------------------------
params = gs_capture.GSCaptureParams(
    # Volume: leave as None to use the currently selected actor in the Outliner.
    volume_actor   = None,

    # Grid spacing inside the volume (cm). 100-150 cm is a good default for
    # an interior archviz scene. Smaller = more cameras = better splat quality
    # but longer training.
    grid_x         = 150.0,
    grid_y         = 150.0,

    # Number of vertical sampling layers. 1 = single height (volume center);
    # 2 = chest + eye level; 3+ = also includes a floor-low and ceiling-high.
    z_layer_count  = 2,

    # XY jitter per station to break grid regularity (helps GS convergence).
    jitter_pos     = 5.0,

    # Skip stations within 30 cm of any blocking surface (walls, furniture).
    avoid_walls    = True,
    min_wall_dist  = 30.0,

    # 6-face cubemap at each station. Smart cubemap skips the redundant
    # up/down faces on the top/bottom Z layers (saves ~16% render time).
    cube_faces     = [True, True, True, True, True, True],  # F, B, L, R, U, D
    smart_cubemap  = True,

    # Lens: 14 mm + 36 mm sensor = ~104deg HFOV -> ~30% overlap between faces.
    focal_mm       = 14.0,
    sensor_mm      = 36.0,
    near_clip      = 1.0,
    far_clip       = 50000.0,

    # Render resolution. 1280x720 trains in ~10 min on a 5090 for ~300 images.
    res_w          = 1280,
    res_h          = 720,
    img_format     = "png",

    output_folder  = OUTPUT_FOLDER,
)


# ---- 3) RUN -------------------------------------------------------------
# This will:
#   a) delete any existing GS_Capture_Cameras folder content
#   b) spawn the cameras under the GS_Capture_Cameras outliner folder
#   c) write COLMAP files to OUTPUT_FOLDER/sparse/0/
#
# To also render via HighResShot (basic, uses current viewport view mode --
# set the viewport to Path Tracing first for best quality):
#   gs_capture.run_all(params, render=True)

gs_capture.run_all(params, render=False)


# ---- 4) RENDER -----------------------------------------------------------
# Recommended: Movie Render Queue with a Path Tracer config.
#   * Create a Level Sequence, add a Camera Cuts track.
#   * Add one shot per camera in the GS_Capture_Cameras folder (1 frame each).
#   * In MRQ, set output filename pattern to {camera_name} and output
#     directory to OUTPUT_FOLDER/images/. Disable the frame-number suffix.
#   * Set renderer to Path Tracer with at least 64 spp + AA enabled.
#   * Render. Files will be named GSCam_0001_front.png etc.
#
# Then update sparse/0/images.txt to use the GSCam_ prefix (open it and
# search/replace), OR rename the rendered files to drop the prefix.
#
# Quick fallback (no MRQ, uses HighResShot at current viewport view mode):
#   gs_capture.render_batch_screenshots(params)
