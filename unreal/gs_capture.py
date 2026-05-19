# -*- coding: utf-8 -*-
"""
==============================================================================
  gs_capture.py  --  v0.1
  =======================
  Synthetic dataset generator for Gaussian Splatting training,
  from Unreal Engine 5+ scenes.

  Targets:
    - Unreal Engine 5.3+ (tested on 5.4, 5.5, 5.6)
    - Output: COLMAP sparse/0/ format (cameras.txt, images.txt, points3D.txt)
    - Trainers tested: LichtFeld Studio, Brush

  Port from MaxScript GS_Capture.ms v2.2 (3ds Max + V-Ray).

  v0.1 scope (initial port):
    * Volume placement mode (multi-Z layers) ............................ DONE
    * Cubemap camera mode (6 cardinal faces + smart skip) ............... DONE
    * Wall-distance raycast (auto-skip stations too close to geometry) .. DONE
    * COLMAP sparse/0/ export (Y-down world, OpenCV camera) ............. DONE
    * Auto-recenter on horizontal axes (vertical preserved) ............. DONE
    * 50 000 random init points in points3D.txt ......................... DONE
    * High-res-screenshot batch render (basic fallback) ................. DONE

  Out of scope for v0.1 (planned for v0.2):
    * Spline placement mode
    * Custom yaw/pitch camera mode
    * Movie Render Queue integration with Path Tracer config
    * Editor Utility Widget UI

  Output structure (same as Max version):
      <output_folder>/
        images/
          0001_front.png     (cubemap mode, <station>_<face>.png)
          0001_back.png
          ...
        sparse/0/
          cameras.txt        (OPENCV intrinsics)
          images.txt         (extrinsics, Y-down world / OpenCV camera)
          points3D.txt       (50k random init points)

  Coordinate notes:
    - Unreal world : +X forward, +Y right, +Z up (LEFT-handed, cm units).
    - Unreal camera local : +X = look direction.
    - COLMAP world : +X right, +Y down, +Z forward (RIGHT-handed).
    - OpenCV camera local : +X right, +Y down, +Z forward.
  The conversion from UE world to COLMAP world is a coordinate-axis remap
  (det = -1, since it flips handedness LH -> RH). Combined with the UE-cam
  to OpenCV-cam axis swap (also det = -1), the resulting camera-to-world
  matrix in COLMAP convention has det = +1 (proper rotation). See section 2.

  Usage (in Unreal Output Log, Cmd switched to Python):

      import gs_capture
      params = gs_capture.GSCaptureParams(
          grid_x=100,
          grid_y=100,
          z_layer_count=2,
          output_folder=r"D:/datasets/my_scene",
      )
      # Select your volume actor in the Outliner, then:
      cams = gs_capture.generate_cameras(params)
      gs_capture.export_colmap_files(params, cams)
      # Render either with Movie Render Queue (recommended) or:
      gs_capture.render_batch_screenshots(params, cams)

  See run_example.py for a copy-pasteable example.
==============================================================================
"""

import os
import math
import random
from dataclasses import dataclass, field
from typing import List, Optional, Tuple

import numpy as np
import unreal


# ==============================================================================
# 0. PARAMS
# ==============================================================================

@dataclass
class GSCaptureParams:
    """Configuration for a GS capture run."""

    # --- Volume placement ---
    # If None, the script uses the first selected actor as the volume bounds.
    volume_actor: Optional[unreal.Actor] = None
    grid_x: float = 100.0         # cm, horizontal spacing
    grid_y: float = 100.0         # cm, horizontal spacing
    z_layer_count: int = 1        # number of vertical sampling layers in the volume
    jitter_pos: float = 5.0       # cm, random offset per station (XY only, Z preserved)

    # --- Wall avoidance ---
    avoid_walls: bool = True
    min_wall_dist: float = 30.0   # cm, skip stations closer than this to any blocking surface

    # --- Camera (cubemap mode only in v0.1) ---
    # Faces order: [front, back, left, right, up, down]
    cube_faces: List[bool] = field(default_factory=lambda: [True] * 6)
    # Smart cubemap: on multi-Z setups, skip "down" on the lowest layer and
    # "up" on the highest layer (~16% time savings, no quality loss).
    smart_cubemap: bool = True

    # --- Lens ---
    focal_mm: float = 14.0        # 14mm @ 36mm sensor = ~104deg HFOV (cubemap default)
    sensor_mm: float = 36.0
    near_clip: float = 1.0        # cm
    far_clip: float = 50000.0     # cm

    # --- Render ---
    res_w: int = 1280
    res_h: int = 720
    img_format: str = "png"

    # --- Output ---
    output_folder: str = ""       # absolute path; the images/ and sparse/ subfolders are created here
    seed: int = 12345


