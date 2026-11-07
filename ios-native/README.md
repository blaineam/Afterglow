# Afterglow, native

The native port of Afterglow for iOS: Swift, SwiftUI for the shell, Metal for the picture and
ARKit for tracking and the camera. It sits beside the Unity app and takes over from it phase by
phase (see "A native port?" in [ROADMAP.md](../ROADMAP.md)). Done so far: **phase 1**, the stereo
rig, head tracking and passthrough; **phase 2**, hands and pinch; **phase 3**, the browser and
WebXR; **phase 4**, media; the toolbar and menu of phase 5. Nothing here touches the Unity app's
code.

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

## Phase 3: the browser and WebXR

The Unity app's browser, on WebKit directly (`Browser.swift`, `WebTab.swift`, `WebBridge.swift`),
with the JavaScript shared as it is: the WebXR shim and the start page come from
`Assets/StreamingAssets/webxr/` (referenced by the project, not copied) and the helper script is a
copy of the plugin's `kHelperSource` (`Browser/web/afterglow-helper.js`). The contract is the
plugin's: three user scripts at document start (helper, `window.__afterglowConfig`, shim), one
message handler `afterglow`, and the `window.__afterglow*` calls for pose, hands, hover, click,
scroll, type, key, fill, select and end.

- **The window**: each tab is a web view of its own (scroll and forms kept between tabs; up to
  six), laid out 1280×800 points, held in a veil in the app's window at alpha 0.01 so WebKit keeps
  drawing it, and snapshotted twelve times a second with `takeSnapshot` (rendered by the web
  process, about 10–20 ms in flight) into a texture on a pane 1.25 m wide, 1.3 m ahead (four
  sizes; "place" re-hangs it where the head looks). Text is scaled with the page zoom (`textScale`,
  150 %) so it reads in the viewer.
- **Gaze and clicks**: the reticle is the head's forward ray on the pane; the helper draws the
  page's own crosshair at that point and highlights the element under it; a pinch beginning, a
  screen tap, or a **double tap on the viewer** (read off the accelerometer; the target is the
  element under the gaze when the first tap landed) clicks there. Looking at the top or bottom
  12 % of the page scrolls it.
- **The chrome and keyboard panels** (`Panels.swift`): SwiftUI views rendered to textures only when
  their content changes, with buttons at known rectangles the gaze hovers and a pinch presses. The
  chrome has the tabs, address, back, forward, reload, home, bookmark, size, place, keyboard, mic
  and close; a login prompt (save or fill) takes its second row. The keyboard is a gaze QWERTY
  with a symbols layer, shift, space, backspace, clear, mic and go, shown when a page field takes
  focus or the keyboard button is pressed; it types into the focused field, else the address bar.
- **Logins**: the helper's field detection as before; passwords are offered for saving and saved
  logins offered back, in the Unity app's Keychain item format (generic password, service = host,
  account = username or "(password only)"), so both apps share them.
- **Tabs, private tabs, history, bookmarks**: history (500, newest first, repeats within a minute
  folded), bookmarks and open tabs in `Documents/browser.json`; private tabs use a non-persistent
  store and leave nothing. The start page lists bookmarks and recent pages.
- **Dictation** (`Input/Dictation.swift`): the Speech framework, on device where it can be; the mic
  button on the keyboard or chrome starts it and the next press stops it and types what was heard.
- **WebXR**: on `sessionstart` the veil goes to alpha 1, scales to the screen and comes to the
  front; the page draws both eyes and the lens distortion itself (the shim's own 40×40 meshes
  from the same viewer numbers) while the app pushes the predicted head pose and the hands every
  frame and skips its own scene; a long press on the screen or the page's own exit ends it. The
  Simulator proves all of it but the hands: a test script (`actions`) presses panel buttons, types,
  looks, enters VR and screenshots.

Launch options: `web` (1: open at launch), `url <address>`, `textScale` (150), `actions <script>`.

## Phase 4: media

The Photos library in the viewer (`Media/`), after the Unity app's `VideoDemo` and its plugins:

