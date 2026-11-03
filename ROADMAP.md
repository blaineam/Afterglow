# Expansion roadmap

Fork of [brenpoly/CardboardXR](https://github.com/brenpoly/CardboardXR) (upstream `v1.0.0`,
Apache-2.0). Goal: first-class **iPhone 18 Pro Max** support, plus WebXR browsing, spatial
media from Photos, more mini games, prebuilt installers, and — as stretch goals — SteamVR
streaming and HDMI capture.

Upstream already does more than it looks. Before adding anything, know what's there:

| Asked for | Upstream state |
|---|---|
| Stereoscopic video | **Mostly done.** 360/VR180, mono + side-by-side + top/bottom, format from filename tags |
| Mini games | **Four exist.** Air Paint, Orb Rush, Portal, Cube Sandbox, on an additive-scene `DemoCatalog` |
| Prebuilt APK | **Done.** `Tools/release_android.sh` signs and drafts a GitHub release |
| Prebuilt IPA | Missing. iOS is build-from-source only |
| 3D printed viewer | On MakerWorld: iPhone 15 Pro, iPhone 16 Pro, Pixel 9 Pro. **Print files only, no CAD source** |
| WebXR, spatial photos/video, SteamVR, HDMI capture | None of it exists |

So the work splits into *retuning what's there for a bigger, cooler-running phone* and
*four genuinely new subsystems*.

---

## Device facts

Verified against Apple's spec sheet, not assumed:

