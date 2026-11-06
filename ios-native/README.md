# Afterglow, native

The native port of Afterglow for iOS: Swift, SwiftUI for the shell, Metal for the picture and
ARKit for tracking and the camera. It sits beside the Unity app and takes over from it phase by
phase (see "A native port?" in [ROADMAP.md](../ROADMAP.md)). Done so far: **phase 1**, the stereo
rig, head tracking and passthrough, and **phase 2**, hands and pinch. Nothing here touches the
Unity app's code.

## What it does

- **Stereo in one pass.** Both eyes are drawn in a single render pass with Metal's vertex
  amplification into one two-slice texture array (`Renderer.swift`, `Shaders.metal`), then warped
  onto the screen through the viewer's lenses by a 40×40 mesh per eye. The lens geometry is a
  line-for-line port of the Unity app's `LensDistortion.cs` and `ViewerParams.cs` (Cardboard v2
  lenses, k1 0.3358 k2 0.5535, screen-to-lens 39.3 mm, inter-lens 63.9 mm, lenses centred on the
  screen); `AfterglowTests` checks it against the Unity app's logged field of view
  (L60.0 R50.0 B57.6 T57.6). The render scale sets the eye textures' size relative to half the
  screen each.
- **6DoF head tracking** from ARKit world tracking. The camera's pose is for the moment its image
  was taken; the head is predicted ahead to the display link's target time with the gyroscope
  (CoreMotion at 100 Hz, on the clock ARKit shares), and position by the velocity between poses.
  The log scores the prediction every five seconds against the pose that then arrives.
- **Passthrough** from the camera at its true field of view, reprojected by direction as the Unity
  app's shader does, so the room is life size and the picture only moves with head rotation. The
  ultra-wide camera's 60 fps format is used when ARKit lists one; otherwise the wide camera's
  1920×1440 at 60. Both the list and the choice are logged under `[Camera]`.
- **A synthwave surrounding** when passthrough is off: the Unity Home scene's sky (violet to hot
  pink, a striped sun on the horizon, stars, dark hills) and its neon grid, drawn procedurally.
- **The same log lines** as the Unity app, so the two compare line for line: `[Frames]` every 5 s
  (fps, worst frame, late frames, where the CPU time went, GPU time, thermal state), `[Thermal]`
  on each change of iOS's thermal state with the time since launch, `[Pose]`, `[AR]`,
  `[Passthrough]`, `[Stereo]`. Written to `Documents/session.log`, previous run kept as
  `session-previous.log`.

## Phase 2: hands and pinch