# ==============================================================================
# 1. UTILITIES
# ==============================================================================

def _log(msg: str):
    unreal.log(f"[GS_Capture] {msg}")

def _log_warning(msg: str):
    unreal.log_warning(f"[GS_Capture] {msg}")

def _log_error(msg: str):
    unreal.log_error(f"[GS_Capture] {msg}")

def _pad_int(n: int, digits: int) -> str:
    return f"{n:0{digits}d}"

def _jitter(amp: float) -> float:
    return random.uniform(-amp, amp) if amp > 0 else 0.0

def _ensure_folder(path: str) -> bool:
    if not path:
        return False
    os.makedirs(path, exist_ok=True)
    return os.path.isdir(path)

def _is_actor_alive(actor) -> bool:
    """Lightweight check that an actor reference is still usable."""
    if actor is None:
        return False
    try:
        _ = actor.get_actor_label()
        return True
    except Exception:
        return False


# ==============================================================================
# 2. COORDINATE SYSTEM CONVERSION
# ==============================================================================
#
# Unreal world      : +X forward, +Y right, +Z up                 (LH, cm)
# Unreal cam local  : +X = look direction
# COLMAP world      : +X right,   +Y down,  +Z forward            (RH)
# OpenCV cam local  : +X right,   +Y down,  +Z forward
#
# UE world -> COLMAP world axis remap (acting on column vectors):
#   CM +X (right) =  UE +Y
#   CM +Y (down)  = -UE +Z
#   CM +Z (fwd)   =  UE +X

_M_UE_TO_COLMAP_WORLD = np.array(
    [[0.0, 1.0,  0.0],
     [0.0, 0.0, -1.0],
     [1.0, 0.0,  0.0]],
    dtype=np.float64,
)


def _actor_to_colmap_c2w(actor) -> Tuple[np.ndarray, np.ndarray]:
    """
    Compute the camera-to-world matrix in COLMAP convention (Y-down world,
    OpenCV camera) for an Unreal actor's transform.

    Returns:
        R_c2w (3x3): columns are OpenCV cam +X, +Y, +Z expressed in COLMAP world.
        t (3,):     camera position in COLMAP world.
    """
    loc = actor.get_actor_location()
    fwd = actor.get_actor_forward_vector()
    right = actor.get_actor_right_vector()
    up = actor.get_actor_up_vector()

    # OpenCV cam axes, expressed in UE world coordinates:
    #   OpenCV +X (right)  =   UE camera right
    #   OpenCV +Y (down)   = - UE camera up
    #   OpenCV +Z (fwd)    =   UE camera fwd
    cv_x_ue = np.array([right.x, right.y, right.z])
    cv_y_ue = -np.array([up.x, up.y, up.z])
    cv_z_ue = np.array([fwd.x, fwd.y, fwd.z])

    M = _M_UE_TO_COLMAP_WORLD
    R_c2w = np.column_stack([M @ cv_x_ue, M @ cv_y_ue, M @ cv_z_ue])
    t = M @ np.array([loc.x, loc.y, loc.z])
    return R_c2w, t