- **Library** (`MediaLibrary.swift`): the smart albums with content (Recents, Favorites, Panoramas,
  Videos, Spatial, Screenshots, Live) and the user's albums, each item classified the Unity way
  (spatial by the subtype, a panorama by the subtype or an aspect of 2.4 and over, 360 by a 2:1
  shape), thumbnails through `PHCachingImageManager`, pictures decoded to BGRA textures (4096 px,
  panoramas 8192), and a spatial photo's two eyes from the HEIC's stereo pair group (or its first
  two images when unmarked, as an imported one is) into a two-slice array.
- **Video** (`VideoPlayer.swift`): `AVPlayer` with `AVPlayerItemVideoOutput` for ordinary videos
  and `AVPlayerVideoOutput` with the stereoscopic and monoscopic tag collections for spatial
  (MV-HEVC) ones, BGRA and Metal-compatible, every frame wrapped as a texture through a texture
  cache with no copy; the original version is asked of Photos so a spatial video's second layer
  survives edits. Looping, play, pause, ±10 s, a ten-step seek bar.
- **Projections** (`mediaFragment` in `Shaders.metal`): one full-screen pass turns each pixel's
  direction into a texture coordinate for the whole sphere (360), the front hemisphere (180), an
  equidistant fisheye, or a cylinder band (panoramas, 60° tall, span = aspect × 60° between 60°
  and 360°), with mono, side-by-side, top-bottom (left eye on top, as the Unity app) and
  two-slice (spatial) layouts, and a yaw to turn the picture; flat pictures and videos hang in a
  1.6 m frame ahead. The format button cycles Flat, Flat SBS, Flat TB, 360, 360 SBS, 360 TB, 180,
  180 SBS, 180 TB, Fisheye, Fisheye SBS, Panorama.
- **Panels**: the album grid and the item grid with thumbnails (five across, fifteen a page), and
  the player's controls below the picture.

- **Files** (`FileSource.swift`): the app's own `Documents/Media` and any folder the user picks in
  the Files app (a security-scoped bookmark, read in place so a large library streams rather than
  copies), walked for pictures and videos, searched by name from the scene keyboard, with
  thumbnails from ImageIO or a video frame at one second. Each file is classified by what it says
  about itself (`MediaMetadata.swift`, the Unity app's `MediaMetadata.cs`): an MP4's `st3d` stereo
  mode and `sv3d`/`equi` crop or spherical v1 `uuid` XML, a JPEG's GPano span, a HEIC's stereo
  pair, then words in the name (`360`, `180`/`vr180`, `flat`, `sbs`/`lr`/`3dh`, `tb`/`ou`/`3dv`,
  `mono`/`2d`), then its shape.

Proven in the Simulator with the Unity repo's fixture media (`Tools/sim_add_media.sh` makes it;
`xcrun simctl addmedia` adds it): a 360 video around the viewer, a spatial HEIC with an eye each,
portrait and landscape photos upright in the frame, the panorama and 360 still on their
projections, the flat video with its controls. Spatial MV-HEVC video and iCloud items await the
phone.

## Surfaces, occlusion and places

- **Surfaces** (`Room/RoomModel.swift`): ARKit's plane anchors, horizontal and vertical, kept as
  world-space meshes with each vertex's place on its plane, and the floor as the lowest large
  horizontal one. Plane detection costs CPU, so it runs only while the surfaces are wanted (the
  toolbar's ▦ toggle, the Places panel's "Scan room", or the room environment). They are drawn
  the Unity way (`surfaceFragment`): small X marks on a 20 cm grid, the plane's edges faded, a
  faint fill, fading in and out over half a second.
- **Occlusion** (`occlusionFragment`): with passthrough on in 6DoF, a depth-only pass writes the
  LiDAR scene depth into the eyes' depth buffer (each pixel's ray taken into the camera, the
  depth read where the confidence is at least medium, the point placed along the ray), so placed
  things drawn after it with a depth test hide behind real walls, tables and hands. The hands'
  own skeleton and the reticle are drawn without the test, since the LiDAR sees the hand itself.
  Off with `occlusion 0` or the menu's toggle; there is no depth in the 3DoF mode or without
  LiDAR.
