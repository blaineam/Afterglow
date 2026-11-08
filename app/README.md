# Afterglow, the app

Afterglow for iOS: Swift, SwiftUI for the shell, Metal for the picture and ARKit for tracking and the
camera. It began as a port of an earlier Unity app, which is why these notes compare with it; that
app is no longer in the tree, only in git history.

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
  app's shader does, so the room is life size and the picture only moves with head rotation.
  Over it, with LiDAR, **3D passthrough** (Settings, on by default; 2026-11-08): the image laid
  on the scene depth as a 128 × 96 mesh in the world and drawn from each eye, so the room has
  its own stereo depth and virtual things sit on it. Shown at infinity in both eyes, the room
  made a virtual floor or the vacuum's dust look far above the real floor. Cells across a jump
  in depth are dropped and the flat passthrough shows through the gap. The
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
`Afterglow/Browser/web/` (the app's own copy since the repository was restructured round it; the Unity app's original is under `unity/`) and the helper script is a
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
  brush (a glossy tube, a flat ribbon facing where you stood, or a glowing tube) and dynamics
  (the stroke thins as the hand speeds up); undo takes the last stroke. Each stroke is one
  smooth mesh: a Catmull-Rom spline through its points with the diameter blending along it, a
  ring of vertices at each sample on a parallel-transported frame, rebuilt only while it
  grows (a chain of capsules read as lumps). Sparks trail the brush. A
  stroke carries on through a pinch that flickers open for up to a second (dots were left
  before), the brush point is smoothed per hand and a jump past 30 cm between results is
  dropped (the flat hand fit jitters in depth when the hand moves fast, which painted jets
  into the distance). Every game but the coaster runs in 6DoF: hands and a body in the room
  need the head's position.
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
  the ball drops, or on Next hole. The course stands on a deck 5 cm above the floor: at floor
  level the room's own LiDAR depth swallowed the felt and left only the walls on the phone. The
  flag hangs from its pole and waves about it. The whole course is laid out round the player at once,
  three holes abreast and six deep in a serpentine, 1.6 times the first draft's size, each on
  its dark base with rounded rails on the bumpers, lamps at its corners and its flag numbered;
  a scoreboard by the first tee shows the card in beads. Only the current hole has the ball.
- **Coaster**: a roller coaster through whichever world Places has up. The course is random
  each ride and one smooth closed curve (2026-11-08; the earlier segment-laid lap dragged its
  last stretch up onto the start and jumped the car back to the station): a plan that wobbles
  round a centre, and a height profile along it joined by smoothsteps (zero slope at every
  join), flat at the station, a chain lift of 16-24 m, a first drop into a flat valley that
  carries a vertical loop when the drop gives the speed for one (offset sideways so it never
  meets itself), smaller hills, and a run back to station level. Speed comes from energy less
  friction and drag, the chain on the lift, and the brakes, which bring the car to rest exactly
  where it boarded; the size is tuned until a ride takes about two minutes. At the end the
  ride stops at the station and shows its summary (time, distance, top speed, highest point,
  loops) with Ride again. `GamesTests` checks the course has no gap, no sudden turn and ends
  at rest. The car waits at the station with its controls window up (Next world cycles
  the bundled photospheres, New course draws another, Ride starts); once riding the camera
  moves by the car's pose relative to where the ride began (a point at the rider's start head
  maps to the seat), so the whole world climbs, tilts and spins round them, the interface stays
  out of the way, and the round button at the feet, kept a metre below the head in the rider's
  own frame whatever the world is doing, reads Exit ride; the viewer's double tap ends it too.
  Rails on
  sleepers and pylons (none where the track passes under itself, as in the loop, where a pylon
  would run through the rails), arch lamps, the car's tub, nose, wheels and lap bar.
  Passthrough is off while the coaster runs: it is a ride through the scene.
- **Portal**: a stone archway (fluted columns on plinths, a lintel, a glowing keystone) with a
  shimmering disc in it and motes swirling in the doorway. It stands where there is room to
  walk through and on (2.6 m clear by the room scan's walls, doors and furniture, ahead first,
  else the nearest clear direction round the player; logged as `[Games] Portal: placed`).
  Walk through, or press Step through, and the room gives way to one of the photospheres;
  walk back through, or Back to the room, and the room returns. Move it in front of me
  re-places it.