def _rot_mat_to_quat(R: np.ndarray) -> Tuple[float, float, float, float]:
    """
    Convert a 3x3 rotation matrix to a quaternion (qw, qx, qy, qz)
    using Shepperd's branched method for numerical stability.
    Output is the convention COLMAP expects in images.txt.
    """
    R00, R01, R02 = R[0, 0], R[0, 1], R[0, 2]
    R10, R11, R12 = R[1, 0], R[1, 1], R[1, 2]
    R20, R21, R22 = R[2, 0], R[2, 1], R[2, 2]
    tr = R00 + R11 + R22

    if tr > 0:
        s = math.sqrt(tr + 1.0) * 2.0
        qw = 0.25 * s
        qx = (R21 - R12) / s
        qy = (R02 - R20) / s
        qz = (R10 - R01) / s
    elif R00 > R11 and R00 > R22:
        s = math.sqrt(1.0 + R00 - R11 - R22) * 2.0
        qw = (R21 - R12) / s
        qx = 0.25 * s
        qy = (R01 + R10) / s
        qz = (R02 + R20) / s
    elif R11 > R22:
        s = math.sqrt(1.0 + R11 - R00 - R22) * 2.0
        qw = (R02 - R20) / s
        qx = (R01 + R10) / s
        qy = 0.25 * s
        qz = (R12 + R21) / s
    else:
        s = math.sqrt(1.0 + R22 - R00 - R11) * 2.0
        qw = (R10 - R01) / s
        qx = (R02 + R20) / s
        qy = (R12 + R21) / s
        qz = 0.25 * s
    return (float(qw), float(qx), float(qy), float(qz))


# ==============================================================================
# 3. EDITOR HELPERS
# ==============================================================================

def _get_editor_world():
    """Return the currently open editor level world."""
    try:
        return unreal.UnrealEditorSubsystem().get_editor_world()
    except Exception:
        # Fallback for older UE versions
        return unreal.EditorLevelLibrary.get_editor_world()


def _get_actor_subsystem():
    return unreal.get_editor_subsystem(unreal.EditorActorSubsystem)


def _get_selected_actors() -> List[unreal.Actor]:
    return _get_actor_subsystem().get_selected_level_actors()


def _get_actor_world_bbox(actor) -> Tuple[unreal.Vector, unreal.Vector]:
    """World-aligned AABB of the actor's bounds. Returns (min, max) corners."""
    origin, extent = actor.get_actor_bounds(
        only_colliding_components=False,
        include_from_child_actors=True,
    )
    bmin = unreal.Vector(origin.x - extent.x, origin.y - extent.y, origin.z - extent.z)
    bmax = unreal.Vector(origin.x + extent.x, origin.y + extent.y, origin.z + extent.z)
    return bmin, bmax


# ==============================================================================
# 4. WALL AVOIDANCE (raycast)
# ==============================================================================

_WALL_TEST_DIRS = [
    (1, 0, 0), (-1, 0, 0),
    (0, 1, 0), (0, -1, 0),
    (0, 0, 1), (0, 0, -1),
    (0.7071, 0.7071, 0), (-0.7071, 0.7071, 0),
    (0.7071, -0.7071, 0), (-0.7071, -0.7071, 0),
]


def _line_trace_blocks(world, start: unreal.Vector, end: unreal.Vector, ignore_actors: list) -> bool:
    """
    Single-shot line trace on the Visibility channel. Returns True if a blocking
    hit was found between start and end.
    """
    try:
        result = unreal.SystemLibrary.line_trace_single(
            world, start, end,
            unreal.TraceTypeQuery.TRACE_TYPE_QUERY1,  # Visibility
            False,                                     # trace_complex
            ignore_actors,
            unreal.DrawDebugTrace.NONE,
            True,                                      # ignore_self
        )
    except Exception as e:
        _log_warning(f"line_trace_single failed: {e}")
        return False

    # The Python binding for line_trace_single returns either:
    #   - (bool blocking_hit, HitResult)  -- typical case in 5.x
    #   - HitResult directly              -- some bindings
    # Defensively handle both.
    if isinstance(result, tuple) and len(result) == 2:
        blocking, _hit = result
        return bool(blocking)
    if result is None:
        return False
    if hasattr(result, "blocking_hit"):
        return bool(result.blocking_hit)
    if isinstance(result, bool):
        return result
    return False


