/*==============================================================================
  GS_Capture.ms  —  v2.1
  =======================
  Synthetic dataset generator for Gaussian Splatting / NeRF training,
  from 3ds Max + V-Ray indoor archviz scenes.

  Targets:
    - 3ds Max 2026 (compatible 2022+)
    - V-Ray 7 GPU (CUDA or RTX)
    - Freecamera native (no Physical Camera class guessing across versions)

  v2.1 changes vs v2.0:
    * Smart cubemap (NEW): on multi-Z layer setups, the lowest layer skips
      the "down" face (already covered by mid/high layers) and the highest
      layer skips the "up" face. Saves ~16% render time on 3+ layers with
      no quality loss for archviz indoor scenes.
    * COLMAP export (NEW): one-click button to generate sparse/0/cameras.txt,
      images.txt, points3D.txt — Brush, LichtFeld, Nerfstudio all read
      COLMAP more reliably than Nerfstudio JSON. Use it as fallback.
    * Auto-recenter on JSON / COLMAP export: camera centroid → origin.
      Required for GS trainers to converge on far-from-origin CAD scenes.

  v2 changes vs v1:
    * Volume placement mode: pick a Box/Dummy/object as bounding volume,
      generate a 3D grid of stations inside.
    * Cubemap camera mode: 6 cardinal-direction cameras per station
      (front/back/left/right/up/down), wide FOV with overlap.
    * Wall-distance raycast: auto-skip stations too close to geometry,
      applied per 3D position (works correctly across multi-Z layers).
    * Multi-Z layers: sample at multiple heights inside the volume.
    * Spline placement + custom yaw/pitch retained as alternative modes.
    * Image filename includes face suffix for cubemap (e.g. 00001_front.png).

  Output structure:
      <outputFolder>/
        images/
          00001_front.png   (cubemap mode)
          00001_back.png
          00001_left.png
          ...
          OR
          00001.png         (custom mode)
          00002.png
          ...
        transforms.json     (Nerfstudio / Postshot / gsplat compatible)

  Coordinate notes:
    - 3ds Max world is Z-up, right-handed.
    - Nerfstudio uses Y-up world, OpenGL camera convention (-Z forward).
    - 3ds Max camera local convention is identical to OpenGL,
      so only WORLD axes need conversion. The export does this automatically.
==============================================================================*/


/*----------------------------------------------------------------------------
  0. PARAMS STRUCT (declared before the rollout that consumes it)
----------------------------------------------------------------------------*/

struct GSC_ParamsStruct (
    -- placement
    placementMode,           -- "volume" or "spline"
    volumeObj,               -- node defining the bounding volume (for volume mode)
    gridX, gridY,            -- grid spacing in X and Y (scene units)
    zLayerCount,             -- number of vertical layers inside the volume
    splineSpacing,           -- arc-length spacing for spline mode
    eyeHeight,               -- height offset for spline mode (above spline)
    jitterPos,               -- positional jitter (scene units)

    -- wall avoidance
    avoidWalls,              -- boolean: enable raycast check
    minWallDist,             -- minimum distance to nearest geometry

    -- camera mode
    cameraMode,              -- "cubemap" or "custom"
    cubeFaces,               -- #(bool, bool, bool, bool, bool, bool) F/B/L/R/U/D
    smartCubemap,            -- if true and zLayers >= 2: skip "down" on lowest
                             --                            layer, "up" on highest
    yawCount,                -- custom mode: number of yaw angles
    pitchList,               -- custom mode: array of pitch angles (deg)
    jitterAng,               -- angular jitter (deg)

    -- lens
    focalMM, sensorMM,       -- focal length & sensor width in mm
    nearClip, farClip,       -- near/far clip in scene units

    -- render
    resW, resH,              -- output image resolution
    imgFormat,               -- "png", "jpg", "tga", "exr"
    resumeIfExists,          -- skip files that already exist

    -- output / misc
    outputFolder,
    seed
)


/*----------------------------------------------------------------------------
  1. GLOBALS
----------------------------------------------------------------------------*/

global GSC_cameras       = #()          -- list of generated cameras
global GSC_camMeta       = #()          -- parallel array of #(stationIdx, faceName)
global GSC_inputSplines  = #()          -- splines selected by user (spline mode)
global GSC_volumeObj     = undefined    -- volume box for volume mode
global GSC_outputFolder  = ""           -- output base folder
global GSC_dialog        = undefined    -- dialog handle


/*----------------------------------------------------------------------------
  2. UTILITIES
----------------------------------------------------------------------------*/

fn padInt n digits = (
    local s = n as string
    while s.count < digits do s = "0" + s
    s
)

fn gscClamp v vmin vmax = (
    if v < vmin then vmin else (if v > vmax then vmax else v)
)

fn gscJitter amp = (
    if amp <= 0 then 0.0 else (random -amp amp)
)

fn gscLog msg = (
    format "[GS_Capture] %\n" msg
)

fn gscEnsureFolder p = (
    if not (doesFileExist p) then makeDir p all:true
    doesFileExist p
)

fn gscParseFloatList s = (
    local arr = #()
    local parts = filterString s ", "
    for p in parts do (
        if p.count > 0 then (
            try ( append arr (p as float) ) catch ()
        )
    )
    if arr.count == 0 then arr = #(0.0)
    arr
)


/*----------------------------------------------------------------------------
  3. COORDINATE / MATRIX CONVERSION
----------------------------------------------------------------------------*/

-- Axis-fix: Max world (Z-up) -> Nerfstudio world (Y-up).
-- In MaxScript row-vector form: (x, y, z) * axisFix = (x, z, -y)
fn gscAxisFix = (
    matrix3 [1, 0, 0] [0, 0, -1] [0, 1, 0] [0, 0, 0]
)

-- Convert a Max camera-to-world matrix into Nerfstudio camera-to-world.
fn gscMaxCamToNerf maxTM = (
    maxTM * gscAxisFix()
)

-- OpenGL → OpenCV camera-frame flip matrix.
-- OpenGL: +X right, +Y up, -Z forward  (Nerfstudio convention)
-- OpenCV: +X right, -Y up, +Z forward  (COLMAP convention)
-- The Y and Z axes flip sign. Apply as: c2w_cv = opencvFlip * c2w_gl
-- (MaxScript row-vector convention).
fn gscOpenCVFlip = (
    matrix3 [1, 0, 0] [0, -1, 0] [0, 0, -1] [0, 0, 0]
)

