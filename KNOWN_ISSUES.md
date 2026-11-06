# Known issues

## Both platforms

- **The browser's two crosshairs disagree.** The gaze reticle (the ring the app draws at the
  centre of each eye) and the page's own crosshair (the dot the helper script draws where the
  app says the gaze is) sit a little apart on the window, the page's higher, and a tap lands
  where the page's dot is. Seen in the Simulator 2026-11-06 (desk mode, 3DoF); the mapping from
  the gaze hit on the quad to page coordinates (`TryGazePoint`, `PageV`) is where to look. Aim by
  the page's dot until then.

- **Hands aren't found on the phone (2026-11-06).** The first device run since the two-hands
  change (2026-11-03) shows the palm detector finding a hand only now and then and the landmarker
  scoring it 0.13 presence, under the 0.5 it needs, so every hand is dropped at once and no pinch
  is ever seen; taps and the floating buttons still work. The crop the landmarker sees is the
  suspect (its orientation or its content), and the next run says: launch with
  `zsh Tools/ios_launch.sh --ei handDump 6` with a hand in view, and the app writes the camera
  image, the detector's input and the landmarker's crops to `HandDumps` in its Documents folder
  (Finder's Files tab, or `devicectl device copy from`), with a log line per crop.

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
