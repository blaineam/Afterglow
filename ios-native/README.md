# Afterglow, native

The native port of Afterglow for iOS: Swift, SwiftUI for the shell, Metal for the picture and
ARKit for tracking and the camera. It sits beside the Unity app and takes over from it phase by
phase (see "A native port?" in [ROADMAP.md](../ROADMAP.md)). This is **phase 1**: the stereo rig,
head tracking and passthrough. Nothing here touches the Unity app's code.

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

## Build and run

```sh
zsh Tools/native_build_and_run.sh                          # build, sign, install, launch, print the log
zsh Tools/native_build_and_run.sh --ei passthrough 1       # with launch options
zsh Tools/native_build_and_run.sh --launch                 # relaunch what is installed
zsh Tools/native_build_and_run.sh --log                    # copy the session log back
zsh Tools/native_build_and_run.sh --test                   # the unit tests, on a simulator
```

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
| `renderScale` | 100 | eye texture size relative to half the screen, percent (25–200) |
| `fps` | 60 | the display link's rate (30, 60, 90, 120) |
| `predictionMs` | 0 | milliseconds added to the display latency when predicting the head |
| `camUltraWide` | 1 | prefer the ultra-wide camera's format when ARKit lists one |
| `thermalCap` | 1 | hold render scale to 80 % at "serious" and 60 %/30 fps at "critical", as the Unity app does |
| `eyesX`, `eyesY`, `eyesZ` | 60, -10, 66 | the eyes' midpoint relative to the camera, mm, camera axes (x right, y up, z back) |

## Phase 1 run (iPhone 18 Pro Max)

_To be filled from the first five-minute run from a cooled phone._

## Layout

```
ios-native/
  project.yml                 xcodegen spec; Afterglow.xcodeproj is generated from it
  Afterglow/App/              AfterglowApp, ContentView (MetalView + control strip), Settings
  Afterglow/Stereo/           ViewerParams, PolynomialRadialDistortion, LensDistortion, ScreenMetrics
  Afterglow/Render/           Renderer, Shaders.metal, ShaderTypes.h
  Afterglow/Tracking/         ARController (session, formats, camera textures), PosePredictor
  Afterglow/Log/              SessionLog, FrameTimingLog, ThermalLog
  AfterglowTests/             the optics against the Unity app's numbers
```
