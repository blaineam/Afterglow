# Roadmap: from a demo lobby to a product

Fork of [brenpoly/CardboardXR](https://github.com/brenpoly/CardboardXR) (upstream `v1.0.0`,
Apache-2.0), built for the **iPhone 18 Pro Max** in brenpoly's printed viewer. Upstream is a
very good prototype: 6DoF, passthrough, camera-tracked hands and a handful of demos in a Cardboard
viewer. The goal here is a **free, open-source product** that people can install, use every day
and trust: a home screen with three browsers — **Media** (the Photos library and files), **Web**
(WebXR pages Safari cannot show) and **Files** — plus the games, on a foundation that is measured,
not assumed.

This file is the plan and the honest state. Where it says *done* there is code; where it says
*verified* that code has run on the phone and the session log says so. The two are not the same,
and the gap between them is most of the work.

---

## Where it stands (2026-11-05)

| Asked for | State |
|---|---|
| Spatial **photos** from the Photos library | Done (`AfterglowPhotoLibrary.mm`, HEIC stereo pair via ImageIO). Verified in the Simulator with a drawn stereo HEIC (2026-11-05); **not verified on the phone.** |
| Spatial **video** from the Photos library | Done (`AfterglowSpatialVideo.mm`, MV-HEVC both layers via `AVPlayerVideoOutput`, zero-copy Metal, iOS 18+). Built 2026-11-04, **never launched on the phone.** |
| **Media browser** | Since 2026-11-05: the whole Photos library as a thumbnail grid with filters (All, Spatial, Panoramas, 360, Videos); panoramas on a cylinder sized from the picture's shape; 2:1 stills on the sphere; flat photos and library videos on the screen; the kind comes from the library's subtypes and the aspect, and the Format button overrides it. Verified in the Simulator with drawn fixtures. The panorama's angular height (60°, so a 4:1 panorama spans 240°) is a guess until a real iPhone panorama is checked on the phone. Not yet: albums, 360 stills in the Files folder, formats from video metadata boxes. |
| **WebXR browser** | A working start: page on a quad at ~12 fps, gaze + pinch click, gaze-edge and gamepad scroll, back/forward/home/reload/resize, address bar, on-screen keys, Bluetooth keyboard, on-device dictation, `immersive-vr` full screen with page-side stereo and barrel distortion from the app's own lens numbers. Window verified on the phone; **an immersive session is not**. Missing: tabs, bookmarks, history, text selection, downloads, `immersive-ar`, hand input sources, floor-relative spaces from the real floor. iOS only. |
| **Two hands** | Done (`723c064`, `aede100`): detector keeps both palms, two `TrackedHand` slots, XR Hands fed left and right. **Never run on the phone**; the last device log predates both commits. |
| **UX** | A **home screen** since 2026-11-05: Media, Web, Files, Play and Settings above the settings panel, open as the app starts, with a Play page for the games and the old checkerboard lobby kept as *The Room*. The room scan no longer blocks the cold start: it runs, with its panel, when an app that places things opens. Still a prototype's inside Media: five text rows a page in the one player, which Files reuses filtered to the copied-in videos. |
| **Performance** | Last device log (iPhone 18 Pro Max, 2026-11-03): 55–77 fps against a 120 target, 13–26 % late frames, steady ~50 ms "present wait" hitches with the browser window up. Visible judder in a headset. |
| **Passthrough** | Fixed 2026-11-06 from the phone's log: ARKit hands a display transform built for portrait, and turning its crop gave a picture 1.75× taller than wide that stretched as the head tilted. The whole image is now mapped from first principles (73° × 58° at true size) and, by default, magnified uniformly to fill the view, with a soft rim; a setting shows it at true size instead. **Unverified on the phone** — the first run says, in `[Passthrough] Image … shown …`. The camera configurations are logged for picking a wider one (`camConfig N`). |
| **Optics** | Until 2026-11-05 the rig defaulted to **Cardboard v1** — the wrong lenses for every viewer this project knows — unless a QR code had been scanned. The printed viewer's profile is now the default, and the scan screen offers the built-ins. |
| **Desk testing** | New: the Editor runs 6DoF in AR Foundation's XR Simulation (a synthetic room), and both the Editor without it and the iOS Simulator run 3DoF with drag-to-look (`DeskHeadLook`). `Tools/ios_sim_build_and_run.sh` builds and launches on a simulator — **verified 2026-11-05**: the app runs on an iPhone 18 Pro Max simulator, defaults to the printed viewer's optics and falls back to 3DoF. |
| **Distribution** | Its own repository since 2026-11-05: [blaineam/Afterglow](https://github.com/blaineam/Afterglow), public (renamed from CardboardXR the same day; the old address redirects). CI runs the script and workflow checks on every push; the EditMode tests and the tag-triggered Android APK + unsigned iOS IPA builds are written but **wait on a Unity licence in the secrets**, so neither has run yet. Until then, Android via `Tools/release_android.sh` and iOS from source. |

Unity 6000.6.0f1 is installed; the C# compiles and all 297 EditMode tests pass (2026-11-04).

---

## Phase 1 — Foundation

Everything else sits on this, and three of the newest features have never run on the device.

- **Verify on the phone**: two hands, spatial photo and video playback, the media browser and a
  real panorama, library videos, the passthrough's shape and fill, the browser's taps and tabs, an
  immersive WebXR session. Each gets a session-log line that proves it, and a
  KNOWN_ISSUES entry for what it does badly. The current build was installed on the iPhone 18 Pro
  Max on 2026-11-05 but not launched: the phone was locked (`zsh Tools/ios_launch.sh` once it
  isn't).
- **Default optics** — done: `ViewerParams.AfterglowViewer` (Cardboard v2 lenses centred on the
  phone's width, which is where brenpoly's carriage puts them: bores at x = 0.0 in the STEP,
  64.0 mm apart) is the rig's default; the scan screen offers *Printed viewer*, *Cardboard v2*,
  *Cardboard v1* and remembers the pick.
- **Desk mode** — done in code, see below. Fixture media for the simulator's Photos library:
  done 2026-11-05 (`Tools/sim_add_media.sh` draws and adds a 360 still, a panorama, flat photos,
  a spatial HEIC and two videos). To do: the Editor's XR Simulation environment checked against
  the room scan.
- **Frame pacing**: find the ~50 ms present-wait hitches (they are *not* CPU time: main 0.6 ms,
  GPU 1.5 ms, present wait 51 ms), then choose a frame target that holds — 120 only if it really
  does with the browser or a hand in view, else 90 or 60, and say which in the log.
- **Settings in the app** — done in code: `SettingsScreen`, from the panel's Settings button, with
  frame rate, render scale, MSAA, focus-wheel offset, brightness, UI size, hand rate, 3DoF/6DoF
  start, room scan at start and the boundary warning, saved through `Settings` (`PlayerPrefs`
  under the launch option's own name; a launch flag still overrides for one run). **Verified in
  the Simulator 2026-11-05**: opens from the panel, pages, shows the saved values. To verify on the
  phone: that the rows read through the lenses, and that a frame-rate change really changes the
  display's refresh rate.
- **Home** — done 2026-11-05: `HomeScreen` replaces the lobby and app library with Media, Web,
  Files, Play and Settings; the lobby is the Play section's *Room*; a new `Home` scene (a grid floor
  under passthrough) is where the app starts and *Leave* returns to; the room scan moved into
  `RoomScanPrompt`, shown when an app with `ScanSurfaces` opens in 6DoF. Web is disabled off iOS and
  says so. **Verified in the Simulator 2026-11-05**: the screen opens over the Home scene at start,
  Web opens the browser, Play turns the page and The Room loads from it. Not exercised there:
  *Leave*, *Files* and the *Settings* tile (the Simulator's screen gear doesn't take injected taps,
  and a palm needs a camera), and the scan prompt, which needs 6DoF and so the phone.
- **A repository of its own, with CI** — done 2026-11-05: `github.com/blaineam/Afterglow`
  (`origin`; brenpoly's stays as `upstream`). `ci.yml` checks scripts, workflows and the Unity
  version on every push and runs the EditMode tests when a licence is in the secrets; `release.yml`
  builds the Android APK and an unsigned iOS IPA on a `v*` tag into a draft release. To do: add the
  licence secrets and watch the first Unity jobs — the iOS archive step (Xcode on `macos-26`,
  unsigned) has never run.

## Phase 2 — Media browser

- **Photos as a grid** — done 2026-11-05: thumbnails from `PHCachingImageManager`, filters
  *All · Spatial · Panoramas · 360 · Videos*, newest first, eight a page for a gaze
  (`VideoDemo`, `PhotoLibrary`). To do: albums and smart albums.
- **Panoramas** — done 2026-11-05: `PHAssetMediaSubtypePhotoPanorama` or a shape wider than
  2.4:1; a **cylindrical band** (`VideoSphere.ShowPanorama`) whose width follows the picture's
  aspect at 60° of height, so a 4:1 panorama spans 240°. The 60° wants checking against a real
  iPhone panorama on the phone.
- **360 stills** — done for the library and the Media folder by a 2:1 shape (3 % tolerance). To
  do: `GPano` XMP.
- **One player**: format from **metadata** — MV-HEVC layers (done), the spherical-video v2 boxes
  (`st3d`, `sv3d`), GPano — before falling back to filename tags. Library videos go by shape (2:1
  is 360) and files by their name tags; the boxes are still to do.
- Flat photos and videos on the screen — done 2026-11-05, as the spatial ones are.

## Phase 3 — Files

- iOS document picker (`UIDocumentPickerViewController`) — done 2026-11-05: the browser's *Import*
  button (`FilePicker`, `AfterglowFilePicker.mm`) copies picks into the app's `Media` folder, which
  Finder and the Files app can already copy into. Android's SAF picker: not until there is an
  Android device to test on.
- Images and videos both, into the same player — done 2026-11-05: JPEG, PNG and HEIC in the folder
  are listed with thumbnails, sized from their headers on iOS and sorted by shape (a 2:1 still, a
  panorama, a photo), and a spatial HEIC shows per eye. Off iOS, Unity reads JPEG and PNG itself
  and a HEIC waits for the phone. Verified in the Simulator with the drawn fixtures copied into the
  folder; the picker itself opens there but its native sheet takes no injected taps, so a real pick
  waits for the phone.

## Phase 4 — Web

- A browser's chrome — done 2026-11-06: the address bar at the top with back, forward and reload,
  a tab strip above it (one web view, so a tab left behind reloads when returned to), the window's
  own controls below, and a screen tap clicks the page where the gaze is, as a pinch does (taps
  did nothing before, which is why the start page's links went nowhere on the phone). To do:
  bookmarks, history, tabs that keep their state.
- `immersive-ar` over the passthrough, which exists and is wasted on a browser that only does VR.
- **Hand input sources**: the tracker's 21 joints as WebXR Hand Input, so pages see hands, not a
  bare gaze `select`.
- `local-floor` from the floor ARKit found rather than a fixed 1.6 m.
- Measure an immersive session's frame rate honestly and say in the start page what to expect.

## Phase 5 — Distribution

- **TestFlight** for iOS, with the unsigned IPA on GitHub releases for people who sideload.
- The Android APK on releases as today; Play later.
- App Store as a bonus. The browser is `WKWebView`, which is WebKit, so guideline 2.5.6 is met;
  the risk is reviewers' view of an app that is a window onto arbitrary content.

## Later

- **More games**, since the hands, the room and the passthrough are the point: a rhythm game
  with hits on incoming neon shapes to the beat (Apple Music streams can't be analysed, so the
  beat maps come from bundled synthwave tracks or the user's own files, with MusicKit for
  playback of their library later), a skyline drive along the neon grid with the head steering,
  a tower-stacking game on a real table, an orbital pong between two hands, and a "glow garden"
  that grows where you point. Each is a catalog entry and a scene, like the four here.

- Gamepad support for the games (a Bluetooth controller already scrolls the browser).
- SteamVR streaming as an ALVR client: seated and gamepad games only, since there are no
  controllers.
- HDMI capture is **not possible on iPhone** (no UVC); a network encoder to the flat screen is the
  route.

---

## Desk mode: testing without the phone

| Where | Tracking | Camera, passthrough, hands | Photos, video, WKWebView |
|---|---|---|---|
| **Editor, XR Simulation on** (default after `ProjectSetup.Apply`) | 6DoF in a synthetic room, keyboard and mouse | A synthetic camera; planes are found; no hands | Photos: none (not iOS). Video files and the Editor's fallbacks only |
| **Editor, no provider** | 3DoF: right-drag or the arrows to look, W A S D / Q E to move, R to face forward (`DeskHeadLook`) | None | As above |
| **iOS Simulator** (`Tools/ios_sim_build_and_run.sh`) | 3DoF: drag or the Mac's arrow keys to look (the Simulator's mouse is a touch), click to tap | None: ARKit does not run in the Simulator | Photos **yes** — `xcrun simctl addmedia booted photo.HEIC`; MV-HEVC decode and WKWebView run; dictation reports unavailable |
| **Phone** | Everything | Everything | Everything |

`Capabilities.SixDof` is the one question everything asks: whether XR Plug-in Management started
an AR provider. Without one, 6DoF, passthrough and hands are refused with a log line instead of
waiting for tracking that never starts, and a drag on the screen is a look rather than a tap
(`GazePointer` cancels a press that travels more than 0.15 in).

---

## Device facts

Verified against Apple's spec sheet, not assumed:

| | iPhone 15 Pro (upstream's test device) | iPhone 18 Pro Max |
|---|---|---|
| Body | 146.6 × 70.6 × 8.25 mm | **163.4 × 78.0 × 8.75 mm** |
| Mass | 187 g | **249 g** |
| Display | 6.1", 2556 × 1179 @ 460 ppi | **6.9" (6.86" rect), 2868 × 1320 @ 460 ppi** |
| Active area | 141.1 × 65.1 mm | **158.4 × 72.9 mm** |

With Cardboard v2 lenses the horizontal view is lens-limited on both phones (the lens renders 60°;
the 6.9" screen subtends 72.5°, and the surplus is thrown away). Vertically the taller screen
reaches the lens's full 60° where the 6.1" ran out at about 52°, and centring the lenses on the
screen — which brenpoly's carriage does — gives 57.6° each way. That is why the printed-viewer
profile is `VerticalAlignment.Center`.

## Licensing

The code is Apache-2.0. brenpoly's printed viewer on MakerWorld is **CC BY-NC-SA**, so everything
in `Hardware/upstream-stretch/` that is derived from it is non-commercial and share-alike, and the
generated STLs are not committed. `Hardware/viewer.scad` is this project's own.

## Platforms

iPhone first-class: the browser, spatial media and dictation are iOS-only, and the only test
device is an iPhone. Android keeps compiling and keeps what it has (6DoF, passthrough, hands, the
games, 360 video); parity for the iOS-only features is not planned until there is an Android
device to test on.
