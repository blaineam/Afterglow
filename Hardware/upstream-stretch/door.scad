// The door, remade for an iPhone 18 Pro Max.
//
// Four changes to upstream's iPhone 15 Pro door:
//   1. stretched +7 across and +12 along, on the same planes and by the same amounts as the shell
//      and carriage, so the hinge knuckles and latch tabs still line up with the shell's;
//   2. anything standing above the plate inside the phone's footprint is cleared, because the
//      upstream rim is sized for a 70.6 x 146.6 phone and this one is 78.0 x 163.4 -- it would
//      hold the phone out rather than hold it in;
//   3. the camera opening is cut to clear the camera plateau, and the plate is filled back in
//      around it so a rim survives all the way round the camera end;
//   4. a retaining collar stands up outside the phone's outline at the camera end, in place of the
//      two TPU corner locators that used to go there and no longer can.
//
// On (3) and (4): the dimensions come from Apple's own drawing -- the Accessory Design Guidelines
// point at a per-device library, and iPhone 18 Pro Max is published there as a dimensioned
// mechanical drawing (developer.apple.com/accessories/dimensional-drawings/, sheet dated
// 2026-09-09). It gives the body as 163.43 x 77.98 x 8.75, every imaging feature's centre and
// diameter, and the plateau standing 2.78 mm proud of the back plate with the camera glass 2.11 mm
// above that.
//
// THE PLATEAU IS THE PHONE'S OWN OUTLINE, INSET. That is the thing two earlier passes got wrong,
// in two different ways, and both mistakes cost a printed part:
//
//   - the first read the plateau as running 0.8 .. 75.8 across. That is the ANTENNA KEEPOUT, a
//     hatched region on the same sheet marked "do not obstruct with metal or other conductive
//     material (full product volume including sidewalls)". It runs the full width and a little
//     past it, which is exactly why it looked like a full-width plateau. A PETG door is not
//     conductive and may cover it freely.
//   - the second read it as a rectangle 3.79 .. 74.20 across by 0 .. 48.87 along, and modelled the
//     opening as a rounded rectangle. The across figures are right -- they are the plateau wall
//     and its chamfer, and they check out at 3.79/3.84/3.89 and 74.09/74.15/74.20 -- but reading
//     them as a rectangle starting at along 0 put the plateau hard against the phone's camera end,
//     and cutting that away took the door's whole end with it.
//
// Sampling the drawing's paths across the phone shows the same inset on every side: 3.79 .. 3.93
// from each side wall AND 3.93 from the camera end. The plateau is the phone's outline brought in
// about 3.8 mm, closed off at along 48.87. So the opening is cut the same way -- `phone_plan`
// shrunk by the rim -- and the rim it leaves is the same width all the way round the camera end
// instead of running off it.

include <phone.scad>

SRCDIR = "..";
SRC = str(SRCDIR, "/Door - Print-ready STLs - iPhone 15 Pro/Door - iPhone 15 Pro (PETG, outer face down).stl");

yc = 55; dy = 6;        // the shell's cut planes and inserts, exactly
xc = 26; dx = 3.5;
big = 400;

// Apple's figures. `phone_x` and `phone_y` come from phone.scad.
fit       = 0.6;         // clearance around the phone
plate_top = 1.9;         // everything above this, inside the footprint, is cleared

// The camera plateau. `plateau_inset` is how far its wall stands inside the phone's outline, and
// `plateau_far` is how far it reaches from the camera end. The lens centres Apple dimensions
// exactly (cameras at 14.37/14.37, 14.37/33.61 and 32.49/23.99, all 16.58 across; flash and rear
// sensor at 64.16/13.82 and 64.16/34.16, both 6.90) sit inside this, so clearing the plateau
// clears every one of them.
plateau_inset  = 3.79;   // the innermost of the three concentric lines: the safe one to trust
plateau_far    = 48.87;
plateau_margin = 1.2;    // clearance around the plateau

// Where the phone's centre sits in the door's own coordinates. It is not the door's centre: the
// door is asymmetric, with the hinge knuckles down one long side and the latch tabs down the
// other, so its outline is offset from the bay it covers. The figure is read off the door's own
// locator pockets, which are symmetric about the phone: they span -38.58 .. 36.87 across, whose
// middle is -0.855. Leaving this out skews every phone-referenced feature by that much.
phone_cx = -0.855;

// The rim the opening leaves over the phone, all the way round the camera end.
rim_w  = plateau_inset - plateau_margin;          // 2.59
cam_y0 = phone_y / 2 - plateau_far - plateau_margin;

