/*==============================================================================
  GS_Capture.ms  —  v2.2
  =======================
  Synthetic dataset generator for Gaussian Splatting training,
  from 3ds Max + V-Ray indoor archviz scenes.

  Targets:
    - 3ds Max 2026 (compatible 2022+)
    - V-Ray 7 GPU (CUDA or RTX)
    - Output: COLMAP sparse/0/ format (cameras.txt, images.txt, points3D.txt)
    - Trainers tested: LichtFeld Studio, Brush

  v2.2 changes vs v2.1:
    * World axis convention: now Y-down (COLMAP/LichtFeld native), so the
      splat opens right-side-up in LichtFeld with no post-fix.
      Previous Y-up Nerfstudio convention + external fix_axis utility
      removed. Brush users: the splat will appear flipped vertically,
      orbit the camera to compensate.
    * points3D.txt: now generates 50 000 random points spanning the scene
      bounding box. LichtFeld refuses to load datasets with empty
      points3D.txt; this makes the export usable out-of-the-box.
    * Auto-recenter: X and Z only (the two horizontal axes in Max).
      The Max Z axis (vertical, ground = 0) is preserved, so the splat
      keeps its floor at world Y=0 in LichtFeld.
    * transforms.json (Nerfstudio) export removed — was unused in our
      pipeline. Use COLMAP for everything.

  v2.1 changes vs v2.0:
    * Smart cubemap: on multi-Z layer setups, the lowest layer skips the
      "down" face and the highest layer skips the "up" face. Saves ~16%
      render time on 3+ layers with no quality loss for archviz indoor.
    * Auto-recenter on export: camera centroid → origin. Required for
      GS trainers to converge on far-from-origin CAD scenes.

  v2 changes vs v1:
    * Volume placement mode: pick a Box/Dummy/object as bounding volume,
      generate a 3D grid of stations inside.
    * Cubemap camera mode: 6 cardinal-direction cameras per station,
      wide FOV with overlap.
    * Wall-distance raycast: auto-skip stations too close to geometry.
    * Multi-Z layers: sample at multiple heights inside the volume.
    * Spline placement + custom yaw/pitch retained as alternative modes.

  Output structure:
      <outputFolder>/
        images/
          0001_front.png   (cubemap mode, <station>_<face>.png)
          0001_back.png
          ...
          OR
          00001.png        (custom mode, sequential index)
          ...
        sparse/0/
          cameras.txt      (OPENCV intrinsics)
          images.txt       (extrinsics, Y-down world / OpenCV camera)
          points3D.txt     (50k random init points)
==============================================================================*/


/*----------------------------------------------------------------------------
  0. PARAMS STRUCT
----------------------------------------------------------------------------*/

struct GSC_ParamsStruct (
    -- placement
    placementMode,           -- "volume" or "spline"
    volumeObj,
    gridX, gridY,
    zLayerCount,
    splineSpacing,
    eyeHeight,
    jitterPos,

    -- wall avoidance
    avoidWalls,
    minWallDist,

    -- camera mode
    cameraMode,              -- "cubemap" or "custom"
    cubeFaces,               -- 6 booleans, F/B/L/R/U/D
    smartCubemap,
    yawCount,
    pitchList,
    jitterAng,

    -- lens
    focalMM, sensorMM,
    nearClip, farClip,

    -- render
    resW, resH,
    imgFormat,
    resumeIfExists,

    -- output
    outputFolder,
    seed
)


/*----------------------------------------------------------------------------
  1. GLOBALS
----------------------------------------------------------------------------*/

global GSC_cameras       = #()
global GSC_camMeta       = #()
global GSC_inputSplines  = #()
global GSC_volumeObj     = undefined
global GSC_outputFolder  = ""
global GSC_dialog        = undefined


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

-- Axis-fix: Max world (Z-up, right-handed) -> COLMAP world (Y-down).
-- Mapping: (x, y, z)_max -> (x, -z, y)_colmap
--
-- Equivalent to: gscAxisFix v2.1 (Max Z-up -> Nerfstudio Y-up) followed by
-- a 180-degree rotation around the X axis (the fix_axis_for_lichtfeld.py
-- utility, now obsolete). The result is the convention LichtFeld Studio
-- expects natively, so the splat opens right-side-up with no post-processing.
fn gscMaxToColmapWorld = (
    matrix3 [1, 0, 0] [0, 0, 1] [0, -1, 0] [0, 0, 0]
)