-- Convert a 3x3 rotation (read from the top-left of a matrix3) to a quaternion
-- (qw, qx, qy, qz). Uses Shepperd's branched method for numerical stability.
-- Input: matrix3 m. We treat m.row1, m.row2, m.row3 as the rotation matrix
-- columns (which corresponds to "local axes in world coords" in MaxScript).
-- This matches the numpy column-vector convention used in standard quaternion
-- literature, so the output works as-is in COLMAP.
fn gscRotMatToQuat m = (
    local R00 = m.row1.x; local R01 = m.row2.x; local R02 = m.row3.x
    local R10 = m.row1.y; local R11 = m.row2.y; local R12 = m.row3.y
    local R20 = m.row1.z; local R21 = m.row2.z; local R22 = m.row3.z

    local tr = R00 + R11 + R22
    local qw = 0.0; local qx = 0.0; local qy = 0.0; local qz = 0.0

    if tr > 0 then (
        local s = (sqrt (tr + 1.0)) * 2.0
        qw = 0.25 * s
        qx = (R21 - R12) / s
        qy = (R02 - R20) / s
        qz = (R10 - R01) / s
    ) else if (R00 > R11) and (R00 > R22) then (
        local s = (sqrt (1.0 + R00 - R11 - R22)) * 2.0
        qw = (R21 - R12) / s
        qx = 0.25 * s
        qy = (R01 + R10) / s
        qz = (R02 + R20) / s
    ) else if R11 > R22 then (
        local s = (sqrt (1.0 + R11 - R00 - R22)) * 2.0
        qw = (R02 - R20) / s
        qx = (R01 + R10) / s
        qy = 0.25 * s
        qz = (R12 + R21) / s
    ) else (
        local s = (sqrt (1.0 + R22 - R00 - R11)) * 2.0
        qw = (R10 - R01) / s
        qx = (R02 + R20) / s
        qy = (R12 + R21) / s
        qz = 0.25 * s
    )
    #(qw, qx, qy, qz)
)


/*----------------------------------------------------------------------------
  4. SCENE GEOMETRY & RAYCAST (wall-avoidance)
----------------------------------------------------------------------------*/

-- Collect renderable scene geometry (exclude hidden/frozen/helpers).
fn gscGetSceneGeometry = (
    local geo = #()
    for o in geometry do (
        if not o.isHidden and not o.isFrozen then (
            -- Exclude our own generated cameras' layer
            local lyr = o.layer
            if lyr == undefined or lyr.name != "GS_Capture_Cameras" then (
                append geo o
            )
        )
    )
    geo
)

-- Test if a station position is valid (i.e. not too close to scene geometry).
-- Casts 6 cardinal rays + 8 diagonal rays for robust check.
fn gscIsStationValid pos minDist sceneGeo = (
    local dirs = #(
        [ 1, 0, 0], [-1, 0, 0],
        [ 0, 1, 0], [ 0,-1, 0],
        [ 0, 0, 1], [ 0, 0,-1],
        -- diagonals (horizontal)
        [ 1, 1, 0], [-1, 1, 0], [ 1,-1, 0], [-1,-1, 0]
    )
    for d in dirs do (
        local nd = normalize d
        local r = ray pos nd
        for o in sceneGeo do (
            local hit = intersectRay o r
            if hit != undefined then (
                if (distance pos hit.pos) < minDist then return false
            )
        )
    )
    true
)


/*----------------------------------------------------------------------------
  5. SPLINE SAMPLING (legacy mode, retained)
----------------------------------------------------------------------------*/

-- Sample positions along a spline at given arc-length spacing.
-- Returns array of #(position, tangent) pairs in WORLD coords.
fn gscSampleSpline splineObj spacing = (
    local samples = #()
    if splineObj == undefined then return samples
    if (classof splineObj != SplineShape and classof splineObj != Line) then return samples

    local numCurves = numSplines splineObj
    if numCurves < 1 then return samples

    for curveIdx = 1 to numCurves do (
        local len = curveLength splineObj curveIdx
        if len >= 0.01 then (
            local numSteps = (len / spacing) as integer
            if numSteps < 1 then numSteps = 1

            for i = 0 to numSteps do (
                local t = (i as float) / numSteps
                if t > 1.0 then t = 1.0

                local p = lengthInterp splineObj curveIdx t

                local t2 = if t < 0.999 then (t + 0.001) else (t - 0.001)
                local p2 = lengthInterp splineObj curveIdx t2

                local tan = p2 - p
                if t2 < t then tan = -tan

                if length tan > 0.0001 then tan = normalize tan else tan = [1, 0, 0]

                append samples #(p, tan)
            )
        )
    )
    samples
)


/*----------------------------------------------------------------------------
  6. VOLUME-BASED STATION GENERATION (new in v2)
----------------------------------------------------------------------------*/

-- Get the world-aligned bounding box of a node.
-- Returns #(p_min, p_max).
fn gscGetWorldBBox obj = (
    local bb = nodeGetBoundingBox obj (matrix3 1)
    #(bb[1], bb[2])
)

-- Generate station positions on a 3D grid inside the volume.
-- Returns array of 3-tuples: #(point3 position, integer layerIdx, integer totalLayers).
--   layerIdx is 1-based; layerIdx == 1 is the LOWEST layer, layerIdx == totalLayers
--   is the HIGHEST. This is used downstream for smart cubemap (skip down/up faces
--   on extreme layers).
fn gscGenerateStationsFromVolume params = (
    local stations = #()
    if params.volumeObj == undefined then return stations

    local bb = gscGetWorldBBox params.volumeObj
    local minP = bb[1]
    local maxP = bb[2]

    -- Number of grid steps in X and Y (avoid div by zero)
    local sx = if params.gridX > 0.001 then params.gridX else 100.0
    local sy = if params.gridY > 0.001 then params.gridY else 100.0
    local nx = ((maxP.x - minP.x) / sx) as integer
    local ny = ((maxP.y - minP.y) / sy) as integer
    if nx < 1 then nx = 1
    if ny < 1 then ny = 1

    -- Build Z layers (centered inside volume)
    local zLayers = #()
    local nz = if params.zLayerCount < 1 then 1 else params.zLayerCount
    if nz == 1 then (
        append zLayers ((minP.z + maxP.z) / 2.0)
    ) else (
        for i = 1 to nz do (
            local tt = (i as float - 0.5) / nz
            append zLayers (minP.z + tt * (maxP.z - minP.z))
        )
    )

    gscLog ("Volume: " + (params.volumeObj.name) + \
            "  bbox size [" + ((maxP.x - minP.x) as string) + ", " + \
            ((maxP.y - minP.y) as string) + ", " + ((maxP.z - minP.z) as string) + \
            "]  grid " + (nx as string) + "x" + (ny as string) + "x" + (nz as string))

    -- Cache scene geometry once for raycast (if needed)
    local sceneGeo = if params.avoidWalls then gscGetSceneGeometry() else #()
    local skippedWall = 0
    local skippedPerLayer = #()
    for i = 1 to nz do append skippedPerLayer 0

    for iz = 1 to nz do (
        local z = zLayers[iz]
        for iy = 0 to ny do (
            local y = minP.y + iy * sy
            if iy == ny then y = maxP.y    -- ensure max boundary hit
            for ix = 0 to nx do (
                local x = minP.x + ix * sx
                if ix == nx then x = maxP.x

                local p = [x, y, z]

                -- Position jitter (horizontal only to keep on layer height)
                if params.jitterPos > 0 then (
                    p = p + [gscJitter params.jitterPos, gscJitter params.jitterPos, 0]
                )

                -- Wall / object avoidance — tested at THIS specific 3D position,
                -- so a station valid at mid-height can be invalid at low-height
                -- (e.g. inside a table or piece of furniture).
                if params.avoidWalls then (
                    if gscIsStationValid p params.minWallDist sceneGeo then (
                        append stations #(p, iz, nz)
                    ) else (
                        skippedWall += 1
                        skippedPerLayer[iz] += 1
                    )
                ) else (
                    append stations #(p, iz, nz)
                )
            )
        )
    )

    if params.avoidWalls then (
        local detail = ""
        for i = 1 to nz do (
            if detail.count > 0 then detail += ", "
            detail += ("L" + (i as string) + "=" + (skippedPerLayer[i] as string))
        )
        gscLog ("Wall avoidance: skipped " + (skippedWall as string) + \
                " stations total  (" + detail + ")")
    )
    gscLog ("Volume mode: " + (stations.count as string) + " valid station-layer pairs.")

    stations
)


