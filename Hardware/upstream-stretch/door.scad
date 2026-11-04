// The door, remade for an iPhone 18 Pro Max.
//
// This does NOT reuse upstream's plate. It keeps the stretched door's frame -- the outline, the
// flange, the hinge knuckles and the latch tabs, which are what the shell mates with -- fills the
// plate solid, and then cuts a new interior: a hex dot field, an opening shaped to this phone's
// camera island, a MagSafe ring groove, and four integral anchors that locate the phone.
//
// Earlier versions kept upstream's plate and cut into it. That is why the camera opening had a
// step in its lower edge (upstream's own opening, for an iPhone 15 Pro island, unioning with the
// new one) and why the dot field came out as rows of dashes (the cut-and-bridge stretch extrudes
// whatever sits on a cut plane, and the dots sit on the cut planes). Both are gone: nothing of
// upstream's plate survives.
//
// EVERY PHONE FIGURE COMES FROM APPLE'S DRAWING
// (developer.apple.com/accessories/dimensional-drawings/, iPhone 18 Pro Max, sheet 2026-09-09),
// read as described in README.md. Two earlier readings of the camera island were wrong and both
// cost a printed part; the third was checked by plotting the drawing's own paths on a millimetre
// grid in the phone's coordinates and reading the island off it:
//
//   island walls          across 3.93 and 74.05      (70.12 wide, centred on the phone)
//   island ends           along  4.87 and 43.10      (38.23 long)
//   island corner radius  about 12 .. 15             (12 used: a smaller radius cuts FURTHER out)
//
// The reading before that had the island 70.41 x 44.94 running from along 0, which is 6 mm too
// long and starts 4 mm too high -- it cut away the whole camera end of the door.

include <phone.scad>

SRCDIR = "..";
SRC = str(SRCDIR, "/Door - Print-ready STLs - iPhone 15 Pro/Door - iPhone 15 Pro (PETG, outer face down).stl");

yc = 55; dy = 6;        // the shell's cut planes and inserts, exactly
xc = 26; dx = 3.5;
big = 400;

fit       = 0.6;        // clearance around the phone
plate_top = 1.9;        // the face the phone rests on

// The door's own body, measured off the stretched outline at 1 mm steps along both ends: a rounded
// rectangle that matches to +-0.10 mm everywhere except where the hinge knuckles and latch tabs
// stand out. Everything built here is clipped to it, so nothing can stand proud of the door.
body_x0 = -42.90; body_x1 = 41.20;
body_y  =  85.59; body_r  = 13.58;

// Where the phone's centre sits in the door's own coordinates. The door is asymmetric -- hinge
// knuckles down one long side, latch tabs down the other -- so its outline is offset from the bay
// it covers. Read off upstream's locator pockets, which are symmetric about the phone.
phone_cx = -0.855;

// The camera island, in the door's own coordinates: x = across - 39.845, y = 81.715 - along.
island_x0 = -36.055; island_x1 = 34.365;
island_y0 =  38.615; island_y1 = 76.845;
island_r  =  12.00;
island_margin = 1.20;

cam_r  = island_r;                       // not grown with the margin, so the corners cut further out
cam_x0 = island_x0 - island_margin;      // -37.255
cam_x1 = island_x1 + island_margin;      //  35.565
cam_y0 = island_y0 - island_margin;      //  37.415
cam_y1 = island_y1 + island_margin;      //  78.045

// MagSafe. Apple puts the magnet array at 57.50 across, centred on the dead centre of the back to
// within 5 microns. An annular GROOVE rather than a circular recess, for two reasons: an adhesive
// metal ring is a ring, and the door prints outer face down, so a full 58 mm recess would leave
// the plate above it bridging 58 mm over the dot field with nothing underneath.
magsafe_od    = 58.00;   // 57.50 plus 0.5, so a ring drops in rather than being pressed
magsafe_id    = 44.00;
magsafe_depth = 0.80;

