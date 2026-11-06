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
| Spatial **photos** from the Photos library | Done (`CardboardXRSpatialPhotos.mm`, HEIC stereo pair via ImageIO). **Not verified on the phone.** |
| Spatial **video** from the Photos library | Done (`CardboardXRSpatialVideo.mm`, MV-HEVC both layers via `AVPlayerVideoOutput`, zero-copy Metal, iOS 18+). Built 2026-11-04, **never launched on the phone.** |
| **Panoramas** | **Not built.** The Photos query asks only for `spatialMedia`; the player has no cylindrical projection; the file scanner lists only video extensions, so a 360 still is invisible too. |
| **WebXR browser** | A working start: page on a quad at ~12 fps, gaze + pinch click, gaze-edge and gamepad scroll, back/forward/home/reload/resize, address bar, on-screen keys, Bluetooth keyboard, on-device dictation, `immersive-vr` full screen with page-side stereo and barrel distortion from the app's own lens numbers. Window verified on the phone; **an immersive session is not**. Missing: tabs, bookmarks, history, text selection, downloads, `immersive-ar`, hand input sources, floor-relative spaces from the real floor. iOS only. |
| **Two hands** | Done (`723c064`, `aede100`): detector keeps both palms, two `TrackedHand` slots, XR Hands fed left and right. **Never run on the phone**; the last device log predates both commits. |
| **UX** | A prototype's: a lobby and a library of *demos*; the media list is five text rows a page inside a demo called "360 Video"; every tuning knob is a Mac-side launch flag; a room scan blocks every cold start. |
| **Performance** | Last device log (iPhone 18 Pro Max, 2026-11-03): 55–77 fps against a 120 target, 13–26 % late frames, steady ~50 ms "present wait" hitches with the browser window up. Visible judder in a headset. |
| **Optics** | Until 2026-11-05 the rig defaulted to **Cardboard v1** — the wrong lenses for every viewer this project knows — unless a QR code had been scanned. The printed viewer's profile is now the default, and the scan screen offers the built-ins. |
| **Desk testing** | New: the Editor runs 6DoF in AR Foundation's XR Simulation (a synthetic room), and both the Editor without it and the iOS Simulator run 3DoF with drag-to-look (`DeskHeadLook`). `Tools/ios_sim_build_and_run.sh` builds and launches on a simulator — **verified 2026-11-05**: the app runs on an iPhone 18 Pro Max simulator, defaults to the printed viewer's optics and falls back to 3DoF. |
| **Distribution** | Its own repository since 2026-11-05: [blaineam/CardboardXR](https://github.com/blaineam/CardboardXR), public. CI runs the script and workflow checks on every push; the EditMode tests and the tag-triggered Android APK + unsigned iOS IPA builds are written but **wait on a Unity licence in the secrets**, so neither has run yet. Until then, Android via `Tools/release_android.sh` and iOS from source. |

Unity 6000.6.0f1 is installed; the C# compiles and all 297 EditMode tests pass (2026-11-04).

---

## Phase 1 — Foundation

Everything else sits on this, and three of the newest features have never run on the device.

- **Verify on the phone**: two hands, spatial photo and video playback, an immersive WebXR
  session. Each gets a session-log line that proves it, and a KNOWN_ISSUES entry for what it
  does badly.
- **Default optics** — done: `ViewerParams.CardboardXRViewer` (Cardboard v2 lenses centred on the
  phone's width, which is where brenpoly's carriage puts them: bores at x = 0.0 in the STEP,
  64.0 mm apart) is the rig's default; the scan screen offers *Printed viewer*, *Cardboard v2*,
  *Cardboard v1* and remembers the pick.
- **Desk mode** — done in code, see below. To do: fixture media for the simulator's Photos
  library, and the Editor's XR Simulation environment checked against the room scan.
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
- **Home**: replace the lobby + app library with a home screen of Media, Web, Files, Play and
  Settings. The lobby becomes the Play section's room. The room scan moves to where 6DoF is first
  needed instead of blocking the cold start.
- **A repository of its own, with CI** — done 2026-11-05: `github.com/blaineam/CardboardXR`
  (`origin`; brenpoly's stays as `upstream`). `ci.yml` checks scripts, workflows and the Unity
  version on every push and runs the EditMode tests when a licence is in the secrets; `release.yml`
  builds the Android APK and an unsigned iOS IPA on a `v*` tag into a draft release. To do: add the
  licence secrets and watch the first Unity jobs — the iOS archive step (Xcode on `macos-26`,
  unsigned) has never run.

## Phase 2 — Media browser

- **Photos as a grid**: thumbnails from `PHCachingImageManager`, albums and smart albums, filters
  *Spatial · Panoramas · 360 · Videos · All*, newest first, paged for a gaze.
- **Panoramas**: list `PHAssetMediaSubtypePhotoPanorama`; a **cylindrical projection** sized from
  the asset's aspect (iPhone panoramas are cylindrical, not equirectangular, and run to about 240°).
- **360 stills**: by `GPano` XMP or a 2:1 aspect; JPEG, HEIC and PNG in the Files folder too.
- **One player**: format from **metadata** — MV-HEVC layers, the spherical-video v2 boxes (`st3d`,
  `sv3d`), GPano — before falling back to filename tags.
- Flat photos and videos on the screen, as the spatial ones are already.

## Phase 3 — Files

- iOS document picker (`UIDocumentPickerViewController`) and the app's own Documents folder, which
  Finder and the Files app can already copy into; Android's SAF picker.
- Images and videos both, into the same player.

## Phase 4 — Web

- Tabs, bookmarks, history; a start page of WebXR-capable sites.
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