- **Hands from Vision** on the Neural Engine (`HandTracker.swift`), the way the Unity app does it
  on the iPhone: each camera image goes to `VNDetectHumanHandPoseRequest`, up to two hands with
  21 joints each, a confidence per joint and which hand it is, at most `handHz` images a second
  (30) and one at a time. The landmarks are placed in 3D by a port of the Unity app's tested
  `HandGeometry.cs`: a flat hand at the learned palm size, fitted to the palm's pixels; where the
  phone has LiDAR, ARKit's scene depth at the palm places the hand where the sensor saw it and
  teaches the palm size for when there is no depth. The joints are smoothed with One Euro filters
  (the Unity app's settings), held for 0.6 s through a missed image, and moved on by the palm's
  speed for the time since their image.
- **Pinch**: the thumb and index tips within 2.5 cm, open again past 4.5 cm for three results in
  a row, never started with a tip at the image's edge, and held as it is while a tip is hidden
  (Vision's confidence under 0.4), since a turning hand hides a fingertip and a guessed tip broke
  the pinch. No pinch starts while the palm is edge-on either (its size at the LiDAR depth under
  60 % of the hand's own flat-on size): with the fingers in line the camera sees only the thumb
  and Vision guesses the index tip beside it. A hand that leaves the view keeps its pinch and
  handedness for five seconds, so a pinch carried out of the camera's view and back is the same
  pinch, and the grab demo keeps the cube until the hand is seen open. A pinch begins only after
  four close results in a row with the tips at the same LiDAR depth (within 2 cm) over the last
  five: a C-shaped hand turned so its tips cross in the image is apart along the camera's axis
  until the crossing, where both tips read the nearer depth, and passes through in less time. Two hands held together come back from Vision as one; the hand it stops reporting
  is kept where it was for two seconds while the other is beside it.
- **Impossible poses dropped**: a result whose palm span changes by more than 40 % against the
  last one 100 ms earlier, whose finger bones change length by over 60 % against their running
  average (more than four of them), or that moves a joint more than 25 cm in that time, is treated
  as a miss and the hand keeps its last pose; after three in a row the result is taken, since the
  hand has really changed. Vision's occasional wrong hand showed as a jump to a pose no hand can
  take.
- **Drawn** as bones and joints over the view, cyan for a left hand and green-tinted for a right,
  the tips magenta while pinching; `showHands 0` hides them. In passthrough the eyes sit at the
  camera (eased over half a second, as the Unity app does), so the hands and anything placed line
  up with the camera image.
- **A grab demo** (`GrabDemo` in `HandOverlay.swift`): a pinch takes the nearest cube within
  8 cm or makes a new one, carries it, and the release leaves it there. Enough to feel the hands
  before the games arrive.
- **Log**: `[Hands]` every five seconds (images/s, Vision's time per image, hands seen and
  tracked, confidence, distance, the palm size and what taught it, pinches, handedness swaps) and
  `[Pinch]` on every pinch and release.

Launch options: `hands` (1), `handHz` (20), `handDepth` (1: the scene depth places the hands and
teaches the palm size), `showHands` (1).

**What the hands cost** (iPhone 18 Pro Max, 2026-11-06, from cold, passthrough on, two hands in
view most of the time): Vision at 30 images/s took 16–18 ms an image on the Neural Engine, the
frame loop stayed at 60.0 fps with 0.0 % late and 1–2 ms of GPU, and the phone went from nominal
to "fair" at 1:43 after launch (the phase 1 run, without hands, stayed nominal). That is the one
steady load the hands add, whether or not a hand is in view, so the default rate is 20 images/s
(the Unity app ran 15); `handHz 30` brings the smoother tracking back.

## 3DoF on the ultra-wide

ARKit's world tracking has no ultra-wide format on the iPhone and stops the moment another
session opens that camera (measured, see `KNOWN_ISSUES.md`), so the ultra-wide's view comes in a
mode of its own: `dof 3` (or the strip's "3DoF ultra-wide" switch, which swaps the source live).
`UltraWideController.swift` runs the ultra-wide through AVFoundation at 1920×1440 and 60 fps,
8-bit full range (a 102° × 86° window in the eye's view against the wide camera's 69° × 55°),
with the intrinsics the capture connection delivers; the head's rotation comes from the motion
sensors (the same attitude the predictor reads, extrapolated to the display time, the first
heading taken as straight ahead), the camera sits at the origin, and the hands run as in 6DoF
but without LiDAR, so they are placed by the flat fit at the learned palm size and the depth
guards on the pinch are off. The 6DoF wide mode (`dof 6`, the default) is unchanged.

## Build and run

```sh
zsh Tools/native_build_and_run.sh                          # build, sign, install, launch, print the log
zsh Tools/native_build_and_run.sh --ei passthrough 1       # with launch options
zsh Tools/native_build_and_run.sh --launch                 # relaunch what is installed
zsh Tools/native_build_and_run.sh --log                    # copy the session log back
zsh Tools/native_build_and_run.sh --test                   # the unit tests, on a simulator
zsh Tools/native_build_and_run.sh --sim --ei dump 4        # run in the iOS Simulator; eye-left.png copied back
AFTERGLOW_DEVICE=iPhone18,2 zsh Tools/native_build_and_run.sh   # a particular phone (here a 17 Pro Max)
```

The Simulator has no ARKit, so there the head stays still and passthrough has no image, but the
stereo rig, the lens warp and the surroundings all draw (one pass per eye, since the Simulator's
Metal has no vertex amplification), and `--ei dump N` saves the left eye's texture N seconds in so
the picture can be checked from the Mac. That, and a second phone named by `AFTERGLOW_DEVICE`,
keep the iPhone 18 Pro Max free for the runs that matter.

The project is generated from `project.yml` by [xcodegen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`); the script regenerates it when the spec is newer. Signing uses the same
team detection as `Tools/ios_build_and_run.sh`. Bundle id `com.wemiller.afterglow.native`, so it
installs beside the Unity app rather than over it. Warnings are errors.

### Launch options

Each `--ei name value` reaches the app as the environment variable `AFTERGLOW_name`; a tap on the
screen shows a control strip for the first four, whose values are kept between runs.

| Option | Default | Meaning |
|---|---|---|
| `passthrough` | 0 | 1 shows the camera, 0 the synthwave surroundings |
| `dof` | 6 | 6: ARKit on the wide camera; 3: the ultra-wide with rotation-only tracking |
| `renderScale` | 100 | eye texture size relative to half the screen, percent (25–200) |
| `fps` | 60 | the display link's rate (30, 60, 90, 120) |
| `predictionMs` | 0 | milliseconds added to the display latency when predicting the head |
| `camUltraWide` | 1 | prefer the ultra-wide camera's format when ARKit lists one |
| `thermalCap` | 1 | hold render scale to 80 % at "serious" and 60 %/30 fps at "critical", as the Unity app does |
| `eyesX`, `eyesY`, `eyesZ` | 60, -10, 66 | the eyes' midpoint relative to the camera, mm, camera axes (x right, y up, z back) |
| `dump` | 0 | save both eyes' textures to `Documents/eye-left.png` and `eye-right.png` this many seconds after launch |
| `ultraTest` | 0 | an experiment: open the ultra-wide through AVFoundation this many seconds in and log what ARKit does (it stops) |
| `cold` | 0 | 1 vouches the phone is cold, so `[Thermal]` times the run from cold despite a recent run |
| `hands`, `handHz`, `handDepth`, `showHands` | 1, 20, 1, 1 | hand tracking on, its image rate, LiDAR depth for the hands, the hands drawn |

## Phase 1 run (iPhone 18 Pro Max, 2026-11-06)

A run from a cold phone with passthrough on (`--ei passthrough 1 --ei cold 1`), off the charger,
the phone lying on the desk: ARKit world tracking, the wide camera at 1920×1440 and 60 fps,
both eyes at 1434×1320 (render scale 100 %), and the lens warp to the 2868×1320 screen. It ran
2:58 before the phone locked (the idle timer was only set once at launch; fixed since), so this is
a three-minute run, not the five intended. Every `[Frames]` line in it reads the same:

| | Native, phase 1 | Unity app, same phone, same day |
|---|---|---|
| Frame rate | 60.0 fps, 0.0 % late, worst 16.7 ms, every 5 s line | 60 fps falling to 36 then 24 fps, 100 % late, once "serious" |
| CPU per frame | 1.2–3.0 ms (main 0.2–0.8, waiting to present 0.8–2.4) | 18–42 ms (main 1–4, waiting to present 16–40) |
| GPU per frame | 1.0–1.3 ms | 1.5–2.6 ms |
| Thermal | nominal for the whole run | fair → serious at 2:02 (warm start); nominal → fair 3:21 → serious 5:30 in the seven-minute run of 2026-11-06 |

Read it for what it is. The native app here runs only the base load: tracking, the camera,
stereo rendering and the lens warp. It runs no hand tracking, no web view, no media, none of
the Unity app's per-frame plugin and scene work, so the table bounds the engine's cost for that
base load and nothing more; a native app skipping a game engine is expected to be cheaper for
it. The numbers are kept as this app's own baseline, so that a later phase that heats the phone
shows against them, rather than as a case to be remade at every step. The Unity figures are from
its session logs of the same day (`KNOWN_ISSUES.md`, "The phone runs hot").

Two shorter runs before it (one to two minutes each, passthrough on and off) read the same, with
one difference worth knowing: in those the loop landed two frames ahead of the display and
"waiting to present" read 15–16 ms a frame, with frames shown 33 ms after the display link's
target; in the three-minute run it landed one frame ahead (16.7 ms after target, 1 ms waits).
Either way the head pose is predicted to the measured moment, and the prediction's error against
the next ARKit pose stays at 0.02–0.05° while the phone is still, against 0.5–1.1° unpredicted
while it moves.

## Layout

```
ios-native/
  project.yml                 xcodegen spec; Afterglow.xcodeproj is generated from it
  Afterglow/App/              AfterglowApp, ContentView (MetalView + control strip), Settings
  Afterglow/Stereo/           ViewerParams, PolynomialRadialDistortion, LensDistortion, ScreenMetrics
  Afterglow/Render/           Renderer, Shaders.metal, ShaderTypes.h
  Afterglow/Tracking/         CameraSource, ARController (6DoF), UltraWideController (3DoF), PosePredictor
  Afterglow/Hands/            HandTracker (Vision), HandGeometry, OneEuroFilter, PinchDetector, HandOverlay + GrabDemo
  Afterglow/Log/              SessionLog, FrameTimingLog, ThermalLog
  AfterglowTests/             the optics against the Unity app's numbers
```