- **Rhythm** (`Games/RhythmGame.swift`): glossy gems travel in along four lane rails to rings
  that pulse on the beat; punch or pinch one as it reaches its ring, or select with the gaze on
  the lane, to score with combos; hits flare. When the Music app has Apple Music playing, the
  notes run to the song's clock at its measured tempo: `Games/TempoAnalyzer.swift` reads ninety
  seconds of the song's own audio through AVAssetReader (when the device holds it unprotected:
  purchased, matched or ripped), takes an onset curve from the energy's rises and the strongest
  autocorrelation between 70 and 180 bpm, and keeps the answer by song id. A protected Apple
  Music stream gives no samples, so audiometa.io's free music data API is asked for the track's
  tempo by title and artist, and only an exact match of title and artist is believed. Its key
  comes from the builder's Keychain at build time (`Tools/embed_tempo_key.sh`); the tempo set with the slower and faster buttons stands when neither knows,
  else the style's default (112 for synthwave), and the status and the Music window say which
  it was, so a default never reads as a match (the first phone rounds found no song in the
  free catalogue, 2026-11-07). With Apple Music playing the style buttons are gone. Without music a built-in synthesiser plays in a style picked on
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
- **The dock**: six tiles low ahead (Apps, Scene/Room, Hands, Recentre, Record, Settings),
  a chip for each minimized window, which brings it back, and, when Apple Music has a song
  queued, back, play or pause and next; hidden until asked for: a round Apps button lies on the floor half a metre ahead of the feet
  (look straight down), a select on it brings the dock for ten seconds. Neither shows during a
  WebXR session, 360 playback, or while the keyboard is up.
- **Start page**: the app's own (`Browser/web/start.html`), in the glass design: the mark, a
  line on how to type, the bookmarks and history as tiles the app fills in, and three tips for
  the viewer. The page shared with the Unity app stays as the fallback.
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
  picker of the twelve projections, not a cycle), recentre and turn, hide (the controls and
  the window's bar go away until the next select, so the picture is all there is), spread
  evenly from margin to margin; for videos the transport and a scrub bar with a thumb (a pinch
  held on it drags, a select jumps, the times read beneath), for pictures a filmstrip of the
  neighbouring pictures to press. A viewer window closed or minimized pauses what it played. The 360
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
viewer, and a three-second press ends a WebXR session. The cog in the top-right corner drops down
Passthrough, 3DoF and Phone view as checked items. A single tap selects what the cursor at the screen's centre is on (the phone is
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
  phone is perfectly still for ten seconds (a head holding a viewer never is; a phone on a
  table is). The earlier "laid flat" rule fired when the wearer looked down at the dock. While
  locked only the keypad draws and takes the gaze. Set and removed from
  Settings; the Home menu locks on demand.
- **Music** (`Home/MusicApp.swift`): Apple Music through MusicKit (authorization asked on first
  open): what is playing with its artwork, its tempo's source and the transport in a window
  sized to that, and the library (playlists, then albums) as a paged list to play from; the
  music keeps playing under the other apps.
- **Branding**: the bundle id is now `com.wemiller.afterglow`, the same as the Unity app's, so
  installing the native app replaces it on the phone; the icon is the Unity app's
  (copied from the Unity app's branding into the asset catalog); version 2.0.0.

## Eighth phone round (2026-11-08)

- **The floor**: ARKit's own floor plane wins (the largest, since stairs and a sunken step are
  floor too), else the lowest large level plane 90 cm below the head (never a table, seat or
  ceiling), else a ray straight down from the camera once a second; level planes are always
  detected, walls only with Surfaces. The neon floor, games and dock read the same height.
- **6DoF and 3DoF switches**: the new tracker's frame is not the old one's, so 0.6 s after a
  switch every open window is hung again in an arc round the way the head faces, in its old
  order (`WindowManager.rearrange`), and a WebXR session's world is re-zeroed. The dock is hung
  ahead of the head each time it opens.
- **WebXR facing**: the page's world starts at the head and faces where it faces (pose and
  hand joints sent in that frame), set on the session's first frame and after a switch.
- **Pinch**: 2 cm to start over three results (four in WebXR), 4.5 cm to release; the phone's
  log had real pinches start at a median 1.6 cm and early ones between 2.2 and 3 cm.