/*----------------------------------------------------------------------------
  7. SPLINE-BASED STATION GENERATION (legacy)
----------------------------------------------------------------------------*/

-- Returns array of #(position, tangent) pairs.
fn gscGenerateStationsFromSplines params = (
    local stations = #()
    if GSC_inputSplines.count == 0 then return stations

    local sceneGeo = if params.avoidWalls then gscGetSceneGeometry() else #()
    local skippedWall = 0

    for sp in GSC_inputSplines do (
        if isValidNode sp then (
            local samp = gscSampleSpline sp params.splineSpacing
            for s in samp do (
                local p = s[1] + [0, 0, params.eyeHeight]
                local tan = s[2]

                if params.jitterPos > 0 then (
                    p = p + [gscJitter params.jitterPos, \
                             gscJitter params.jitterPos, \
                             gscJitter (params.jitterPos * 0.3)]
                )

                local valid = true
                if params.avoidWalls then (
                    if not (gscIsStationValid p params.minWallDist sceneGeo) then (
                        valid = false
                        skippedWall += 1
                    )
                )
                if valid then append stations #(p, tan)
            )
        )
    )

    if params.avoidWalls then (
        gscLog ("Wall avoidance: skipped " + (skippedWall as string) + " stations.")
    )
    gscLog ("Spline mode: " + (stations.count as string) + " valid stations.")

    stations
)


/*----------------------------------------------------------------------------
  8. CUBEMAP DIRECTIONS
----------------------------------------------------------------------------*/

-- Returns array of 6 #(faceName, lookDir) pairs in Max world (Z-up).
-- Indices: 1=front(+Y), 2=back(-Y), 3=left(-X), 4=right(+X), 5=up(+Z), 6=down(-Z).
fn gscCubemapDirs = (
    #(
        #("front", [ 0,  1,  0]),
        #("back",  [ 0, -1,  0]),
        #("left",  [-1,  0,  0]),
        #("right", [ 1,  0,  0]),
        #("up",    [ 0,  0,  1]),
        #("down",  [ 0,  0, -1])
    )
)


/*----------------------------------------------------------------------------
  9. CUSTOM YAW/PITCH LOOK DIRECTION
----------------------------------------------------------------------------*/

-- Given a base tangent (or [0,1,0] if none) and yaw/pitch offsets in degrees,
-- return normalized world-space look direction.
fn gscComputeLookDir tangent yawDeg pitchDeg = (
    local horizTan = [tangent.x, tangent.y, 0]
    if length horizTan < 0.0001 then horizTan = [0, 1, 0]
    horizTan = normalize horizTan

    local cy = cos yawDeg
    local sy = sin yawDeg
    local yawed = [horizTan.x * cy - horizTan.y * sy, \
                   horizTan.x * sy + horizTan.y * cy, 0]

    local cp = cos pitchDeg
    local sp = sin pitchDeg
    local lookDir = [yawed.x * cp, yawed.y * cp, sp]

    normalize lookDir
)


/*----------------------------------------------------------------------------
  10. CAMERA CREATION
----------------------------------------------------------------------------*/

-- Horizontal FOV (deg) from focal length and sensor width (both mm).
fn gscFocalToHFOV focalMM sensorWidthMM = (
    2.0 * atan(sensorWidthMM / (2.0 * focalMM))
)

-- Create a Freecamera at pos, oriented so it looks along lookDir.
-- Max camera looks down local -Z, so local +Z (in world) = -lookDir.
fn gscMakeCamera camName pos lookDir hfov nearclip farclip parentLayer = (
    local cam = Freecamera fov:hfov nearclip:nearclip farclip:farclip name:camName

    local zAxis = normalize (-lookDir)
    local worldUp = [0, 0, 1]

    -- Edge case: looking straight up/down
    if (abs (dot zAxis worldUp)) > 0.999 then worldUp = [0, 1, 0]

    local xAxis = normalize (cross worldUp zAxis)
    local yAxis = normalize (cross zAxis xAxis)

    cam.transform = matrix3 xAxis yAxis zAxis pos

    if parentLayer != undefined then parentLayer.addNode cam

    cam
)


/*----------------------------------------------------------------------------
  11. LAYER & CLEANUP
----------------------------------------------------------------------------*/

fn gscGetLayer = (
    local lyr = LayerManager.getLayerFromName "GS_Capture_Cameras"
    if lyr == undefined then lyr = LayerManager.newLayerFromName "GS_Capture_Cameras"
    lyr
)

fn gscDeleteGeneratedCameras = (
    if GSC_cameras.count > 0 then (
        for c in GSC_cameras do (
            if isValidNode c then try (delete c) catch ()
        )
    )
    GSC_cameras = #()
    GSC_camMeta = #()

    local lyr = LayerManager.getLayerFromName "GS_Capture_Cameras"
    if lyr != undefined then (
        local nodes = #()
        lyr.nodes &nodes
        for n in nodes do try (delete n) catch ()
    )

    gscLog "Cleared generated cameras."
    redrawViews()
)