def _is_station_valid(world, pos: unreal.Vector, min_dist: float, ignore_actors: list) -> bool:
    """Cast 10 short rays from pos; return False if any blocks closer than min_dist."""
    for dx, dy, dz in _WALL_TEST_DIRS:
        end = unreal.Vector(
            pos.x + dx * min_dist,
            pos.y + dy * min_dist,
            pos.z + dz * min_dist,
        )
        if _line_trace_blocks(world, pos, end, ignore_actors):
            return False
    return True


# ==============================================================================
# 5. STATION GENERATION (volume mode)
# ==============================================================================

def _generate_stations_from_volume(
    params: GSCaptureParams,
    world,
) -> List[Tuple[unreal.Vector, int, int]]:
    """
    Sample a 3D grid of stations inside the volume actor's world AABB.
    Returns a list of (position, layer_idx_1based, total_layers).
    """
    if params.volume_actor is None or not _is_actor_alive(params.volume_actor):
        _log_error("No volume actor set.")
        return []

    bmin, bmax = _get_actor_world_bbox(params.volume_actor)

    sx = max(params.grid_x, 0.001)
    sy = max(params.grid_y, 0.001)

    nx = max(int((bmax.x - bmin.x) / sx), 1)
    ny = max(int((bmax.y - bmin.y) / sy), 1)
    nz = max(params.z_layer_count, 1)

    z_layers = []
    if nz == 1:
        z_layers.append((bmin.z + bmax.z) / 2.0)
    else:
        for i in range(1, nz + 1):
            tt = (i - 0.5) / nz
            z_layers.append(bmin.z + tt * (bmax.z - bmin.z))

    _log(
        f"Volume: '{params.volume_actor.get_actor_label()}'  "
        f"bbox size [{bmax.x - bmin.x:.0f}, {bmax.y - bmin.y:.0f}, {bmax.z - bmin.z:.0f}] cm  "
        f"grid {nx}x{ny}x{nz}"
    )

    # Ignore the volume actor itself in raycasts (it may have collision).
    ignore_actors = [params.volume_actor]

    stations: List[Tuple[unreal.Vector, int, int]] = []
    skipped_wall = 0
    skipped_per_layer = [0] * nz

    for iz_idx, z in enumerate(z_layers):
        iz = iz_idx + 1  # 1-based for downstream
        for iy in range(ny + 1):
            y = bmin.y + iy * sy if iy < ny else bmax.y
            for ix in range(nx + 1):
                x = bmin.x + ix * sx if ix < nx else bmax.x

                pos = unreal.Vector(
                    x + _jitter(params.jitter_pos),
                    y + _jitter(params.jitter_pos),
                    z,
                )

                if params.avoid_walls:
                    if _is_station_valid(world, pos, params.min_wall_dist, ignore_actors):
                        stations.append((pos, iz, nz))
                    else:
                        skipped_wall += 1
                        skipped_per_layer[iz_idx] += 1
                else:
                    stations.append((pos, iz, nz))

    if params.avoid_walls:
        detail = ", ".join([f"L{i + 1}={n}" for i, n in enumerate(skipped_per_layer)])
        _log(f"Wall avoidance: skipped {skipped_wall} stations total  ({detail})")
    _log(f"Volume mode: {len(stations)} valid station-layer pairs.")

    return stations


# ==============================================================================
# 6. CUBEMAP DIRECTIONS (in UE world)
# ==============================================================================
# Index order matches Max version: 1=front, 2=back, 3=left, 4=right, 5=up, 6=down.
# In Unreal world (X forward, Y right, Z up):

_CUBEMAP_DIRS = [
    ("front", unreal.Vector(1, 0, 0)),
    ("back",  unreal.Vector(-1, 0, 0)),
    ("left",  unreal.Vector(0, -1, 0)),
    ("right", unreal.Vector(0, 1, 0)),
    ("up",    unreal.Vector(0, 0, 1)),
    ("down",  unreal.Vector(0, 0, -1)),
]


# ==============================================================================
# 7. CAMERA CREATION
# ==============================================================================

GS_CAMERA_FOLDER = "GS_Capture_Cameras"


def _look_dir_to_rotator(look_dir: unreal.Vector) -> unreal.Rotator:
    """
    Build a Rotator whose forward (+X local) points along look_dir.
    Uses MakeRotFromX which keeps roll = 0 and handles gimbal lock by aligning
    the "right" axis to world +Y when forward is near vertical.
    """
    return unreal.MathLibrary.make_rot_from_x(look_dir.normal())


