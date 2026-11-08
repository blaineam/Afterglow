# Bill of materials

Everything the viewer in [`viewer.scad`](viewer.scad) needs that doesn't come off the printer.
The design is friction-fit, so there are no screws, magnets or glue in the build itself.

## Required

| Part | Spec to match | Qty | Notes |
|---|---|---|---|
| **Lenses** | 25 mm diameter, ~34 mm focal length, biconvex aspheric — sold as "Google Cardboard lens", "Cardboard 2.0 lens" or "VR lens 25mm 34mm" | 2 | See the caveat below |
| **Head strap** | 25 mm webbing with a tri-glide, or an elastic three-point VR strap | 1 | Threads the two 25 × 4 mm slots at the face end |
| **Face foam** | Self-adhesive EVA or memory foam, 8–10 mm thick, ~20 mm wide | ~400 mm | Cut to the face rim; comfort only, not structural |

### The lens caveat — read before buying

"Cardboard v2 lens" is a convention, not a part number. Google's
[manufacturer guidelines](https://support.google.com/cardboard/manufacturers/answer/6321873) give
the viewer geometry (39.3 mm screen-to-lens, 63.9 mm inter-lens, k₁ 0.336, k₂ 0.553) but the lens
itself is specified only as the 2015 Cardboard's, and sellers' focal lengths vary between about
34 and 45 mm under the same name.

This matters because the app's distortion correction is built from those coefficients. A lens with a
different focal length will still show a picture, but the correction will be slightly wrong — which
is exactly what the focus wheel and the app's focus offset are for: slide the carriage until the
image is sharp, then set the offset in the settings panel to match so the geometry agrees with the
optics.

**Buy 34 mm focal length if the listing states one.** If it doesn't, assume it may be off and plan
to use the offset.

Search links (these are searches, not endorsements — check the stated focal length):
- [AliExpress — VR lens 25mm](https://www.aliexpress.com/w/wholesale-vr-lens-25mm-34mm.html)
- [Amazon — Google Cardboard lens](https://www.amazon.com/s?k=google+cardboard+replacement+lens+25mm)
- [eBay — Cardboard VR lens](https://www.ebay.com/sch/i.html?_nkw=google+cardboard+vr+lens+25mm)

Salvaging the pair out of a cheap plastic Cardboard-style viewer is often cheaper than buying
lenses loose, and those are the right lenses by construction.

## Recommended

| Part | Why | Qty |
|---|---|---|
| **Counterweight** | The iPhone 18 Pro Max is 249 g against the 15 Pro's 187 g, +33%, all of it on a lever in front of the face. A 100–150 g weight at the back of the strap balances it and is the difference between twenty minutes and five. Lead tape, a roll of coins in tape, or a small power bank | 1 |
| **Top strap** | Takes the load off the cheekbones once the phone is this heavy | 1 |

Focus carriage sliding on its own? The printed fix is in [focus-brake/](focus-brake/).

## Not needed

- **No magnet or trigger.** Classic Cardboard viewers have one because the phone's screen is
  unreachable. This app's input is gaze plus a pinch in front of the rear camera, which the open
  back leaves clear, so there is nothing to press. The matching viewer profile declares
  `ButtonType.None`.
- **No screws or nuts.** The carriage slides in channels and the door is a ring with one bar
  across the middle of the phone's back, which drops into a recess. Both ends of the phone stay
  open, which is how the rear camera is kept clear without needing the camera island's dimensions.
- **No lens spacers.** The focus carriage is the adjustment.

## Parked

Two features are deferred, and neither needs anything bought yet:

- **A WiFi HDMI encoder box** (HDMI → RTSP/SRT over the network) would put a Switch or a PC on the
  virtual screen. The iPhone cannot take a USB capture card at all — external UVC cameras are iPad
  only — so a network encoder is the only route on this phone.
- **SteamVR streaming** via an ALVR client needs a PC, not a part.

## Print notes

| Part | Orientation | Supports |
|---|---|---|
| `body` | Open face down on the plate | None |
| `plate` | Flat | None |
| `door` | Flat | None |

PLA is fine; PETG if it will sit in a car. 0.2 mm layers, 3 perimeters, 15% infill. The only
dimension worth a test print is the carriage fit — print `plate` first and check it slides in the
body's channels before committing to the whole body.