// The plate filled back in at the camera end. The method only ever moves material, it never adds
// any, and upstream's door has no plate this far out -- its own camera opening is a corner square
// for the iPhone 15 Pro's island, so the end of its plate is both narrower and shorter than this
// phone needs. Without this there is nothing for the rim to be cut from.
//   The bounds stay inside the door's own outline, and short of its end at 85.59 so the fill never
// stands proud. The 2 mm perforation grid stops at 31.35 across, so the only perforations this
// closes are the few the opening would have taken anyway.
//   The x bounds also have to clear the door's own pocket walls rather than stop just inside them:
// at -42.00 and 40.50 they landed 0.31 and 0.11 mm short of faces at -42.311 and 40.605, and the
// two slivers left over came out as inside-out shells -- the part reported as three.
//   Two pieces. `side_` is the strip down the latch side, which has to go back whatever else
// happens: upstream's own camera opening is a corner square offset to that side, and stretched it
// reaches 40.37 across -- wider than this opening -- so without the strip the hole never narrows.
// `end_` is the camera end proper, which is new.
side_x0 =  35.55; side_x1 = 41.00;
side_y0 =  24.00; side_y1 = 85.00;
end_x0  = -42.60; end_x1  = 41.00;
end_y0  =  60.00; end_y1  = 85.00;

// Both are clipped to the door's own outline, because a plain rectangle squares off its rounded
// camera-end corner: measured against the stretched outline, a fill reaching 41.00 stands 9.40 mm
// proud at y 85. The outline there is two straight sides at -42.90 and 41.20 closing on a 13.58
// corner radius at y 85.59 -- a fit good to 0.02 mm at every y from 75 to 85.
door_x0 = -42.90; door_x1 = 41.20;
door_end = 85.59; door_r = 13.58;
fill_inset = 0.20;       // so the fill stops just short of the outline rather than on it

// The retaining collar. It stands outside the phone's outline, on the filled plate, and takes over
// from the two camera-end TPU locators -- which cannot work here, whatever they are made of:
// upstream's locator is 15.87 mm wide, and the part of the pocket that would hold one lies under
// the camera plateau, which has to be cut through. A rigid lip at a known clearance is what fits.
//
// Every number here is the bay's, measured on the stretched shell in this frame rather than taken
// from the 80.00 x 166.18 the bay is nominally. The bay runs -40.80 .. 39.15 across for its whole
// straight length and its camera end wall stands at y 83.05, so:
//
//   down the sides, outboard of the phone      0.955 mm (left), 1.015 mm (right)
//   across the end, beyond the phone's 81.715  1.335 mm
//
// The end is what binds, and 0.35 + 0.80 leaves 0.185 mm to the bay there. That is also the whole
// retention gain: the phone could travel 1.335 mm toward the camera end before the shell stopped
// it, and now it travels 0.35.
//
// (An earlier pass put the collar at 0.40 + 0.90 from y 60, off a reading of 1.87 mm taken at
// y 70 -- which happens to be one of two local pockets in the bay wall, not the wall. The collar
// stood 0.28 mm into the shell for 9 mm of its length.)
//
// `collar_gap` also has to clear the rim-clearing cut below, which takes fit/2 = 0.30.
collar_gap = 0.35;
collar_w   = 0.80;
collar_y0  = 74.00;      // where the phone's corner has curved far enough in to leave 2.2 mm
collar_top = 4.50;

// MagSafe. Apple's drawing puts the magnet array at 57.50 across, centred 38.99 across and 81.72
// along -- the dead centre of the phone's back to within 5 microns. This is a groove in the outer
// face for a ring to sit in and be located by, not a hole: the plate is 1.9 mm thick here and
// Apple's note 8 allows a case up to 2.1 mm on the back for full functionality, so MagSafe already
// works through it and cutting through would only throw away the plate that holds the phone.
//   It is an annular GROOVE, not a circular recess, and that is a printing constraint rather than
// a design preference. The door prints outer face down, so a recess in this face is a pocket that
// opens downward: a full 58 mm circle leaves the plate above it bridging 58 mm with nothing
// underneath, over a region that is perforated, so the bridge lines break at every 2 mm hole.
// Measured on the mesh it was 2090 mm2 of unsupported ceiling, the only such area in the part.
// A groove leaves the middle sitting on the plate from the first layer and the bridge is one
// 7 mm span, anchored both sides. A ring is a ring; the groove locates its outer diameter, which
// is the only face that has to be located.
magsafe_d      = 57.50;
magsafe_clear  = 0.5;    // so a printed ring drops in rather than having to be pressed
magsafe_id     = 44.00;  // the groove's inner wall: takes any ring with ID >= 44 and OD <= 58
magsafe_depth  = 0.8;    // of the 1.9 mm plate, leaving 1.1

// The locator pockets, as the stretch leaves them: upstream's are at -38.58..-24.48 and
// 21.47..36.87 across and +-56.92..78.72 along, and each edge moves by the same rule as everything
// else (past -26 by -3.5, past 26 by +3.5, past +-55 by +-6). They have to be cut again because
// the plate is filled back in below, which would otherwise close them.
//   Only the USB-end pair. The camera-end pair are gone: see `collar_gap` above.
pocket_r = 2;
pockets = [
    [-42.08, -24.48, -84.72, -62.92],
    [ 21.47,  40.37, -84.72, -62.92],
];