def _make_camera(
    name: str,
    pos: unreal.Vector,
    look_dir: unreal.Vector,
    focal_mm: float,
    sensor_mm: float,
    near_cm: float,
    res_w: int,
    res_h: int,
) -> unreal.CineCameraActor:
    """Spawn a CineCameraActor in the editor world, configure lens + DOF off."""
    rotator = _look_dir_to_rotator(look_dir)
    actor_sub = _get_actor_subsystem()
    cam_actor = actor_sub.spawn_actor_from_class(
        unreal.CineCameraActor, pos, rotator,
    )
    cam_actor.set_actor_label(name)
    cam_actor.set_folder_path(GS_CAMERA_FOLDER)

    cam_comp = cam_actor.get_cine_camera_component()

    # Lens
    cam_comp.set_current_focal_length(focal_mm)

    # Filmback: enforce square pixels matching render resolution
    filmback = unreal.CameraFilmbackSettings()
    filmback.sensor_width = sensor_mm
    filmback.sensor_height = sensor_mm * float(res_h) / float(res_w)
    cam_comp.set_editor_property("filmback", filmback)

    # Disable DOF entirely -- GS training requires sharp focus everywhere.
    focus = unreal.CameraFocusSettings()
    focus.focus_method = unreal.CameraFocusMethod.DISABLE
    cam_comp.set_editor_property("focus_settings", focus)

    # Custom near clip plane (requires r.SetNearClipPlane=1 in Project Settings
    # to take effect at render time, but it's a no-op otherwise so we always set it).
    try:
        cam_comp.set_editor_property("custom_near_clipping_plane", near_cm)
    except Exception:
        pass

    return cam_actor


def delete_generated_cameras() -> int:
    """Delete every actor inside the GS_Capture_Cameras outliner folder."""
    actor_sub = _get_actor_subsystem()
    all_actors = actor_sub.get_all_level_actors()
    to_delete = []
    for a in all_actors:
        try:
            folder = str(a.get_folder_path())
            if folder == GS_CAMERA_FOLDER and isinstance(a, unreal.CineCameraActor):
                to_delete.append(a)
        except Exception:
            pass
    for a in to_delete:
        try:
            actor_sub.destroy_actor(a)
        except Exception as e:
            _log_warning(f"Could not destroy {a}: {e}")
    _log(f"Deleted {len(to_delete)} cameras from folder '{GS_CAMERA_FOLDER}'.")
    return len(to_delete)


def scan_existing_cameras() -> List[Tuple[unreal.CineCameraActor, int, str]]:
    """
    Rebuild a (camera, station_idx, face_tag) list from the GS_Capture_Cameras
    folder. Useful after an editor restart so export/render work without
    re-generating.
    Returns the list sorted by camera label.
    """
    actor_sub = _get_actor_subsystem()
    all_actors = actor_sub.get_all_level_actors()

    cams = []
    for a in all_actors:
        try:
            if str(a.get_folder_path()) == GS_CAMERA_FOLDER and isinstance(a, unreal.CineCameraActor):
                cams.append(a)
        except Exception:
            pass

    cams.sort(key=lambda c: c.get_actor_label())

    result: List[Tuple[unreal.CineCameraActor, int, str]] = []
    for c in cams:
        label = c.get_actor_label()
        # Expected pattern: GSCam_<station4>_<face>
        parts = label.split("_")
        if len(parts) >= 3 and parts[0] == "GSCam":
            try:
                station_idx = int(parts[1])
                face_tag = "_".join(parts[2:])
                result.append((c, station_idx, face_tag))
            except ValueError:
                pass
    return result


# ==============================================================================
# 8. MAIN CAMERA GENERATION ORCHESTRATOR
# ==============================================================================