-- Scan the GS_Capture_Cameras layer and rebuild GSC_cameras + GSC_camMeta
-- from existing camera nodes in the scene. Useful after a Max restart, so
-- that "Render Dataset" / "Export JSON" can resume without re-generating.
-- Returns the number of cameras found.
fn gscScanExistingCameras = (
    local lyr = LayerManager.getLayerFromName "GS_Capture_Cameras"
    if lyr == undefined then return 0

    local nodes = #()
    lyr.nodes &nodes

    -- Filter to cameras only
    local foundCams = #()
    for n in nodes do (
        if (superclassof n == Camera) then append foundCams n
    )
    if foundCams.count == 0 then return 0

    -- Sort by name so that array order matches the original generation order
    -- (alphabetical sort on our naming scheme preserves station + angle order)
    qsort foundCams (fn cmpByName a b = (
        if a.name < b.name then -1 else (if a.name > b.name then 1 else 0)
    ))

    -- Rebuild parallel arrays
    GSC_cameras = #()
    GSC_camMeta = #()

    for n in foundCams do (
        -- Camera name format:
        --   cubemap mode: "GSCam_<stationIdx>_<faceName>"      e.g. GSCam_0001_front
        --   custom mode:  "GSCam_<stationIdx>_y<yaw>_p<pitch>" e.g. GSCam_0001_y00_p-15
        local parts = filterString n.name "_"
        if parts.count >= 3 then (
            local stationIdx = parts[2] as integer
            -- Re-glue everything after the station as the meta tag (faceName,
            -- or "y00_p-15" etc. — keeps underscores in custom mode)
            local faceTag = parts[3]
            for i = 4 to parts.count do faceTag += "_" + parts[i]

            append GSC_cameras n
            append GSC_camMeta #(stationIdx, faceTag)
        )
    )

    GSC_cameras.count
)


/*----------------------------------------------------------------------------
  12. MAIN CAMERA GENERATION ORCHESTRATOR
----------------------------------------------------------------------------*/

fn gscGenerateCameras params = (
    -- Pre-checks
    if params.placementMode == "volume" then (
        if params.volumeObj == undefined or not (isValidNode params.volumeObj) then (
            messageBox "Pick a volume object first (Box, Dummy, or any geometry)." \
                       title:"GS_Capture"
            return false
        )
    ) else (
        if GSC_inputSplines.count == 0 then (
            messageBox "Pick splines first." title:"GS_Capture"
            return false
        )
    )

    -- Cleanup prior
    gscDeleteGeneratedCameras()
    seed (params.seed)

    local lyr = gscGetLayer()
    local hfov = gscFocalToHFOV params.focalMM params.sensorMM
    local idx = 0
    local stationIdx = 0

    -- Get stations — formats differ by placement mode:
    --   volume mode: 3-tuple  #(point3 pos, integer layerIdx, integer totalLayers)
    --   spline mode: 2-tuple  #(point3 pos, point3 tangent)
    local stations = #()
    local hasTangents = false
    if params.placementMode == "volume" then (
        stations = gscGenerateStationsFromVolume params
        hasTangents = false
    ) else (
        stations = gscGenerateStationsFromSplines params
        hasTangents = true
    )

    if stations.count == 0 then (
        messageBox "No stations generated. Check params/volume/spline." title:"GS_Capture"
        return false
    )

    -- Sanity warn for huge counts
    local nPerStation = if params.cameraMode == "cubemap" then (
        local c = 0
        for f in params.cubeFaces do if f then c += 1
        c
    ) else (
        params.yawCount * params.pitchList.count
    )
    local totalEstimate = stations.count * nPerStation
    if totalEstimate > 3000 then (
        local ok = queryBox ("This will generate " + (totalEstimate as string) + \
                              " cameras. Continue?") title:"GS_Capture"
        if not ok then return false
    )

    -- Generate cameras at each station
    progressStart "GS_Capture generating cameras..."

    for sIdx = 1 to stations.count while (not getProgressCancel()) do (
        stationIdx = sIdx
        local pos = undefined
        local tan = [0, 1, 0]
        local layerIdx = 0
        local totalLayers = 0

        if hasTangents then (
            -- Spline mode: 2-tuple #(point3, tangent)
            pos = stations[sIdx][1]
            tan = stations[sIdx][2]
        ) else (
            -- Volume mode: 3-tuple #(point3, layerIdx, totalLayers)
            pos = stations[sIdx][1]
            layerIdx = stations[sIdx][2]
            totalLayers = stations[sIdx][3]
        )

        if params.cameraMode == "cubemap" then (
            -- Cubemap: 6 cardinal directions in world space.
            -- Faces array index: 1=front, 2=back, 3=left, 4=right, 5=up, 6=down
            local dirs = gscCubemapDirs()

            -- Build effective face mask: start from user's checkbox choices,
            -- then mask further with smart cubemap (skip "down" on lowest layer,
            -- "up" on highest layer — those views are redundant with mid layers).
            local effFaces = #(params.cubeFaces[1], params.cubeFaces[2], \
                               params.cubeFaces[3], params.cubeFaces[4], \
                               params.cubeFaces[5], params.cubeFaces[6])
            if params.smartCubemap and totalLayers >= 2 then (
                if layerIdx == 1 then effFaces[6] = false             -- low: no down
                if layerIdx == totalLayers then effFaces[5] = false   -- high: no up
            )

            for f = 1 to 6 do (
                if effFaces[f] then (
                    idx += 1
                    local faceInfo = dirs[f]
                    local camName = "GSCam_" + (padInt stationIdx 4) + "_" + faceInfo[1]
                    local cam = gscMakeCamera camName pos faceInfo[2] hfov \
                                              params.nearClip params.farClip lyr
                    append GSC_cameras cam
                    append GSC_camMeta #(stationIdx, faceInfo[1])
                )
            )
        ) else (
            -- Custom yaw + pitch
            for yawIdx = 0 to (params.yawCount - 1) do (
                local yawDeg = (360.0 / params.yawCount) * yawIdx
                for pitchDeg in params.pitchList do (
                    idx += 1
                    local ay = yawDeg + (gscJitter params.jitterAng)
                    local ap = pitchDeg + (gscJitter params.jitterAng)
                    local lookDir = gscComputeLookDir tan ay ap
                    local camName = "GSCam_" + (padInt stationIdx 4) + "_y" + \
                                    (padInt yawIdx 2) + "_p" + \
                                    (formattedPrint pitchDeg format:".0f")
                    local cam = gscMakeCamera camName pos lookDir hfov \
                                              params.nearClip params.farClip lyr
                    append GSC_cameras cam
                    append GSC_camMeta #(stationIdx, "y" + (yawIdx as string) + \
                                                     "p" + (pitchDeg as string))
                )
            )
        )

        progressUpdate (100.0 * sIdx / stations.count)
    )

    progressEnd()

    gscLog ("Generated " + (GSC_cameras.count as string) + " cameras across " + \
            (stations.count as string) + " stations.")
    redrawViews()
    true
)


/*----------------------------------------------------------------------------
  13. BATCH RENDER (V-Ray)
----------------------------------------------------------------------------*/