- **Places** (`Room/PlacesApp.swift`): the surroundings are the synthwave scene, the real room
  (passthrough with the surfaces marked), one of seven drawn places, or a 360 photo or panorama
  from the Media folder drawn all round through the media projection; and the toolbar's 3DoF
  switch gives a stationary mode. The places (`placeSky`/`placeFloor` in `Shaders.metal`) are
  procedural, by day and by night with a two-second dusk: a forest (tree line, moss, fireflies at
  night), a desert (dunes, ripples), a beach (a sea with moving waves and foam), ruins (columns,
  flagstones), a cyberpunk city (lit towers, wet streets), the Moon (no air, the Earth hanging,
  craters) and Mars (butterscotch sky, red rock). Clouds drift and stars twinkle.
- **Bundled photospheres** (`Afterglow/Places/`, copied into the app as a folder): twenty-four
  360 pictures the owner chose, shown in Places as picture tiles (eight a page, each tile its
  own thumbnail with the name over it) beside the user's own 360 files and library photos:
  five from cameras and HDRIs (a beach cottage at night, a sequoia grove, a forest cabin at
  night, an evening meadow, a clear desert night under the Milky Way; the EXRs tone-mapped with
  `Tools/exr_to_place.py`) and nineteen generated ones named by their subjects (a grand library,
  a cosy cafe, a treehouse at night, a Japanese garden in autumn, a space station, a fjord
  village, a baroque church, a stone village street and more). 16 MB in all. The drawn places
  and the generation button are gone from Places (owner, 2026-11-07); the generator code stays
  behind the Environments folder for files dropped in by hand.

The Simulator proves the drawing with a synthetic floor and wall (`fakeplanes` in the test
script); plane detection, the floor height and occlusion need the phone.

## Recording and casting

- **Recording** (`Capture/EyeRecorder.swift`): the menu's "Record left eye" / "Record right eye"
  copies that eye's undistorted picture every frame into a pool buffer and encodes it as H.264
  through an AVAssetWriter at the display's rate; the movie lands in `Documents/Recordings` and
  is saved to Photos. The Simulator proved 240 frames in four seconds with none dropped.
- **Casting** (`Capture/ExternalDisplay.swift`): when the phone mirrors to an Apple TV (or any
  screen), iOS gives the app an external-display scene; a Metal layer on it shows the left eye
  flat, letterboxed, blitted each frame. The lens-warped phone screen itself is not what the TV
  gets. Untested without a second display.

## Games

A game host (`Games/GameHost.swift`) runs one game at a time; the Games window launches them.
When a game starts the launcher minimizes to the dock and the game's own controls open in a
window of their own (the paint palette; the rhythm style, tempo, restart and stop; the golf
holes), so nothing crowds the launcher (owner, 2026-11-07); closing that window stops the
game, and stopping brings the launcher back. Games draw into a small lit-mesh scene
(`Games/Scene3D.swift`): a mesh library built on the GPU once (smooth spheres, capsules,
cylinders, cones, tori, a thin ring, rounded boxes, discs), drawn per instance through
`meshVertex`/`meshFragment` with a model matrix, a colour and a material (roughness, metal,
glow, a surface pattern: dimples, stripes, checks, scales or noise), lit by one sun with a
sky/ground hemisphere, a rim and a little Fresnel, dimmed with the place's night. Under
everything a soft blob shadow on the floor; over it additive glow sprites with a radial falloff
for lamps, sparks, trails and bolts, and a particle system (bursts with gravity and drag) the
games share. The meshes test depth against the room's LiDAR prepass, so they hide behind real
furniture like the panels do. The games (`Games/Games.swift`):