- **Games**: picking a game while another runs is a change too (the menu minimizes and the
  controls follow; the menu is only the games now). Every game has a controls window. A pinch
  that begins on a window, the dock or a summary never paints, spawns or fires. Games that end
  show a summary panel ahead (Blobs: score, wave, popped, accuracy, time; Vacuum; Golf's
  card; the coaster's ride) with Play again and Exit game. Toys: a big glowing button on the
  box's rim, pressed by gaze or a pinch near it before anything else, and Come alive, New toy
  and Tidy up in the controls; a pinch spawns a toy only at the box's open top.
- **Browser text**: the size setting now applies live (it saved but never reached the page),
  starts at 220%, and has smaller and larger buttons on the browser's bar; never during a
  WebXR session.
- **Music** opens at 1.0 m. **The dock**: six tiles, with minimized windows and the music's
  controls on a tray row above.
- **Voice unlock**: Say your passcode on the lock listens on the phone only (it refuses where
  only server recognition exists) and turns the spoken digits into the passcode; what was
  heard is never logged or shown.
- **Harness**: the Simulator app is installed by name and the build output lives off iCloud
  (`~/Library/Developer/Afterglow/native-derived`): an iCloud "Afterglow 2.app" copy sorted
  first and ran stale code. The last run's log is removed before launch, so screenshots fire
  at their own steps. New verb `dock`.

## Ninth phone round (2026-11-08)

The owner's run of round eight: the coaster, toy box, games menu, paint, WebXR facing, portal
and floor are right now. This round fixes what was left.

- **Quick pinches**: a pinch and release registers without holding. In a real pinch the thumb
  hides the index tip (or the other way round) and Vision rates the hidden one about 0.1; that
  result had cleared the three-in-a-row count. Now a hidden tip counts when the other is sure,
  both guessed pauses the count, a result between 2 and 4.5 cm pauses it, and only an open
  hand or more than four paused results clear it. The tips' distance is taken before the joint
  smoothing, which lagged a tenth of a second and flattened a quick pinch's dip.
- **The wrist**: Vision now and then puts the wrist past the fingertips. A wrist always sits on
  the far side of the knuckle line from the fingers' middle joints, however the hand turns or
  faces, so one on the fingers' side is put back where the knuckles last had it, before the
  palm's fit uses it. The five-second hands line counts them ("wrists put back").
- **Files from a file provider**: a picked folder from a cloud drive or another app's remotes is
  listed through file coordination (metadata only) and walked three levels deep, without
  downloading its files. A file not on the phone is classified by its name, gets the
  provider's thumbnail or (a picture up to 25 MB) is downloaded for one, and is downloaded when
  opened ("Downloading…" on the controls), then classified from its contents. Stale bookmarks
  are renewed at launch. A provider's folders can be picked only when its extension declares
  folder picking (`NSExtensionFileProviderSupportsPickingFolders`); one that doesn't is greyed
  out in the picker.

## Tenth phone round (2026-11-08)

- **WebXR at 1:1**: the browser's text zoom laid the page out small and broke WebXR. When a page
  asks for a session, the app lays it out at 100% first and the shim waits for that (a resize
  during a session made a player end it), then starts the session; the zoom comes back when
  the session ends, or after 3 s if the page never starts one.
- **Exit button at the feet**: every WebXR session has an "Exit VR" button 1.2 m below the eyes
  and 0.55 m ahead, tilted to face them. The app places it in the session's space and hit-tests
  it; the shim draws it into both eyes over the page. It follows lazily, only once you walk
  35 cm or turn 45° away, so looking down at it doesn't move it. Look at it (it turns pink) and
  pinch or tap, or pinch with your fingers on it. The double tap still ends a session too.
- **Head smoothing**: a low-pass on the predicted head rotation, set in Settings (Off, Low,
  Medium, High, Max; Medium by default, 5.4 Hz). Half its lag is predicted back, so a steady
  turn keeps up; a jump (a recentre, a tracking switch) is taken at once. The prediction past
  the newest gyro reading now uses the last three readings' average rate instead of one.

## Eleventh phone round (2026-11-08)

- **Voice unlock's crash**: the speech permission's answer arrives on another thread, and a closure
  written inside a main-actor class is main-actor isolated, so Swift 6 stopped the app the moment
  it ran. The permission, the microphone's tap and the recognizer's results are now made outside
  that isolation (a test runs each off the main thread). A silent microphone format no longer
  raises, the audio category goes back when listening ends, and the button says why when it
  can't listen (no permission, on-device speech not installed).
- **Golf bumpers**: each wall's box was turned a quarter off its wall, so the back wall's box ran up
  the fairway over the tee and the side walls' lay across it. They now lie along the walls the
  ball bounces off; a test checks that, and that no hole's tee is near a bumper.
- **WebXR AR**: `immersive-ar` sessions. The page's view goes see-through and the app draws only the
  passthrough beneath it, in 6DoF (no switch to the ultra-wide). Everything of the page but its
  canvas is hidden for the session. Hit tests (`requestHitTestSource`, `XRRay`) land on the room's
  planes, with the floor running on past them, so a reticle always has somewhere to go. A required
  feature that can't be given rejects the session honestly.
- **The real floor**: `local-floor` starts at the height ARKit measured instead of a fixed 1.6 m, and
  it stands through the switch to 3DoF. The Exit VR button sits by the real floor too.
- **Frame rate**: the page's drawn rate is logged every five seconds, and the start page says what
  the last session averaged.
- **Four more games** (`MoreGames.swift`): Tower (drop sliding slabs on a real table, or a plinth;
  what misses breaks off), Glow garden (plants grow where you point), Orbital pong (a ball spirals
  out from a sun; palms, the gaze or a stick knock it back), Skyline drive (steer by looking, or with
  the stick; rings, pylons, three shields; the room gives way to the synthwave surroundings). A
  game can say `hidesRoom`, as the coaster does while riding.
- **The phone overlay**: the strip and its two-finger tap are gone. A cog in the top-right corner
  drops down Passthrough, 3DoF and Phone view as checked items. The rest is in Settings.
- **The place you chose stays**: it comes back at launch with no window opened, a file by name (its
  path changes with each install). The portal's and the coaster's passing worlds aren't saved, and
  the passthrough setting stands as you left it.
- **Nothing collides top or bottom**: a keyboard hangs from its window's bottom edge, tilted like a
  desk (`BrowserWindow.hanging`): it used a rough offset and sat behind the window's plane, so it
  rode up over the window. Windows hang lower (4 cm above the eyes, and the browser lower still for
  its chrome), so the bar over them stays in view, and the dock places itself below whatever hangs
  ahead, keyboards and filmstrips included.
- **A gallery**: `Tools/capture_gallery.sh` renders what each experience looks like from inside to
  `docs/gallery`, using the new `shot <name>` and `world <n>` script verbs. The marketing page's
  drawn mockups are gone in favour of these captures.

## Hands in WebXR (2026-11-08)

A page gets the wearer's hand positions only if they say so. When a page asks for a session, the
browser's bar asks "Hands for <site>?": Not now, Just this time, or Always. The answer holds the
page's request until given. Without it, the page still has the head pose, and a pinch is a plain
select. The hand button on the bar changes a site's answer: ask, always, never. A private tab
remembers nothing. See `HandAccess`.

## The keyboard's text bar (2026-11-08)

A bar across the top of the keyboard shows what is in the field, with its cursor, and left and right
arrows move it: typing and deleting happen there, so a mistake is fixed without deleting what came
after it. The address bar, Files search and a place's prompt are `TextEdit`s; a page's field is
reported by the helper (`field` messages, never logged, a password only ever as dots), which also
keeps the cursor itself for email and number inputs, since those expose no selection.

## The App Store (2026-11-08)

Listed as **Afterglow XR**, version 1.0.0, in nine languages, through rocket from this folder:
`appstore-metadata*.md` (the review phone is set on the draft directly, since this repo is public),
`.local-ci.conf` and `.local-screenshots.conf`.

- **iPhone only**: `TARGETED_DEVICE_FAMILY` has to be set on the app target, or XcodeGen's iPhone and
  iPad preset wins over the project-wide value. `telephony` in the required capabilities keeps it
  off iPads in compatibility mode too.
- **Xcode Cloud**: `ci_scripts/` is ready for a workflow. It needs `AUDIOMETA_API_KEY` set as a secret
  in the workflow's Environment; `ci_pre_xcodebuild.sh` hands it to the build phase through a file
  and fails an archive without it. Build numbers there start above the uploads made from a Mac.
- **Screenshots**: run `Tools/capture_gallery.sh` (needs the three URLs, see its header), then
  `rocket shots "Afterglow XR" --upload`. `Tools/capture_store_screenshots.sh` picks the ten shots,
  turns them for Monkr's frame, captures the watch app, and writes the `.monkr` files, which embed
  the images and so are not committed. The watch shot is framed like the rest; to redo it alone, run
  the watch part of that script, then `update-screenshots.sh --skip-capture --device watch-46mm` from
  `_shared` with the App Store Connect key in the environment.
- **The header and search result art** (iOS 27's Creative Assets): `rocket assets "Afterglow XR"
  --generate --locale all`, then `--upload --locale all`. `appstore-creative/creative.json` lays the
  phone on its side (`"landscape": true`) with the stereo view in front, on the app's own captures.
  The listing never mentions price or that the app costs nothing, in the text or in the art.
- **The tempo key**: stored once with
  `security add-generic-password -U -a "$USER" -s afterglow-audiometa-key -w`. It is masked in the app,
  not secret: all it allows is reading a free catalogue, at 100 requests a minute across all users.

## Apple Watch as a controller

`AfterglowWatch/` is a single-target watchOS app embedded in the iOS app. Its one button carries
`handGestureShortcut(.primaryAction)`, so the watch's double-tap gesture (and a tap on the
button) sends `select` to the phone over WatchConnectivity, and turning the Digital Crown sends
`scroll` with a delta. On the phone `Input/WatchReceiver.swift` turns `select` into a plain select
of what the gaze is on: never an exit, so it can't end a WebXR session or the coaster, and it
reaches a WebXR page even while the page holds the hands. `scroll` moves a media grid while one is
open, and otherwise the page. The watch's status line says "Ready: double tap to select" when
connected and "Open Afterglow on your iPhone" when not. The watch app needs no authorization; it is
reachable whenever the phone app is in the foreground.

`zsh Tools/test_watch_link.sh` proves the link on a paired iPhone and Apple Watch Simulator: the
watch presses Select and turns the crown by itself (the Debug-only launch option
`AFTERGLOW_WATCH_AUTOPRESS`), and the test passes when the phone logs them reaching its frame loop
and is still running. From a cold boot nothing arrives for about 2.5 minutes, then everything at
once. Not tried on a real watch yet: its double tap and Digital Crown are what the test can't press.

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
team detection as the Unity app's `unity/Tools/ios_build_and_run.sh`. Bundle id `com.wemiller.afterglow` (since 2026-11-06), so it
installs over the Unity app, replacing it. Warnings are errors.

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
| `headSmoothing` | 50 | how much the head's rotation is smoothed, percent (0 off; Settings: Off, Low, Medium, High, Max) |
| `camUltraWide` | 1 | prefer the ultra-wide camera's format when ARKit lists one |
| `thermalCap` | 1 | hold render scale to 80 % at "serious" and 60 %/30 fps at "critical", as the Unity app does |
| `eyesX`, `eyesY`, `eyesZ` | 60, -10, 66 | the eyes' midpoint relative to the camera, mm, camera axes (x right, y up, z back) |
| `dump` | 0 | save both eyes' textures to `Documents/eye-left.png` and `eye-right.png` this many seconds after launch |
| `ultraTest` | 0 | an experiment: open the ultra-wide through AVFoundation this many seconds in and log what ARKit does (it stops) |
| `web`, `url`, `textScale` | 1, –, 150 | the browser open at launch, a page to open, the page zoom in percent |
| `surfaces`, `occlusion` | 0, 1 | scan and show the room's surfaces; hide placed things behind the real room (LiDAR, 6DoF, passthrough) |
| `actions` | – | a test script: `wait N; press <button>; type <text>; key <Backspace\|Clear\|Enter>; look <yaw> <pitch>; tap; dump; screenshot; immersive; end; js <expr>; record <eye>; fakeplanes; fakehand <1\|0\|punch\|off>; open <window>; lock; voice; shot <name>; world <n>; press win:<window>:<move\|larger\|smaller\|minimize\|close>` |
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
app/
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