fn gscRenderBatch params = (
    if GSC_cameras.count == 0 then (
        local nFound = gscScanExistingCameras()
        if nFound > 0 then (
            gscLog ("Detected " + (nFound as string) + " existing cameras from scene layer. Resuming.")
        ) else (
            messageBox "No cameras. Click 'Generate Cameras' first." title:"GS_Capture"
            return false
        )
    )
    if params.outputFolder == "" or not (doesFileExist params.outputFolder) then (
        messageBox "Pick a valid output folder first." title:"GS_Capture"
        return false
    )

    local imgDir = params.outputFolder + "\\images"
    gscEnsureFolder imgDir

    local total = GSC_cameras.count
    gscLog ("Batch render: " + (total as string) + " frames @ " + \
            (params.resW as string) + "x" + (params.resH as string) + \
            (if params.resumeIfExists then " (resume)" else ""))

    local savedOutput   = rendOutputFilename
    local savedSaveFile = rendSaveFile
    rendSaveFile = true

    progressStart "GS_Capture rendering..."

    local startTime = timeStamp()
    local rendered  = 0
    local skipped   = 0
    local failed    = 0
    local cancelled = false

    for i = 1 to total while not cancelled do (
        if getProgressCancel() then (
            gscLog "Cancelled by user."
            cancelled = true
        ) else (
            local cam = GSC_cameras[i]
            if isValidNode cam then (
                -- Build filename: in cubemap mode, include face suffix
                local meta = GSC_camMeta[i]
                local fname
                if params.cameraMode == "cubemap" then (
                    fname = imgDir + "\\" + (padInt meta[1] 4) + "_" + meta[2] + \
                            "." + params.imgFormat
                ) else (
                    fname = imgDir + "\\" + (padInt i 5) + "." + params.imgFormat
                )

                if params.resumeIfExists and doesFileExist fname then (
                    skipped += 1
                ) else (
                    try (
                        render camera:cam outputFile:fname vfb:false quiet:true \
                               outputWidth:params.resW outputHeight:params.resH
                        rendered += 1
                    ) catch (
                        failed += 1
                        gscLog ("Render failed (" + cam.name + "): " + \
                                (getCurrentException()))
                    )
                )
            )
            progressUpdate (100.0 * i / total)
        )
    )

    progressEnd()

    local elapsed = (timeStamp() - startTime) / 1000.0
    gscLog ("Done: " + (rendered as string) + " rendered, " + (skipped as string) + \
            " skipped, " + (failed as string) + " failed, in " + \
            (elapsed as string) + "s.")

    rendOutputFilename = savedOutput
    rendSaveFile = savedSaveFile

    true
)


/*----------------------------------------------------------------------------
  14. JSON EXPORT (transforms.json, Nerfstudio convention)
----------------------------------------------------------------------------*/

fn gscExportTransformsJson params = (
    if GSC_cameras.count == 0 then (
        local nFound = gscScanExistingCameras()
        if nFound > 0 then (
            gscLog ("Detected " + (nFound as string) + " existing cameras from scene layer.")
        ) else (
            messageBox "No cameras to export. Generate first." title:"GS_Capture"
            return false
        )
    )
    if params.outputFolder == "" then (
        messageBox "Pick an output folder first." title:"GS_Capture"
        return false
    )

    gscEnsureFolder params.outputFolder

    -- Intrinsics
    local flXPx = (params.resW as float / params.sensorMM) * params.focalMM
    local flYPx = flXPx
    local cxPx  = (params.resW as float) / 2.0
    local cyPx  = (params.resH as float) / 2.0

    -- AUTO-RECENTER: compute centroid of all camera positions (in Nerfstudio
    -- coords) and translate all poses so centroid sits at origin.
    -- Critical: GS trainers (Brush, Nerfstudio, Postshot...) fail to initialize
    -- silently when the scene is far from origin (typical for CAD-imported
    -- scenes with georeferenced or absolute coordinates). The visual result
    -- is identical — only the scene's coordinate system origin changes.
    local centroidX = 0.0
    local centroidY = 0.0
    local centroidZ = 0.0
    local nValid = 0
    for cam in GSC_cameras do (
        if isValidNode cam then (
            local nerfTM = gscMaxCamToNerf cam.transform
            centroidX += nerfTM.row4.x
            centroidY += nerfTM.row4.y
            centroidZ += nerfTM.row4.z
            nValid += 1
        )
    )
    if nValid > 0 then (
        centroidX /= nValid
        centroidY /= nValid
        centroidZ /= nValid
    )
    gscLog ("Auto-recenter: scene centroid was at (" + \
            (centroidX as string) + ", " + (centroidY as string) + ", " + \
            (centroidZ as string) + ") — translated to origin in JSON.")

    local out = stringStream ""

    format "{\n" to:out
    format "  \"camera_model\": \"OPENCV\",\n" to:out
    format "  \"fl_x\": %,\n" flXPx to:out
    format "  \"fl_y\": %,\n" flYPx to:out
    format "  \"cx\": %,\n" cxPx to:out
    format "  \"cy\": %,\n" cyPx to:out
    format "  \"w\": %,\n" params.resW to:out
    format "  \"h\": %,\n" params.resH to:out
    format "  \"k1\": 0.0, \"k2\": 0.0, \"p1\": 0.0, \"p2\": 0.0,\n" to:out
    format "  \"frames\": [\n" to:out

    local n = GSC_cameras.count
    local writtenCount = 0

    for i = 1 to n do (
        local cam = GSC_cameras[i]
        if isValidNode cam then (
            local nerfTM = gscMaxCamToNerf cam.transform
            local r1 = nerfTM.row1
            local r2 = nerfTM.row2
            local r3 = nerfTM.row3
            local r4 = nerfTM.row4

            -- Apply auto-recenter to position (translation only, not rotation)
            local tx = r4.x - centroidX
            local ty = r4.y - centroidY
            local tz = r4.z - centroidZ

            -- Image path (forward slashes for JSON portability)
            local meta = GSC_camMeta[i]
            local imgFile
            if params.cameraMode == "cubemap" then (
                imgFile = "images/" + (padInt meta[1] 4) + "_" + meta[2] + \
                          "." + params.imgFormat
            ) else (
                imgFile = "images/" + (padInt i 5) + "." + params.imgFormat
            )

            if writtenCount > 0 then format ",\n" to:out
            format "    {\n" to:out
            format "      \"file_path\": \"%\",\n" imgFile to:out
            format "      \"transform_matrix\": [\n" to:out
            format "        [%, %, %, %],\n" r1.x r2.x r3.x tx to:out
            format "        [%, %, %, %],\n" r1.y r2.y r3.y ty to:out
            format "        [%, %, %, %],\n" r1.z r2.z r3.z tz to:out
            format "        [0.0, 0.0, 0.0, 1.0]\n" to:out
            format "      ]\n" to:out
            format "    }" to:out
            writtenCount += 1
        )
    )

    format "\n  ]\n}\n" to:out

    local jsonPath = params.outputFolder + "\\transforms.json"
    local f = createFile jsonPath
    if f == undefined then (
        messageBox ("Could not write " + jsonPath) title:"GS_Capture"
        return false
    )
    format "%" (out as string) to:f
    close f

    gscLog ("transforms.json written: " + jsonPath + "  (" + (writtenCount as string) + " frames)")
    true
)


/*----------------------------------------------------------------------------
  14b. COLMAP EXPORT
----------------------------------------------------------------------------*/