def generate_cameras(
    params: GSCaptureParams,
) -> List[Tuple[unreal.CineCameraActor, int, str]]:
    """
    Generate the full camera grid in the editor world.
    Returns a list of (camera_actor, station_idx, face_tag).

    Side-effects:
      * Deletes any pre-existing actors in the GS_Capture_Cameras folder.
      * Spawns N new CineCameraActor in that folder.
      * If params.volume_actor is None, uses the first selected actor.
    """
    world = _get_editor_world()

    # Resolve volume from selection if not explicitly provided.
    if params.volume_actor is None:
        sel = _get_selected_actors()
        if not sel:
            _log_error(
                "No volume actor. Either set params.volume_actor or select one "
                "actor in the Outliner before running.",
            )
            return []
        params.volume_actor = sel[0]
        _log(f"Using selected actor as volume: '{params.volume_actor.get_actor_label()}'")

    delete_generated_cameras()
    random.seed(params.seed)

    stations = _generate_stations_from_volume(params, world)
    if not stations:
        _log_error("No stations generated. Check params/volume.")
        return []

    # Pre-flight estimate
    n_per_station = sum(1 for f in params.cube_faces if f)
    total_est = len(stations) * n_per_station
    if total_est > 3000:
        _log_warning(
            f"About to spawn ~{total_est} cameras. "
            "Coarser grid or fewer Z layers if too many.",
        )

    created: List[Tuple[unreal.CineCameraActor, int, str]] = []

    with unreal.ScopedSlowTask(len(stations), "GS_Capture: generating cameras...") as task:
        task.make_dialog(True)

        for s_idx_0, (pos, layer_idx, total_layers) in enumerate(stations):
            if task.should_cancel():
                _log("Cancelled by user.")
                break
            task.enter_progress_frame(1)

            s_idx = s_idx_0 + 1  # 1-based

            # Smart cubemap: skip "down" on lowest layer, "up" on highest layer
            eff_faces = list(params.cube_faces)
            if params.smart_cubemap and total_layers >= 2:
                if layer_idx == 1:
                    eff_faces[5] = False  # face index 5 = down
                if layer_idx == total_layers:
                    eff_faces[4] = False  # face index 4 = up

            for f_idx, (face_name, dir_vec) in enumerate(_CUBEMAP_DIRS):
                if not eff_faces[f_idx]:
                    continue
                cam_name = f"GSCam_{_pad_int(s_idx, 4)}_{face_name}"
                cam = _make_camera(
                    cam_name, pos, dir_vec,
                    params.focal_mm, params.sensor_mm, params.near_clip,
                    params.res_w, params.res_h,
                )
                created.append((cam, s_idx, face_name))

    _log(f"Generated {len(created)} cameras across {len(stations)} stations.")
    return created


# ==============================================================================
# 9. COLMAP EXPORT
# ==============================================================================
#
# Generate COLMAP-format sparse reconstruction files at:
#   <output_folder>/sparse/0/cameras.txt
#   <output_folder>/sparse/0/images.txt
#   <output_folder>/sparse/0/points3D.txt
#
# Conversion chain:
#   1. cam transform (UE world LH) -> COLMAP world (Y-down, RH), via axis remap
#      (_actor_to_colmap_c2w handles this).
#   2. R_c2w columns are already OpenCV cam basis in COLMAP world.
#   3. Apply horizontal recenter to position: subtract centroid of X and Z
#      (CM X and Z are horizontal; CM Y is vertical and preserved so the
#      ground stays at world Y = 0 in the splat).
#   4. w2c = inverse(c2w) ; for orthonormal R, this is R.T and t' = -R.T @ t.
#   5. Decompose w2c into quaternion (qw, qx, qy, qz) + translation, write images.txt.
#
# This matches the GS_Capture.ms v2.2 export byte-for-byte in convention so the
# same trainer configs work for datasets from Max OR Unreal.