module src() { import(SRC, convexity = 12); }
module sec_y(y) { projection(cut = true) translate([0, 0, -y]) rotate([90, 0, 0]) src(); }
module half_y(lo, hi) { intersection() { src(); translate([0, (lo + hi) / 2, 0]) cube([big, hi - lo, big], center = true); } }
module grown_y() {
    half_y(-yc, yc);
    translate([0,  dy, 0]) half_y(yc, big);
    translate([0, -dy, 0]) half_y(-big, -yc);
    translate([0, yc, 0]) rotate([-90, 0, 0]) linear_extrude(height = dy) sec_y(yc);
    translate([0, -yc - dy, 0]) rotate([-90, 0, 0]) linear_extrude(height = dy) sec_y(-yc);
}
module sec_x2(x) { projection(cut = true) translate([0, 0, -x]) rotate([0, -90, 0]) grown_y(); }
module half_x(lo, hi) { intersection() { grown_y(); translate([(lo + hi) / 2, 0, 0]) cube([hi - lo, big, big], center = true); } }
module grown() {
    half_x(-xc, xc);
    translate([ dx, 0, 0]) half_x(xc, big);
    translate([-dx, 0, 0]) half_x(-big, -xc);
    translate([xc, 0, 0]) rotate([0, 90, 0]) linear_extrude(height = dx) sec_x2(xc);
    translate([-xc - dx, 0, 0]) rotate([0, 90, 0]) linear_extrude(height = dx) sec_x2(-xc);
}

module rrect(w, l, h, r = 6) {
    hull() for (sx = [-1, 1], sy = [-1, 1])
        translate([sx * (w / 2 - r), sy * (l / 2 - r), 0]) cylinder(h = h, r = r, center = true, $fn = 48);
}

// Everything above the plate inside the phone's own footprint. Shaped like the phone rather than
// like a rounded rectangle, so it agrees with the collar at the corners.
module phone_above(extra) {
    translate([phone_cx, 0, plate_top])
        linear_extrude(height = big) phone_plan(extra);
}

// The camera opening: the phone's outline brought in by the rim, from the plateau's far edge out
// past the camera end. Cut through, because the plateau stands 2.78 mm proud of the phone's back
// and the plate is only 1.9 thick.
module camera_opening() {
    intersection() {
        translate([phone_cx, 0, -big / 2]) linear_extrude(height = big) phone_plan(-rim_w);
        translate([-big / 2, cam_y0, -big / 2]) cube(big);
    }
}

// The door's own outline over the camera end, as a 2-D shape to clip the fills with.
module end_outline() {
    offset(r = -fill_inset) hull() {
        for (x = [door_x0 + door_r, door_x1 - door_r], y = [0, door_end - door_r])
            translate([x, y]) circle(r = door_r, $fn = 96);
    }
}

module fill_box(x0, x1, y0, y1) {
    translate([0, 0, plate_top / 2])
        linear_extrude(height = plate_top, center = true)
            intersection() {
                translate([x0, y0]) square([x1 - x0, y1 - y0]);
                end_outline();
            }
}

module end_fill() {
    fill_box(side_x0, side_x1, side_y0, side_y1);
    fill_box(end_x0, end_x1, end_y0, end_y1);
}

module end_collar() {
    translate([0, 0, plate_top])
        linear_extrude(height = collar_top - plate_top)
            intersection() {
                difference() {
                    translate([phone_cx, 0]) phone_plan(collar_gap + collar_w);
                    translate([phone_cx, 0]) phone_plan(collar_gap);
                }
                translate([-big / 2, collar_y0]) square(big);
            }
}

difference() {
    union() {
        grown();
        end_fill();
        end_collar();
    }

    // (2) Clear the old rim: it is sized for a much smaller phone.
    phone_above(fit / 2);

    // (3) The camera opening.
    camera_opening();

    // The MagSafe ring's groove, in the outer face, which is at z = 0 because the source STL is
    // the "outer face down" one.
    translate([phone_cx, phone_y / 2 - 81.72, 0])
        difference() {
            translate([0, 0, -0.01])
                cylinder(h = magsafe_depth + 0.01, d = magsafe_d + magsafe_clear, $fn = 160);
            translate([0, 0, -0.02])
                cylinder(h = magsafe_depth + 0.03, d = magsafe_id, $fn = 160);
        }

    // The USB-end locator pockets, reopened through the fill.
    for (k = pockets)
        translate([(k[0] + k[1]) / 2, (k[2] + k[3]) / 2, 0])
            rrect(k[1] - k[0], k[3] - k[2], big, pocket_r);
}
