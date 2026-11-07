# Known issues

## Both platforms

- **The browser's two crosshairs disagree.** The gaze reticle (the ring the app draws at the
  centre of each eye) and the page's own crosshair (the dot the helper script draws where the
  app says the gaze is) sit a little apart on the window, the page's higher, and a tap lands
  where the page's dot is. Seen in the Simulator 2026-11-06 (desk mode, 3DoF); the mapping from
  the gaze hit on the quad to page coordinates (`TryGazePoint`, `PageV`) is where to look. Aim by
  the page's dot until then.

- **Hands weren't found on the phone (2026-11-06; fixed the same day with Vision, confirmed on the phone).**
  The first device run since the two-hands change (2026-11-03) showed the palm detector finding
  a hand only now and then and the landmarker scoring it 0.13 presence, under the 0.5 it needs,
  so every hand was dropped at once and no pinch was ever seen; taps and the floating buttons
  still worked. On the iPhone the hands are now found by Apple's Vision hand pose on the Neural
  Engine (`AfterglowHandPose.mm`, `VisionHandPose.cs`): it sees both hands in the whole image
  with 21 landmarks each, its confidence is the presence and its chirality the handedness, and
  the MediaPipe landmarker only gives each hand its 3D shape, fitted to Vision's landmarks. The
  palm detector, the CPU's 30–50 ms per run, no longer runs; `handModel 1` brings it back for
  comparison. The crop dumps found the original fault: the orientation read off ARKit's display
  matrix (built for a portrait screen) had Vision turn an image that is upright in the viewer as
  it comes, and Vision reports points in the turned frame, so every landmark was mirrored across
  the image and the landmarker's crop held the room beside the hand. Upright, on an iPhone 18
  Pro Max: Vision 5 ms and the landmarker 20 ms per image, 15 images/s, presence 0.72–0.84, the
  shape fitting at 11–18 px, the hand placed 0.26–0.41 m away, pinches reaching the Home panel.
  `handOrientation N` turns the image if a phone ever needs it, `handDump N` still writes the
  image and the crops, and *Show tracked hands* in Settings draws the joints over the camera
  image to see how the tracking follows. In a WebXR page the hand came and went about once a
  second (107 input-source changes in a session) and its handedness swapped 21 times, which a
  page saw as two controllers jumping about and a pinch that never ended: the tracker now
  keeps a hand Vision misses for up to 0.3 s, blends handedness over results, and the page
  keeps a source for 0.35 s after the app stops sending it (2026-11-06, to be confirmed). That overlay showed the joints turned a quarter from
  the real hand: the joints were placed along image axes read off the same portrait-built
  matrix. They now follow passthrough's own rule (the image as it comes when the matrix is
  portrait-built on a landscape screen, `camTurn` respected); the overlay then sat on the real hand (confirmed 2026-11-06). Results still arrive ~165 ms behind the camera image
  (sampling the crop takes 13 ms on the main thread), which the prediction covers for ~120 ms.

- **A WebXR page drew wrong from its second session frame** (fixed 2026-11-06, Simulator-verified;
  to be confirmed on the phone). The session held and the page's renderer presented every frame,
  yet the screen never showed the stereo scene. The shim's lens-distortion pass changed GL state
  (program, buffers, the attribute pointers of whatever vertex array three.js had bound, texture
  unit 0, enables, clear colour) and never put it back; three.js remembers the state it sets and
  skips calls it thinks redundant, so from frame two it drew with the shim's program, buffers and
  texture. The pass now draws through its own vertex arrays and saves and restores every piece of
  state it touches, as does the layer setup. A three.js 360-video page renders in stereo through
  the lenses in the Simulator past a thousand frames. A long press on the screen (a second and a
  half) still ends a session, and the browser keeps every video inline rather than letting the
  phone's own full-screen player over it.
- **Hands froze for seconds at a time, and the phone ran hot (2026-11-06, iPhone 18 Pro Max).**
  The log showed ARKit itself starved: its camera at 1–11 frames a second instead of 60, the
  session "initializing" and the pose "limited", while the hand landmarker took 53–66 ms an image
  "including waits" (20 ms on a quiet frame) and its crop sampling 15–22 ms on the main thread,
  with the saved 120 fps target and 120% render scale on top; "serious" came two minutes in.
  Changes: the landmarker is off by default (`handShape 1` brings it back) and a flat hand from
  Vision's landmarks places the hand at 5–8 ms an image on the Neural Engine; the app holds
  itself to 60 fps and 80% render scale while the thermal state is serious (30 fps and 60% at
  critical) whatever is set; the camera's rate never changes while hands are on (a change
  restarts the session). The ultra-wide camera was meant to follow, but ARKit on the iPhone 18
  Pro Max lists no ultra-wide format at all (22 formats, every one the main camera, read off
  ARKit itself), so passthrough stays at 70° there and the view is still magnified to fill the
  viewer; only a native capture outside ARKit could use the ultra-wide. To be measured on the phone.