-- Convert a Max camera-to-world matrix into COLMAP camera-to-world
-- (world is Y-down, camera is still OpenGL-local at this stage —
-- the OpenCV camera flip is applied later).
fn gscMaxCamToColmap maxTM = (
    maxTM * gscMaxToColmapWorld()
)

-- OpenGL -> OpenCV camera-frame flip.
-- OpenGL: +X right, +Y up,   -Z forward
-- OpenCV: +X right, -Y up,   +Z forward   (COLMAP convention)
-- Apply as: c2w_cv = opencvFlip * c2w_gl  (MaxScript row-vector convention)
fn gscOpenCVFlip = (
    matrix3 [1, 0, 0] [0, -1, 0] [0, 0, -1] [0, 0, 0]
)

-- Convert a 3x3 rotation (top-left of a matrix3) to a quaternion
-- (qw, qx, qy, qz). Uses Shepperd's branched method for numerical stability.
-- The output works as-is in COLMAP images.txt.
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

fn gscGetSceneGeometry = (
    local geo = #()
    for o in geometry do (
        if not o.isHidden and not o.isFrozen then (
            local lyr = o.layer
            if lyr == undefined or lyr.name != "GS_Capture_Cameras" then (
                append geo o
            )
        )
    )
    geo
)

fn gscIsStationValid pos minDist sceneGeo = (
    local dirs = #(
        [ 1, 0, 0], [-1, 0, 0],
        [ 0, 1, 0], [ 0,-1, 0],
        [ 0, 0, 1], [ 0, 0,-1],
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
  5. SPLINE SAMPLING (legacy mode)
----------------------------------------------------------------------------*/

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
  6. VOLUME-BASED STATION GENERATION
----------------------------------------------------------------------------*/

fn gscGetWorldBBox obj = (
    local bb = nodeGetBoundingBox obj (matrix3 1)
    #(bb[1], bb[2])
)

-- Returns array of 3-tuples: #(point3 position, integer layerIdx, integer totalLayers).
fn gscGenerateStationsFromVolume params = (
    local stations = #()
    if params.volumeObj == undefined then return stations

    local bb = gscGetWorldBBox params.volumeObj
    local minP = bb[1]
    local maxP = bb[2]

    local sx = if params.gridX > 0.001 then params.gridX else 100.0
    local sy = if params.gridY > 0.001 then params.gridY else 100.0
    local nx = ((maxP.x - minP.x) / sx) as integer
    local ny = ((maxP.y - minP.y) / sy) as integer
    if nx < 1 then nx = 1
    if ny < 1 then ny = 1

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

    local sceneGeo = if params.avoidWalls then gscGetSceneGeometry() else #()
    local skippedWall = 0
    local skippedPerLayer = #()
    for i = 1 to nz do append skippedPerLayer 0

    for iz = 1 to nz do (
        local z = zLayers[iz]
        for iy = 0 to ny do (
            local y = minP.y + iy * sy
            if iy == ny then y = maxP.y
            for ix = 0 to nx do (
                local x = minP.x + ix * sx
                if ix == nx then x = maxP.x

                local p = [x, y, z]

                if params.jitterPos > 0 then (
                    p = p + [gscJitter params.jitterPos, gscJitter params.jitterPos, 0]
                )

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

-- 6 cardinal directions in Max world (Z-up).
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

fn gscFocalToHFOV focalMM sensorWidthMM = (
    2.0 * atan(sensorWidthMM / (2.0 * focalMM))
)

fn gscMakeCamera camName pos lookDir hfov nearclip farclip parentLayer = (
    local cam = Freecamera fov:hfov nearclip:nearclip farclip:farclip name:camName

    local zAxis = normalize (-lookDir)
    local worldUp = [0, 0, 1]

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


-- Rebuild GSC_cameras + GSC_camMeta from existing nodes in the
-- GS_Capture_Cameras layer. Useful after a Max restart so Render and Export
-- work without forcing a full re-Generate.
fn gscScanExistingCameras = (
    local lyr = LayerManager.getLayerFromName "GS_Capture_Cameras"
    if lyr == undefined then return 0

    local nodes = #()
    lyr.nodes &nodes

    local foundCams = #()
    for n in nodes do (
        if (superclassof n == Camera) then append foundCams n
    )
    if foundCams.count == 0 then return 0

    qsort foundCams (fn cmpByName a b = (
        if a.name < b.name then -1 else (if a.name > b.name then 1 else 0)
    ))

    GSC_cameras = #()
    GSC_camMeta = #()

    for n in foundCams do (
        local parts = filterString n.name "_"
        if parts.count >= 3 then (
            local stationIdx = parts[2] as integer
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

    gscDeleteGeneratedCameras()
    seed (params.seed)

    local lyr = gscGetLayer()
    local hfov = gscFocalToHFOV params.focalMM params.sensorMM
    local idx = 0
    local stationIdx = 0

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

    progressStart "GS_Capture generating cameras..."

    for sIdx = 1 to stations.count while (not getProgressCancel()) do (
        stationIdx = sIdx
        local pos = undefined
        local tan = [0, 1, 0]
        local layerIdx = 0
        local totalLayers = 0

        if hasTangents then (
            pos = stations[sIdx][1]
            tan = stations[sIdx][2]
        ) else (
            pos = stations[sIdx][1]
            layerIdx = stations[sIdx][2]
            totalLayers = stations[sIdx][3]
        )

        if params.cameraMode == "cubemap" then (
            local dirs = gscCubemapDirs()

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
  14. COLMAP EXPORT
----------------------------------------------------------------------------*/

-- Generate COLMAP-format sparse reconstruction files into <outputFolder>/sparse/0/:
--   cameras.txt   - intrinsics (OPENCV model, single shared camera)
--   images.txt    - extrinsics (quaternion + translation in COLMAP convention)
--   points3D.txt  - 50 000 random init points spanning the scene bounding box
--                   (LichtFeld refuses to load datasets with an empty points3D)
--
-- Coordinate conversion chain:
--   1. cam.transform (Max world Z-up, OpenGL local) * gscMaxToColmapWorld()
--      -> c2w with world Y-down (COLMAP/LichtFeld native), camera still OpenGL.
--   2. cvFlip * c2w -> camera switched to OpenCV local.
--   3. Apply centroid recenter to translation. We recenter the two horizontal
--      axes only (X and Z in the new world, = X and Y in Max). The vertical
--      axis (Y in new world, = Z in Max) is preserved so Max's ground plane
--      Z=0 stays at world Y=0 in the splat.
--   4. w2c = inverse(c2w_cv)
--   5. Decompose w2c into quaternion (qw, qx, qy, qz) and translation.
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

    local sparseDir = params.outputFolder + "\\sparse\\0"
    gscEnsureFolder (params.outputFolder + "\\sparse")
    gscEnsureFolder sparseDir

    -- Compute recenter centroid (X and Z only — Y is vertical, preserved)
    local centroidX = 0.0
    local centroidZ = 0.0
    local nValid = 0
    for cam in GSC_cameras do (
        if isValidNode cam then (
            local c2wNew = gscMaxCamToColmap cam.transform
            centroidX += c2wNew.row4.x
            centroidZ += c2wNew.row4.z
            nValid += 1
        )
    )
    if nValid > 0 then (
        centroidX /= nValid
        centroidZ /= nValid
    )
    gscLog ("Auto-recenter (horizontal only, vertical preserved): centroid (X=" + \
            (centroidX as string) + ", Z=" + (centroidZ as string) + ") -> origin.")

    -- === cameras.txt ===
    local camPath = sparseDir + "\\cameras.txt"
    local cFile = createFile camPath
    if cFile == undefined then (
        messageBox ("Could not write " + camPath) title:"GS_Capture"
        return false
    )
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
    -- Also collect recentered camera positions for the points3D scale estimate.
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
    local maxAbsX = 0.0; local maxAbsY = 0.0; local maxAbsZ = 0.0

    for i = 1 to GSC_cameras.count do (
        local cam = GSC_cameras[i]
        if isValidNode cam then (
            local c2wNew = gscMaxCamToColmap cam.transform
            local c2wCv = cvFlip * c2wNew

            c2wCv.row4 = [c2wCv.row4.x - centroidX, \
                          c2wCv.row4.y, \
                          c2wCv.row4.z - centroidZ]

            -- Track recentered camera position bbox (for points3D scale)
            local px = c2wCv.row4.x; local py = c2wCv.row4.y; local pz = c2wCv.row4.z
            if (abs px) > maxAbsX then maxAbsX = abs px
            if (abs py) > maxAbsY then maxAbsY = abs py
            if (abs pz) > maxAbsZ then maxAbsZ = abs pz

            local w2c = inverse c2wCv

            local q = gscRotMatToQuat w2c
            local qw = q[1]; local qx = q[2]; local qy = q[3]; local qz = q[4]
            local tx = w2c.row4.x; local ty = w2c.row4.y; local tz = w2c.row4.z

            local meta = GSC_camMeta[i]
            local imgName
            if params.cameraMode == "cubemap" then (
                imgName = (padInt meta[1] 4) + "_" + meta[2] + "." + params.imgFormat
            ) else (
                imgName = (padInt i 5) + "." + params.imgFormat
            )

            format "% % % % % % % % 1 %\n" \
                i qw qx qy qz tx ty tz imgName to:iFile
            format "\n" to:iFile    -- empty POINTS2D line (required by COLMAP)
            writtenCount += 1
        )
    )
    close iFile

    -- === points3D.txt (50k random init points) ===
    -- LichtFeld refuses to load datasets where points3D.txt has "Number of points: 0".
    -- Trainers use these points as the initial Gaussian seed positions.
    -- We span a cube ~1.5x the recentered camera bbox; the trainer prunes irrelevant
    -- points during training, so over-spanning is harmless.
    local boxHalfX = maxAbsX * 1.5
    local boxHalfY = maxAbsY * 1.5
    local boxHalfZ = maxAbsZ * 1.5
    local boxHalf = amax #(boxHalfX, boxHalfY, boxHalfZ)
    if boxHalf < 100.0 then boxHalf = 500.0
    gscLog ("points3D scene scale: +/-" + (boxHalf as string) + " units, generating 50000 points...")

    local N = 50000
    seed 12345
    local sb = stringStream ""
    format "# 3D point list with one line of data per point:\n" to:sb
    format "#   POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[] as (IMAGE_ID, POINT2D_IDX)\n" to:sb
    format "# Number of points: %\n" N to:sb
    for i = 1 to N do (
        local x = (random -1.0 1.0) * boxHalf
        local y = (random -1.0 1.0) * boxHalf
        local z = (random -1.0 1.0) * boxHalf
        local r = random 80 175
        local g = random 80 175
        local b = random 80 175
        format "% % % % % % % 0.0 1 0\n" i x y z r g b to:sb
    )
    local pPath = sparseDir + "\\points3D.txt"
    local pFile = createFile pPath
    if pFile == undefined then (
        messageBox ("Could not write " + pPath) title:"GS_Capture"
        return false
    )
    format "%" (sb as string) to:pFile
    close pFile

    gscLog ("COLMAP files written to: " + sparseDir + "  (" + (writtenCount as string) + " frames, " + (N as string) + " init points)")
    messageBox ("COLMAP files exported to:\n" + sparseDir + "\n\n" + \
                "Drop the parent folder (containing 'images/' and 'sparse/') into LichtFeld / Brush.") \
               title:"GS_Capture"
    true
)


/*----------------------------------------------------------------------------
  15. UI ROLLOUT
----------------------------------------------------------------------------*/

try (destroyDialog GSC_rollout) catch ()

rollout GSC_rollout "GS Capture v2.2  —  Gaussian Splatting Dataset Generator" \
                    width:430 height:800 (

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
        spinner spnFocal  "Focal length (mm) - 14mm = 104deg HFOV (cubemap default)" \
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
        button btnExportColmap "3) Export COLMAP files" width:380 height:24
        button btnRunAll      "RUN ALL (1 + 2 + 3)"     width:380 height:30
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
        local smartSavings = 0

        if rdoCamera.state == 1 then (
            for f in #(chkFront.checked, chkBack.checked, chkLeft.checked, \
                       chkRight.checked, chkUp.checked, chkDown.checked) do (
                if f then nPer += 1
            )
            if chkSmartCube.checked and spnZLayers.value >= 2 then (
                if chkDown.checked then smartSavings += 1
                if chkUp.checked then smartSavings += 1
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
            local totalCams = totalStations * nPer - stationsPerLayer * smartSavings
            lblTotalEst.text = "Estimate: " + stationsEst + " stations x ~" + (nPer as string) + \
                                " cams = ~" + (totalCams as string) + " cameras" + \
                                (if smartSavings > 0 then \
                                    (" (smart cubemap saves ~" + ((stationsPerLayer * smartSavings) as string) + ")") \
                                 else "")
        ) else (
            lblTotalEst.text = "Cams per station: " + (nPer as string) + \
                                " - Generated: " + (GSC_cameras.count as string)
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
            lblSplines.text = "(no splines in selection - select splines first)"
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

    on btnExportColmap pressed do (
        local p = buildParams()
        gscExportColmapFiles p
    )

    on btnRunAll pressed do (
        local p = buildParams()

        -- Resume-after-restart logic: if cameras already exist in the scene
        -- and no fresh input has been picked, skip Generate.
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