def export_colmap_files(
    params: GSCaptureParams,
    cameras: Optional[List[Tuple[unreal.CineCameraActor, int, str]]] = None,
) -> bool:
    """
    Write sparse/0/{cameras.txt, images.txt, points3D.txt}.
    If `cameras` is not provided, scans the GS_Capture_Cameras folder.
    """
    if not cameras:
        cameras = scan_existing_cameras()
        if not cameras:
            _log_error("No cameras to export. Run generate_cameras() first.")
            return False
        _log(f"Detected {len(cameras)} existing cameras from scene folder.")

    if not params.output_folder:
        _log_error("output_folder not set.")
        return False

    sparse_dir = os.path.join(params.output_folder, "sparse", "0")
    if not _ensure_folder(sparse_dir):
        _log_error(f"Could not create {sparse_dir}")
        return False

    # ---- Compute recenter centroid (X and Z only -- Y is vertical, preserved) ----
    centroid_x = 0.0
    centroid_z = 0.0
    n_valid = 0
    for cam, _s_idx, _face in cameras:
        if not _is_actor_alive(cam):
            continue
        _R, pos_cm = _actor_to_colmap_c2w(cam)
        centroid_x += pos_cm[0]
        centroid_z += pos_cm[2]
        n_valid += 1
    if n_valid > 0:
        centroid_x /= n_valid
        centroid_z /= n_valid
    _log(
        f"Auto-recenter (horizontal only, vertical preserved): "
        f"centroid (X={centroid_x:.1f}, Z={centroid_z:.1f}) -> origin.",
    )

    # ---- cameras.txt ----
    fl_x_px = (params.res_w / params.sensor_mm) * params.focal_mm
    fl_y_px = fl_x_px
    cx_px = params.res_w / 2.0
    cy_px = params.res_h / 2.0
    cam_path = os.path.join(sparse_dir, "cameras.txt")
    with open(cam_path, "w", encoding="utf-8") as f:
        f.write("# Camera list with one line of data per camera:\n")
        f.write("#   CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]\n")
        f.write("# Number of cameras: 1\n")
        f.write(
            f"1 OPENCV {params.res_w} {params.res_h} "
            f"{fl_x_px} {fl_y_px} {cx_px} {cy_px} 0.0 0.0 0.0 0.0\n",
        )

    # ---- images.txt + collect recentered bbox for points3D scale ----
    img_path = os.path.join(sparse_dir, "images.txt")
    max_abs = np.zeros(3)
    written = 0
    with open(img_path, "w", encoding="utf-8") as f:
        f.write("# Image list with two lines of data per image:\n")
        f.write("#   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME\n")
        f.write("#   POINTS2D[] as (X, Y, POINT3D_ID)\n")
        f.write(f"# Number of images: {len(cameras)}\n")

        for i_0, (cam, s_idx, face) in enumerate(cameras):
            i = i_0 + 1  # COLMAP image IDs start at 1
            if not _is_actor_alive(cam):
                continue
            R_c2w, t = _actor_to_colmap_c2w(cam)
            t_rec = np.array([t[0] - centroid_x, t[1], t[2] - centroid_z])

            for k in range(3):
                if abs(t_rec[k]) > max_abs[k]:
                    max_abs[k] = abs(t_rec[k])

            # w2c = inverse(c2w); for orthonormal R, R.T inverts the rotation.
            R_w2c = R_c2w.T
            t_w2c = -R_w2c @ t_rec
            qw, qx, qy, qz = _rot_mat_to_quat(R_w2c)

            img_name = f"{_pad_int(s_idx, 4)}_{face}.{params.img_format}"
            f.write(
                f"{i} {qw} {qx} {qy} {qz} "
                f"{t_w2c[0]} {t_w2c[1]} {t_w2c[2]} 1 {img_name}\n",
            )
            f.write("\n")  # empty POINTS2D line (required by COLMAP parser)
            written += 1

    # ---- points3D.txt (50k random init points) ----
    # LichtFeld refuses to load datasets with "Number of points: 0".
    # We seed the scene with random points spanning ~1.5x the recentered camera bbox.
    # The trainer prunes irrelevant points within a few epochs.
    box_half = max(max_abs[0], max_abs[1], max_abs[2]) * 1.5
    if box_half < 100.0:
        box_half = 500.0
    _log(f"points3D scene scale: +/-{box_half:.0f} cm, generating 50000 points...")

    points_path = os.path.join(sparse_dir, "points3D.txt")
    rng = random.Random(12345)  # fixed seed so re-exports are deterministic
    N = 50000
    with open(points_path, "w", encoding="utf-8") as f:
        f.write("# 3D point list with one line of data per point:\n")
        f.write("#   POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[] as (IMAGE_ID, POINT2D_IDX)\n")
        f.write(f"# Number of points: {N}\n")
        for i in range(1, N + 1):
            x = rng.uniform(-1.0, 1.0) * box_half
            y = rng.uniform(-1.0, 1.0) * box_half
            z = rng.uniform(-1.0, 1.0) * box_half
            r = rng.randint(80, 175)
            g = rng.randint(80, 175)
            b = rng.randint(80, 175)
            f.write(f"{i} {x} {y} {z} {r} {g} {b} 0.0 1 0\n")

    _log(
        f"COLMAP files written to: {sparse_dir}  "
        f"({written} frames, {N} init points)",
    )
    return True