| | iPhone 15 Pro (upstream's test device) | iPhone 18 Pro Max |
|---|---|---|
| Body | 146.6 × 70.6 × 8.25 mm | **163.4 × 78.0 × 8.75 mm** |
| Mass | 187 g | **249 g** |
| Display | 6.1", 2556 × 1179 @ 460 ppi | **6.9" (6.86" rect), 2868 × 1320 @ 460 ppi** |
| Active area | 141.1 × 65.1 mm | **158.4 × 72.9 mm** |
| Per-eye half-width | 70.6 mm | **79.2 mm** |

Three consequences that drive everything below:

1. **+8.6 mm of screen per eye — most of which cannot be used.** This was wrong in the first
   draft of this file, and the arithmetic is worth keeping. With Cardboard v2 lenses the
   horizontal view is *already* lens-limited on a 6.1" phone: its screen subtends 61° and the
   profile allows 60°, so the 6.9" phone's 72.5° of screen falls outside what the lens renders
   and is thrown away. The 60° is Google's statement about that lens, not an arbitrary cap, so
   raising it only pushes the picture past the lens's usable field.
   **Vertically there is a real gain**: the 6.1" screen runs out at about 52°, short of the lens,
   where the taller screen reaches the full 60°. So a bigger phone buys a taller view, not a wider
   one — and centring the lenses on the screen instead of standing them above a tray buys more
   still (57.6° each way, 115.2° total, against the tray's 50.0/60.0 and 110.0). That is why
   `Hardware/viewer.scad` centres them and ships its own viewer profile.
2. **+62 g (+33%) of phone mass**, on a lever arm in front of the face. This is a comfort and
   strap problem, not just a bigger pocket in the tray.
3. **A20 Pro + vapour chamber.** The premise of this whole expansion. Upstream's limits
   (`fps 120`, hand models at 7–31 ms/frame, "fair" thermal state in ~3½ min on a 15 Pro)
   were measured on an air-cooled A17 Pro and must be **re-measured, not assumed better**.

---

## Phase 1 — Make the 18 Pro Max correct — **done except the thermal retune**

Nothing else is worth doing while the stereo geometry is wrong.

### 1.1 Physical screen size on iOS *(bug, not a feature)* — **done**

`Assets/_Project/Scripts/Stereo/ScreenMetrics.cs` reads real per-axis DPI from
`DisplayMetrics` on Android, but on iOS falls through to `Screen.dpi` — which comes from
Unity's own device table. **Unity 6000.6.0f1 predates the iPhone 18 Pro Max**, so that lookup
may return a wrong value or the 160 dpi fallback. Physical screen size feeds the lens
distortion directly, so a wrong number means wrong stereo scale and wrong distortion on
every frame, silently.

Fix: a native plugin beside `Plugins/iOS/CardboardXRDeviceState.mm` reporting
`UIScreen.nativeBounds` × scale and a `hw.machine` → ppi table, with the Unity value as
last resort. Log which source won, as `ScreenMetrics` already does.

### 1.2 Viewer profile for brenpoly's own viewer — **done**

The only built-in profile is **Cardboard v1** (42 mm screen-to-lens, 60 mm inter-lens,
K₁ 0.441 / K₂ 0.156) — but the printed viewer uses **Cardboard v2 lenses**. Unless a QR code
is scanned, the app runs v2 optics through v1 math.

Worse, the viewer has a **focus wheel that moves the lens carriage**, and
`screenToLensDistance` is a single fixed number in `ViewerParams` with no way to tell the app
where the carriage actually is. On a thicker phone the carriage sits differently again.

Fix: ship a built-in profile per printed variant, and add a focus-offset control to the
settings panel that adjusts `screenToLensDistance` live, so the software can be matched to
where the wheel actually is.

### 1.3 Thermal and frame-rate retune — **not started; needs a device**

Re-measure first, then raise budgets: hand-model main-thread cost, time-to-`fair` from cold,
and what frame rate actually holds with a hand in view. Replace the global
`fps`/`renderScale`/`msaa` defaults with per-device tiers so the 18 Pro Max isn't capped by
15 Pro numbers. Update `KNOWN_ISSUES.md` with the new figures — several of its entries are
device-specific and will read as false on the new phone.

### 1.4 Housekeeping

Add the 18 Pro Max to `Tools/record_eye.py`'s `--phone` profiles.

---

## Phase 2 — The printed viewer

**There is no CAD source anywhere.** The MakerWorld listing publishes per-phone print files
(3MF) for three phones; the repo has no `.scad`, `.step` or `.f3d` at all. A fourth phone
therefore means either getting the source from brenpoly, or authoring a parametric model.

Recommendation: **author a parametric OpenSCAD model in this fork**, under `Hardware/`,
driven by a phone table (width, height, thickness, camera-island cutout, port clearance) and
a lens block. Four phone variants already exist and users on the listing are asking for
more — a parametric model makes each new phone a data row instead of a redraw.

Design points specific to this phone:

- Tray grows +16.8 mm long, +7.4 mm wide, +0.5 mm deep over the 15 Pro.
- **The rear camera must stay fully clear.** It drives passthrough, hand tracking and QR
  scanning — an occluding cutout doesn't just look wrong, it breaks tracking. The 18 Pro's
  camera island differs from the 15 Pro's.
- **+62 g needs addressing**, by a top strap, a counterweight pocket at the rear, or both.
- Lens carriage travel should be re-checked against the thicker body and the new
  screen-to-lens distance.

### Licensing — important

The code is Apache-2.0, but the MakerWorld model is **CC BY-NC-SA**: attribution,
**non-commercial**, share-alike. Any model derived from it inherits those terms. A model
authored from scratch here is yours to license, but if it's a port of brenpoly's geometry it
is a derivative. Worth deciding deliberately before publishing print files.

### Bill of materials

`Hardware/BOM.md`, with sourcing links for everything not printed: Cardboard v2 lenses, head
strap, face foam, magnets, fasteners, and the optional extras Phase 5 needs. **Blocked on one
input**: the exact lens part the design assumes. "Cardboard v2 lens" is a 34 mm focal length
convention, not a part number, and guessing it would make the whole BOM wrong — it needs to
come from the MakerWorld `README.pdf` assembly guide or from brenpoly.

---

## Phase 3 — Media

### 3.1 Flat screen projection — **done**

`VideoFormat.Projection` is only `Full360` or `Half180`; both wrap the video on a sphere.
There is no **flat rectilinear screen**. Adding `Projection.Flat` — a quad at a settable
size and distance, honouring the existing `StereoLayout` so side-by-side 3D films work —
gives "a massive screen in a virtual room", and is also the display surface for HDMI capture
(5.2) and desktop streaming (5.1). Cheapest high-value item on the list.

### 3.2 Spatial photos — **done**. Spatial video — **not started**

The strongest new feature, and the one that only works properly on this hardware. iPhone
15 Pro and later shoot **MV-HEVC**, which carries both eyes as separate layers in one file.

- Photos access via `PHPhotoLibrary`, filtering on `.spatialMedia`.
- A plain decode gives only layer 0, the "hero" eye. Both eyes need VideoToolbox told
  explicitly to decode both layers (iOS 17.2+).
- Unity's `VideoPlayer` cannot do this, so this is a native AVFoundation + VideoToolbox
  plugin writing both eye textures into Metal textures Unity samples — the same shape as the
  existing `VideoSphere` eye-rect split, but fed per-eye instead of by cropping one frame.
- Spatial **photos** (HEIC stereo pairs) are the easy half and worth doing first.

### 3.3 More mini games

The `DemoCatalog` + additive-scene pattern is good and adding demos is cheap. The real
constraint is input, not engine: gaze + pinch + one hand that, per `KNOWN_ISSUES.md`, leaves
the 68° × 42° camera cone often (4 of 8 cube drags in one test). Games should keep hands low
and central and never require two. Candidates: a whack-a-mole on detected surfaces, a
gaze-aimed tower defence on the real floor, a catch/juggle game, a room-scale hide-and-seek
using found planes.

---

## Phase 4 — Distribution

### 4.1 Prebuilt IPA

`Tools/release_ios.sh`, mirroring `release_android.sh`. The build is the easy part; **how a
stranger installs it is not.** An IPA is not a double-clickable APK:

| Route | Reach | Cost |
|---|---|---|
| **TestFlight** | 10,000 testers, no sideloading | Paid developer account; each build reviewed |
| **AltStore / Sideloadly** | Anyone, their own Apple ID | **7-day expiry** on a free account; fiddly |
| **Developer-signed IPA** | 100 registered UDIDs | Collecting UDIDs by hand |
| **EU alternative distribution** | EU only | Notarisation, developer terms |

TestFlight is the honest answer for "users can self-install". Plan for it, and ship the
unsigned IPA alongside for people who sideload.

### 4.2 App Store — stretch

Realistic risks, in order: **2.5.6** (web content must use WebKit) hits the WebXR browser
hardest, since it is a browser built on an injected polyfill; arbitrary desktop streaming and
capture-card input are both "app as a window onto uncurated content" problems. The headset
form factor itself is fine.

Treat TestFlight + sideload as the shipping path and the App Store as a bonus. Submitting a
build with the browser and streaming features **disabled** is the plausible route in.

---

## Phase 5 — Stretch goals

### 5.1 WebXR browsing — **not started**; architecture settled, see below

**iOS Safari does not support WebXR.** Not in 26, not in 27; `immersive-vr` is Vision Pro
only, and Apple has published no iOS timeline. So this cannot be "open a WebXR page in a web
view" — there is no WebXR to open.

What works instead: a native `WKWebView` rendered into a Metal texture, with the **WebXR
polyfill** injected into the page and fed head pose, eye matrices and pinch from this app's
own tracking, which already produces all three. The page renders its two eye views into its
canvas and this app composites them.

Expect: fine for well-behaved three.js/A-Frame content; broken on anything touching native XR
sessions; and a real performance cost, since a browser compositing two eye views is now
competing with the hand models for the same thermal budget. Scope it as "view WebXR scenes",
not "a VR web browser".

### 5.2 HDMI capture — **blocked on iPhone**

Worth saying plainly: **iPhone does not support UVC external cameras.**
`AVCaptureDevice.DeviceType.external` is iPad-only, and the iPhone 15 Pro's USB-C port did not
change that. No capture card will enumerate. I found nothing indicating iOS 26 or 27 changed
it; this is the one request on the list I think is simply unavailable on the target device.

Two ways to still get Switch gameplay onto a giant virtual screen:

- **Network encoder (works on iPhone, recommended).** HDMI → a small RTSP/SRT encoder box →
  Wi-Fi → the app plays the stream on the Phase 3.1 flat screen. Adds ~50–150 ms, fine for
  anything that isn't twitch-competitive, and needs no new platform capability.
- **Android build.** USB-host UVC does work there. Real, but it only helps the Android target,
  and the printed viewer is sized for an iPhone.

### 5.3 SteamVR streaming — the biggest single item

Don't invent a protocol: be an **ALVR client**. The server side already exists as a SteamVR
driver, the visionOS client is open source, and a (now deprecated, ARKit-based) iOS client
proves the path. Work is binding `alvr_client_core` into Unity, HEVC decode through
VideoToolbox, and pushing pose upstream.

The honest caveat is **input, not video**: ALVR expects two 6DoF controllers. This headset has
gaze, one hand, and no controllers, so most SteamVR titles are unplayable regardless of how
good the streaming is. Seated, gamepad-driven and cockpit games are the realistic target.
Bluetooth gamepad support is a cheap, large win here and should land before the streaming
work.

---

## Suggested order

1. **Phase 1** — screen metrics, viewer profile, thermal retune. Everything depends on it.
2. **Phase 3.1** — flat screen. Small, and unblocks 3 later features.
3. **Phase 2** — parametric model + BOM, so the thing is printable.
4. **Phase 3.2** — spatial media from Photos. Best new feature on the list.
5. **Phase 4.1** — IPA + TestFlight.
6. **Phase 3.3** — more mini games, as filler between the heavier items.
7. **Phase 5**, in order: gamepad support → 5.2 network encoder → 5.1 WebXR → 5.3 SteamVR.

## Where it stands

| | State |
|---|---|
| Screen measured without Unity's device table | Done, unbuilt |
| Cardboard v2 profile + focus-wheel offset | Done, unbuilt. Set with `focus N`; no settings-panel control yet |
| Flat screen projection | Done, unbuilt |
| Spatial photos from Photos | Done, unbuilt |
| Printable viewer + BOM | Written, **unrendered** — OpenSCAD is Gatekeeper-blocked on this machine |
| Thermal retune, spatial video, WebXR | Not started |

**Nothing here has been compiled.** Unity 6000.6.0f1 is not installed on this machine, so no C#
has been through a compiler, no EditMode test has run, and no `.mm` has been through clang. The
code was written against the repo's own idioms and the arithmetic in it was checked by hand, but
that is not the same as building. Installing Unity is the single thing standing between this and a
real test.

### WebXR, when it is picked up

The approach is settled and worth writing down, because the obvious one does not work. iOS Safari
has no WebXR, and rendering a `WKWebView` into a Unity texture at headset frame rates is not
possible with public API. So: overlay a full-screen `WKWebView` above Unity's view and let the
*page* draw the stereo pair and the barrel distortion itself, with a WebXR shim injected into it
and fed this app's own fused head pose — which is better than the `DeviceOrientation` a page could
get for itself. Unity hides its own view while the browser is up. The open question is whether to
vendor `webxr-polyfill` (MIT, battle-tested, but its cardboard path wants `DeviceOrientation`) or
write a small shim for the subset that matters; vendoring is the lower-risk start.

## Open inputs

- The exact **Cardboard v2 lens part** the viewer assumes (blocks the BOM).
- Whether to ask brenpoly for **CAD source** or author the parametric model from scratch.
- Whether **Android** stays a first-class target, which decides if the printed viewer needs
  non-iPhone trays.
