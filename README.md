<p align="center">
  <img src="docs/images/banner.svg" alt="Afterglow: a neon sun over a grid" width="100%">
</p>

<p align="center">
  <a href="https://github.com/blaineam/Afterglow/actions/workflows/ci.yml"><img src="https://github.com/blaineam/Afterglow/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/iPhone-18%20Pro%20Max-ff3fa4" alt="iPhone 18 Pro Max">
  <img src="https://img.shields.io/badge/licence-Apache--2.0-2de2e6" alt="Apache-2.0">
  <img src="https://img.shields.io/badge/viewer-print%20it-b028d8" alt="Printable viewer">
</p>

<h3 align="center">Phone VR, done properly, for the iPhone 18 Pro Max.</h3>

<p align="center">
  Your photos and videos in 3D. Panoramas and 360 photos all around you. A WebXR browser your
  hands can reach into. Games in your own room. All on the phone in your pocket and a viewer you
  print, free and open source.
</p>

**Afterglow** is a native Swift, Metal and ARKit app for Cardboard-style viewers that goes well
past what Cardboard ever did: **6DoF head tracking** from ARKit, **camera passthrough**, **hand
tracking** on the Neural Engine (pinch, grab, point, two hands), a **WebXR browser** that gives
pages your hands, **spatial photos and videos**, **panoramas** and **360 photos as the
surroundings**, twenty-four bundled photospheres, a visionOS-style interface of glass windows
with a launcher, a dock and a phone view, and twelve games with lit 3D graphics. It is built and
tested on the **iPhone 18 Pro Max** with its own printed viewer.

