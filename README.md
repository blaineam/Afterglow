# Afterglow

[![CI](https://github.com/blaineam/Afterglow/actions/workflows/ci.yml/badge.svg)](https://github.com/blaineam/Afterglow/actions/workflows/ci.yml)

A fork of [brenpoly/CardboardXR](https://github.com/brenpoly/CardboardXR), named Afterglow since
2026-11-05 (it carried upstream's name until then), that is growing the prototype into a product: a home for spatial photos and videos, panoramas, WebXR pages and the
games, built for the iPhone 18 Pro Max in a printed viewer and tested without one in the Editor and
the iOS Simulator. [ROADMAP.md](ROADMAP.md) is the plan and the honest state of each piece.

A Unity phone app for Google Cardboard-style viewers: split-screen stereo with lens distortion,
plus what classic Cardboard never had — 6DoF head tracking from ARCore or ARKit, a camera
passthrough view, detected surfaces with anchored objects, and hand tracking from the phone's rear
camera with pinch, grab and a pointing ray.

Tested on a **Pixel 9 Pro** (Android, ARCore) and an **iPhone 15 Pro** (iOS, ARKit, with LiDAR).

## Video and viewer

**Watch the video** about the project on YouTube:

[![CardboardXR on YouTube](https://img.youtube.com/vi/XtNmiTohUcs/maxresdefault.jpg)](https://youtu.be/XtNmiTohUcs)

**Print the viewer**: the 3D print files for a mobile VR viewer made for modern smartphones are on
MakerWorld: [Mobile VR viewer for modern smartphones](https://makerworld.com/en/models/3511377-mobile-vr-viewer-for-modern-smartphones).

This fork also carries a viewer of its own in [`Hardware/`](Hardware/), parametric in the phone so a
new one is a row in a table rather than a redraw, with its own
[bill of materials](Hardware/BOM.md). It is built for the iPhone 18 Pro Max and uses the same
Cardboard v2 lenses. See [ROADMAP.md](ROADMAP.md) for what is being added and what is still missing.

## Interactive pages

Two interactive pages go with the project. Click an image to open it.

**From Cardboard to VR glasses**: every headset since 2013, by launch price or form factor, and
where phone VR fell away.

[![The headset timeline: every VR headset from 2013 to 2027 plotted by launch price](docs/images/timeline.png)](https://brenpoly.github.io/CardboardXR/)

**Inside the iPhone build**: how the hardware, Apple's and Unity's frameworks and the app fit
together, layer by layer.

[![The iPhone build's architecture: sensors and camera through ARKit and the AI runtime to head, hand and room tracking, rendering and heat control](docs/images/architecture.png)](https://brenpoly.github.io/CardboardXR/iphone-architecture.html)

The pages are in `docs/`, served by GitHub Pages.

## Install

For Android, download the APK from [Releases](https://github.com/blaineam/Afterglow/releases) on
an ARCore phone (Android 10 or later, 64-bit, with Vulkan) and open it. Android asks you to allow
installing apps from your browser or file manager. Releases also carry an **unsigned** iOS IPA, which
needs signing with your own Apple ID before it installs; building from source, below, does that for
you. (This fork has no release of its own yet; upstream's `v1.0.0` was Android only.)

## Requirements

- Unity **6000.6.0f1** with the Android and iOS build modules. The scripts expect it where Unity
  Hub puts it; for another location, set `UNITY=/path/to/Unity.app/Contents/MacOS/Unity`
- For Android: `adb` on your `PATH` (it's in `~/Library/Android/sdk/platform-tools`)
- For iOS: full Xcode, signed into an Apple ID (a free personal team is enough)

Close the project in the Editor before running any script: they build in batch mode, which needs
the project lock.

## Build and run

Each script builds the app, installs it, launches it and prints the start of the
session log.

```sh
zsh Tools/build_and_run.sh                                   # Android
zsh Tools/ios_build_and_run.sh                               # iOS
zsh Tools/ios_build_and_run.sh --xcode                       # iOS, reusing the last Unity export
zsh Tools/ios_launch.sh                                      # iOS, relaunch without rebuilding
zsh Tools/ios_sim_build_and_run.sh                           # iOS Simulator, for work that needs no phone
```

### Without a phone

Most of the app can be worked on at a desk. **In the Editor**, play mode runs 6DoF in AR
Foundation's XR Simulation (a synthetic room, driven from the keyboard and mouse) once
`ProjectSetup.Apply` has run; without a provider it runs 3DoF, where a right-button drag or the
arrow keys look around (2° a press, steady when held), W A S D move, Q and E go down and up, and
R faces forward again. **In the iOS
Simulator** (`Tools/ios_sim_build_and_run.sh`, which boots an iPhone 18 Pro Max simulator and leaves
it running) a drag looks and a click taps; the Photos library works there, so spatial photos and
videos can be added to it with `xcrun simctl addmedia booted photo.HEIC` (`Tools/sim_add_media.sh`
draws a set of test media — a 360 still, a panorama, flat photos, a spatial photo and two videos —
and adds them, and puts a GPano photo sphere and a video with spherical boxes in the app's Media
folder; `Tools/inject_spherical.py` writes those boxes into any MP4), and so do WKWebView and
video decoding. What neither has is ARKit: no passthrough, no surfaces and no camera-tracked hands.
The app notices (`Capabilities`) and refuses those with a log line rather than waiting for tracking.

Builds are release builds. For a development build (debuggable, with the Unity Profiler able to
connect over the local network), set `AFTERGLOW_DEVELOPMENT=1`. The app id is
`com.wemiller.afterglow`; an iOS bundle id belongs to the Apple team that first signed it, so to
build for your own iPhone pick your own, the same way for every script:

```sh
AFTERGLOW_BUNDLE_ID=com.example.afterglow zsh Tools/ios_build_and_run.sh
```

The Android script also runs the EditMode tests first. On iOS, the first install needs Developer
Mode on the phone (Settings > Privacy & Security, which only appears after a first install attempt)
and trusting the developer (Settings > General > VPN & Device Management). The phone must be
unlocked to launch; a build takes about five minutes, so if it auto-locks in the meantime, unlock
it and run `ios_launch.sh`.

### Releases

Pushing a version tag (`git tag v1.2.3 && git push origin v1.2.3`) runs the **Release** workflow
([`.github/workflows/release.yml`](.github/workflows/release.yml)): it builds the Android APK and an
unsigned iOS IPA on GitHub's runners and attaches both, with their SHA-256 sums, to a **draft**
release for you to review and publish. It needs the Unity licence secrets described under
*Continuous integration*; with the keystore secrets named at the top of the workflow the APK is
signed with your release key, otherwise with Unity's debug key.

`Tools/release_android.sh 1.2.3` is the same for Android from this Mac: it builds a release APK from
a fresh clone of the public repository (so it holds only the placeholder videos), signs it with your
release keystore, checks the signature and contents, and makes a draft GitHub release with it. The
script's header says where the keystore and its password go.

### Launch options

Development overrides, given the same way on both platforms after the script's own arguments.
The ones a user would want are also **settings** (the panel's *Settings* button, see below), saved
on the phone; a launch option overrides the saved setting for that run only.

```sh
zsh Tools/build_and_run.sh --ei dof 3 --ei mono 1
zsh Tools/ios_launch.sh --ei dof 3 --ei mono 1
```

On Android they're intent extras; on iOS they reach the app as environment variables
(`AFTERGLOW_<name>`). Either way they only apply to a launch from the Mac, not one from the
phone's home screen. The app logs the options it received at startup (`[Stereo] Launch options`).

| Option | Effect |
|---|---|
| `demo N` | Start in app N (its index in `Assets/_Project/Demos/DemoCatalog.asset`, from 0) instead of Home |
| `pinch 0` | Pinch-to-click off in 3DoF, for measuring its heat (it's otherwise always on) |
| `dof 3` | Start Home in 3DoF (it starts in 6DoF passthrough otherwise) |
| `scan 0` | No room scan when an app that places things opens; 6DoF finds the floor only |
| `passthrough 1` | Start with the camera passthrough view |
| `mono 1` | One full-screen view with no lens distortion, for use without a viewer |
| `boundaryCm N` | Turn on the boundary warning: in VR, a grid on real surfaces within N cm |
| `arView 1` | Debug view: the AR camera full screen with every detected surface drawn (forces 6DoF) |
| `fps N` | Target frame rate (default 120) |
| `renderScale N` | Eye texture resolution in percent (default 100) |
| `msaa N` | Anti-aliasing samples: 1, 2, 4 or 8 (default 2) |
| `handHz N` | Run the hand landmark model at most N times a second (default 0: every camera image) |
| `predictionMs N` | How far ahead head rotation is predicted, in ms (default 30) |
| `tracker 1` | Head rotation from Android's game rotation vector instead of the app's own sensor fusion |
| `nativeImu 0` | Android: read the sensors through the Input System instead of the native plugin |
| `imuPosition 0` | Leave the accelerometer out of 6DoF position, for comparison |
| `handAxes 1..8` | Override how the camera image's axes lie on screen, for hand tracking |
| `keychainTest 1` | Store, read back and delete a throwaway secret in the Keychain at start and log how it went (`[Keychain] Self-test`), for a build whose entitlement is in doubt |
| `handDump N` | Write the next N landmarker crops, with the detector input and the camera image, to `HandDumps` in the app's Documents folder, for checking what the hand models see |
| `pinchStudy 1` | A prompted run that logs pinch measurements, for tuning pinch detection |
| `uiScale N` | Size of the Material UI in percent of Android XR's dp sizes (default 160, for phone viewers' lower resolution) |
| `brightness N` | Screen brightness while the app is in front, in percent (default 90; 0 leaves it alone) |
| `focus N` | Where the viewer's focus wheel has left the lens carriage, in tenths of a millimeter off the profile's screen-to-lens distance. Saved, so it is found once per viewer |

## Using the app

- **The screen's gear button**, top right, opens a small menu: *Set viewer* opens the viewer
  screen, where you scan a viewer's QR code or pick a built-in profile — *Printed viewer* (the
  default: Cardboard v2 lenses centred on the screen, which is what this project's viewer and
  brenpoly's both have), *Cardboard v2* or *Cardboard v1* — and the choice is remembered; *Phone
  view* / *Viewer view* switches between the viewer's split-screen view and a single full-screen
  phone view; *Open settings* opens the settings panel.
- **The home screen** is what the app opens on, above the settings panel: *Media*, *Web*, *Files*,
  *Play* and *Settings*. Look at one to see what it is, and pinch or tap to open it, from anywhere,
  so you can go straight from one app to another; a dot marks the one running, and *Leave* in the
  header goes back to Home. Picking an app closes the browser if it was open, so one experience is
  up at a time; *Web* opens the browser over whatever is up. *Play* turns the page to the games (Cube Sandbox, Air Paint, Orb Rush,
  Portal) and *The Room*, a checkerboard room with colored markers for looking around and checking
  the lenses. *Home* on the settings panel shows and hides the screen. The app starts in 6DoF
  passthrough with the screen open in front of you; nothing waits on a room scan. Each app switches
  on what it needs (6DoF, passthrough, hands) and leaving puts back what you had. From anywhere, a
  round *Home* button floats low in the view: look down at it and tap or pinch to get the home
  screen back, with no hand in the camera's view and no phone in hand needed. While an app is
  running a *Close* button sits beside it, which leaves the app for Home.
- **The settings screen**, from the panel's *Settings* button or the home screen's *Settings* tile,
  stands where the home screen does and has the knobs that used to need a launch from the Mac: frame
  rate, render scale, anti-aliasing, the focus wheel's offset, screen brightness, UI size, hand
  tracking rate, whether to start in 3DoF or 6DoF, whether apps scan the room, the boundary
  warning, and whether passthrough fills the view or shows the camera at true size. Look at the minus or plus beside a value and pinch or tap. Most apply at once; UI size
  and the start mode wait for the next launch, and the note at the bottom says so. *Defaults* puts
  everything back.
- **Input is gaze and pinch everywhere**: look at something and pinch in front of the camera to
  click it. A screen tap works too. The reticle turns light blue while the camera sees your hand.
  In 6DoF demos, hand tracking does it (and picks things up); in 3DoF, a lighter detector that only
  watches for pinches, from a plain camera feed, and slows down while no hand is in view.
  Every pinch goes through one order (`PinchRouter`): the palm's settings gear, then a button under
  the gaze, then the demo's own use (painting, hitting orbs), then picking up, then a plain click.
  If you rest your gaze on a button with no hand in the camera's view, a hint under the reticle says
  to raise it.
- **Media** is a browser of your Photos library: a grid of thumbnails, newest first, with filters
  *All · Spatial · Panoramas · 360 · Videos*, and the video files on the phone after them. The
  *Albums* button lists the library's albums with something in them (Favorites, Recents, the
  camera's own kinds, then yours) to list one in place of the whole library. Pick
  one and it shows the way its kind says: a **spatial photo or video** (an iPhone 15 Pro and later
  record a picture for each eye) with a picture per eye on a screen ahead of you, a **panorama**
  on a cylinder as wide as it was swept (about 240° for a 4:1 one), a **2:1 still** all the way
  round, a plain photo or film on the screen, and a 360 or VR180 video on the sphere. The kind is
  read from the library and the picture's shape; the controls' *Format* button changes it when
  that guess is wrong. Pinch on the picture for the controls; they appear as something opens, too,
  with how far a download from iCloud has got. Allow Photos the first time Media opens. **Files** is the same browser listing only the photos and videos you brought in yourself,
  and never asks about Photos: the browser's *Import* button (iPhone) opens the Files picker, with
  the phone out of the viewer, and copies what you pick into the app's `Media` folder, which
  Finder's Files tab for the phone and the Files app can also drop things into (Afterglow > Media;
  on Android `adb push video.mp4 /storage/emulated/0/Android/data/com.wemiller.afterglow/files/Media`).
  Photos there, a spatial HEIC included, are sorted by their shape like the library's, and a file
  that says what it is wins over its name and shape: a video's spherical-video boxes (`st3d`,
  `sv3d`, the v1 XML, as 360 cameras and the spatial-media injector write them) give its
  projection and layout, and a JPEG's GPano says it is a photo sphere and how much of the sphere
  it covers, which sizes the panorama exactly rather than guessing from its shape. Two small
  test clips are bundled; to bundle your own in local builds, put them in a `360` folder beside the
  project (or set `AFTERGLOW_VIDEOS`): the build scripts copy them into `Assets/StreamingAssets`,
  which git ignores apart from the test clips. Tags in a video's name set the format (`_360`,
  `_180`, `_flat`, `_sbs`, `_tb`, `_mono`); `_flat` (or `_screen`, `_cinema`) is a film on a screen
  rather than anything wrapped around you, which is what a 3D film wants. For Google Drive, put
  share links in `videos.txt` in that folder, one per line; each downloads on first play.
- **Web** is a browser for WebXR pages, which Safari on the iPhone can't show in a viewer: the
  page sits on a window ahead of you, with an address bar above it (back, forward, reload, a
  star that keeps the page as a bookmark, the keys and the microphone) and a strip of tabs above
  that; a tap on the screen or a pinch clicks what the gaze is on, the gaze at an edge scrolls, a
  Bluetooth keyboard or the on-screen keys type, and dictation fills the address. The start page
  lists your bookmarks and the pages you opened recently (with *Clear history*), and the tabs
  come back as you left them. A page's *Enter VR* takes the whole screen in stereo through the
  lenses; hold a finger on the screen for a second and a half to end the session, since the
  page's own buttons and the app's gear are out of reach inside the viewer. Video in a page
  always plays inside the page, never in the iPhone's own full-screen player, which would cover
  the viewer. **Logins**: when you sign in to a site the browser offers to keep the password in the
  phone's Keychain (this phone only, readable only while it's unlocked, never in a backup), and on
  that site's login page next time it offers to fill it; nothing is kept unless you say *Save*.
  Bookmarks, history and the tabs live in a file in the app's own folder. iPhone only. (The
  Simulator build is signed ad hoc so the Keychain's entitlement is embedded; an unsigned build
  gets `-34018` from the Keychain and the login can't be kept.)
- **Air Paint** paints strokes in the air with your hand, like Tilt Brush, starting in passthrough
  so you paint in your own room: pinch to paint, and look at the tool panel on your left and pinch
  to pick a color, brush (Ink, Tube, Glow) and size, or to undo, reset (press twice), or switch
  between passthrough and VR.
- **Orb Rush** is a one-handed game: orbs fly toward you and you hit them with your
  hand as they reach their rings. Face the way you want to play and press Start; Pause (on the
  score line above the track) resumes, restarts or quits a round. The best score is kept.
- **Portal** opens a doorway on your floor (look at it and pinch) with a night world beyond it.
  Walk through the frame, off the cable, and the world surrounds you, with your room showing
  through the door behind; walk back through to return. It's in passthrough, so all of it is flat.
- **The settings panel**, in every scene: hold a hand up with its palm toward you and a gear button
  appears between your thumb and index finger; pinch to open the panel in front of you. It has
  *Home* (the home screen), *Settings* (the settings screen), *Browser*, *Recenter* and *Scan Room*
  (in 6DoF: scans again, or ends a scan), and the toggles *6DoF* and *Passthrough*. It follows
  you lazily as you turn; the *X* below it closes it. Look at a button and tap the screen, or
  pinch. Holding a tap recenters.
- **Surfaces**: in 6DoF the floor is found by itself, with a short scan whenever 6DoF starts, to
  save CPU for the hand models. An app that puts things on your tables (the Cube Sandbox) scans the
  whole room as it opens, with a small panel counting the surfaces found: look around at the floor
  and any tables until it says it's done, or tap *Skip* (*Done* once the floor is in). The scan
  runs until it finds nothing new, and once the room is scanned no later app scans it again. The
  *Scan the room for apps* setting turns this off, leaving the floor only.
- **Placing and moving objects**: in 6DoF, look at a surface and tap or pinch to place a cube,
  which is anchored there. Your head aims and a pinch clicks; your hand, or its ray, picks cubes
  up. A cube turns cyan when a pinch would grab it. Held, it turns with your hand and knocks other
  cubes aside; open your fingers to let go or throw it. Free cubes have physics: they fall, bounce
  off each other and land on detected surfaces. If the camera loses your hand while you hold one,
  it stays where it was rather than dropping.

## Logs

Every launch writes a session log on the phone, replacing the last one (which is kept as
`session-previous.log`). The scripts print its start; to read the whole thing:

```sh
adb pull /storage/emulated/0/Android/data/com.wemiller.afterglow/files/session.log   # Android
```

On iOS, `ios_launch.sh` copies it to `$TMPDIR/afterglow/ios-session.log`.

Lines are tagged by area: `[Pose]` head tracking, `[AR]` the AR session, `[Room]` surfaces and the
floor, `[Anchor]` placed objects, `[Hands]` hand tracking and grabs, `[Pinch]` the pinch study,
`[Passthrough]`, `[Gaze]` clicks, `[Frames]` and `[Hitch]` frame timing, `[Stereo]` setup, and
`[Tracking]` the motion sensors. Most areas log a status line every five seconds. Warnings and
errors are always kept.

## Recording clips

To film what one eye sees, without the lens distortion, record the phone's screen while using the
app in the viewer, then flatten one eye with `Tools/record_eye.py`:

- **iPhone**: on the Mac, QuickTime Player > File > New Movie Recording, and pick the iPhone as the
  camera (over USB). The phone writes no file, so it costs little.
- **Android**: `scrcpy --record clip.mp4` over USB, or the phone's own screen recorder.

```sh
python3 Tools/record_eye.py clip.mov --log session.log          # screen and viewer from the run's log
python3 Tools/record_eye.py clip.mov --phone iphone --fov 70    # Cardboard v1; narrower is sharper
```

It crops the left eye (`--eye right` for the other), undoes the distortion with the app's own lens
math, and writes a 1920x1080 (`--size`) H.264 clip next to the input; `--start` and `--duration`
trim it. In passthrough both eyes see the same image, so one eye is the whole experience.

## Tests

```sh
/Applications/Unity/Hub/Editor/6000.6.0f1/Unity.app/Contents/MacOS/Unity -batchmode \
    -projectPath . -runTests -testPlatform EditMode -testResults results.xml
```

EditMode tests cover the parts that don't need a device: lens distortion and viewer QR profiles,
sensor and pose fusion, the camera clock, hand geometry, pinch detection, depth sampling and palm
calibration, floor picking, passthrough, gaze pointing and anchoring.

### Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push to `main` and every pull
request. Its *Checks* job needs nothing: it parses the scripts, lints the workflows and fails if the
Unity version differs anywhere. Its *EditMode tests* job runs the tests above in
[game-ci](https://game.ci)'s Unity image, and is **skipped until the repository has a Unity licence**
in its secrets — a Personal licence works, and game-ci's
[activation guide](https://game.ci/docs/github/activation) walks through getting the licence file
(`.ulf`) for it. Then, from a Mac signed into `gh`:

```sh
gh secret set UNITY_LICENSE < Unity_v6000.x.ulf
gh secret set UNITY_EMAIL     # the Unity account's email, then its password: both are needed to
gh secret set UNITY_PASSWORD  # activate a Personal licence in a container
```

Pull requests from forks don't see the secrets, so for them only *Checks* runs. The Release
workflow needs the same three secrets.

## How it's built

Only one XR loader can run at a time, and AR Foundation's (ARCore, ARKit) is the one that provides
6DoF, the camera and surfaces. So the app doesn't use Google's Cardboard plugin: it renders its own
stereo views, with lens distortion ported from the Cardboard SDK.

Code is in `Assets/_Project/Scripts`, one assembly per area:

- **Stereo** — the stereo rig and lens distortion, head tracking (a gyroscope fusion corrected by
  AR poses, or `DeskHeadLook` where there are no sensors), what the build can do (`Capabilities`),
  passthrough, surfaces, anchors, frame timing and the session log
- **Hands** — hand tracking with MediaPipe's BlazeHand models on Unity Inference Engine, placed in
  3D and fed to XR Hands and the XR Interaction Toolkit; on iOS, LiDAR depth teaches the hand's size
- **Interaction** — gaze pointing and highlighting
- **UI** — a Material Design for XR kit (Material 3's baseline dark scheme, Roboto, Material
  Icons) sized in Android XR's dp, which every scene's UI is built from
- **Demos** — the home screen, moving between Home and the apps, the room scan's prompt, and what
  each app needs from Core
- **Tracking** — sensor fusion and filters with no Unity dependencies

**The app is one Core scene with Home and the apps loaded on top.** Core holds everything that
has to keep running across apps: the rig, head tracking, AR, hands, gaze, the settings panel and
the home screen above it. Home and each app are scenes loaded additively and unloaded on leaving;
`DemoManager` switches between them and app scripts reach Core through `CoreServices`. An app's
scene, assets and scripts live in `Assets/_Project/Demos/<Name>/`, and its entry in
`DemoCatalog.asset` names its scene, its section of the home screen (Play, or Media for the player)
and what it needs. The home screen's Media and Files tiles both open the Media entry; Files passes
it a word (`DemoManager.Argument`) that makes it list only the files.

**Core is generated**, not edited by hand: `Assets/Editor/ProjectBootstrap/StereoBuilder.cs`
builds `Core.unity` and its materials on every build, so changes made to them in the Editor are
lost. **Home, the Room and the apps are edited by hand**: `DemoScenes.cs` makes a starter scene or
catalog entry only when it's missing, and never overwrites one. `ProjectSetup.Apply` sets the
player and XR settings for both platforms.

See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for current limitations and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for ported code and models.

## Privacy and the network

The app works offline. The camera images used for tracking, passthrough and QR scanning are
processed on the phone and never stored or sent anywhere. It goes online only when you ask:

- **Scanning a viewer's QR code**: short links on the code are followed over HTTPS, at most five
  redirects, until they reach a Cardboard viewer URL, as Google's Cardboard apps do.
- **Google Drive videos** listed in `videos.txt`: each downloads from Google Drive on first play.
- **The browser**, for the pages you open; the search field goes to a search engine that keeps no
  account. Bookmarks, history and open tabs stay in `browser.json` in the app's folder; saved
  logins stay in the phone's Keychain, and only when you ask.

Unity's analytics, crash reporting and engine diagnostics are off. The session log stays on the
phone (in the app's own storage) and holds tracking and performance figures, nothing personal.

## License

Apache License 2.0; see [LICENSE](LICENSE). Bundled third-party code, models and fonts keep their
own licenses, listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