// The dot field. Upstream's door is a hex-packed field of round holes with solid zones around the
// border, the camera opening and the MagSafe ring; this keeps that, with two dot sizes so the
// field fades out at its edges the way theirs does.
dot_pitch = 3.40;
dot_big   = 2.20;
dot_small = 1.40;
dot_fade  = 2.60;        // width of the small-dot band at the field's edge
dot_inset = 1.00;        // how far inside the phone's own outline the field stops
dot_clear = 2.60;        // solid margin kept around the camera opening
ring_r0   = 20.50;       // solid annulus for the MagSafe ring
ring_r1   = 30.50;

// The anchors: four integral PETG ribs standing on the plate just outside the phone's outline, at
// the corners. They are what locates the phone now that there are no TPU locators.
//   The sizes are the bay's, measured on the stretched shell in this frame: it runs -40.80 .. 39.15
// across for its whole straight length, against a phone at -39.845 .. 38.135, so there is about
// 1.0 mm a side -- and its camera-end wall stands at y 83.05, 1.335 mm beyond the phone. The
// corners are where the room is: by |y| = 74 the phone's own corner has curved in far enough to
// leave 2.2 mm.
anchor_gap = 0.35;
anchor_w   = 0.80;
anchor_y0  = 74.00;
anchor_top = 5.00;

// ---------------------------------------------------------------- the stretched upstream frame

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

// ---------------------------------------------------------------- 2-D helpers

module rr(x0, x1, y0, y1, r) {
    hull() for (x = [x0 + r, x1 - r], y = [y0 + r, y1 - r])
        translate([x, y]) circle(r = r, $fn = 72);
}

module body(k = 0) { offset(r = k) rr(body_x0, body_x1, -body_y, body_y, body_r); }
module opening_2d(k = 0) { offset(r = k) rr(cam_x0, cam_x1, cam_y0, cam_y1, cam_r); }
module phone_2d(k = 0) { translate([phone_cx, 0]) phone_plan(k); }

// Where dots are allowed: inside the phone's footprint, clear of the opening and the MagSafe ring.
module field(k = 0) {
    difference() {
        intersection() { offset(r = k) phone_2d(-dot_inset); body(-2.0); }
        opening_2d(dot_clear);
        difference() {
            translate([phone_cx, 0]) circle(r = ring_r1, $fn = 160);
            translate([phone_cx, 0]) circle(r = ring_r0, $fn = 160);
        }
    }
}

module dots(d) {
    for (j = [-30 : 30]) {
        yy = j * dot_pitch * 0.8660254;
        off = (j % 2 == 0) ? 0 : dot_pitch / 2;
        for (i = [-16 : 16])
            translate([phone_cx + i * dot_pitch + off, yy]) circle(d = d, $fn = 16);
    }
}

// ---------------------------------------------------------------- the part

module plate() {
    linear_extrude(height = plate_top) body();
}

module dot_holes() {
    translate([0, 0, -1])
        linear_extrude(height = plate_top + 2) {
            intersection() { dots(dot_big); field(-dot_fade); }
            intersection() { dots(dot_small); difference() { field(); field(-dot_fade); } }
        }
}

module camera_opening() {
    translate([0, 0, -big / 2]) linear_extrude(height = big) opening_2d();
}

module magsafe_groove() {
    translate([phone_cx, 0, -0.01])
        linear_extrude(height = magsafe_depth + 0.01)
            difference() {
                circle(d = magsafe_od, $fn = 200);
                circle(d = magsafe_id, $fn = 200);
            }
}

module anchors() {
    translate([0, 0, plate_top])
        linear_extrude(height = anchor_top - plate_top)
            intersection() {
                difference() {
                    phone_2d(anchor_gap + anchor_w);
                    phone_2d(anchor_gap);
                }
                body(-0.2);
                union() {
                    translate([-big / 2, anchor_y0]) square(big);
                    translate([-big / 2, -anchor_y0 - big]) square(big);
                }
            }
}

difference() {
    union() {
        grown();
        plate();
        anchors();
    }
    // Clear everything standing above the plate inside the phone's footprint: upstream's rim is
    // sized for a 70.6 x 146.6 phone and would hold this one out rather than in.
    translate([0, 0, plate_top]) linear_extrude(height = big) phone_2d(fit / 2);
    camera_opening();
    magsafe_groove();
    dot_holes();
}