**Get it**: [Afterglow XR on the App Store](https://apps.apple.com/us/app/afterglow-xr/id6832358037), or build it yourself below.

## Gallery

From inside the viewer, one eye without the lens warp, except where it says through the lenses.
They are rendered by [`Tools/capture_gallery.sh`](Tools/capture_gallery.sh) in the Simulator, which
has no camera, so the app's synthwave surroundings stand in for your room's passthrough.

| | |
|---|---|
| <img src="docs/gallery/home.jpg" alt="The launcher"><br>The launcher | <img src="docs/gallery/windows.jpg" alt="Windows side by side, where you put them"><br>Windows side by side, where you put them |
| <img src="docs/gallery/browser-page.jpg" alt="The browser, with its tabs and address bar"><br>The browser, with its tabs and address bar | <img src="docs/gallery/files.jpg" alt="Files: your folders, with a search typed on the keyboard"><br>Files: your folders, with a search typed on the keyboard |
| <img src="docs/gallery/photo-360.jpg" alt="A 360 photo as the surroundings, with its filmstrip"><br>A 360 photo as the surroundings, with its filmstrip | <img src="docs/gallery/place-world.jpg" alt="Places: twenty-four photospheres to be in"><br>Places: twenty-four photospheres to be in |
| <img src="docs/gallery/settings.jpg" alt="Settings, as a window"><br>Settings, as a window | <img src="docs/gallery/games.jpg" alt="Twelve games"><br>Twelve games |
| <img src="docs/gallery/game-paint.jpg" alt="Paint: ribbons in the air"><br>Paint: ribbons in the air | <img src="docs/gallery/game-blobs.jpg" alt="Blobs: punch to fire"><br>Blobs: punch to fire |
| <img src="docs/gallery/game-vacuum.jpg" alt="Vacuum: clean your real floor"><br>Vacuum: clean your real floor | <img src="docs/gallery/game-toys.jpg" alt="Toys: a box that comes alive"><br>Toys: a box that comes alive |
| <img src="docs/gallery/game-golf.jpg" alt="Mini golf: eighteen holes at your feet"><br>Mini golf: eighteen holes at your feet | <img src="docs/gallery/game-coaster.jpg" alt="Coaster: a new course every ride"><br>Coaster: a new course every ride |
| <img src="docs/gallery/game-portal-through.jpg" alt="Portal: step through to another world"><br>Portal: step through to another world | <img src="docs/gallery/game-rhythm.jpg" alt="Rhythm: to your own music"><br>Rhythm: to your own music |
| <img src="docs/gallery/game-tower.jpg" alt="Tower: stack slabs on a real table"><br>Tower: stack slabs on a real table | <img src="docs/gallery/game-garden.jpg" alt="Glow garden: plants grow where you point"><br>Glow garden: plants grow where you point |
| <img src="docs/gallery/game-pong.jpg" alt="Orbital pong: your palms are the paddles"><br>Orbital pong: your palms are the paddles | <img src="docs/gallery/game-drive.jpg" alt="Skyline drive: steer by looking"><br>Skyline drive: steer by looking |
| <img src="docs/gallery/summary.jpg" alt="Every game ends with a summary"><br>Every game ends with a summary | <img src="docs/gallery/webxr-vr.jpg" alt="WebXR VR, through the lenses, with Exit VR at your feet"><br>WebXR VR, through the lenses, with Exit VR at your feet |
| <img src="docs/gallery/webxr-ar.jpg" alt="WebXR AR: a page placing a reticle on your floor"><br>WebXR AR: a page placing a reticle on your floor | <img src="docs/gallery/through-the-lenses.jpg" alt="What the phone's screen really shows"><br>What the phone's screen really shows |

## Repository

| Where | What |
|---|---|
| [`app/`](app/) | The app: the Xcode project (generated from `project.yml`), the Swift sources, the Watch app, the unit tests and the app's own [README](app/README.md), which is the full reference. |
| [`Tools/`](Tools/) | `native_build_and_run.sh` (build, install, launch, log, test, Simulator harness), the fixture-media makers and the EXR converter. |
| [`Hardware/`](Hardware/) | The printed viewer: OpenSCAD source, STLs, bill of materials, listing text. Doors for the other LiDAR Pro iPhones come from the [door generator](https://wemiller.com/apps/afterglow/door/). |
| [`docs/`](docs/) | The project site and its images. |

## Start here

1. **Print the viewer**: [ready to print on MakerWorld](https://makerworld.com/en/models/3559894-afterglow-cardboardxr-viewer-for-iphone-18-pro-max#profileId-4073827),
   or from [`Hardware/`](Hardware/) (OpenSCAD source, [bill of materials](Hardware/BOM.md)). On an
   iPhone other than the 18 Pro Max, [generate its door](https://wemiller.com/apps/afterglow/door/).
2. **Build the app** on a Mac with Xcode 27 and [xcodegen](https://github.com/yonaskolb/XcodeGen)
   (`brew install xcodegen`), signed into an Apple ID (a free personal team is enough), the phone
   unlocked and plugged in:

   ```sh
   zsh Tools/native_build_and_run.sh --ei passthrough 1
   ```

   The script generates the project when `project.yml` is newer, builds, installs, launches
   and prints the start of the session log. `--launch` relaunches what is installed, `--log`
   pulls the session log, `--test` runs the unit tests, `--sim` runs the Simulator harness.
3. **Put the phone in the viewer.** The launcher opens ahead over the surroundings; look down for
   the round button at your feet to bring the dock. Pinch to select, or tap the viewer's button.

Everything else, from the stereo rig and the pinch rules to each app and game, the phone view,
the launch options and the Simulator harness, is in [`app/README.md`](app/README.md).

## Requirements

- An iPhone with LiDAR and ARKit world tracking (built and tuned on the iPhone 18 Pro Max; the
  lens geometry is the printed viewer's).
- macOS with Xcode 27 and xcodegen to build; the Apple Watch app is optional.
- iOS 26.

## Tests and continuous integration

`zsh Tools/native_build_and_run.sh --test` runs the unit tests (lens geometry, hand geometry,
the pinch detector, browser helpers, media metadata) in the Simulator. The GitHub workflow in
`.github/workflows/ci.yml` does the same on every push: it generates the project, builds for
the Simulator with warnings as errors, runs the tests and parses the tools.

## Logs

The app writes `Documents/session.log` (`[Frames]`, `[Thermal]`, `[Pose]`, `[Hands]`,
`[Pinch]`, `[WebXR]`, `[Media]`, `[Games]` and the rest, one line each); the build script
copies it after a launch and `--log` pulls it any time. Known issues are in
[KNOWN_ISSUES.md](KNOWN_ISSUES.md), the plan in [ROADMAP.md](ROADMAP.md).

## Privacy and the network

Everything runs on the phone. The network is used only by the browser, by Apple Music through
MusicKit when you play it, and by the rhythm game's lookup of a song's tempo, which sends only its
title and artist to audiometa.io, and only when the song's own audio can't be read. Nothing is sent
anywhere else.

## Credits

Song tempo data for the rhythm game is provided by [audiometa.io](https://audiometa.io).

## License

Apache-2.0, as the upstream project. Third-party notices
are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