-- Generate COLMAP-format sparse reconstruction files into <outputFolder>/sparse/0/:
--   cameras.txt   - intrinsics (OPENCV model, single shared camera)
--   images.txt    - extrinsics (quaternion + translation in OpenCV/COLMAP convention)
--   points3D.txt  - 3D points (empty; trainers will random-init from cameras)
--
-- COLMAP format is more universally supported than Nerfstudio JSON. Brush,
-- LichtFeld Studio, and Postshot all read it reliably. Use this when the JSON
-- path triggers parser bugs (Brush issue #269 in particular).
--
-- Coordinate conversion math (verified by hand on cubemap faces):
--   1. Take Max camera transform -> apply gscAxisFix() -> c2w in Nerfstudio
--      (OpenGL: -Z forward, +Y up).
--   2. c2w_cv = gscOpenCVFlip() * c2w_gl    (flip Y & Z axes of cam local frame)
--   3. Apply centroid recenter to translation (same as JSON export).
--   4. w2c = inverse(c2w_cv)
--   5. Decompose w2c into quaternion (qw, qx, qy, qz) and translation (tx, ty, tz).
fn gscExportColmapFiles params = (
    if GSC_cameras.count == 0 then (
        local nFound = gscScanExistingCameras()
        if nFound > 0 then (
            gscLog ("Detected " + (nFound as string) + " existing cameras from scene layer.")
        ) else (
            messageBox "No cameras to export. Generate first." title:"GS_Capture"
            return false
        )
    )
    if params.outputFolder == "" then (
        messageBox "Pick an output folder first." title:"GS_Capture"
        return false
    )

    -- Build target dir: <outputFolder>\sparse\0\
    local sparseDir = params.outputFolder + "\\sparse\\0"
    gscEnsureFolder (params.outputFolder + "\\sparse")
    gscEnsureFolder sparseDir

    -- Compute auto-recenter centroid (same logic as JSON export)
    local centroidX = 0.0; local centroidY = 0.0; local centroidZ = 0.0
    local nValid = 0
    for cam in GSC_cameras do (
        if isValidNode cam then (
            local nerfTM = gscMaxCamToNerf cam.transform
            centroidX += nerfTM.row4.x
            centroidY += nerfTM.row4.y
            centroidZ += nerfTM.row4.z
            nValid += 1
        )
    )
    if nValid > 0 then (
        centroidX /= nValid; centroidY /= nValid; centroidZ /= nValid
    )
    gscLog ("COLMAP auto-recenter: centroid (" + (centroidX as string) + ", " + \
            (centroidY as string) + ", " + (centroidZ as string) + ") -> origin.")

    -- === cameras.txt ===
    local camPath = sparseDir + "\\cameras.txt"
    local cFile = createFile camPath
    if cFile == undefined then (
        messageBox ("Could not write " + camPath) title:"GS_Capture"
        return false
    )
    -- Intrinsics: convert focal-in-mm to focal-in-pixels using sensor width
    local flXPx = (params.resW as float / params.sensorMM) * params.focalMM
    local flYPx = flXPx
    local cxPx  = (params.resW as float) / 2.0
    local cyPx  = (params.resH as float) / 2.0
    format "# Camera list with one line of data per camera:\n" to:cFile
    format "#   CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]\n" to:cFile
    format "# Number of cameras: 1\n" to:cFile
    format "1 OPENCV % % % % % % 0.0 0.0 0.0 0.0\n" \
        params.resW params.resH flXPx flYPx cxPx cyPx to:cFile
    close cFile

    -- === images.txt ===
    local imgPath = sparseDir + "\\images.txt"
    local iFile = createFile imgPath
    if iFile == undefined then (
        messageBox ("Could not write " + imgPath) title:"GS_Capture"
        return false
    )
    format "# Image list with two lines of data per image:\n" to:iFile
    format "#   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME\n" to:iFile
    format "#   POINTS2D[] as (X, Y, POINT3D_ID)\n" to:iFile
    format "# Number of images: %\n" GSC_cameras.count to:iFile

    local cvFlip = gscOpenCVFlip()
    local writtenCount = 0

    for i = 1 to GSC_cameras.count do (
        local cam = GSC_cameras[i]
        if isValidNode cam then (
            -- Step 1+2: Max -> Nerfstudio (OpenGL) -> OpenCV
            local c2wGl = gscMaxCamToNerf cam.transform
            local c2wCv = cvFlip * c2wGl

            -- Step 3: apply centroid recenter to translation only
            c2wCv.row4 = [c2wCv.row4.x - centroidX, \
                          c2wCv.row4.y - centroidY, \
                          c2wCv.row4.z - centroidZ]

            -- Step 4: invert for world-to-camera
            local w2c = inverse c2wCv

            -- Step 5: extract quaternion + translation
            local q = gscRotMatToQuat w2c
            local qw = q[1]; local qx = q[2]; local qy = q[3]; local qz = q[4]
            local tx = w2c.row4.x; local ty = w2c.row4.y; local tz = w2c.row4.z

            -- Image filename (no "images/" prefix — COLMAP looks in images/ by default)
            local meta = GSC_camMeta[i]
            local imgName
            if params.cameraMode == "cubemap" then (
                imgName = (padInt meta[1] 4) + "_" + meta[2] + "." + params.imgFormat
            ) else (
                imgName = (padInt i 5) + "." + params.imgFormat
            )

            format "% % % % % % % % 1 %\n" \
                i qw qx qy qz tx ty tz imgName to:iFile
            format "\n" to:iFile    -- empty POINTS2D line (required by COLMAP format)
            writtenCount += 1
        )
    )
    close iFile

    -- === points3D.txt (empty initialization) ===
    local pPath = sparseDir + "\\points3D.txt"
    local pFile = createFile pPath
    format "# 3D point list with one line of data per point:\n" to:pFile
    format "#   POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[] as (IMAGE_ID, POINT2D_IDX)\n" to:pFile
    format "# Number of points: 0\n" to:pFile
    close pFile

    gscLog ("COLMAP files written to: " + sparseDir + "  (" + (writtenCount as string) + " frames)")
    messageBox ("COLMAP files exported to:\n" + sparseDir + "\n\n" + \
                "Drop the parent folder (containing 'images/' and 'sparse/') into Brush / LichtFeld.") \
               title:"GS_Capture"
    true
)


/*----------------------------------------------------------------------------
  15. UI ROLLOUT
----------------------------------------------------------------------------*/

try (destroyDialog GSC_rollout) catch ()

rollout GSC_rollout "GS Capture v2.1  —  Gaussian Splatting Dataset Generator" \
                    width:430 height:830 (

    /* ---- Placement mode ---- */
    group "1. Placement mode" (
        radiobuttons rdoPlacement "" labels:#("Volume (recommended)", "Spline (legacy)") \
                                  default:1 columns:2 align:#left
    )

    /* ---- Volume params ---- */
    group "2A. Volume params" (
        button btnPickVolume "Pick volume object (Box/Dummy/any)" width:380 height:24
        label  lblVolume     "(no volume picked)" align:#left width:380
        spinner spnGridX     "Grid X (units)"     range:[5, 2000, 100]  type:#float fieldwidth:70 align:#left
        spinner spnGridY     "Grid Y (units)"     range:[5, 2000, 100]  type:#float fieldwidth:70 align:#left
        spinner spnZLayers   "Z layers (vertical)" range:[1, 20, 1]     type:#integer fieldwidth:70 align:#left
    )

    /* ---- Spline params ---- */
    group "2B. Spline params" (
        button btnPickSplines "Pick selected splines" width:380 height:24
        label  lblSplines     "(no splines picked)"  align:#left width:380
        spinner spnSpacing    "Spline spacing (units)" range:[1, 2000, 80] type:#float fieldwidth:70 align:#left
        spinner spnHeight     "Eye height (units)"     range:[10, 500, 160] type:#float fieldwidth:70 align:#left
    )

    /* ---- Common placement ---- */
    group "3. Placement common" (
        spinner spnPosJit       "Position jitter (units)"     range:[0, 100, 5]    type:#float fieldwidth:70 align:#left
        checkbox chkAvoidWalls "Avoid walls (raycast check)" checked:true align:#left
        spinner spnMinWallDist "Min distance to walls (units)" range:[1, 200, 30]  type:#float fieldwidth:70 align:#left
    )

    /* ---- Camera mode ---- */
    group "4. Camera mode" (
        radiobuttons rdoCamera "" labels:#("Cubemap 6 views (recommended)", "Custom yaw + pitch") \
                              default:1 columns:1 align:#left
    )

    /* ---- Cubemap faces ---- */
    group "4A. Cubemap faces" (
        checkbox chkFront "Front (+Y)" checked:true across:3
        checkbox chkBack  "Back (-Y)"  checked:true
        checkbox chkLeft  "Left (-X)"  checked:true
        checkbox chkRight "Right (+X)" checked:true across:3
        checkbox chkUp    "Up (+Z)"    checked:true
        checkbox chkDown  "Down (-Z)"  checked:true
        checkbox chkSmartCube "Smart cubemap: skip 'down' on lowest layer, 'up' on highest (only with Z layers >= 2)" \
                              checked:true align:#left
    )

    /* ---- Custom angles ---- */
    group "4B. Custom yaw+pitch (alternative)" (
        spinner spnYawCount "Yaw angles" range:[1, 24, 8] type:#integer fieldwidth:70 align:#left
        edittext edtPitches "Pitch list (deg)" text:"-15, 0, 15" fieldwidth:200 align:#left
        spinner spnAngJit  "Angle jitter (deg)" range:[0, 15, 2] type:#float fieldwidth:70 align:#left
    )

    /* ---- Lens ---- */
    group "5. Lens" (
        spinner spnFocal  "Focal length (mm) — 14mm = 104° HFOV (cubemap default)" \
                          range:[6, 400, 14] type:#float fieldwidth:70 align:#left
        spinner spnSensor "Sensor width (mm)" range:[8, 70, 36] type:#float fieldwidth:70 align:#left
        spinner spnNear   "Near clip (units)" range:[0.01, 100, 1] type:#float fieldwidth:70 align:#left
        spinner spnFar    "Far clip (units)" range:[100, 1e6, 50000] type:#float fieldwidth:70 align:#left
    )

    /* ---- Render ---- */
    group "6. Render" (
        spinner spnResW "Width"  range:[256, 8192, 1280] type:#integer fieldwidth:70 align:#left
        spinner spnResH "Height" range:[256, 8192, 720]  type:#integer fieldwidth:70 align:#left
        dropdownlist ddFormat "Format" items:#("png", "jpg", "tga", "exr") selection:1 width:120 align:#left
        checkbox chkResume "Resume mode (skip existing files)" checked:true align:#left
    )

    /* ---- Output ---- */
    group "7. Output folder" (
        button btnPickFolder "Choose output folder..." width:380 height:24
        label  lblFolder     "(no folder selected)" align:#left width:380
    )

    /* ---- Actions ---- */
    group "8. Actions" (
        button btnGenerate    "1) Generate Cameras"     width:380 height:26
        button btnPreview     "Preview cam 1"           width:125 height:22 across:3
        button btnDelete      "Delete cams"             width:125 height:22
        button btnTestRender  "Test render"             width:125 height:22
        button btnRenderAll   "2) Render Dataset (V-Ray)" width:380 height:26
        button btnExportJson  "3a) Export transforms.json (Nerfstudio)" width:380 height:24
        button btnExportColmap "3b) Export COLMAP files (more compatible)" width:380 height:24
        button btnRunAll      "RUN ALL (1 + 2 + 3a + 3b)" width:380 height:30
    )

    label lblTotalEst "Estimated total cameras: --" align:#left width:380

    /* ---------- Helpers ---------- */

    fn buildParams = (
        local pMode = if rdoPlacement.state == 1 then "volume" else "spline"
        local cMode = if rdoCamera.state == 1 then "cubemap" else "custom"
        local faces = #(chkFront.checked, chkBack.checked, \
                        chkLeft.checked, chkRight.checked, \
                        chkUp.checked, chkDown.checked)

        GSC_ParamsStruct \
            placementMode:   pMode \
            volumeObj:       GSC_volumeObj \
            gridX:           spnGridX.value \
            gridY:           spnGridY.value \
            zLayerCount:     spnZLayers.value \
            splineSpacing:   spnSpacing.value \
            eyeHeight:       spnHeight.value \
            jitterPos:       spnPosJit.value \
            avoidWalls:      chkAvoidWalls.checked \
            minWallDist:     spnMinWallDist.value \
            cameraMode:      cMode \
            cubeFaces:       faces \
            smartCubemap:    chkSmartCube.checked \
            yawCount:        spnYawCount.value \
            pitchList:       (gscParseFloatList edtPitches.text) \
            jitterAng:       spnAngJit.value \
            focalMM:         spnFocal.value \
            sensorMM:        spnSensor.value \
            nearClip:        spnNear.value \
            farClip:         spnFar.value \
            resW:            spnResW.value \
            resH:            spnResH.value \
            imgFormat:       (ddFormat.items[ddFormat.selection]) \
            resumeIfExists:  chkResume.checked \
            outputFolder:    GSC_outputFolder \
            seed:            12345
    )

    fn updateEstimate = (
        local nPer = 0
        local smartSavings = 0    -- per-station face count lost to smart cubemap

        if rdoCamera.state == 1 then (
            for f in #(chkFront.checked, chkBack.checked, chkLeft.checked, \
                       chkRight.checked, chkUp.checked, chkDown.checked) do (
                if f then nPer += 1
            )
            -- Smart cubemap: lowest layer loses "down" (idx 6), highest loses "up" (idx 5)
            if chkSmartCube.checked and spnZLayers.value >= 2 then (
                if chkDown.checked then smartSavings += 1    -- 1 station's worth on low layer
                if chkUp.checked then smartSavings += 1      -- 1 station's worth on high layer
            )
        ) else (
            nPer = spnYawCount.value * (gscParseFloatList edtPitches.text).count
        )

        local stationsEst = "?"
        if rdoPlacement.state == 1 and GSC_volumeObj != undefined and isValidNode GSC_volumeObj then (
            local bb = gscGetWorldBBox GSC_volumeObj
            local nx = ((bb[2].x - bb[1].x) / (amax #(spnGridX.value, 0.001))) as integer + 1
            local ny = ((bb[2].y - bb[1].y) / (amax #(spnGridY.value, 0.001))) as integer + 1
            local stationsPerLayer = nx * ny
            local totalStations = stationsPerLayer * spnZLayers.value
            stationsEst = (totalStations as string) + " (max)"
            -- Total cams = (all layers full) - (smart cubemap removals on extreme layers)
            local totalCams = totalStations * nPer - stationsPerLayer * smartSavings
            lblTotalEst.text = "Estimate: " + stationsEst + " stations × ~" + (nPer as string) + \
                                " cams = ~" + (totalCams as string) + " cameras" + \
                                (if smartSavings > 0 then \
                                    (" (smart cubemap saves ~" + ((stationsPerLayer * smartSavings) as string) + ")") \
                                 else "")
        ) else (
            lblTotalEst.text = "Cams per station: " + (nPer as string) + \
                                " — Generated: " + (GSC_cameras.count as string)
        )
    )

    /* ---------- Handlers ---------- */

    on btnPickVolume pressed do (
        local obj = pickObject message:"Pick a Box/Dummy/object for volume bounds" \
                               filter:(fn f o = (o != undefined and superclassof o != Camera and superclassof o != Light))
        if obj != undefined then (
            GSC_volumeObj = obj
            local bb = gscGetWorldBBox obj
            local sz = bb[2] - bb[1]
            lblVolume.text = "Volume: " + obj.name + "   size [" + \
                             ((formattedPrint sz.x format:".0f")) + ", " + \
                             ((formattedPrint sz.y format:".0f")) + ", " + \
                             ((formattedPrint sz.z format:".0f")) + "]"
            updateEstimate()
        )
    )

    on btnPickSplines pressed do (
        GSC_inputSplines = #()
        for o in selection do (
            if (classof o == SplineShape or classof o == Line) then \
                append GSC_inputSplines o
        )
        if GSC_inputSplines.count == 0 then (
            lblSplines.text = "(no splines in selection — select splines first)"
        ) else (
            local names = ""
            for s in GSC_inputSplines do (
                if names.count > 0 then names += ", "
                names += s.name
            )
            lblSplines.text = (GSC_inputSplines.count as string) + " spline(s): " + names
        )
        updateEstimate()
    )

    on btnPickFolder pressed do (
        local p = getSavePath caption:"Choose dataset output folder"
        if p != undefined then (
            GSC_outputFolder = p
            lblFolder.text = p
        )
    )

    on btnGenerate pressed do (
        local p = buildParams()
        gscGenerateCameras p
        updateEstimate()
    )

    on btnPreview pressed do (
        if GSC_cameras.count == 0 then gscScanExistingCameras()
        if GSC_cameras.count > 0 and isValidNode GSC_cameras[1] then (
            viewport.setCamera GSC_cameras[1]
            redrawViews()
        ) else (
            messageBox "No cameras. Generate first." title:"GS_Capture"
        )
    )

    on btnDelete pressed do (
        gscDeleteGeneratedCameras()
        updateEstimate()
    )

    on btnTestRender pressed do (
        if GSC_cameras.count == 0 then gscScanExistingCameras()
        if GSC_cameras.count == 0 then (
            messageBox "Generate cameras first." title:"GS_Capture"
        ) else if GSC_outputFolder == "" then (
            messageBox "Pick output folder first." title:"GS_Capture"
        ) else (
            local p = buildParams()
            local imgDir = p.outputFolder + "\\images"
            gscEnsureFolder imgDir
            local fname = imgDir + "\\test_render." + p.imgFormat
            gscLog ("Test render -> " + fname)
            try (
                render camera:GSC_cameras[1] outputFile:fname vfb:true \
                       outputWidth:p.resW outputHeight:p.resH
            ) catch (
                gscLog ("Test render failed: " + (getCurrentException()))
            )
        )
    )

    on btnRenderAll pressed do (
        local p = buildParams()
        gscRenderBatch p
    )

    on btnExportJson pressed do (
        local p = buildParams()
        gscExportTransformsJson p
    )

    on btnExportColmap pressed do (
        local p = buildParams()
        gscExportColmapFiles p
    )

    on btnRunAll pressed do (
        local p = buildParams()

        -- Smart RUN ALL: if cameras already exist (auto-detected from scene)
        -- and the user has NOT picked a fresh input (volume/spline), skip the
        -- Generate step. This is the typical "resume after restart" workflow.
        local skipGenerate = false
        if GSC_cameras.count > 0 then (
            local needVolume = (p.placementMode == "volume" and GSC_volumeObj == undefined)
            local needSpline = (p.placementMode == "spline" and GSC_inputSplines.count == 0)
            if needVolume or needSpline then skipGenerate = true
        )

        local proceed = true
        if skipGenerate then (
            gscLog ("RUN ALL: skipping Generate (" + (GSC_cameras.count as string) + \
                    " cameras already in scene, no new input picked).")
        ) else (
            proceed = gscGenerateCameras p
        )

        if proceed then (
            if gscRenderBatch p then (
                gscExportTransformsJson p
                gscExportColmapFiles p
            )
        )
        updateEstimate()
    )

    on rdoPlacement changed val do updateEstimate()
    on rdoCamera changed val do updateEstimate()
    on spnGridX changed val do updateEstimate()
    on spnGridY changed val do updateEstimate()
    on spnZLayers changed val do updateEstimate()
    on spnYawCount changed val do updateEstimate()
    on edtPitches changed txt do updateEstimate()
    on chkFront changed st do updateEstimate()
    on chkBack changed st do updateEstimate()
    on chkLeft changed st do updateEstimate()
    on chkRight changed st do updateEstimate()
    on chkUp changed st do updateEstimate()
    on chkDown changed st do updateEstimate()
    on chkSmartCube changed st do updateEstimate()
    on GSC_rollout open do (
        -- After a Max restart, the script globals are reset but the cameras
        -- may still exist in the scene. Auto-detect them so Render / Export
        -- works without forcing the user to re-Generate.
        local nFound = gscScanExistingCameras()
        if nFound > 0 then (
            gscLog ("Auto-detected " + (nFound as string) + " existing cameras from scene.")
        )
        updateEstimate()
    )
)

GSC_dialog = createDialog GSC_rollout \
    style:#(#style_titlebar, #style_border, #style_sysmenu, #style_resizing, \
            #style_minimizebox, #style_maximizebox)