- **Hands stopped in a long WebXR session; fingers drawn stretched; the view shook (2026-11-06).**
  The log showed hands found but "without a pose" by the hundred: an image newer than every
  recorded pose got no pose (the tracker takes the image in its own loop, the pose arrives in
  Update), and at 30 camera frames a second (ARKit drops to 30 when the phone is hot) that was
  most images. The newest pose now stands in for an image up to 70 ms newer. The flat hand put
  every joint on the palm's plane, so a fingertip nearer the camera than the palm, which
  projects far out in the image, was drawn stretched; the shape is now lifted (every finger
  bone at its real length along its pixel's ray, `HandGeometry.LiftedShape`), and a pinch is a
  3D fingertip distance again. The shown head position is low-passed, harder the faster the head
  moves (`headSmooth 0` off). To be confirmed on the phone.
- **Pinches at the image's edge, and two hands together.** With fingers partly out of view the
  model guessed a pinch; no pinch starts within the edge margin now. Two hands clapped or palm
  to palm read as one or swap: Vision reports them as it can and the tracker matches regions by
  distance, so overlapping hands aren't told apart; keep them a hand's width apart.
- **A tall photo sphere is drawn on a cylinder.** A GPano crop gives a panorama's exact span and
  height, and the band is a cylinder, which is right up to about 90° tall; a sphere cropped to,
  say, 360° × 150° stretches towards its top and bottom on it. The whole sphere (or near enough,
  170° tall) goes on the sphere instead. A spherical cap mesh for the in-between is to do.
- **Library videos aren't read for their spherical boxes.** A video in the Photos library is
  classified by its shape (2:1 is 360) and the library's subtypes; its `st3d`/`sv3d` boxes would
  need the file itself through `PHAssetResource`, a download for an iCloud item. Files in the
  Media folder are read. The controls' Format button corrects a wrong guess either way.

### Hands leave the camera's view

The hands are tracked in the rear camera's image, which covers about 68° across and only 42° up
and down (±21°). A hand reaching for something, or carrying it, often leaves the frame, usually
at a side edge: in one test on the iPhone, 4 of 8 cube drags ended that way. A carried cube stays
where it was while the hand is out of view, rather than dropping.

For the same reason nothing is poked with a fingertip: anything within reach would have to sit
inside that narrow cone, which was too cramped to use.

### Hands very close to the camera

At about 15 cm the camera sees a window only about 11 cm tall, so the hand only partly fits and
the hand model's 3D shape collapses on most results (up to 140 of 150 in five seconds). The hand's
depth there comes from the last shape that fit.

### Passthrough is flat

There's one camera, so passthrough is one image, the same in both eyes, drawn at one distance. It
gives no sense of depth, and how far the hand is from a virtual object can't be judged by eye. A
cube turns cyan when a pinch would grab it, to make up for that.

### Surfaces found after the floor are missed

Surface detection runs until the floor is found and a few seconds more, then stops to leave the
CPU to the hand models. The Cube Sandbox scans the whole room instead, until it finds nothing new;
elsewhere, a table first looked at later isn't a surface until 6DoF starts again.
ARKit took about 45 s to find its first surface in one plain room; ARCore can take minutes.

### Hand size, and so hand depth, is estimated

A hand's distance, joint positions and pinch gap all scale with the size assumed for the palm.

- **iPhone Pro**: LiDAR depth teaches the palm size, from hands 25–70 cm away with a close fit.
  At 30 cm a hand then read 30.5 cm against a ruler. The size learned varies by about ±6% between
  runs with how the hand is held, and LiDAR isn't used directly under 25 cm: at 15 cm it read 7–11%
  off, long in some runs and short in others.
- **Android**: there's no depth sensor, so the palm size comes from the hand model's own
  estimates. On the iPhone, before LiDAR taught it, the palm size left hands 8–12% nearer than a
  ruler said.

### Stray hand detections far away

The palm detector sometimes finds "hands" 0.9–1.7 m away. A hand first found beyond 80 cm is
ignored, since it can't be the user's; one being followed may go farther, since a real hand at
full stretch can. A real hand that first comes into view beyond 80 cm isn't picked up until it's
nearer.

### A missed grab can place a cube

A pinch that doesn't grab clicks whatever the head is looking at, and on a surface that places a
cube. No cube is placed within 15 cm of another, which stops most of these, but a missed grab
farther out still places one.

### Launch options need a launch from the Mac

They're passed by the scripts (intent extras on Android, environment variables on iOS), so opening
the app from the phone's home screen uses the defaults.

## Building

### The build report counts thousands of "errors" on a successful build

`[Build] Build Succeeded: … 14466 errors` is Unity 6000.6's TypeDB logging `Class 'X' was already
registered, previous declaration was in 'A', current declaration is in 'A'` once per class in every
assembly, and the build report counting each as an error. The messages name the same assembly twice,
so nothing is actually duplicated; the export, the Xcode build and the app are fine. Real failures
still say `error CS` in the log and `Build Failed` in the summary, which the scripts check for.

### An incremental player build can crash at launch after a script's serialized fields change

Seen 2026-11-05 after `DemoCatalog.Entry` gained a field: the Simulator export took 31 s, the app
crashed at launch in `CachedReader::OutOfBoundsError` while reading a MonoBehaviour's string array,
and no session log was written. The exported IL2CPP code was current; the serialized data was not.
Deleting `Builds/<target>`, its derived data and `Library/BuildPlayerData` and exporting again fixed
it. If an app crashes before its first `[Stereo]` line after a change to serialized fields, do that
before looking for a bug.

### CI's Unity jobs have never run

`ci.yml`'s EditMode tests and all of `release.yml` need a Unity licence in the repository's secrets
(README, "Continuous integration") and are skipped — or, for a release, fail at once — without one.
They have never run, so expect a first round of fixes when the secrets arrive: the iOS step in
particular builds Unity's Xcode project unsigned on a `macos-26` runner, which has only been
reasoned about, not tried. The *Checks* job needs no licence and does run.

## Editor and iOS Simulator

### No ARKit, so no 6DoF, passthrough, surfaces or hands

The iOS Simulator has no ARKit, and the Editor has 6DoF only through AR Foundation's XR Simulation
(a synthetic room). Where no AR provider starts, `Capabilities.SixDof` is false: 6DoF, passthrough
and hand tracking are refused with a `[Pose]` or `[Demos]` log line, demos that need them open flat
in 3DoF, and `DeskHeadLook` moves the head from the mouse, touch and keyboard. The Simulator's
Photos library, video decoding and WKWebView do work; dictation reports itself unavailable.

### Panels are hidden by nearer objects

The settings panel, the home screen and the settings screen are world-space canvases at 1.25 m,
drawn with depth: a scene object nearer than that, such as the Room's floating cubes, draws over
them. Seen in the Simulator on 2026-11-05 with the Room's white cube over the settings screen's
title. The fix is to draw the panels last, over everything, as the gaze reticle already is.

### Big iCloud assets take a while, and library videos need iOS 18

A photo or video kept only in iCloud downloads before it shows; an 11 K panorama is 20 MB. The
controls show the download's progress, and tapping the item again while it loads no longer
starts it over (which is why nothing opened on 2026-11-05). Library videos play through the
AVFoundation plugin, which needs iOS 18; before that they say so.

### A panorama's height is a guess

A panorama is drawn on a cylinder 60° tall, so its width in degrees is its aspect times 60 (a 4:1
panorama spans 240°). That is about right for an iPhone's camera but has only been checked against
a drawn fixture in the Simulator; a real iPhone panorama on the phone may want a different height
(`VideoLibrary.k_PanoramaHeightDegrees`). The controls' *Format* button offers the other wrappings
meanwhile.

### The Simulator's Photos alert and corner gear ignore injected taps

The "Allow Afterglow to access your photo library?" alert, and the app's own corner gear button and
its menu, don't respond to taps injected by simctl-driven tools (2026-11-05); gaze clicks on
world-space panels do. Grant the library instead with
`xcrun simctl privacy booted grant photos com.wemiller.afterglow`, then relaunch. On a real phone
both are ordinary taps.

### The browser's page shows faintly behind the stereo view

With the browser window open in the Simulator (2026-11-05), the page itself is also visible, very
faintly and at full screen, behind the two eye views: the web view sits in the view hierarchy under
Unity's and is not fully covered. Not checked on the phone. The window on the quad is unaffected.

## The native port (`ios-native/`, phase 1)

### No ultra-wide with 6DoF on the iPhone 18 Pro Max

ARKit's `supportedVideoFormats` on this phone lists 22 formats, every one from the wide camera
(the list looks doubled because the HDR variants come first); there is no
`builtInUltraWideCamera` entry (logged by the native app under `[Camera]`, 2026-11-06). The
native app says so in the log and uses the wide camera's 1920×1440 at 60 fps, a 69° × 55° window
in the eye's view. The same applies to the Unity app's `camUltraWide` default, which can only
fall back to the main camera here.

Nor can the ultra-wide run beside ARKit: `--ei ultraTest 8` opens it through AVFoundation eight
seconds in (`UltraWideProbe.swift`), and the moment it started ARKit logged "Session interrupted"
and delivered no more frames while it ran (measured 2026-11-06; the ultra-wide itself reported
106° and ran, and the phone says multi-cam is supported, but ARKit is not an AVFoundation
session). So 6DoF comes from the wide camera, and the ultra-wide's view is only reachable in a
mode without ARKit: 3DoF from the motion sensors, passthrough and hands from an AVFoundation
session, as the Unity app's 3DoF mode did.

### The camera image is 10-bit video range

The captured image arrives as `x420` (10-bit samples in 16-bit words, video range) even for the
non-HDR formats. Read as 8-bit full range it was yellow and blue static; the app now reads the
planes as 16-bit textures and scales the range (`ARController.swift`, `Shaders.metal`). A phone
that delivers `420f` takes the 8-bit full-range path, which has not been seen on this one.

### The right eye was black until the layering fix

Until 2026-11-06 afternoon the scene shaders wrote the eye's index to the render target array
index and the pass's view mappings added it again, so the right eye went to a slice that does not
exist and, as the GPU had it, onto the left slice: the left eye showed both views over each other
and the right eye nothing. Found when the hand overlay appeared twice in an eye dump; the shaders
now write 0 and the mappings pick the slice. `--ei dump N` writes both eyes, which is how to check
anything stereo from the Mac.

### Hands

The hand's 3D shape is flat: the joints sit at the palm's depth (LiDAR's where it has one), so a
finger pointed at the camera reads as short, and the pinch distance is the tips' distance in the
image at that depth. Vision's chirality flips now and then on a hand seen edge-on; the blended
handedness settles it but a hand can still change colour for a moment. An edge-on palm (fingers
in line with the camera) is told by its apparent size at the LiDAR depth, so without LiDAR, or
closer than 20 cm, that guard is off and the guessed index tip can read as a pinch. Two hands held
together come back from Vision as one observation (as in the Unity app): the hand it stops
reporting is kept where it was for two seconds while the other is beside it, then dropped, and
takes its slot back when the hands part. A C-shaped hand turned so its tips cross in the image
is told from a pinch by the tips' LiDAR depths over the last five results and by needing four
close results in a row, so a pinch begins about 200 ms after the tips meet; a slow turn that holds
the crossing can still read as one, and Vision sometimes drops the hand at the crossing. Vision takes 15–20 ms an
image on the Neural Engine at 30 images/s whether or not a hand is in view, which is the one
steady load the phase 1 run did not have; `handHz` lowers it.

### Built in the Simulator, not yet run on the phone (2026-11-06 evening)

Everything after phase 2 was proven only by the Simulator harness: the browser and its WebXR
sessions, the toolbar and menu, the Photos and Files media viewers with every projection, the
surfaces, occlusion and places, recording, the games (lit meshes, the toy box's wake-up
button) and the rhythm game, controllers, the Apple Watch app (no paired watch in the
Simulator). On the
phone these are untested: real hands driving the browser's keyboard and the games, LiDAR
occlusion, plane detection and the floor height, spatial MV-HEVC video, dictation, the double
tap's threshold, AirPlay casting, the Files picker, and the heat all of it adds. Expect a round
of fixes from the first device runs, as phases 1 and 2 had.

### The browser (native)

The owner saw the page drawn larger than its window on the phone (2026-11-07); in the Simulator
the page quad and the chrome match, and the window is resynced to the window manager's pane
every frame, so the cause is not yet found. The page zoom (175 %) can also lay a desktop page
out wider than the window, which then needs a horizontal scroll; lower the browser text in
Settings if a page overflows.

The page is a snapshot, twelve a second (WebKit's `takeSnapshot`, rendered off the main thread),
so video in the window plays at that rate and a fast scroll smears; the window is for reading and
pages that need the screen take it through WebXR. An immersive session in the Simulator shows
black for several seconds while software WebGL starts at the screen's full resolution; the phone
has not been measured. The page's zoom (150 % for readable text) is set to 1:1 for a session, or
one eye filled the screen and the other sat off its edge. Dictation has not been tried on the
phone, and the double tap's accelerometer threshold (0.9 g) is a guess to be tuned on the viewer.

### Frames show about two frames after they are built

With three drawables the frame loop runs ahead of the display and a frame is presented about
33 ms after the display link's target; the renderer measures that and predicts the head pose to
the real moment, so the picture does not lag a turn, but the camera image in passthrough is
still 70–85 ms old by the time it is seen. Two drawables halve the rate to 30 fps instead, so
three it stays. A frame built later in the vertical interval, closer to the vsync, is the next
step if the latency shows.

## iPhone 18 Pro Max

### Frames are late with the browser window up

Measured 2026-11-03 (session log, 3DoF, browser window in the scene): 55–77 fps against a 120
target, 13–26 % of frames late, and a steady run of 42–53 ms hitches with the time in **present
wait** (main thread 0.5–11 ms, GPU 1.0–1.6 ms). The work is not the app's; the frame is waiting on
the display. Not yet diagnosed; see ROADMAP.md, Phase 1.

### Not yet verified on this phone

Two-hand tracking, spatial photo and video playback, and an immersive WebXR session have been
built but had not run on the device as of 2026-11-05.

## iPhone 15 Pro

### 120 fps doesn't hold with hand tracking, or when the phone is hot

The app renders at 120 fps, in stereo and in 6DoF, but running the hand models needs 7–31 ms of
main-thread time a frame, more than the 8.3 ms a 120 Hz frame allows, so with a hand in view it
runs at 52–103 fps. Heat matters too: Unity's iOS player lowers the frame rate by itself when
the thermal state gets serious or critical, to 60 and 30 fps as this project sets it. From a
cooled phone, the Cube Sandbox reached iOS's "fair" thermal state in about 3½ minutes; a phone
already warm from testing reached "serious" in about 70 s. The `[Thermal]` log lines time each
change, and say when a run didn't start cold.

## iPhone 18 Pro Max

### The phone runs hot, and the frame rate falls with it

(2026-11-06) In a seven-minute run of Home and the browser, with an immersive WebXR session in
the middle, iOS's thermal state was "serious" for most of it, and the app held 16–60 fps against
its 120 fps target with nearly every frame late. The frame itself is cheap: the main thread took
1–9 ms and the GPU up to 6 ms, with the rest spent waiting to present. The heat is from what
runs every frame regardless of the scene: the rear camera at 1920×1440 at 60 Hz for passthrough
and hands, ARKit world tracking for 6DoF, stereo rendering aimed at 120 fps, and the web view
drawing its page (during a session, now at the screen's own pixels rather than nearly twice
them). The hand models were not the cost in this run: with no hand in view the palm detector
ran about twice a second at 32–51 ms on the CPU, and the landmarker not at all; with a hand in
view the landmarker runs on every image unless `handHz` limits it. The phone went from
"nominal" to "fair" 3:21 after launch and to "serious" at 5:30, and it had not started cold.
Unity's own drawing is already paused while a page has the screen. Options still open: a 60 fps
default (`fps 60` tries it), a 3DoF browser and media player with no ARKit when nothing needs the
room, a 30 Hz camera when no hand is being tracked, and the hand models on the Neural Engine
through Apple's Vision hand pose instead of the CPU.

## Pixel 9 Pro

### The display drops to 60 Hz while the camera runs

Android holds the display at 60 Hz whenever the camera is in use, and the app can't override it,
so 6DoF, passthrough and hand tracking all run at 60 fps.

### Some screen taps freeze the view for 75–85 ms

About one in eight real finger taps (including a viewer's button) holds up the next frame for
75–85 ms, which shows as a visible hitch in the viewer. The app's own work stays at 3–6 ms per
frame. The time is spent waiting for the display.

What's known:

- Each freeze lines up with the display driver switching its TE2 rate (`hwc-display`
  `DisplayTe2Manager::setTe2Rate` writes 30 Hz, then 120 Hz within ~25 ms).
- The driver's TE2 is in its "changeable" mode (`adb shell dumpsys SurfaceFlinger`), because a
  system client keeps the proximity sensor active. In that mode it follows the display's refresh
  rate, so the pairs suggest the display drops briefly to its 30 Hz idle rate.
- Taps injected with `adb shell input tap` don't trigger it. Only physical touches do.
- No effect: turning off `Window.setFrameRateBoostOnTouchEnabled` and
  `setFrameRatePowerSavingsBalanced`, or turning on the proximity sensor from the app.
- The 120 Hz display mode on a 240 Hz vsync (what `DisplayRefreshRate` picks) avoids the same stall
  when there's no touch. The default 120 Hz mode stalled every 5–25 seconds.

Next step if it matters: record a perfetto trace during real taps to see what drops the refresh
rate.