# ==============================================================================
# 10. BATCH RENDER -- High-Res Screenshot (basic fallback)
# ==============================================================================
#
# For best quality (path-traced rendering with proper anti-aliasing and
# convergence), use Movie Render Queue with your own Path Tracer config.
# This function is a simple drop-in for testing and Lumen-quality datasets.
#
# Tip: before calling this, set the viewport view mode to Path Tracer
#      (Viewport menu -> View Mode -> Path Tracing) so screenshots use it.
#
# Limitations:
#   * Path Tracer convergence sample count is whatever the editor uses for
#     viewport view; that may be lower than what MRQ would give you.
#   * No motion blur control, no console-variable overrides per shot.
#   * Filenames are appended a number suffix by Unreal in some cases; if the
#     filename collides with an existing file, behavior is engine-dependent.

def render_batch_screenshots(
    params: GSCaptureParams,
    cameras: Optional[List[Tuple[unreal.CineCameraActor, int, str]]] = None,
) -> bool:
    """
    Iterate all cameras and take a HighResShot for each.
    Files are named <station4>_<face>.<ext> to match the COLMAP images.txt.
    """
    if not cameras:
        cameras = scan_existing_cameras()
    if not cameras:
        _log_error("No cameras to render.")
        return False
    if not params.output_folder:
        _log_error("output_folder not set.")
        return False

    img_dir = os.path.join(params.output_folder, "images")
    if not _ensure_folder(img_dir):
        _log_error(f"Could not create {img_dir}")
        return False

    total = len(cameras)
    rendered = 0
    failed = 0

    with unreal.ScopedSlowTask(total, "GS_Capture: rendering screenshots...") as task:
        task.make_dialog(True)
        for cam, s_idx, face in cameras:
            if task.should_cancel():
                _log("Cancelled by user.")
                break
            task.enter_progress_frame(1)

            fname = os.path.join(
                img_dir,
                f"{_pad_int(s_idx, 4)}_{face}.{params.img_format}",
            )
            try:
                unreal.AutomationLibrary.take_high_res_screenshot(
                    params.res_w, params.res_h,
                    fname,
                    camera=cam,
                )
                rendered += 1
            except Exception as e:
                _log_warning(f"Screenshot failed for {cam.get_actor_label()}: {e}")
                failed += 1

    _log(f"Done: {rendered} rendered, {failed} failed in {img_dir}/")
    return True


# ==============================================================================
# 11. RUN ALL (convenience wrapper)
# ==============================================================================

def run_all(params: GSCaptureParams, render: bool = False) -> bool:
    """
    Convenience: generate cameras, export COLMAP, and optionally batch-render.

    Args:
        params: configuration.
        render: if True, also renders via high-res screenshots. Default False --
                we recommend rendering via Movie Render Queue manually for v0.1.
    """
    cams = generate_cameras(params)
    if not cams:
        return False

    if not params.output_folder:
        _log_warning("output_folder not set -- skipping COLMAP export.")
        return True

    ok = export_colmap_files(params, cams)
    if not ok:
        return False

    if render:
        render_batch_screenshots(params, cams)
    else:
        _log(
            "Camera generation + COLMAP export done. "
            "Render the dataset via Movie Render Queue (Path Tracer recommended), "
            "or pass render=True to run_all() for a basic HighResShot pass.",
        )
    return True