- **Paint**: pinch and move to paint in the air. The palette, in the game's own controls
  window, picks the colour (eight swatches, or a rainbow by the hand's height), the size, the
  brush (a glossy tube, a flat ribbon facing you, or a glowing bead trail) and dynamics (the
  stroke thins as the hand speeds up); undo takes the last stroke. Sparks trail the brush. A
  stroke carries on through a pinch that flickers open for half a second (dots were left
  before), and the game runs in 6DoF, since painting in the air needs the head's position.
- **Blobs**: scaled, squashing blobs with eyes that follow you and glowing antennae squelch in
  by waves (each faster and larger); a punch forward (the hand moving ahead faster than 1.5 m/s)
  fires a plasma bolt from the hand along the gaze; hits splash goo, kills burst; a blob that
  reaches you costs a life and flashes the view red.
- **Vacuum**: dust bunnies (lumpy, noisy spheres) lie over the detected floor or a square round
  the player; a hand held low grows a chrome nozzle with a glow, and what it passes over swirls
  up into it; walking over a pile cleans it too.
- **Toys**: a painted toy box on the floor ahead holds seven toys, each built from parts: a car
  (body, cabin, wheels, headlamps), a duck (beak, eyes, tail), a rocket (fins, porthole), a robot
  (eyes, arms, legs, antenna), a plane (wings, tail, propeller), a dimpled ball and a top. Pinch
  a toy to carry it, let go to throw it: gravity, bounces off the floor, detected tables and the
  box's own floor, collisions, a dust puff on a hard landing; pinch in empty space for another.
  At the bottom of the box is a red button on a chrome base; pinch it, or select with the gaze on
  it, and every toy wakes: cars drive in arcs and climb out over the rim, ducks waddle and hop,
  rockets count down, lift off on a flame, arc over and parachute back, robots march in right
  angles swinging their arms, planes take off and circle the room banking into the turn with the
  propeller spinning, balls kick themselves about, tops spin and precess, all staying within a
  few metres of the box; the button again sends them to sleep.
- **Mini golf**: eighteen holes laid out one at a time on the floor ahead, the tee a step in
  front of the player. Each fairway is one felt surface (its polygon ear-clipped into a mesh)
  on a dark base, with wooden bumper walls along its edges in its own shape (straights,
  doglegs, a zigzag, a hook, islands, gates, a maze), ramps and hills, windmills whose blades
  block the gap, tunnel bridges, a cup with a flag that counts the hole in beads, par per hole
  and a card. A putter hangs from each hand (grip at the hand, a steel shaft to a brass head on
  the felt, facing the way the hand points); only the head moving through the ball putts it,
  at the head's speed, so a hand near the ball does nothing. The ball rolls and slows, bounces
  off the bumpers with three quarters of its speed, and drops in the cup. When it comes to
  rest more than a stride away the course shifts so it lies a step ahead again (the teleport
  between putts, also on the controls window's Step to the ball); the next hole lays out when
  the ball drops, or on Next hole. The whole course is laid out round the player at once,
  three holes abreast and six deep in a serpentine, 1.6 times the first draft's size, each on
  its dark base with rounded rails on the bumpers, lamps at its corners and its flag numbered;
  a scoreboard by the first tee shows the card in beads. Only the current hole has the ball.
- **Coaster**: a roller coaster over the grid. The course is poses half a metre apart from a
  list of segments (a chain lift, a drop, hills, a loop, banked turns, dips), repeated as the
  rider nears its end; the car follows it, gaining speed down the drops, losing it up the
  climbs, lifted by the chain on the way up. The rider stays where they stood, in a car drawn
  round them, and the track moves past through the car's inverse pose, so the room's panels
  (the Stop button among them) stay in reach and the view never leaves the car. Rails on
  sleepers and pylons (none where the track passes under itself, as in the loop, where a pylon
  would run through the rails), arch lamps, the car's tub, nose, wheels and lap bar.
  Passthrough is off while the coaster runs: it is a ride through the scene.
- **Portal**: a stone archway (fluted columns on plinths, a lintel, a glowing keystone) with a
  shimmering disc of the next world's colour in it and motes swirling in the doorway; walk
  through and the surroundings change palette, with a burst; back again for the previous.
- **Rhythm** (`Games/RhythmGame.swift`): glossy gems travel in along four lane rails to rings
  that pulse on the beat; punch or pinch one as it reaches its ring, or select with the gaze on
  the lane, to score with combos; hits flare. When the Music app has Apple Music playing, the
  notes run to the song's clock at its measured tempo: `Games/TempoAnalyzer.swift` reads ninety
  seconds of the song's own audio through AVAssetReader (when the device holds it unprotected:
  purchased, matched or ripped), takes an onset curve from the energy's rises and the strongest
  autocorrelation between 70 and 180 bpm, and keeps the answer by song id. A protected Apple
  Music stream gives no samples, so a public music catalogue is asked for the track's tempo
  by title and artist, then a second, keyed catalogue when `Documents/tempo-api-key.txt` holds
  a key for it; the tempo set with the slower and faster buttons stands when neither knows.
  With Apple Music playing the style buttons are gone: the song decides. Without music a built-in synthesiser plays in a style picked on
  the games panel: synthwave, techno, lo-fi, drum and bass or chiptune, each with its own
  tempo, drums and lead.

In the Simulator the test script's `fakehand 1|0|punch|off` stands in for a hand and `tap`
for the headset's double tap; every game has been run by script with the screen captured, and
the toy box's button pressed by gaze. Cost: a frame of the toy box awake is about 120 mesh
draws; the Simulator's software Metal keeps 56–60 fps with them.

## Controllers

`Input/Controllers.swift` listens for Bluetooth controllers through the GameController framework
(Joy-Cons, DualSense, DualShock, MFi pads): A selects, B closes the menu or the app, Menu opens
the menu, the left stick scrolls a page and the right stick looks in desk mode, and where a pad
reports motion (DualSense and DualShock do; Joy-Cons as iOS passes it) its attitude is kept for a
3DoF pointer. No controller pairs to an iPhone with camera-tracked 6DoF.

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

## The interface: Afterglow glass

The first phone round (2026-11-07) found the panels unreadable through the cardboard lenses
and the whole thing a pile of button grids, so the interface was remade on one design language
(`Browser/Panels.swift`, `PanelStyle` and `ButtonsView`):

- **Glass**: dark violet glass with a top highlight and a hairline rim, continuous corners,
  transparent outside the corners (the panel quads blend their alpha), rounded type, one pink
  accent for what the gaze is on and cyan for the current choice.
- **Type for lenses**: every control's text is sized from its height with a floor of 60 texture
  pixels; at a window's usual 1.8 m width and 1.4 m distance that is 2.5-3 degrees tall, the
  size a phone behind a cardboard lens needs (the earlier 26-34 px titles were about 1 degree).
  Panels show few things, large: tiles with an icon over a word, pills, round icons, rows.
- **Launch**: the app opens on the surroundings (the scene or passthrough) with the Home
  launcher ahead: eight tiles (Browser, Media, Files, Games, Places, Music, Settings, Lock).
  Launching an app closes Home and puts the app's window where it was. The browser no longer
  opens on its own (`web 1` as a launch option still does).
- **Windows**: traffic lights at the top left of every window (red close, yellow minimize,
  green size, cycling four widths from 1.3 to 3.2 m), the name as a grab handle (hold a pinch
  on it to drag), move on the right. New windows open 40 degrees to the right of the last.
- **The dock**: six tiles low ahead (Apps, Scene/Room, Hands, Recentre, Record, Settings)
  and a chip for each minimized window, which brings it back; hidden until asked for: a round Apps button lies on the floor half a metre ahead of the feet
  (look straight down), a select on it brings the dock for ten seconds. Neither shows during a
  WebXR session, 360 playback, or while the keyboard is up.
- **Browser chrome**: back, forward, reload, the address pill (select it for the keyboard;
  while a page loads it shows the progress), keyboard, dictation, bookmark and start on the
  first row; tabs as pills with new, private and close on the second; a login prompt takes the
  second row when there is one. The media viewer likewise shows Loading… over its controls
  until the first picture is up.
- **Photos**: tabs across the top (Library, Albums, Spatial, Panoramas, 360°, Videos) over a
  grid that scrolls by rows: twelve pictures in view with a badge for what each is (Spatial,
  360°, Panorama, a video's length), or the user's own albums as covers with their names and
  counts, eight in view. Scroll with the arrows at the grid's side, by holding the gaze at its
  top or bottom edge, by holding a pinch on it and moving the hand up or down, or by dragging
  on the phone. The viewer's controls: back to the grid, previous and next, the format (a
  picker of the twelve projections, not a cycle), recentre and turn, hide (the controls go
  away until the next select, so the picture is all there is), with the transport and a seek
  bar for videos and, for pictures, a filmstrip of the neighbouring pictures to press. The 360
  collection is found by shape over the whole library, not its newest two thousand. A 360, 180
  or panorama picture is the surroundings while it plays, passthrough or not.
- **Windows open in free slots**: a new window takes the nearest free arc round the user,
  ahead first, then alternately right and left, never through an open window.

## Phone view

`view 1` (or the control strip's toggle, or Settings) is the phone in the hand instead of the
viewer, as the Unity app had: one eye at the camera, a symmetric frustum the screen's shape and
58 degrees tall (the wide camera's, so passthrough is life-size), no lens warp, drawn full
screen through the blit pipeline. The head is still tracked, so the phone is a window moved
around the room. A tap selects what it lands on (the tap's pixel becomes the pointer ray for
that frame), a double tap brings up the system keyboard (the view is a `UIKeyInput`; text goes
where dictation goes, Return is Go), a drag scrolls the page or swipes between pictures in the
viewer, a three-second press ends a WebXR session, and a two-finger tap shows or hides the
control strip. A single tap selects what the cursor at the screen's centre is on (the phone is
aimed like a torch; `tapAtPoint 1` selects where the tap lands instead).
Without tracking (the Simulator) a drag still turns the head.

## Pinch, second round (and third, and fourth)

The phone round found real pinches blocked and a "perspective trick" (a straight index finger
whose tip the thumb crosses in the image) accepted. The LiDAR tip-depth rule was the cause of
both: at 40 cm it cannot tell two touching fingertips apart, so it blocked true pinches, and it
never caught the trick. It is gone. A pinch now also needs the index finger bent: its knuckle
to tip over the length along its bones, in the image, which is 1 for a straight finger from any
angle (the points stay in line) and 0.6-0.85 in a pinch. That too failed on the phone: from the
headset's camera the index finger points at the lens in a pinch and its joints project in a line
(0.91-0.99 on every real pinch), so the curl is logged and no longer gates. The tips' distance
with its hysteresis decide: a start closer than 3 cm for two results, a release past 5 cm for
three (a four-result start at 2.5 cm took about a second on the phone); the edge-on guard is
looser (40 % open blocks a start, not 60 %). A hand back in view after a gap keeps its pinch only
if the tips are still together; WebXR had seen hands pinched for good after they returned. A
WebXR session ends on the viewer's double tap or a three-second press on the screen, never a
pinch, and two seconds in (once the page has settled) runs in 3DoF on the ultra-wide camera at
20 hand images a second while it lasts, with a pinch needing three results to start there (a
page acts on every select). The view keeps its layout size through a session: changing it fired
a resize the owner's player answered by disposing its renderer, ending the session 0.2 s in. The predictor's callbacks (the viewer's taps, the lock's
motion) follow the camera across that switch; before this they stayed on the first camera, so
in 3DoF the viewer's double tap did nothing and a session could not be ended. A session that
ends within three seconds of starting is logged as the page's doing, with the page's reason.
The grab demo's cubes are behind the `demo 1` launch option. A wrist at the image's edge, or one Vision was unsure of, is held
where the knuckles say it was last seen, so the hand no longer folds forward at the wrist when
it reaches the camera's edge.

## Windows, Home, settings, lock, music

- **Windows** (`Home/WindowManager.swift`): every app is a window in the scene with a title bar
  above its pane: a move mode (✥, the window follows the gaze until the next select), size
  steps (− +, five widths from 0.8 to 2.6 m), minimize (▁, to a chip on the dock) and close (✕);
  holding a pinch on the title drags the window at the distance it was grabbed. Several windows
  are open at once; new ones hang 40° to the right of the last, round the user. The browser,
  media, files, games, places, settings and music are all windows.
- **Home** (`HomeMenu`): the toolbar's More opens the Home window, tiles for every app (a dot on
  the open ones), a lock button; launching closes Home.
- **Settings** (`Home/SettingsWindow.swift`): render scale, frame rate, browser text, hand rate,
  head prediction as rows with − and +; passthrough, hands, 6DoF/3DoF, surfaces, occlusion and
  the passcode as toggles.
- **Lock** (`Home/AppLock.swift`): a six-digit passcode kept as `salt$hash` in the Keychain (the
  Unity app's format); asked for at launch, after a minute in the background, and when the
  viewer comes off, which the motion sensors tell: the phone laid flat for two seconds, or held
  still for thirty. While locked only the keypad draws and takes the gaze. Set and removed from
  Settings; the Home menu locks on demand.
- **Music** (`Home/MusicApp.swift`): Apple Music through MusicKit (authorization asked on first
  open): what is playing with its artwork and the transport, and the library (playlists, then
  albums) as a paged list to play from; the music keeps playing under the other apps.
- **Branding**: the bundle id is now `com.wemiller.afterglow`, the same as the Unity app's, so
  installing the native app replaces it on the phone; the icon is the Unity app's
  (`Assets/_Project/Branding/AppIcon.png`) in an asset catalog; version 2.0.0.

## Apple Watch as a controller

`AfterglowWatch/` is a single-target watchOS app embedded in the iOS app. Its one button carries
`handGestureShortcut(.primaryAction)`, so the watch's double-tap gesture (and a tap on the
button) sends `select` to the phone over WatchConnectivity, and turning the Digital Crown sends
`scroll` with a delta. On the phone `Input/WatchReceiver.swift` turns `select` into the same
request as a double tap on the headset (select what the gaze is on, or pinch for the games) and
`scroll` into browser scrolling. The watch app needs no authorization; it is reachable whenever
the phone app is in the foreground. Not tried on a real watch yet: the Simulator cannot pair
one with the phone build the harness uses.

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
| `web`, `url`, `textScale` | 1, –, 150 | the browser open at launch, a page to open, the page zoom in percent |
| `surfaces`, `occlusion` | 0, 1 | scan and show the room's surfaces; hide placed things behind the real room (LiDAR, 6DoF, passthrough) |
| `actions` | – | a test script: `wait N; press <button>; type <text>; key <Backspace\|Clear\|Enter>; look <yaw> <pitch>; tap; dump; screenshot; immersive; end; js <expr>; record <eye>; fakeplanes; fakehand <1\|0\|punch\|off>; open <window>; lock; press win:<window>:<move\|larger\|smaller\|minimize\|close>` |
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
  Afterglow/Browser/          Browser, WebTab, WebBridge, BrowserWindow, Panels (chrome + keyboard), BrowserStore, CredentialStore, web/afterglow-helper.js
  Afterglow/Media/            MediaLibrary (Photos), VideoPlayer, MediaApp (grids, viewer, formats)
  Afterglow/Home/             Toolbar (dock), WindowManager + HomeMenu, SettingsWindow, AppLock, MusicApp
  Afterglow/Room/             RoomModel (surfaces, floor), PlacesApp (environments), SkyboxGenerator (AI photospheres)
  Afterglow/Capture/          EyeRecorder (one eye to a movie), ExternalDisplay (a TV gets the left eye flat)
  Afterglow/Games/            GameHost, Scene3D (meshes, lit scene, particles), Games (Paint, Blobs, Vacuum, Toys, Golf, Ride, Portal), RhythmGame (+ Synth)
  Afterglow/Input/            HeadsetTap, Dictation, Controllers (GameController pads)
  Afterglow/Input/            HeadsetTap (double tap on the viewer), Dictation
  Afterglow/Log/              SessionLog, FrameTimingLog, ThermalLog
  AfterglowTests/             the optics against the Unity app's numbers
```
